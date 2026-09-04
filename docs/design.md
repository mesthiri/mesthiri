# mesthiri — design

Status: draft, 2026-08-29 (revised 2026-09-04: GitHub App identity, serial
execution, rubric location; then agent containment, command surface,
eligibility policy, output validation). Distilled from the research and design discussion
that produced [KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md);
this document records the decisions so the repo is self-explaining.
[architecture.md](architecture.md) draws the same system as diagrams.

## What mesthiri is

An Agentic Development Lifecycle (ADLC) orchestrator: a long-running service
that executes the stages of the software development lifecycle with
autonomous coding agents, for any Git-hosted project, while humans set
intent, define guardrails, and review outcomes. The model follows the
published ADLC literature (agents execute; humans direct) and the working
precedent of fullsend.sh's six-stage pipeline, but is:

- **self-hosted**: you run the service and its database on your own
  server, and it talks to the world over outbound HTTPS only — nothing
  listens. Identity is a GitHub App *you* register and install on *your*
  repos; there is no hosted multi-tenant service, no cloud sandbox
  provider, and no vendor to enroll with;
- **written in Kaappi Scheme**, dogfooding the language and its ecosystem
  libraries (`kaappi-http`, `kaappi-json`, `kaappi-sqlite`, `kaappi-log`,
  `kaappi-cli`, fibers);
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

Serial does not mean single-target. Several repos are polled each cycle and
served **round-robin**, so a busy repo cannot starve a quiet one — fairness
is in the queue from the beginning rather than retrofitted into one that
assumed a single target. Rate limit and nightly budget are shared across
targets and accounted per target.

1. **Triage** (cron): poll open issues since the last cursor; for each,
   verify the issue's claims against the code before trusting them
   (diagnosis in an issue is a hypothesis, not a fact); propose exactly one
   priority label per the target project's documented rubric; post label +
   one-paragraph rationale. Never edits code.
2. **Prioritize** (cron): rank triaged issues into a ready queue
   (RICE-style scoring where the project has no rubric of its own).
3. **Code** (queue-driven): claim a ready issue; clone into a scratch
   worktree; drive the agent to a tested implementation; run the *project's
   own* test command. The agent writes commits in its clone and stops
   there — **the service pushes**, because the agent holds no credential
   and has no network path to the forge (see *Agent containment*). Between
   the two sits the eligibility check: the service reads the finished diff,
   refuses it if it touches a denied path, and only then pushes the branch
   and opens the PR. One issue, one PR.
4. **Review** (PR events, discovered by polling): dimensions — correctness,
   security, performance, intent alignment — each an independent agent pass;
   findings verified adversarially before posting (a finding that cannot
   survive a refutation attempt is not posted).
5. **Fix** (review findings): apply findings, push, re-run tests; iterate
   to a bounded depth, then hand to a human.
6. **Retro** (cron): mine completed pipeline records (timings, iteration
   counts, failure classes) and file improvement proposals as issues on
   mesthiri — where a human picks them up, since mesthiri is not a target
   of its own pipeline (see *Non-goals*).

## Triggers and the command surface

Stages are reached three ways, and all three arrive as the same
**normalized event** so routing logic lives in one place:

- **cron** — reactor timers for triage, prioritize, retro;
- **queue** — the code stage draining ready work;
- **commands** — a human typing `/triage`, `/implement`, `/review`, `/fix`
  or `/retro` in an issue or PR comment.

Commands are parsed **deterministically** — a plain grammar, never a model —
so an issue body cannot talk the parser into a command it did not contain.
Every command is authorized against the **commenter's** permission on the
target repository, fetched from the forge, not against mesthiri's own: a
mutating command (`/implement`, `/fix`) requires write or better, a
read-only one (`/triage`, `/review`) requires triage or better, and an
unauthorized command is answered with a refusal comment rather than
silence. Commands are further restricted to the entity where their inputs
exist — `/implement` on an issue, `/fix` on a PR — and de-duplicated by
comment id so a re-delivered event cannot run a stage twice.

Events are discovered by **polling** the forge on a cursor. mesthiri makes
outbound requests and accepts no inbound ones; there is no webhook receiver
and no listening socket (see below). Stages consume the normalized event
and never see how it was found.

## Forge identity and event discovery

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
- **How the signature is made**: RS256 does not exist in the Kaappi
  ecosystem, and mesthiri does not add it. The signing input goes over
  stdin to a one-shot `openssl dgst -sha256 -sign` through the same
  `run-process` path that already drives `git` — the key is passed
  as a file path, never on argv, and never leaves the host. Base64url is
  about twenty-five lines of Scheme, since kaappi core does not export
  base64 either. That is the whole of it: no `kaappi-crypto` dependency, no
  cross-repo release on the critical path, and one more binary to have
  installed. OpenSSL is already a system dependency here — `kaappi-net`
  links it for TLS — so this asks for the CLI that normally ships beside
  the library rather than for anything new.
