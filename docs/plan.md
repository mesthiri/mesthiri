# mesthiri — implementation plan

Status: living document, created 2026-09-04, re-sequenced 2026-09-04 (agent
before triage; GitHub App identity; then agent containment, command surface,
eligibility policy, output validation). [design.md](design.md) is the design
authority — this file only sequences it. Update the checkboxes and the
"reality check" notes as milestones land; a milestone's scope changes belong
in design.md first.

Ground rules for the whole plan: Kaappi ≥ 0.26 (`(kaappi process)` is
assumed everywhere, KEP-0022 Final), every stage lands with tests runnable
via `kaappi --lib-path ./lib tests/test-<module>.scm`, exactly one agent run
is in flight at a time process-wide, no agent runs outside its sandbox, and
each milestone ends in something *demonstrable*, not a pile of modules.

## M0 — Project setup and recon

Two of these are human-only; one is in another repo. Start them first,
because M1 and M2 each block on one.

- [x] Repo seeded: README, design.md, CLAUDE.md, kaappi.pkg, MIT license
- [x] Design unblocked: kaappi v0.26.0 shipped KEP-0022; shim plan removed
- [ ] **GitHub App registration** (human-only): register the `mesthiri` App
      under the `mesthiri` org; permissions Contents / Pull requests /
      Issues: write, Metadata: read, and **no** merge-granting permission;
      subscribe to `issues`, `issue_comment`, `pull_request`,
      `pull_request_review`; generate and store the private key and webhook
      secret. No machine account, ToS acceptance, or 2FA enrolment is
      needed — the App acts as `mesthiri[bot]`.
- [ ] **RS256 in `kaappi-crypto`** (other repo, blocks M1): the ecosystem
      has digests and HMACs only, and App auth needs an RS256-signed JWT.
      Add RSA sign/verify over OpenSSL's `EVP_DigestSign` (OpenSSL is
      already linked there), release, then add `kaappi-crypto` to
      `kaappi.pkg`. File it as an issue on `kaappi/kaappi-crypto` and track
      it here — it is a cross-repo release on mesthiri's critical path.
- [ ] **pi recon** (blocks M2): install pi, pin the exact version in config,
      and capture its *actual* `--rpc` frame schema — a handshake, a tool
      call, a completion, an error — into `docs/pi-rpc.md` plus a recorded
      fixture under `tests/fixtures/`. `agent.sld` gets written against
      observed frames, not assumed ones. Note what pi needs from the
      filesystem and network while you are there — M2's sandbox policy is
      written from that list.
- [ ] Sandbox target: create `mesthiri/sandbox` (a small real-but-disposable
      repo with its own test command) and seed it with issues; install the
      App on it. This is M5's demo target.
- [ ] Org hygiene: DCO app + branch protection on `mesthiri/mesthiri`
      before any outside PR
- [ ] CI: `.github/workflows/ci.yml` — install the released kaappi binary,
      run the test suite on push/PR (mirror the kaappi-* ecosystem repos'
      inline style)

## M1 — Foundations: forge, store, config

The plumbing every stage shares. No agent, no writes to any forge yet.
Blocked on M0's `kaappi-crypto` release for the App credential provider —
the PAT provider is written first so the rest of M1 can proceed meanwhile.

