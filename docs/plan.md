# mesthiri — implementation plan

Status: living document, created 2026-09-04, re-sequenced 2026-09-04 (agent
before triage; GitHub App identity). [design.md](design.md) is the design
authority — this file only sequences it. Update the checkboxes and the
"reality check" notes as milestones land; a milestone's scope changes belong
in design.md first.

Ground rules for the whole plan: Kaappi ≥ 0.26 (`(kaappi process)` is
assumed everywhere, KEP-0022 Final), every stage lands with tests runnable
via `kaappi --lib-path ./lib tests/test-<module>.scm`, exactly one agent run
is in flight at a time process-wide, and each milestone ends in something
*demonstrable*, not a pile of modules.

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
      observed frames, not assumed ones.
- [ ] Sandbox target: create `mesthiri/sandbox` (a small real-but-disposable
      repo with its own test command) and seed it with issues; install the
      App on it. This is M4's demo target.
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
      cursor, triage verdicts, queue claims, pipeline runs (stage timings,
      spend, outcome), webhook delivery ids, retro facts. Migrations as
      numbered scripts run at startup.
- [ ] `lib/mesthiri/config.sld` — one config file (targets and their rubric
      paths, App id / key path / webhook secret path, budgets, cadences,
      pinned pi version); `kaappi-cli` for the entry-point flags. Startup
      validation rejects a triage target with no rubric path.
- [ ] `lib/mesthiri/log.sld` — thin wrapper over `kaappi-log`: every log
      line carries stage + target repo + run id.

**Demo:** `mesthiri sync <owner/repo>` populates the store from a public
repo read-only and prints a summary table; `mesthiri whoami` shows which
installation it is authenticated as and the remaining rate limit. Tests hit
recorded fixtures, not the network; one live read-only smoke test is tagged
and skipped in CI.

## M2 — Agent integration

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

## M3 — Triage stage (first forge-visible value)

- [ ] `lib/mesthiri/triage.sld`: for each unseen issue — verify the issue's
      claims against a checkout using the M2 agent, classify per the rubric
      read from the *target repo* at its configured path (first target:
      kaappi org's `docs/dev/github-issues.md`, exactly one `priority:`
      label), record verdict + one-paragraph rationale + the rubric file's
      commit SHA in the store.
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

## M4 — Code stage

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
reviewed PR out, with the pipeline run record to show for it.

## M5 — Review + Fix stages

- [ ] Webhook receiver: `kaappi-http` server endpoint, HMAC-SHA256
      verification of the raw body against the App's webhook secret,
      delivery-id de-duplication in the store, and payloads handed onward as
      untrusted data. Public inbound surface — behind a reverse proxy with
      TLS (M7 covers the provisioning).
- [ ] Review: per-dimension agent passes (correctness, security,
      performance, intent alignment); adversarial verification before
      posting; findings as PR comments (the App has no approve/merge
      permission, and mesthiri's principle is that humans gate anyway).
- [ ] Fix: consume findings on mesthiri-authored PRs, push fixes, re-run
      tests, bounded iteration depth, then hand to a human.

## M6 — Prioritize + Retro

- [ ] Prioritize: rank triaged issues into the ready queue (target's own
      rubric first, RICE fallback), on a cron cadence.
- [ ] Retro: mine pipeline runs for timings/iteration/failure patterns;
      file improvement proposals as issues on mesthiri itself.

## M7 — Deployment hardening

- [ ] Single binary via `zig build -Dbundle-src=mesthiri.scm`; systemd
      unit + timer files under `deploy/`.
- [ ] Server provisioning notes (a small DO droplet suffices); public
      hostname + TLS termination for the webhook endpoint; secrets layout
      (App private key and webhook secret on disk, mode 0600, never in the
      store).
- [ ] Observability: `mesthiri status` reading the store; nightly summary
      comment or email (kaappi-email) — optional.

## Later / explicitly deferred

- Concurrent agent runs (a worker pool), justified by real M6 retro timings
  rather than by anticipation.
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
- **Prompt injection**: triage and code read attacker-writable text; the
  untrusted-data discipline is in the first prompt written, and the M3
  red-team fixture is a test, not a note.
- **Public inbound surface**: M5's webhook endpoint is the first thing
  mesthiri exposes to the internet. Signature verification, body-size caps,
  and delivery de-duplication are part of M5's definition of done, not
  hardening to add afterwards.
- **Rubric drift**: mesthiri consumes target-repo rubrics; a rubric change
  upstream silently changes behavior — the triage verdict records the
  rubric file's commit hash.
- **pi upstream churn**: pin the pi version in config; `agent.sld` is the
  only file that knows its RPC shape.
