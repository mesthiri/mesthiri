# mesthiri

**Autonomous development-lifecycle agents for Git-hosted projects, written in
[Kaappi Scheme](https://kaappi-lang.org/).**

*Mesthiri* (മേസ്തിരി) is Malayalam for the site foreman — the person who
directs a crew of workers on a building site. That is what this project is:
an orchestrator that directs headless coding agents through the software
development lifecycle, while humans set direction, define guardrails, and
review outcomes.

## Status: pre-alpha (design settled, nothing runs yet)

The design is settled (see [docs/design.md](docs/design.md)) and
[docs/plan.md](docs/plan.md) sequences the work, but there is no code in
this repository yet. The project's subprocess needs drove
[KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md)
— native `(kaappi process)` support — which **shipped in Kaappi v0.26.0**
(all four phases; the KEP is Final), so mesthiri requires **Kaappi ≥ 0.26**
to build.

You will not need Kaappi to *use* it. mesthiri compiles to a standalone
binary that a workflow in your repository downloads and runs.

### Inspired by fullsend

The CI-native execution model here is learned from
[fullsend](https://fullsend.sh) — an Apache-2.0 Go project pursuing the same
goal at far larger scale, with multi-forge support, org-wide installation
and shared infrastructure mesthiri does not attempt. mesthiri is an
independent implementation in Kaappi Scheme rather than a port: no fullsend
code, schema or prose is copied, and mesthiri stays MIT. If you want this
capability in production today, look at fullsend first.

[docs/guide.md](docs/guide.md) shows the intended end-user experience —
install, configure, first triage, what a mesthiri pull request looks like.
It is written ahead of the code, so treat it as a design preview rather
than instructions.

## The pipeline

| Stage | Trigger | What it does |
|---|---|---|
| **Triage** | issue events + schedule | Classify incoming issues, verify their claims, apply priority labels per the project's rubric |
| **Prioritize** | schedule | Score and rank the ready backlog |
| **Code** | label or command | Drive a coding agent to a tested implementation, then push and open the PR from outside the sandbox |
| **Review** | PR events | Multi-dimensional review: correctness, security, performance, intent alignment |
| **Fix** | review findings | Apply findings, push, re-run tests until clean |
| **Retro** | schedule | Analyze completed runs, file process-improvement proposals as issues on the same repo |

Five of the six can also be run on demand by slash command — `/triage`,
`/implement`, `/review`, `/fix`, `/retro` — by someone whose own permission
on the repo covers it, and only where their inputs exist: `/implement` on an
issue, `/fix` on a pull request. Prioritize is scheduled only; it ranks a
backlog, which is not a thing you ask for one of.

## Architecture (one paragraph)

Diagrams — trust zones, the dispatch path, the credential boundary, the
label state machine — are in
[docs/architecture.md](docs/architecture.md).

There is no server and no database. A thin shim workflow in your repository
subscribes to native forge events and a schedule, and calls a reusable
workflow that downloads one checksummed Kaappi-compiled binary and runs
`mesthiri dispatch`: normalize the event, authorize it against the
commenter's own permission, match it to exactly one stage, run that stage in
that job. The coding agent — [pi](https://pi.dev/) first, via its `--rpc`
JSON-over-stdio mode — runs inside a namespace sandbox within the job, with
the scratch clone as its only writable path. State lives in the repository:
workflow state in labels a human can read and change, the same labels acting
as the cursor for scheduled sweeps, and run history in your CI's own run
history — mesthiri keeps no state you cannot see. Guardrails are
structural: no App holds merge permission, the shim uses
`pull_request_target` and never checks out a PR's code, the agent holds no
credential and has no route to the forge — it writes commits and the job
does the pushing — its output is schema-checked outside itself, a path
denylist and intent tier decide what it may attempt at all, commits are
signed off by the accountable human and disclose the machine that wrote
them, and every run has a token/turn budget and a kill-the-tree timeout.

## Principles

1. **Humans gate merges.** The pipeline's output is a reviewed PR, not a
   deploy.
2. **Independent validation.** The agent runs your test command while it
   works, but the evidence a change is good is your CI running on the pull
   request afterwards — not the agent's own account of how it went.
3. **Untrusted inputs.** Issue and PR text is data, never instructions to
   the orchestrator.
4. **Budgets, honestly.** A run's token, turn and wall-clock caps are
   exact, because the run enforces them on itself. Caps *across* runs are
   derived from recent run history and are approximate — enough to stop a
   runaway, not to bill against. That is the price of keeping no
   database.
5. **Bring your own agent.** The coding agent is a subprocess speaking a
   small protocol; pi is the first backend, not the only possible one.
6. **No new infrastructure.** Your CI is already the event receiver, the
   scheduler and the compute plane. A daemon would reproduce all three
   worse, and ask you to operate a server as well.
7. **Contain the agent.** Prompt wording is not a security boundary. The
   sandbox decides what a subverted run can reach; everything else is
   defence in depth.
8. **The repository is the coordinator.** State a human can read in the
   forge beats state in a database only mesthiri can see.

## License

MIT — see [LICENSE](LICENSE).