- **Events**: found by polling, not delivered. A cursor per target and per
  event class (issues, issue comments, pulls, reviews) advances on a
  watermark; conditional requests carry the previous `ETag`, so an
  unchanged poll returns `304` and costs nothing against the rate limit.
  Work already handled is de-duplicated by issue, comment and commit id in
  the store, so a re-read is idempotent. The App is registered **without a
  webhook URL**, which means there is no webhook secret to hold and one
  fewer credential on disk.

### Why no webhook receiver

A receiver was considered and rejected. Webhooks buy low latency, and
mesthiri has little use for it: three of its six stages run on cron, two
more are driven by its own queue rather than by anything arriving from
outside, and only review waits on an external event. That plus commands is
the whole latency-sensitive surface, and both are answered well enough on a
poll interval measured in a few minutes. Against that, a receiver costs a
public inbound endpoint on the operator's server, a hostname and TLS
termination in front of it, signature verification, replay and body-size
handling, and a second credential to store — all of it exposed to the
internet, on a service whose entire threat model is about not trusting what
arrives from outside. Polling also fails better: a webhook missed while the
droplet reboots is gone (and GitHub disables an endpoint that keeps
failing), whereas a poll re-reads the source of truth and catches up on its
own. The trade-off accepted is latency and a steady trickle of API reads;
the trade-off refused is being reachable from the internet at all.

This is the same conclusion other ADLC orchestrators reach, though by a
different route: a project built on hosted CI can make the CI system itself
the receiver, with a thin workflow in each target repo forwarding native
events inward. That option is not open to a long-lived service on a
droplet — a shim would have nowhere to forward *to* except an inbound
endpoint, which is the thing being avoided — so mesthiri polls for
everything rather than for some things.

## Rubrics

Triage rubrics live **in the target repository**, at a path named in
mesthiri's per-target config (the first target is the kaappi org's
`docs/dev/github-issues.md`). mesthiri consumes the rubric a project already
maintains; it does not author policy for projects it does not run. A target
with no rubric file is not eligible for triage, and that is a startup
configuration error rather than a silent fallback. Every triage verdict
records the commit SHA of the rubric it was decided under, so an upstream
rubric change is visible as a behaviour change instead of a mystery.

## Eligibility: what mesthiri may attempt

Branch protection stops a bad change from *merging*. It says nothing about
what mesthiri should try in the first place, and an orchestrator that
attempts anything an issue asks for is one well-written issue away from
proposing a change to its own guardrails. Two mechanisms decide eligibility
*before* an agent is spawned:

- **A path denylist**, per target, of files no mesthiri-authored change may
  touch: auth and policy code, public API surface, deploy and CI
  definitions, ownership files, and mesthiri's own configuration. Enforced
  twice — the code stage refuses to open a PR whose diff touches a denied
  path, and the review stage treats such a diff as an automatic escalation.
- **An intent tier** on the issue, deciding whether the issue alone is
  sufficient authorization to act. Tier 0 (pre-authorized, additive,
  trivially revertible — typos, doc fixes), tier 1 (a single issue
  suffices — the ordinary bug fix), tier 2 (a human must say so explicitly
  before the code stage may claim it — features, migrations, anything
  cross-cutting). Triage assigns a proposed tier; only a human can raise
  the ceiling. The review stage re-derives the tier independently from the
  diff, so a change that grew past its authorization is caught by someone
  other than the agent that wrote it.

Neither mechanism is a substitute for review; both exist so that review is
not the *only* thing standing between an issue and a change.

## Process supervision

The agent and git are both subprocesses, supervised through
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
deadline, group-kill on expiry); one-shot tool calls (`git`, `openssl`) use
`run-process`, whose `timeout:` implies `new-group: #t` and kills with
SIGKILL, and whose stdin defaults to `'null` unless `input:` is given.

An earlier revision of this document specified a socat shim as an interim
transport while KEP-0022 was unreleased; it was never built and is no
longer needed. The one-module rule survives it for a different reason:
`lib/mesthiri/agent.sld` isolates the *agent protocol* (spawn arguments,
RPC framing, budget enforcement), so a second agent backend is a new
module, not a change to stage code.

## Agent containment

Supervision bounds how *long* an agent runs and kills its children when the
deadline passes. It does not bound what the agent can reach while it runs,
and mesthiri's threat model demands that it must: the agent is driven by
attacker-writable issue text, and it runs on the same host as the App
private key. Tree-kill after the fact is not containment.

