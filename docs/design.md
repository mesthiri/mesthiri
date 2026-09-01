# mesthiri — design

Status: draft, 2026-08-29. Distilled from the research and design discussion
that produced [KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md);
this document records the decisions so the repo is self-explaining.

## What mesthiri is

An Agentic Development Lifecycle (ADLC) orchestrator: a long-running service
that executes the stages of the software development lifecycle with
autonomous coding agents, for any Git-hosted project, while humans set
intent, define guardrails, and review outcomes. The model follows the
published ADLC literature (agents execute; humans direct) and the working
precedent of fullsend.sh's six-stage pipeline, but is:

- **self-hosted on a plain server** (no GitHub Apps, no cloud sandbox
  service, no vendor enrollment);
- **written in Kaappi Scheme**, dogfooding the language and its ecosystem
  libraries (`kaappi-http`, `kaappi-json`, `kaappi-sqlite`, `kaappi-log`,
  `kaappi-cli`, fibers);
- **agent-agnostic**: the coding agent is a subprocess speaking JSON over
  stdio. The first backend is [pi](https://pi.dev/) (`pi --rpc`,
  MIT-licensed, minimal harness); the interface is small enough that other
  headless agents can slot in.

## Stage design

Each stage is a fiber (or pool of worker fibers) in one process:

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
4. **Review** (PR events): dimensions — correctness, security, performance,
   intent alignment — each an independent agent pass; findings verified
   adversarially before posting (a finding that cannot survive a refutation
   attempt is not posted).
5. **Fix** (review findings): apply findings, push, re-run tests; iterate
   to a bounded depth, then hand to a human.
6. **Retro** (cron): mine completed pipeline records (timings, iteration
   counts, failure classes) and file improvement proposals as issues.

## Process supervision

The agent, git, and gh are all subprocesses. Requirements that drove
KEP-0022 and define what mesthiri needs from `(kaappi process)`:

- streaming bidirectional pipes as fiber-parking ports (`pi --rpc` is a
  long-lived JSON event stream);
- Python's timeout contract (timeout leaves the child for the caller to
  kill and drain) and process-group / Job-Object **tree-kill** — an agent's
  own bash children must die with it;
- argv-only spawning — issue text is untrusted and must never reach a
  shell;
- budgets: wall-clock timeout per run, token/turn budget passed to the
  agent, per-night caps per stage.

### Interim: the shim

Until KEP-0022 Phases 1–2 land in a kaappi release, the agent runs behind
`socat TCP-LISTEN:<port>,fork EXEC:'pi --rpc'` under systemd, and mesthiri
connects with `kaappi-net`. The shim is scaffolding: it is deleted the day
`(kaappi process)` ships, and nothing in the stage code may depend on its
existence (all process access goes through one `mesthiri agent` module).

## State

SQLite (`kaappi-sqlite`): issues seen, triage verdicts, queue claims,
pipeline runs (per-stage timings, agent spend, outcomes), retro facts.
The database is the only state; the service is restartable at any point.

## Guardrails (structural, not aspirational)

| Guardrail | Mechanism |
|---|---|
| Humans gate merges | mesthiri has no merge permission; branch protection stays on |
| Sign-off | every commit made with `git commit -s` (DCO) |
| Untrusted input | issue/PR text is data; prompts label it as such; no shell ever sees it |
| Least privilege | fine-grained PAT scoped per target repo; no org-wide tokens |
| Spend | per-run and per-night budgets enforced by the orchestrator, not the agent |
| Runaway agents | tree-kill on timeout; bounded fix-loop depth |

## Non-goals

- Auto-merge, even on green CI (a target project may layer that on itself).
- A hosted multi-tenant service.
- Replacing the target project's CI, review culture, or triage rubric —
  mesthiri *consumes* those; it does not define them.

## Open questions

- The agent-backend protocol boundary: pi's RPC schema as-is, or a thin
  mesthiri-defined envelope so backends are swappable without touching
  stage code.
- Forge abstraction: GitHub first; GitLab/Forgejo later via the same
  REST-client module or a forge protocol.
- Where triage rubrics live: per-target-repo config file in the target
  repo, or mesthiri-side config.
