# mesthiri — implementation plan

Status: living document, created 2026-09-04. [design.md](design.md) is the
design authority — this file only sequences it. Update the checkboxes and
the "reality check" notes as milestones land; a milestone's scope changes
belong in design.md first.

Ground rules for the whole plan: Kaappi ≥ 0.26 (`(kaappi process)` is
assumed everywhere, KEP-0022 Final), every stage lands with tests runnable
via `kaappi --lib-path ./lib tests/test-<module>.scm`, and each milestone
ends in something *demonstrable*, not a pile of modules.

## M0 — Project setup

Mostly done at seeding; the rest needs the org owner.

- [x] Repo seeded: README, design.md, CLAUDE.md, kaappi.pkg, MIT license
- [x] Design unblocked: kaappi v0.26.0 shipped KEP-0022; shim plan removed
- [ ] **`mesthiri-bot` machine account** (human-only: ToS, email, 2FA);
      fine-grained PAT per target repo (Contents, Pull requests, Issues —
      write)
- [ ] Org hygiene: DCO app + branch protection on `mesthiri/mesthiri`
      before any outside PR
- [ ] CI: `.github/workflows/ci.yml` — install the released kaappi binary,
      run the test suite on push/PR (mirror the kaappi-* ecosystem repos'
      inline style)

## M1 — Foundations: forge, store, config

The plumbing every stage shares. No agent, no writes to any forge yet.

- [ ] `lib/mesthiri/forge.sld` — GitHub REST client over `kaappi-http` +
      `kaappi-json`: issues (list/get/comment/label), pulls
      (create/list/get), repos. Takes a **credential provider** ("token for
      repo X"), PAT provider first, so the later GitHub App provider is a
      new module, not a rewrite. Pagination and rate-limit headers handled
      here and nowhere else.
- [ ] `lib/mesthiri/store.sld` — `kaappi-sqlite` schema: issues seen +
      cursor, triage verdicts, queue claims, pipeline runs (stage timings,
      spend, outcome), retro facts. Migrations as numbered scripts run at
      startup.
- [ ] `lib/mesthiri/config.sld` — one config file (targets, tokens path,
      budgets, cadences); `kaappi-cli` for the entry-point flags.
- [ ] `lib/mesthiri/log.sld` — thin wrapper over `kaappi-log`: every log
      line carries stage + target repo + run id.

**Demo:** `mesthiri sync <owner/repo>` populates the store from a public
repo read-only and prints a summary table. Tests hit recorded fixtures, not
the network; one live read-only smoke test is tagged and skipped in CI.

## M2 — Triage stage (first real value)

- [ ] `lib/mesthiri/triage.sld`: for each unseen issue — verify the
      issue's claims against a checkout before trusting them, classify per
      the target's rubric (first target: kaappi org's
      `docs/dev/github-issues.md`, exactly one `priority:` label), record
      verdict + one-paragraph rationale in the store.
- [ ] **Dry-run first**: `mesthiri triage --dry-run` prints proposed
      labels/rationales without writing to the forge. This works before
      the bot account exists and is the mode CI exercises.
- [ ] Live mode (needs M0 bot): apply label + post rationale comment as
      `mesthiri-bot`.
- [ ] Scheduling: reactor timer loop inside the service *and* a
      `mesthiri triage --once` entry point so a systemd timer or cron can
      drive it externally; pick one as default at deploy time.

Note: triage needs the agent for claim-verification reasoning — so M2's
verification depth is bounded by M3; ship M2 first with rubric-mechanical
classification + "claims unverified" marker, deepen after M3.

**Demo:** nightly dry-run against kaappi/kaappi producing verdicts that the
org owner spot-checks; graduation to live labels is a config flip.

## M3 — Agent integration

- [ ] `lib/mesthiri/agent.sld` — the one module that touches the coding
      agent: `spawn-process '("pi" "--rpc") …` with `'pipe` stdin/stdout,
      `'null` stderr, `new-group: #t`; JSON framing over the ports from a
      drive fiber; per-run wall-clock deadline (`process-wait 'timeout:` →
      `process-kill 'group: #t`), token/turn budget passed to pi; run
      record written to the store win or lose.
- [ ] Backend interface documented in design.md (settle its open
      question: pi's RPC schema as-is vs. a mesthiri envelope) — decide
      when the second consumer appears, but keep pi-specific names out of
      stage code now.
- [ ] Prompt hygiene: issue/PR text enters prompts only inside an
      explicit untrusted-data block; never into argv.

**Demo:** `mesthiri agent-smoke` — spawn pi, run a trivial task in a
scratch dir, show the event stream, kill on deadline, print the run record.

## M4 — Code stage

- [ ] Queue claim from the store; fresh clone per issue under a scratch
      root; `run-process` for git/gh (never a shell).
- [ ] Drive the agent to an implementation with tests; run the *target
      project's own* test command; iterate within budget.
- [ ] PR: branch push as `mesthiri-bot`, commits `-s` +
      `Co-authored-by`, PR body links the issue and the pipeline run; one
      issue, one PR; **never merge**.
- [ ] Failure honesty: a run that can't reach green tests files its state
      as a comment on the issue, not a broken PR.

**Demo:** one real closed-loop PR on a low-stakes target repo (a docs/wiki
class repo, or a sandbox repo under the mesthiri org).

## M5 — Review + Fix stages

- [ ] Review: per-dimension agent passes (correctness, security,
      performance, intent alignment); adversarial verification before
      posting; findings as PR comments (a bot cannot approve its own PR,
      and mesthiri's principle is that humans gate anyway).
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
- [ ] Server provisioning notes (a small DO droplet suffices); secrets
      layout (tokens on disk, mode 0600, never in the store).
- [ ] Observability: `mesthiri status` reading the store; nightly summary
      comment or email (kaappi-email) — optional.

## Later / explicitly deferred

- GitHub App packaging (the third-party adoption story; replaces the PAT
  credential provider).
- Forge abstraction: GitLab / Forgejo backends behind `forge.sld`'s
  interface.
- Second agent backend (proves the `agent.sld` boundary).
- scsh-style process notation upstream (kaappi ecosystem, not here).

## Risks / reality checks

- **Budget burn**: M4+ spends real tokens; per-night caps are in config
  from M3, not bolted on later.
- **Prompt injection**: the triage/code stages read attacker-writable
  text; the untrusted-data discipline is in the first prompt written, and
  a red-team fixture (an issue that tries to instruct the agent) is in the
  M2 test suite from day one.
- **Rubric drift**: mesthiri consumes target-repo rubrics; a rubric change
  upstream silently changes behavior — the triage verdict records the
  rubric file's commit hash.
- **pi upstream churn**: pin the pi version in config; `agent.sld` is the
  only file that knows its RPC shape.
