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
- [ ] **GitHub Apps** (human-only): register a **reader** App (triage,
      review — Issues and Pull requests write for comments and labels, code
      read) and a **writer** App (code, fix — Contents write), neither with
      merge permission, neither with a webhook URL. Store each private key
      as a repository secret on the target.
- [ ] **pi recon** (blocks M3): install pi, pin the version, capture its
      real `--rpc` frame schema into `docs/pi-rpc.md` plus a fixture. Note
      what it needs from filesystem and network — M3's sandbox policy comes
      from that list.
- [ ] Sandbox target: `mesthiri/sandbox`, a small disposable repo with its
      own test command and seeded issues. M6's demo target.
- [ ] Org hygiene: DCO app + branch protection on `mesthiri/mesthiri`.
- [ ] CI for this repo: build the binary, run the test suite on push/PR.

## M1 — The binary: config, event, forge

Everything here runs locally against fixtures. Nothing touches CI yet.

- [ ] `lib/mesthiri/config.scm` reader — `.mesthiri/config.scm` parsed with
      `read`: rubric path, budgets, path denylist, command permissions,
      pinned agent version, `operator:` identity. Startup validation refuses
      a triage target with no rubric path and a code stage with no denylist
      or operator.
- [ ] `lib/mesthiri/event.sld` — the normalized event, built from the CI
      environment and the forge payload the shim passes through. One shape
      for issue, comment, PR, review and schedule events.
- [ ] `lib/mesthiri/trigger.sld` — the s-expression predicate language over
      a normalized event, **interpreted over a fixed vocabulary, never
      `eval`ed**. A test asserts that a config attempting to call an
      arbitrary procedure is rejected rather than run.
- [ ] `lib/mesthiri/jwt.sld` — App JWT: base64url in Scheme (kaappi core
      does not export base64), signature from one-shot
      `openssl dgst -sha256 -sign` over `run-process`, input on stdin, key
      as a file path. Tested by verifying the signature back with
      `openssl dgst -verify`.
- [ ] `lib/mesthiri/forge.sld` — GitHub REST client over `kaappi-http` +
      `kaappi-json`: issues, comments, labels, pulls, reviews, permission
      lookup. Credential providers behind one interface: installation token
      from `jwt.sld` in deployment, PAT locally. Pagination and rate-limit
      handling here and nowhere else.
- [ ] `lib/mesthiri/log.sld` — every line carries stage, repo and run URL.

**Demo:** `mesthiri inspect <owner/repo>` reads a public repo and prints
what it would consider actionable. Tests run against recorded fixtures.

## M2 — Dispatch: the first thing that runs in CI

The heart of the re-architecture. Until this works, nothing else can.

- [ ] `mesthiri dispatch` — normalize, authorize, match a trigger, run one
      stage. One event, one stage, one job.
- [ ] The shim workflow, in `templates/`: native triggers plus `schedule`,
      calling the reusable workflow and nothing else. **PR events use
      `pull_request_target` and the shim never checks out the PR's code** —
      a test asserts the template contains no such checkout, because the
      failure mode is handing credentials to anyone who opens a pull
      request.
- [ ] The reusable workflow, in `.github/workflows/`: download the pinned
      mesthiri release, **verify its checksum**, run it.
- [ ] Commands: `/triage`, `/implement`, `/review`, `/fix`, `/retro` parsed
      by a plain grammar, authorized against the commenter's permission,
      restricted to the entity holding their inputs, refused with an
      explanatory comment when unauthorized. Tests include a command-shaped
      string inside an issue body that must not execute.
- [ ] Idempotency: a handler checks whether it already acted on this event
      id before acting; a CI concurrency group collapses rapid edits.

**Demo:** `/ping` from an authorized account on `mesthiri/sandbox` gets a
reply comment; from an unauthorized account, a refusal. End to end, in CI,
with no server.

## M3 — Agent execution and containment

- [ ] `lib/mesthiri/agent.sld` — the only module that spawns the agent.
      `spawn-process '("pi" "--rpc") …`, `'pipe` stdin/stdout, `'null`
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
- [ ] `.mesthiri/harness/<role>.scm` — prompt, allowed tools, model and
      effort, budgets and sandbox policy as one reviewable file per role.
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
      clear-downstream-on-new-commit rule.
