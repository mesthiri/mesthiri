# mesthiri — implementation plan

Status: living document, created 2026-09-04; re-sequenced the same day when
the execution model moved from a self-hosted service to CI-native dispatch.
[design.md](design.md) is the design authority — this file only sequences
it. Update the checkboxes as milestones land; scope changes belong in
design.md first.

Ground rules: mesthiri is a standalone binary a workflow runs, not a
service. Every stage lands with tests runnable as
`kaappi --lib-path ./lib tests/test-<module>.scm`. No agent runs outside its
sandbox and none of them holds a credential. Each milestone ends in
something *demonstrable*, not a pile of modules.

## What the re-architecture changed

Recorded so the earlier milestones' reasoning is not lost. **Kept**, because
none of it depended on the daemon: untrusted-input discipline, agent
containment, the credential boundary, output validation, eligibility rules,
workflow labels, slash commands with ACL, target-repo rubrics, operator
sign-off, and the rule that mesthiri is never its own target. **Dropped**:
systemd and the droplet, the reactor timer loop, the SQLite store, globally
serial execution, round-robin across targets, and `mesthiri status` reading
a database. **Improved**: polling was accepted with a latency cost because
there was no receiver; native CI triggers are the receiver, so events arrive
promptly and there is still nothing listening on a port.

## M0 — Setup and recon

- [x] Repo seeded: README, design.md, CLAUDE.md, kaappi.pkg, MIT license
- [x] Design unblocked: kaappi v0.26.0 shipped KEP-0022
- [x] **GitHub Apps** registered and installed:
      `mesthiri-reader` (app id 4825652) and `mesthiri-writer` (4825675),
      both in the `mesthiri` org, both installed on selected repositories
      rather than all. Permissions confirmed against the API rather than the
      form: reader holds `contents: read` — which is what makes "triage and
      review cannot write code" true rather than a promise — and writer holds
      `contents: write`; both hold `issues` and `pull_requests` write and
      `metadata` read, and nothing else. Private keys are repository secrets
      on `mesthiri/sandbox` and exist nowhere else.

      Registered through the plain form, not the manifest flow. Confirming a
      manifest does not create the App: it issues a code that must be
      exchanged at `POST /app-manifests/{code}/conversions`, and that
      exchange returns the private key — one more step than the form, and it
      routes a key through an extra hop. `deploy/register-apps.html` records
      this and leads with the form.
- [x] **Ecosystem deps installed** (dev machine done): `kaappi-http` and `kaappi-net` are C-FFI
      libraries, so their built shared object has to be where the FFI loader
      looks (`~/.kaappi/lib/`) — `--lib-path` alone finds the Scheme and not
      the `.dylib`, and the failure is `ffi-open: dlopen … relative path not
      allowed`, which reads like a path bug rather than a missing install.
      `thottam install` is the flow. Verified absent on the dev machine.
- [x] **pi recon** (unblocks M3): done against pi 0.84.4 —
      `docs/pi-rpc.md` records the protocol and
      `tests/fixtures/pi-rpc-session.jsonl` is a real 15-frame session. It
      found that the flag is `--mode rpc` and not `--rpc`, which four
      documents had wrong; that there is no in-band cancel, so the deadline
      must be a group kill; that `agent_settled` rather than `agent_end` is
      terminal; and that pi reads `AGENTS.md`/`CLAUDE.md` from the working
      directory by default, which in a target's scratch clone is a
      prompt-injection path — so `--no-context-files` is not optional.
- [x] Sandbox target: `mesthiri/sandbox` exists — a tiny Kaappi library
      whose test suite is green as committed, with one deliberate defect
      (`median` returns the upper middle element for even-length lists), so
      a fix must add the failing assertion as well as make it pass. Four
      seeded issues cover the cases triage must tell apart: a reproducible
      defect, a feature request, a docs typo, and one whose body tries to
      instruct the agent. Its shim and `.mesthiri/` are hand-committed until
      M9, and every stage is off but triage in dry-run.
- [x] Branch protection on `mesthiri/mesthiri`: `diagrams`, `suite` and
      `DCO` are all required, force pushes and deletions blocked,
      conversation resolution required. Admins are not enforced, so the owner can still push to
      `main` directly; flip `enforce_admins` when outside contributions
      start.
