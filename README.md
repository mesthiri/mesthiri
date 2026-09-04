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
**Kaappi ≥ 0.26** and builds directly on `spawn-process`/`run-process`.
[docs/plan.md](docs/plan.md) sequences the work: agent integration first,
then triage — the triage stage's job is verifying an issue's claims against
the code, and that needs the agent underneath it.

## The pipeline

| Stage | Trigger | What it does |
|---|---|---|
| **Triage** | cron | Classify incoming issues, verify their claims, apply priority labels per the project's rubric |
| **Prioritize** | cron | Score and rank the ready backlog |
| **Code** | queue | Pick up a ready issue, drive a coding agent to an implementation PR with tests, following repo conventions |
| **Review** | PR event | Multi-dimensional review: correctness, security, performance, intent alignment |
| **Fix** | review findings | Apply findings, push, re-run tests until clean |
| **Retro** | cron | Analyze completed workflows, file process-improvement proposals |

Every stage can also be run on demand with a slash command (`/triage`,
`/implement`, `/review`, `/fix`, `/retro`) by someone whose permission on the
repo covers it.

## Architecture (one paragraph)

A single Kaappi program, compiled to a standalone binary
(`zig build -Dbundle-src=`), running under systemd on a server. Fibers +
reactor timers drive the cron stages; a worker fiber drives a headless coding
agent — [pi](https://pi.dev/) first, via its `--rpc` JSON-over-stdio mode —
one run at a time, each inside a namespace sandbox whose only writable path
is that run's scratch clone; pipeline state lives in SQLite, while workflow
state lives in labels a human can read and change. The forge is reached
through its REST API, authenticated as a GitHub App you register and install
on your own repos; stages are woken by cron, by the queue, or by a slash
command from someone with the repo permission to issue it. Every event is
found by polling — mesthiri makes outbound requests and nothing listens, so
the server it runs on needs no hostname, no TLS, and no open inbound port. Guardrails are
structural: the App has no merge permission, the agent cannot reach the
credentials that drive it, its output is schema-checked outside itself, a
path denylist and intent tier decide what it may attempt at all, commits are
signed off, and every run has a token/turn budget and a kill-the-tree
timeout.

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
6. **Self-hosted.** You run the service and hold its credentials. There is
   no hosted mesthiri to sign up for.
7. **Contain the agent.** Prompt wording is not a security boundary. The
   sandbox decides what a subverted run can reach; everything else is
   defence in depth.
8. **Nothing listens.** Outbound HTTPS only. The cheapest attack surface to
   secure is the one that does not exist.

## License

MIT — see [LICENSE](LICENSE).