So the agent is spawned inside a **sandbox** — Linux namespaces via
`bwrap`/`unshare`, wrapped by `agent.sld` and by nothing else, so a stage
cannot spawn an unsandboxed agent even by mistake:

- read-only root filesystem;
- the run's scratch clone as the only writable mount, and the *only* part of
  the host filesystem the agent can see at all;
- the secrets directory (App private key, cached tokens) outside the mount
  namespace entirely — unreachable rather than merely unreadable;
- network egress restricted to what the run needs (the target's package
  registries, the model endpoint), denied by default — **the forge is not
  on that list**: the agent neither pushes nor calls the API, because it
  has no credential to do either with;
- a separate unprivileged uid, so a namespace escape still lands somewhere
  that owns nothing.

This is why the code stage splits in two. The agent writes commits into
its clone and exits; the service, outside the sandbox, reads the resulting
diff, applies the eligibility rules to it, and does the pushing. A
compromised agent can therefore produce a bad diff — which is what review
is for — but it cannot deliver one anywhere by itself.

Blast radius is then what the sandbox permits, which is the point. The
sandbox is a Linux-only mechanism; on a developer's macOS machine mesthiri
runs the agent uncontained and says so loudly at startup, because a
development convenience that fails silently in production is worse than no
convenience at all.

## Output validation

Everything an agent returns is validated against a declared schema
**outside the agent** before any stage code reads it: a triage verdict, a
review finding, a tier re-derivation. Validation failure is retried a
capped number of times and then fails the run — no unvalidated,
partially-parsed, or plausibly-shaped output flows downstream. The agent
proposes; `agent.sld` decides whether what came back is even the right
shape to consider.

## State

SQLite (`kaappi-sqlite`): issues seen, triage verdicts, queue claims,
pipeline runs (per-stage timings, agent spend, outcomes), poll cursors and
`ETag`s, ids already handled, retro facts. The database is mesthiri's own
state, and the service is restartable at any point.

Workflow state, though, lives where humans can see it: **in labels on the
target repo**. `ready-for-triage`, `ready-to-implement`, `ready-for-review`,
`ready-for-merge`, `needs-human`, `blocked`. Transitions are guarded — only
declared moves are legal, the states are mutually exclusive, and a
transition is written then read back to confirm it took. The rule that
earns the machine its keep: **a new commit clears every downstream label**,
so a `ready-for-merge` earned by one head cannot survive the push that
invalidated it. A human reading the issue can see what mesthiri thinks
without reading mesthiri's database, and can change it by changing a
label.

## Guardrails (structural, not aspirational)

| Guardrail | Mechanism |
|---|---|
| Humans gate merges | the App has no merge permission; branch protection stays on |
| Sign-off | every commit made with `git commit -s` (DCO) |
| Untrusted input | issue/PR text is data; prompts label it as such; no shell ever sees it |
| Agent containment | agent runs in a namespace sandbox: read-only root, scratch clone the only writable mount, secrets outside the namespace, egress denied by default |
| Output validation | agent output schema-checked outside the agent; capped retries then hard fail |
| Command authorization | commands parsed deterministically and authorized against the *commenter's* repo permission |
| Eligibility | path denylist and intent tier checked before an agent is spawned, not at merge time |
| Stale approval | any new commit clears downstream workflow labels |
| No inbound surface | outbound HTTPS only; nothing listens, so nothing can be reached |
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
- **Working on itself.** Retro files improvement proposals as issues on
  mesthiri, and a human implements them. mesthiri is never configured as a
  target of its own pipeline: an orchestrator that can modify the code
  deciding what it is allowed to do has no guardrail left that it cannot
  reach. The denylist protects targets from mesthiri; this protects
  mesthiri from itself, and a rule is easier to keep than a denylist is to
  get exhaustively right.

## Open questions

- The agent-backend protocol boundary: pi's RPC schema as-is, or a thin
  mesthiri-defined envelope so backends are swappable without touching
  stage code.
- **Who signs off.** Every commit carries a DCO `Signed-off-by`, and the
  kaappi org enforces it. A sign-off is a person certifying the origin of a
  contribution, which `mesthiri[bot]` cannot meaningfully do. Candidates:
  sign off in the operator's name (they configured the instance and are
  accountable for it), sign off as the bot and let the human reviewer's
  merge be the certification, or require a human to add their own sign-off
  before a mesthiri PR is mergeable. This needs settling before the first
  PR to a repo that enforces DCO — which is M5's demo.
- Forge abstraction: GitHub first; GitLab/Forgejo later via the same
  REST-client module or a forge protocol. (GitHub App identity is a GitHub
  concept; the credential-provider seam is where a second forge's auth
  would attach.)
