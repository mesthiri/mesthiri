# mesthiri

**Autonomous development-lifecycle agents for Git-hosted projects, written in
[Kaappi Scheme](https://kaappi-lang.org/).**

*Mesthiri* (മേസ്തിരി) is Malayalam for the site foreman — the person who
directs a crew of workers on a building site. That is what this project is:
an orchestrator that directs headless coding agents through the software
development lifecycle, while humans set direction, define guardrails, and
review outcomes.

## Status: pre-alpha (design settled, implementation unblocked)

Nothing runs yet, but nothing is waiting on the platform anymore. The
design is settled (see [docs/design.md](docs/design.md)), and the project's
subprocess needs drove
[KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md)
— native `(kaappi process)` support — which **shipped in Kaappi v0.26.0**
(all four phases; the KEP is Final). mesthiri therefore requires
**Kaappi ≥ 0.26** and builds directly on `spawn-process`/`run-process`;
implementation starts with the triage stage.

## The pipeline

| Stage | Trigger | What it does |
|---|---|---|
| **Triage** | cron | Classify incoming issues, verify their claims, apply priority labels per the project's rubric |
| **Prioritize** | cron | Score and rank the ready backlog |
| **Code** | queue | Pick up a ready issue, drive a coding agent to an implementation PR with tests, following repo conventions |
| **Review** | PR event | Multi-dimensional review: correctness, security, performance, intent alignment |
| **Fix** | review findings | Apply findings, push, re-run tests until clean |
| **Retro** | cron | Analyze completed workflows, file process-improvement proposals |

## Architecture (one paragraph)

A single Kaappi program, compiled to a standalone binary
(`zig build -Dbundle-src=`), running under systemd on a server. Fibers +
reactor timers drive the cron stages; worker fibers drive a headless coding
agent — [pi](https://pi.dev/) first, via its `--rpc` JSON-over-stdio mode —
in isolated clones; pipeline state lives in SQLite; the forge is reached
through its REST API. Guardrails are structural: agents open PRs and never
merge, commits are signed off, issue text is treated as untrusted input, and
every agent run has a token/turn budget and a kill-the-tree timeout.

## Principles

1. **Humans gate merges.** The pipeline's output is a reviewed PR, not a
   deploy.
2. **Independent validation.** The project's own CI, not the agent's
   self-assessment, is the evidence a change is good.
3. **Untrusted inputs.** Issue and PR text is data, never instructions to
   the orchestrator.
4. **Budgets everywhere.** Per-run and per-night caps on agent spend.
5. **Bring your own agent.** The coding agent is a subprocess speaking a
   small protocol; pi is the first backend, not the only possible one.

## License

MIT — see [LICENSE](LICENSE).
