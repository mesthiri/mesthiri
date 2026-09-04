# mesthiri — design

Status: draft, 2026-08-29 (revised 2026-09-04: GitHub App identity, serial
execution, rubric location). Distilled from the research and design discussion
that produced [KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md);
this document records the decisions so the repo is self-explaining.

## What mesthiri is

An Agentic Development Lifecycle (ADLC) orchestrator: a long-running service
that executes the stages of the software development lifecycle with
autonomous coding agents, for any Git-hosted project, while humans set
intent, define guardrails, and review outcomes. The model follows the
published ADLC literature (agents execute; humans direct) and the working
precedent of fullsend.sh's six-stage pipeline, but is:

- **self-hosted**: you run the service, its database, and its webhook
  receiver on your own server. Identity is a GitHub App *you* register and
  install on *your* repos — there is no hosted multi-tenant service, no
  cloud sandbox provider, and no vendor to enroll with;
- **written in Kaappi Scheme**, dogfooding the language and its ecosystem
  libraries (`kaappi-http`, `kaappi-json`, `kaappi-sqlite`, `kaappi-crypto`,
  `kaappi-log`, `kaappi-cli`, fibers);
- **agent-agnostic**: the coding agent is a subprocess speaking JSON over
  stdio. The first backend is [pi](https://pi.dev/) (`pi --rpc`,
  MIT-licensed, minimal harness); the interface is small enough that other
  headless agents can slot in.

## Stage design

The service is one process. Cron stages are reactor timers; the code stage
is driven by a queue. **Exactly one agent run is in flight at a time,
process-wide** — serial execution is the design, not a temporary
simplification: it makes budget accounting, scratch-directory isolation, and
forge rate-limit behaviour trivially correct. A worker pool is a later
change, justified by real timings from the retro stage.

1. **Triage** (cron): poll open issues since the last cursor; for each,
   verify the issue's claims against the code before trusting them
   (diagnosis in an issue is a hypothesis, not a fact); propose exactly one
   priority label per the target project's documented rubric; post label +
   one-paragraph rationale. Never edits code.
2. **Prioritize** (cron): rank triaged issues into a ready queue
   (RICE-style scoring where the project has no rubric of its own).
3. **Code** (queue-driven): claim a ready issue; clone into a scratch
   worktree; drive the agent to a tested implementation; run the *project's
   own* test command; open a PR with sign-off. One issue, one PR.
4. **Review** (PR events, delivered by webhook): dimensions — correctness,
   security, performance, intent alignment — each an independent agent pass;
   findings verified adversarially before posting (a finding that cannot
   survive a refutation attempt is not posted).
5. **Fix** (review findings): apply findings, push, re-run tests; iterate
   to a bounded depth, then hand to a human.
6. **Retro** (cron): mine completed pipeline records (timings, iteration
   counts, failure classes) and file improvement proposals as issues.

## Forge identity and events

mesthiri authenticates as a **GitHub App** that the operator registers and
installs on the repos it should work on. The App is the primary and default
credential path; it acts as `mesthiri[bot]` with no human machine account
behind it, its permissions are declared once and reviewable, and its
installation is scoped to selected repositories.

- **Token minting**: sign a short-lived JWT with the App's private key
  (RS256), exchange it for an installation access token, cache the token
  until shortly before its expiry, refresh transparently. All of this lives
  behind `forge.sld`'s **credential provider** interface, so a personal
  access token provider remains available for local development and
  fixture work without stage code knowing the difference.
- **Ecosystem dependency**: RS256 signing does not exist in the Kaappi
  ecosystem yet — `kaappi-crypto` currently exports digests and HMACs only.
  It gains RSA signing upstream (OpenSSL is already linked there), and
  mesthiri's App auth depends on that landing.
- **Events**: the App delivers webhooks to a receiver built on
  `kaappi-http`'s server side. Deliveries are authenticated with
  HMAC-SHA256 over the raw body (`kaappi-crypto`'s `hmac-sha256`, which
  exists today), de-duplicated by delivery id in the store, and then treated
  as ordinary untrusted data — a verified signature proves the sender, never
  the contents. The endpoint is public inbound surface and is hardened as
  such.