- [ ] `lib/mesthiri/forge.sld` — GitHub REST client over `kaappi-http` +
      `kaappi-json`: issues (list/get/comment/label), pulls
      (create/list/get), repos. Takes a **credential provider** ("token for
      repo X"). Two providers behind one interface: a PAT provider for local
      development and fixtures, and the **App installation-token provider**
      that is the default in deployment — RS256 JWT from the App private
      key, exchanged for an installation token, cached and refreshed before
      expiry. Pagination and rate-limit headers handled here and nowhere
      else.
- [ ] `lib/mesthiri/store.sld` — `kaappi-sqlite` schema: issues seen +
      cursor, triage verdicts (with intent tier), queue claims, pipeline
      runs (stage timings, spend, outcome), handled delivery and comment
      ids, workflow label transitions, retro facts. Migrations as numbered
      scripts run at startup.
- [ ] `lib/mesthiri/config.sld` — one config file (targets and their rubric
      paths, App id / key path / webhook secret path, budgets, cadences,
      pinned pi version, per-target **path denylist**, command permission
      thresholds, sandbox egress allowlist); `kaappi-cli` for the entry-point
      flags. Startup validation rejects a triage target with no rubric path,
      and refuses to start if a denylist is missing where the code stage is
      enabled.
- [ ] `lib/mesthiri/log.sld` — thin wrapper over `kaappi-log`: every log
      line carries stage + target repo + run id.

**Demo:** `mesthiri sync <owner/repo>` populates the store from a public
repo read-only and prints a summary table; `mesthiri whoami` shows which
installation it is authenticated as and the remaining rate limit. Tests hit
recorded fixtures, not the network; one live read-only smoke test is tagged
and skipped in CI.

## M2 — Agent integration and containment

Moved ahead of triage: triage's whole value is verifying an issue's claims
against the code, and that needs the agent. Building the agent first means
triage is written once, correctly.

- [ ] `lib/mesthiri/agent.sld` — the one module that touches the coding
      agent: `spawn-process '("pi" "--rpc") …` with `'pipe` stdin/stdout,
      `'null` stderr, `new-group: #t`; JSON framing over the ports from a
      drive fiber, against the schema captured in M0; per-run wall-clock
      deadline (`process-wait 'timeout:` → `process-kill 'group: #t`),
      token/turn budget passed to pi; run record written to the store win or
      lose.
- [ ] **Containment** — the agent is spawned inside a namespace sandbox
      (`bwrap`/`unshare`) and `agent.sld` is the only place that can spawn
      it, so no stage can produce an uncontained run: read-only root, the
      scratch clone as the only writable mount, the secrets directory
      outside the mount namespace, egress denied by default with an
      allowlist from config, separate unprivileged uid. macOS runs
      uncontained and warns loudly at startup; Linux is the deployment
      target.
- [ ] **Output validation** — every agent response validated against a
      declared schema *outside* the agent, capped retries, then hard-fail.
      No unvalidated output reaches stage code.
- [ ] Serial execution enforced here: a single agent slot the stages
      acquire, so no caller can start a second run. Budgets are counted in
      one place because there is only one place.
- [ ] Backend interface documented in design.md (settle its open question:
      pi's RPC schema as-is vs. a mesthiri envelope) — decide when the
      second consumer appears, but keep pi-specific names out of stage code
      now.
- [ ] Prompt hygiene: issue/PR text enters prompts only inside an explicit
      untrusted-data block; never into argv.

**Demo:** `mesthiri agent-smoke` — spawn pi, run a trivial task in a
scratch dir, show the event stream, kill on deadline, print the run record.
The same command in `--prove-sandbox` mode asserts the boundary rather than
describing it: the agent cannot read the secrets directory, cannot write
outside its scratch clone, and cannot reach a host that is not on the
allowlist. Those three are tests, not a paragraph.

## M3 — Triage stage (first forge-visible value)

Cron-driven and one module wide. The `priority:` label triage writes is a
plain forge call — the workflow label *state machine* is M4's problem, and
triage does not need it to be useful.

- [ ] `lib/mesthiri/triage.sld`: for each unseen issue — verify the issue's
      claims against a checkout using the M2 agent, classify per the rubric
      read from the *target repo* at its configured path (first target:
      kaappi org's `docs/dev/github-issues.md`, exactly one `priority:`
      label), propose an **intent tier** (0 pre-authorized / 1 issue
      suffices / 2 needs explicit human authorization), and record verdict +
      one-paragraph rationale + tier + the rubric file's commit SHA in the
      store.
- [ ] **Dry-run first**: `mesthiri triage --dry-run` prints proposed
      labels/rationales without writing to the forge. This is the mode CI
      exercises and the mode the first live target runs in for a while.
- [ ] Live mode: apply label + post rationale comment as `mesthiri[bot]`.
- [ ] Red-team fixture in the test suite from day one: an issue whose body
      tries to instruct the agent, asserted to change no verdict.
- [ ] Scheduling: reactor timer loop inside the service *and* a
      `mesthiri triage --once` entry point so a systemd timer or cron can
      drive it externally; pick one as default at deploy time.

**Demo:** nightly dry-run against kaappi/kaappi producing verdicts that the
org owner spot-checks; graduation to live labels is a config flip.

## M4 — Commands and workflow labels

The first time a human can ask mesthiri for something directly, and the
first time its state is legible without reading its database. Split out of
M3 because triage is worth shipping on its own, and because these three
modules are a coherent piece of work rather than an appendix to a stage.

- [ ] `lib/mesthiri/event.sld` — one **normalized event** every trigger
      funnels into (cron tick, queue item, forge event), with delivery
      behind a **driver**. The polling driver lands here. It arrives with
      commands rather than with triage on purpose: cron alone would make it
      a one-consumer abstraction, which is a guess dressed as a design —
      commands give it a real second shape to satisfy. M6's webhook
      receiver then slots in as the second delivery driver, and the stages
      never learn which one woke them.
- [ ] `lib/mesthiri/command.sld` — `/triage`, `/implement`, `/review`,
      `/fix`, `/retro` parsed by a plain grammar, never by a model.
      Authorized against the **commenter's** permission on the target repo
      (write+ to mutate, triage+ for read-only), restricted to the entity
      where their inputs exist, de-duplicated by comment id, and answered
      with an explicit refusal comment when unauthorized. Tests include a
      command-shaped string inside an issue body that must not execute.
- [ ] `lib/mesthiri/labels.sld` — the workflow label state machine:
      declared legal transitions, mutual exclusion, write-then-read-back
      confirmation, transitions recorded in the store, and the
      clear-downstream-on-new-commit rule implemented here even though the
      approval it protects does not exist until M6.
- [ ] Triage re-enters through the command path, so `/triage <issue>` and
      the nightly cron run reach the same code by different doors.

**Demo:** `/triage` on a single issue returns a verdict on demand; the same
command from an account without triage permission is refused with a comment
explaining why; an illegal label transition is rejected rather than written.

## M5 — Code stage

- [ ] **Eligibility gate before anything is spawned**: refuse tier-2 issues
      without explicit human authorization, and refuse to open a PR whose
      diff touches a denylisted path. Both refusals are comments explaining
      which rule fired, not silence.
- [ ] Queue claim from the store; fresh clone per issue under a scratch
      root; `run-process` for git/gh (never a shell).
- [ ] Drive the agent to an implementation with tests; run the *target
      project's own* test command; iterate within budget.
- [ ] PR: branch push as the App installation, commits `-s` +
      `Co-authored-by`, PR body links the issue and the pipeline run; one
      issue, one PR; **never merge**.
- [ ] Failure honesty: a run that can't reach green tests files its state
      as a comment on the issue, not a broken PR.

**Demo:** one real closed-loop PR on `mesthiri/sandbox` — seeded issue in,
reviewed PR out, with the pipeline run record to show for it. A second
seeded issue asks for a change to a denylisted path and is refused with a
comment; a third is tier 2 and waits for a human.

## M6 — Review + Fix stages

- [ ] Webhook receiver as the **second event driver** behind M4's
      normalized event: `kaappi-http` server endpoint, HMAC-SHA256 verification of the
      raw body against the App's webhook secret, delivery-id
      de-duplication, body-size cap, rapid-fire edits debounced into one
      run, payloads handed onward as untrusted data. Commands and stages
      are unchanged by its arrival — that is the test. Public inbound
      surface, behind a reverse proxy with TLS (M8 provisions it).
- [ ] Stale-approval rule enforced: a new commit clears every downstream
      workflow label, so `ready-for-merge` cannot outlive the head that
      earned it.
- [ ] Review: per-dimension agent passes (correctness, security,
      performance, intent alignment); each pass re-derives the intent tier
      from the diff independently, so a change that grew past its
      authorization is caught by something other than the agent that wrote
      it; adversarial verification before posting; findings as PR comments
      (the App has no approve/merge permission, and mesthiri's principle is
      that humans gate anyway).
- [ ] Fix: consume findings on mesthiri-authored PRs, push fixes, re-run
      tests, bounded iteration depth, then hand to a human.

## M7 — Prioritize + Retro

- [ ] Prioritize: rank triaged issues into the ready queue (target's own
      rubric first, RICE fallback), on a cron cadence.
- [ ] Retro: mine pipeline runs for timings/iteration/failure patterns;
      file improvement proposals as issues on mesthiri itself.

## M8 — Deployment hardening

- [ ] Single binary via `zig build -Dbundle-src=mesthiri.scm`; systemd
      unit + timer files under `deploy/`.
- [ ] Server provisioning notes (a small DO droplet suffices); `bwrap`
      present and unprivileged user namespaces enabled; the agent's
      unprivileged uid; public hostname + TLS termination for the webhook
      endpoint; secrets layout (App private key and webhook secret on disk,
      mode 0600, owned by the service uid and outside the agent's mount
      namespace, never in the store).
- [ ] Observability: `mesthiri status` reading the store; nightly summary
      comment or email (kaappi-email) — optional.

## Later / explicitly deferred

- Concurrent agent runs (a worker pool), justified by real M7 retro timings
  rather than by anticipation.
- Stronger isolation than namespaces (microVM per run) if the threat model
  or the target set outgrows a single-operator droplet.
- Golden-set evals for triage verdicts and review findings — prompts are
  currently regression-tested only by the red-team fixture and the M3 test
  suite. Worth doing once verdict volume makes drift measurable.
- Per-stage harness files (prompt, tools, budget as one versioned unit) if
  inline prompts in stage modules start drifting apart.
- Forge abstraction: GitLab / Forgejo backends behind `forge.sld`'s
  interface; a second forge's auth attaches at the credential-provider seam.
- Second agent backend (proves the `agent.sld` boundary).
- Listing the App publicly for third-party installation — a distribution
  question, not an architecture one; the App itself is M0.
- scsh-style process notation upstream (kaappi ecosystem, not here).

## Risks / reality checks

- **Cross-repo blocker**: M1's App credential provider cannot ship until
  `kaappi-crypto` gains RS256 and cuts a release. If that stalls, M1 lands
  on the PAT provider and the App provider follows — the interface makes
  that a swap, not a rewrite, but the plan is not done until the App path
  works.
- **Unvalidated backend**: pi's RPC schema is assumed until M0's recon
  captures it. If it differs materially from what `agent.sld` was sketched
  around, M2 grows.
- **Budget burn**: M2+ spends real tokens; per-night caps are in config
  from M2, not bolted on later.
- **Prompt injection**: triage and code read attacker-writable text. Three
  layers answer it, and none of them is prompt wording alone — the M2
  sandbox bounds what a subverted agent can reach, output validation bounds
  what it can say, and the eligibility gate bounds what it may attempt. The
  M3 red-team fixture is a test, not a note.
- **Containment is Linux-only**: development on macOS runs the agent
  uncontained. The startup warning is load-bearing; a silent fallback here
  would be worse than no sandbox at all, because it would look safe.
- **Command latency before M6**: commands arrive by polling until the
  webhook driver lands, so `/implement` responds on the poll interval, not
  in seconds. Acceptable; worth saying out loud so it is not mistaken for a
  bug.
- **Public inbound surface**: M6's webhook endpoint is the first thing
  mesthiri exposes to the internet. Signature verification, body-size caps,
  and delivery de-duplication are part of M6's definition of done, not
  hardening to add afterwards.
- **Rubric drift**: mesthiri consumes target-repo rubrics; a rubric change
  upstream silently changes behavior — the triage verdict records the
  rubric file's commit hash.
- **pi upstream churn**: pin the pi version in config; `agent.sld` is the
  only file that knows its RPC shape.