- [x] **DCO2 app** installed on `mesthiri/mesthiri` and `mesthiri/sandbox`
      (human-only): <https://github.com/apps/dco-2>, source
      [cncf/dco2](https://github.com/cncf/dco2) — the same app the kaappi org
      uses, not the older `apps/dco`. `.github/dco.yml` is already seeded in
      both repos, matching the org's template. The status check it posts is
      named **`DCO`**, so after installing:

      ```
      gh api -X PATCH repos/mesthiri/mesthiri/branches/main/protection/required_status_checks \
        -f 'contexts[]=diagrams' -f 'contexts[]=suite' -f 'contexts[]=DCO'
      ```

      `infra/scripts/require-dco-check.sh` does this for kaappi repos but
      hardcodes that org, so it does not apply here. Installed org-wide
      (`repository_selection: all`) on 2026-09-04.
- [x] CI for this repo, docs half: `.github/workflows/docs.yml` validates
      every Mermaid block on push and pull request.
- [x] CI for this repo, code half: `.github/workflows/test.yml` runs the
      module suite on push and pull request. Needs no C-FFI library —
      `forge.sld` takes an injected transport, so only pure-Scheme
      `kaappi-json` is fetched. Both checks are required in branch
      protection.

## M1 — The binary: config, event, forge

Everything here runs locally against fixtures and nothing touches CI yet.
The modules can be built and tested immediately; only the demo waits on M0's
App registration, since minting a real token is the whole point of it.

- [x] `lib/mesthiri/config.sld` — reads `.mesthiri/config.scm` with
      `read`: rubric path, budgets, path denylist, command permissions,
      pinned agent version, reader/writer App IDs as
      `(apps (reader <id>) (writer <id>))`, exactly one `operator:`
      identity. No target list — mesthiri acts on the repository it is
      installed in. Validation refuses triage with no rubric path, a code
      stage with no denylist or operator, and any run with no App IDs. The
      guide's sample config is the scaffold contract `install` produces.
- [x] `lib/mesthiri/event.sld` — the normalized event, built from the CI
      environment and the forge payload the shim passes through. One shape
      for issue, comment, PR, review and schedule events.
- [x] `lib/mesthiri/trigger.sld` — the s-expression predicate language over
      a normalized event, **interpreted over a fixed vocabulary, never
      `eval`ed**. A test asserts that a config attempting to call an
      arbitrary procedure is rejected rather than run.
- [x] `lib/mesthiri/jwt.sld` — App JWT: base64url in Scheme (kaappi core
      does not export base64), signature from one-shot
      `openssl dgst -sha256 -sign` over `run-process`, input on stdin, key
      as a file path. Tested by verifying the signature back with
      `openssl dgst -verify`.

      **Already proven end-to-end**, which is worth knowing since this was
      called the riskiest piece: a 2048-bit RS256 JWT minted in Kaappi
      v0.26.1 this way verifies with `openssl dgst -verify`. Two API details
      the probe settled — `run-process` returns *multiple values*,
      `(exit-code stdout stderr)`, so `define-values` is the calling shape,
      not an alist lookup; and `output:` takes `'string` or `'bytevector`,
      of which a signature needs `'bytevector` because it is binary.
      base64url needs no SRFI — plain `quotient`/`modulo` is enough, though
      `(srfi 151)` is available if the bit operations read better.
- [x] `lib/mesthiri/forge.sld` — GitHub REST client over `kaappi-http` +
      `kaappi-json`: issues, comments, labels, pulls, reviews, permission
      lookup. `http-request` takes `(method url headers body)`, so arbitrary
      methods and headers are available and `PATCH` needs no helper —
      checked, because GitHub uses it for issues and labels. Credential providers behind one interface: installation token
      from `jwt.sld` in deployment, PAT locally. Pagination and rate-limit
      handling here and nowhere else.
- [x] `lib/mesthiri/log.sld` — every line carries stage, repo and run URL.

**Demo:** `mesthiri whoami` mints a real installation token from the App key
and prints which installation it is, the permissions it holds and the
remaining rate limit. That exercises the whole milestone in one command —
`config.sld` for the App IDs and key path, `jwt.sld` signing through
`openssl`, `forge.sld` for auth and rate-limit headers — and it puts the
riskiest piece first: RS256 through a subprocess is the part of M1 with no
precedent in the Kaappi ecosystem to copy from.

`event.sld` and `trigger.sld` are covered by tests over recorded fixtures
rather than a command. Printing a matched stage is `explain-event`'s job and
it belongs with dispatch in M2, where there is a real event to explain.

## M2 — Dispatch: the first thing that runs in CI

The heart of the re-architecture. Until this works, nothing else can.

- [x] `mesthiri dispatch` — normalize, authorize, match a trigger, run one
      stage. One event, one stage, one job.
- [x] The shim workflow, in `templates/`: native triggers plus a single
      hourly `schedule` tick — dispatch matches the tick against each
      stage's configured schedule, a whole-hour UTC time optionally
      qualified by a weekday — calling the reusable
      workflow and nothing else. **PR events use
      `pull_request_target` and the shim never checks out the PR's code** —
      a test asserts the template contains no such checkout, because the
      failure mode is handing credentials to anyone who opens a pull
      request.
- [x] The reusable workflow, in `.github/workflows/`: download the pinned
      mesthiri release, **verify its checksum**, run it.
- [x] Commands: `/triage`, `/implement`, `/review`, `/fix`, `/retro` parsed
      by a plain grammar, authorized against the commenter's permission,
      restricted to the entity holding their inputs, refused with an
      explanatory comment when unauthorized. A label a human applies that
      triggers a stage authorizes identically, against the labeler's
      permission — write for the code and fix stages — while labels
      mesthiri's own Apps apply pass. Tests include a command-shaped
      string inside an issue body that must not execute.
- [x] Idempotency: a handler checks whether it already acted on this event
      id before acting; a CI concurrency group collapses rapid edits.
- [x] `mesthiri explain-event` — print the normalized event and which
      trigger predicates were tested and how they matched. "A stage did
      nothing and said nothing" is the failure mode this architecture makes
      easiest to hit, and it is unhelpful without this.

**Demo:** `/triage` from an authorized account on `mesthiri/sandbox` gets a
reply comment from the M2 probe handler; from an account without triage
permission, a refusal naming what was needed. End to end, in CI, with no
server. **Blocked on M0**: needs `mesthiri/sandbox` to exist and the Apps
registered.

The probe replaced the planned `/ping`. A demo-only command would have had
to bypass the command table, the entity check and the permission rule — so
it would have demonstrated a path that does not ship. Registering a
placeholder handler for the real `triage` stage exercises every gate
instead, and M4 replaces the handler rather than deleting a special case.

## M3 — Agent execution and containment

- [ ] `lib/mesthiri/agent.sld` — the only module that spawns the agent.
      `spawn-process '("pi" "--mode" "rpc" "--no-session"
      "--no-context-files") …`, `'pipe` stdin/stdout, `'null`
      stderr, `new-group: #t`; JSON framing from a drive fiber against M0's
      captured schema; wall-clock deadline via `process-wait 'timeout:` then
      `process-kill 'group: #t`; token and turn budgets passed to pi.
- [ ] **Containment inside the runner**: namespace sandbox via
      `bwrap`/`unshare` constructed by `agent.sld` and nothing else —
      read-only root, scratch clone the only writable mount, the App key and
      installation token outside the mount namespace, egress denied by
      default with an allowlist that **excludes the forge**, separate
      unprivileged uid.
- [ ] **Output validation** outside the agent: declared schema, capped
      retries, then hard fail.
- [ ] Budgets: per-run token, turn and wall-clock caps enforced by the run
      on itself, and the **derived cross-run cap** — before starting, query
      recent workflow runs and their traces and decline if the day's spend
      already looks exhausted. This is the only place that approximation
      exists, so it lives with the budgets rather than being assumed by
      every stage.
- [ ] `.mesthiri/harness/<role>.scm` — prompt, allowed tools, provider and
      pinned model, effort, budgets and sandbox policy as one reviewable
      file per role. A floating model alias is rejected at load, not
      resolved.
- [ ] Shipped default harnesses, one per role, so a repo runs on
      `config.scm` alone; a repo file overrides any subset and inherits the
      rest. A harness with no provider gets the sole declared one and must
      name one if several exist, and its budgets may only lower the
      per-run ceiling from `config.scm`, never raise it.
- [ ] The sandbox egress allowlist is **derived** from the configured
      provider endpoint, never hand-written alongside it — a mismatch
      between the two surfaces as a connection failure inside an agent run,
      which looks like anything but the typo it is.
- [ ] Prompt hygiene: issue and PR text enters prompts only inside an
      explicit untrusted-data block, and never argv.
- [ ] A JSONL trace per run, uploaded as a CI artifact — the input M8's
      retro stage reads instead of a database.

**Demo:** `mesthiri agent-smoke` in CI runs a trivial task and prints the
run record; `--prove-sandbox` asserts the boundary rather than describing
it — the agent cannot read the token, cannot write outside its clone,
cannot reach a host off the allowlist.

## M4 — Triage and workflow labels

- [ ] `lib/mesthiri/labels.sld` — the state machine: declared legal
      transitions, mutual exclusion, write-then-read-back, and the
      clear-downstream-on-new-commit rule. Label definitions ship in the
      M9 install pull request; dispatch applies `ready-for-triage` on
      issue open, and the M4 sweep backstops unlabeled or updated issues.
- [ ] `lib/mesthiri/triage.sld` — verify the issue's claims against a
      checkout using the M3 agent, classify per the rubric read from the
      target repo at its configured path, propose exactly one `priority:`
      label and an intent tier (the tier lives in the verdict and run
      record, never as a label), comment the rationale, record the
      rubric's commit SHA in the verdict.
- [ ] Stage `mode` — `off` | `dry-run` | `live`, defaulting to **off**.
      A freshly installed repo has triage in dry-run and everything else
      off; merging an install pull request must not start opening real
      ones. The code stage also carries `max-tier`, default 0.
- [ ] Red-team fixture from day one: an issue whose body tries to instruct
      the agent, asserted to change no verdict.
- [ ] The scheduled sweep, finding its work by **querying the forge for
      labels and update times** rather than keeping a cursor. Labels are the
      watermark; mesthiri stores nothing a human cannot see in the repo.

- [ ] `mesthiri try <owner/repo>` — apply the rubric to open issues from a
      PAT and print the result, writing nothing and cloning nothing. It
      calls a model **directly, with no agent subprocess**: verifying an
      issue's claims needs tools against attacker-writable text, which
      belongs in a sandbox on a runner rather than on someone's laptop. So
      it answers the narrower question honestly — does this rubric produce
      sane priorities — and says in its output that claims are unverified.

**Demo:** scheduled dry-run triage on kaappi/kaappi that the org owner
spot-checks; going live is a config change. Separately, `mesthiri try`
against any public repo with a rubric, from a laptop, with no install.

Note the shape of that ask has changed. When mesthiri was a service it could
be pointed at kaappi/kaappi from outside; per-repo installation means the
demo needs a shim workflow committed **into the core repo**, which is a
pull request against 2000-plus commits of someone's main project. Run it on
`mesthiri/sandbox` first and treat kaappi/kaappi as the graduation.

## M5 — Prioritize

- [ ] Rank triaged issues into the ready queue — the repository's own
      rubric ranking first, oldest-triaged-first where it has none, age
      breaking ties — on the scheduled (UTC) run, moving labels rather
      than rows. The per-day cap counts runs started.
- [ ] Ranking is explainable: the scheduled run leaves a comment on each
      issue it promotes saying what moved it, so a maintainer can disagree
      with the ranking rather than only with the outcome.

**Demo:** a scheduled run on `mesthiri/sandbox` turns a set of triaged
issues into an ordered `ready-to-implement` set, with a reason on each.

## M6 — Code stage

- [ ] Eligibility before anything is spawned: refuse tier-2 issues unless
      a write-permission `/implement` claimed them — the command is the
      authorization, and `max-tier` caps only the label-driven path; refuse
      a diff touching a denylisted path. Both refusals are comments naming
      the rule that fired.
- [ ] Fresh clone in the job; `run-process` for git, never a shell, and no
      `gh` — `forge.sld` is the only API path.
- [ ] Drive the agent to an implementation with tests; run the *target
      project's own* test command; iterate within budget.
- [ ] **The job pushes, not the agent**: agent exits leaving commits, the
      job reads the diff outside the sandbox, re-checks the denylist, then
      pushes and opens the PR.
- [ ] PR mechanics: author and `Signed-off-by` both the configured operator
      (checkers compare the two), `Co-authored-by: mesthiri[bot]`, a
      `Generated-by` trailer naming backend, version, provider/model and
      run URL, PR body
      saying in prose that the change is machine-generated. One issue, one
      PR; **never merge**. A test asserts a produced commit passes a DCO
      check the way the org's app applies it.
- [ ] Failure honesty: a run that cannot reach green tests comments its
      state on the issue rather than opening a broken PR.

**Demo:** a closed-loop PR on `mesthiri/sandbox` from a seeded issue; a
second seeded issue touching a denylisted path refused with a comment; a
third at tier 2 waiting for a human.

## M7 — Review and Fix

- [ ] Review fires only on pull requests **mesthiri opened**, plus explicit
      `/review`. `pull_request_target` fires for fork PRs, so reviewing
      everything lets anyone who can open one spend the repo's budget; the
      per-day cap is approximate and not a defence. An explicit `/review`
      on a foreign PR fetches the diff through the API into a read-only
      clone the agent cannot push from.
- [ ] The review harness must not match the code harness: the other
      provider where two are declared, otherwise a different model. A
      config where they match is rejected at load.
- [ ] Review on `pull_request_target` and `pull_request_review`: per-
      dimension passes (correctness, security, performance, intent), each
      re-deriving the intent tier from the diff independently; adversarial
      verification before posting; findings as PR comments. No App holds
      approve or merge permission.
- [ ] Fix: consume findings on mesthiri-authored PRs, push, re-run tests,
      bounded depth, then hand to a human.
- [ ] Stale-approval rule enforced: a new commit clears downstream labels.

**Demo:** on the M6 pull request, review posts findings; `/fix` consumes
them, pushes, and the tests re-run; a fresh commit visibly clears
`ready-for-merge`. A deliberately unfixable finding exhausts the depth and
hands over with `needs-human`.

## M8 — Retro

- [ ] Mine completed CI runs and their JSONL trace artifacts for timings,
      iteration counts, spend and failure classes; the trace contains the
      run record, retention follows CI artifact retention. File
      improvement proposals as issues **on the repository mesthiri is
      installed in** — flaky tests burning
      budget, work that keeps escalating to a human, rubric gaps. It writes
      where the work is, with the same repo-scoped token every other stage
      uses, and needs no cross-repo credential.
- [ ] Improvements to mesthiri itself arrive the ordinary way: a human
      reads a retro issue and reports it upstream. mesthiri is never
      installed on its own repository — the `mesthiri/mesthiri` string-match
      refusal lands with `install` in M9; until then it is a rule in the
      README rather than a mechanism.

**Demo:** after the M6 and M7 runs, a scheduled retro files an issue on
`mesthiri/sandbox` naming something real — a test that failed twice, or a
stage that spent its budget without reaching green.

## M9 — Installation and distribution

- [ ] `mesthiri install <owner/repo>` — scaffold `.mesthiri/` (config plus
      a **starter rubric**, since most repos have none and "first write a
      policy document" is a poor first five minutes), create the workflow
      labels through the API, and open the shim workflow as a pull request,
      in ordered layers that install forward, uninstall in reverse, and
      report status — `mesthiri uninstall <owner/repo>` is the guide's exit
      route and opens the reversing pull request. The
      scaffolded config matches the guide's sample (App IDs, deny-paths,
      `max-tier 0`, budgets, pinned versions). The layering idea is
      fullsend's ADR 0006.
- [x] Release automation: `.github/workflows/release.yml` builds Linux
      x86_64 and arm64 plus macOS arm64, smoke-tests each, and publishes with
      SHA256SUMS on a tag push.

      It is a **matrix of native builds, not cross-compilation**, and that is
      forced rather than chosen: kaappi stamps bytecode with
      `compilerHashFor(version, build_id, target)` and refuses a mismatch at
      startup, so a `.sbc` must be compiled by a kaappi built for the same
      target as the binary embedding it. A macOS-built bundle will not run in
      a Linux binary however it is cross-built. The error prints only the
      build id, so the two sides read as identical and it still refuses —
      which is why this is written down.

      Two more traps the workflow guards: the C-FFI shared objects must be
      installed before the bundle is compiled, or the compile writes a
      truncated `.sbc` (~46 KB against ~128 KB) as well as exiting non-zero;
      and `zig build -Dbundle=` overwrites `zig-out/bin/kaappi`, so the plain
      kaappi used as the compiler is copied aside first. Layered
      distribution means a fix here reaches installed repos without
      a pull request to each — and means every run depends on this
      repository, which the checksum check is there to bound.
- [ ] `mesthiri apps create` — print pre-filled GitHub App manifest URLs
      for the reader and writer Apps so registration is a confirm rather
      than a form. Secrets are still pasted by hand: GitHub's secrets API
      needs NaCl sealed-box encryption, and a crypto dependency is too much
      to carry for a once-per-repo step (design.md records this).
- [ ] A preset for the kaappi org so its repos install with one command.
      It ships a placeholder operator the org fills in; rotation afterwards
      is a config edit.
- [ ] `mesthiri install` refuses `mesthiri/mesthiri` by string match; forks
      are unaffected.

**Demo:** `mesthiri install` opens a pull request against a repo that has
never seen mesthiri, and merging it is enough to make `/triage` work.
Uninstall reverses it and leaves no trace but the labels.

## Later / explicitly deferred

- Reviewing pull requests mesthiri did not open **automatically**, on the
  pull-request event. Explicit `/review` on such a pull request already
  works and is permission-checked; what is deferred is the unprompted
  version, which needs a spend gate worth trusting — an approximate per-day
  cap is no defence on a trigger any stranger can pull.
- Vendored installs: writing the workflow and pinning the binary into the
  target repo so nothing is fetched at run time. Worth having for an adopter
  who reviews everything they run; not worth two code paths before there is
  one such adopter.
- GitLab: the same binary under GitLab CI, with fullsend's two-path model —
  native triggers where they exist, scheduled polling elsewhere.
- A second agent backend, which is what would prove `agent.sld`'s boundary.
- Golden-set evals for triage verdicts and review findings, once verdict
  volume makes drift measurable.
- Org-scale installation, a central token mint, shared infrastructure. This
  is where fullsend is years ahead, and where mesthiri deliberately is not
  competing.

## Risks / reality checks

- **CI is now a hard dependency.** Deleting the server bought simplicity at
  the price of standing alone. A forge that changes its Actions semantics
  changes mesthiri, and a repo whose CI is disabled cannot run it.
- **The shim is the security boundary.** `pull_request_target` plus never
  checking out PR code is the single control preventing a pull request from
  rewriting the workflow that holds the credentials. It is asserted by a
  test in M2 rather than trusted to review.
- **Unvalidated backend**: pi's RPC schema is assumed until M0's recon
  captures it. If it differs materially, M3 grows.
- **Prompt injection**: three layers answer it and none is prompt wording —
  the sandbox bounds what a subverted agent reaches, output validation
  bounds what it says, eligibility bounds what it may attempt.
- **Containment is Linux-only**, which CI runners are. This bites only
  where an agent is spawned: `try` and `install` spawn none, so the macOS
  build is unaffected, but running a stage locally during development does,
  and must say so loudly at startup — a security fallback that fails
  silently is worse than none, and a warning printed where nothing needs
  containing is how one gets ignored.
- **Cross-run spend caps are approximate and derived**, not counted: with
  no cursor file there is nowhere to keep a counter, so a job queries recent
  run history before starting an expensive stage. Lagging, and defeatable by
  concurrent jobs starting at once. Enough to stop a runaway, not to bill
  against.
- **`openssl` must be on the runner** — it is, on every standard image, but
  a missing binary surfaces at authentication, so startup checks for it.
- **The operator signs for work they have not read.** Settled in design.md
  as the only DCO clause that fits, and a real obligation rather than a
  formality: an operator who stops reading has turned a certification into a
  rubber stamp, and nothing here can detect that.