## Rubrics

Triage rubrics live **in the target repository**, at a path named in
mesthiri's per-target config (the first target is the kaappi org's
`docs/dev/github-issues.md`). mesthiri consumes the rubric a project already
maintains; it does not author policy for projects it does not run. A target
with no rubric file is not eligible for triage, and that is a startup
configuration error rather than a silent fallback. Every triage verdict
records the commit SHA of the rubric it was decided under, so an upstream
rubric change is visible as a behaviour change instead of a mystery.

## Process supervision

The agent, git, and gh are all subprocesses, supervised through
`(kaappi process)` (KEP-0022, **shipped in kaappi v0.26.0** — the KEP is
Final; mesthiri requires kaappi ≥ 0.26). Every requirement mesthiri stated
is met by what shipped:

- streaming bidirectional pipes as fiber-parking ports (`pi --rpc` is a
  long-lived JSON event stream) — `spawn-process` with `'pipe` specs;
- Python's timeout contract (`process-wait 'timeout:` leaves the child for
  the caller to kill and drain) and **tree-kill** — `new-group: #t` +
  `process-kill 'group: #t` (a process group on POSIX, a Job Object on
  Windows), so an agent's own bash children die with it;
- argv-only spawning — issue text is untrusted and must never reach a
  shell (the library has no shell mode at all);
- budgets: wall-clock timeout per run, token/turn budget passed to the
  agent, per-night caps per stage.

Two shipped details stage code should assume: long-lived agent runs use
`spawn-process` (drive stdin/stdout from fibers, `process-wait` with a
deadline, group-kill on expiry); one-shot tool calls (`git`, `gh`) use
`run-process`, whose `timeout:` implies `new-group: #t` and kills with
SIGKILL, and whose stdin defaults to `'null` unless `input:` is given.

An earlier revision of this document specified a socat shim as an interim
transport while KEP-0022 was unreleased; it was never built and is no
longer needed. The one-module rule survives it for a different reason:
`lib/mesthiri/agent.sld` isolates the *agent protocol* (spawn arguments,
RPC framing, budget enforcement), so a second agent backend is a new
module, not a change to stage code.

## State

SQLite (`kaappi-sqlite`): issues seen, triage verdicts, queue claims,
pipeline runs (per-stage timings, agent spend, outcomes), webhook delivery
ids, retro facts. The database is the only state; the service is restartable
at any point.

## Guardrails (structural, not aspirational)

| Guardrail | Mechanism |
|---|---|
| Humans gate merges | the App has no merge permission; branch protection stays on |
| Sign-off | every commit made with `git commit -s` (DCO) |
| Untrusted input | issue/PR text is data; prompts label it as such; no shell ever sees it |
| Authenticated events | webhook deliveries HMAC-verified and de-duplicated; contents still untrusted |
| Least privilege | GitHub App installed on selected repos only, minimal declared permissions, short-lived installation tokens |
| Spend | per-run and per-night budgets enforced by the orchestrator, not the agent |
| Serial execution | one agent run in flight process-wide; budgets and scratch dirs cannot race |
| Runaway agents | tree-kill on timeout; bounded fix-loop depth |

## Non-goals

- Auto-merge, even on green CI (a target project may layer that on itself).
- A hosted multi-tenant service. (An App is how *you* grant mesthiri access
  to *your* repos; it is not a product listing.)
- Replacing the target project's CI, review culture, or triage rubric —
  mesthiri *consumes* those; it does not define them.

## Open questions

- The agent-backend protocol boundary: pi's RPC schema as-is, or a thin
  mesthiri-defined envelope so backends are swappable without touching
  stage code.
- Forge abstraction: GitHub first; GitLab/Forgejo later via the same
  REST-client module or a forge protocol. (GitHub App identity is a GitHub
  concept; the credential-provider seam is where a second forge's auth
  would attach.)