- [ ] `lib/mesthiri/triage.sld` — verify the issue's claims against a
      checkout using the M3 agent, classify per the rubric read from the
      target repo at its configured path, propose exactly one `priority:`
      label and an intent tier, comment the rationale, record the rubric's
      commit SHA in the verdict.
- [ ] `--dry-run` prints proposed labels and rationales without writing.
      The mode CI exercises and the mode a new target runs in for a while.
- [ ] Red-team fixture from day one: an issue whose body tries to instruct
      the agent, asserted to change no verdict.
- [ ] The scheduled sweep, and its cursor on the `mesthiri-state` branch
      with write-then-verify.

**Demo:** scheduled dry-run triage on kaappi/kaappi that the org owner
spot-checks; going live is a config change.

## M5 — Prioritize

- [ ] Rank triaged issues into the ready queue — the target's own rubric
      first, RICE-style scoring where it has none — on the scheduled run,
      moving labels rather than rows.

## M6 — Code stage

- [ ] Eligibility before anything is spawned: refuse tier-2 issues without
      explicit human authorization; refuse a diff touching a denylisted
      path. Both refusals are comments naming the rule that fired.
- [ ] Fresh clone in the job; `run-process` for git, never a shell, and no
      `gh` — `forge.sld` is the only API path.
- [ ] Drive the agent to an implementation with tests; run the *target
      project's own* test command; iterate within budget.
- [ ] **The job pushes, not the agent**: agent exits leaving commits, the
      job reads the diff outside the sandbox, re-checks the denylist, then
      pushes and opens the PR.
- [ ] PR mechanics: author and `Signed-off-by` both the configured operator
      (checkers compare the two), `Co-authored-by: mesthiri[bot]`, a
      `Generated-by` trailer naming backend, version and run URL, PR body
      saying in prose that the change is machine-generated. One issue, one
      PR; **never merge**. A test asserts a produced commit passes a DCO
      check the way the org's app applies it.
- [ ] Failure honesty: a run that cannot reach green tests comments its
      state on the issue rather than opening a broken PR.

**Demo:** a closed-loop PR on `mesthiri/sandbox` from a seeded issue; a
second seeded issue touching a denylisted path refused with a comment; a
third at tier 2 waiting for a human.

## M7 — Review and Fix

- [ ] Review on `pull_request_target` and `pull_request_review`: per-
      dimension passes (correctness, security, performance, intent), each
      re-deriving the intent tier from the diff independently; adversarial
      verification before posting; findings as PR comments. No App holds
      approve or merge permission.
- [ ] Fix: consume findings on mesthiri-authored PRs, push, re-run tests,
      bounded depth, then hand to a human.
- [ ] Stale-approval rule enforced: a new commit clears downstream labels.

## M8 — Retro

- [ ] Mine completed CI runs and their JSONL trace artifacts for timings,
      iteration counts, spend and failure classes; file improvement
      proposals as issues on mesthiri, where a human picks them up.
      mesthiri is never a target of its own pipeline, and the config reader
      refuses one that names it.

## M9 — Installation and distribution

- [ ] `mesthiri install <owner/repo>` — scaffold `.mesthiri/` and the shim
      workflow as a pull request, in ordered layers that install forward,
      uninstall in reverse, and report status. The layering idea is
      fullsend's ADR 0006.
- [ ] Release automation: build the standalone binary for Linux x86_64 and
      arm64, publish with SHA256SUMS, and pin it in the reusable workflow.
- [ ] A preset for the kaappi org so its repos install with one command.

## Later / explicitly deferred

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
- **Containment is Linux-only**, which CI runners are; local development on
  macOS runs uncontained and must say so loudly at startup, because a
  security fallback that fails silently is worse than none.
- **Cross-run spend caps are approximate**, since the state branch is not a
  transaction log. Enough to stop a runaway, not to bill against.
- **`openssl` must be on the runner** — it is, on every standard image, but
  a missing binary surfaces at authentication, so startup checks for it.
- **The operator signs for work they have not read.** Settled in design.md
  as the only DCO clause that fits, and a real obligation rather than a
  formality: an operator who stops reading has turned a certification into a
  rubber stamp, and nothing here can detect that.
