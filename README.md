# mesthiri

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/mascot-dark.png">
  <img align="right" width="230" alt="A Great Hornbill perched on a steel beam, sighting a plumb line" src="assets/mascot.png">
</picture>

**Autonomous development-lifecycle agents for Git-hosted projects, written in
[Kaappi Scheme](https://kaappi-lang.org/).**

*Mesthiri* (മേസ്തിരി) is Malayalam for the site foreman — the person who
directs a crew of workers on a building site. That is what this project is:
an orchestrator that directs headless coding agents through the software
development lifecycle, while humans set direction, define guardrails, and
review outcomes. The mascot is a Great Hornbill — Kerala's state bird, which
grows its own hard hat and is here checking the wall against a plumb line rather
than building it. See [assets/README.md](assets/README.md) for the marks.

## Status: pre-alpha (every milestone landed, no live agent run yet)

The design is settled (see [docs/design.md](docs/design.md)) and
[docs/plan.md](docs/plan.md) sequences the work; M0 through M9 are now
ticked. That means the modules, dispatch, all six stages, the sandbox, the
release workflow and `mesthiri install` exist, under 466 assertions across
25 modules.

`run-agent` now spawns pi for real, and a test in the suite proves it: a
live pi process driven over its RPC protocol against a stub model server on
localhost, covering a run that settles, a model that hangs until the
deadline kills the process group, and a prompt pi refuses. That test found
four defects nothing else could — the agent inherited the job's whole
environment, App keys included; a refused prompt hung until a deadline that
was accepted as a parameter and never implemented; and the agent's reply was
read from the wrong shape and the wrong role, so every real run would have
ended at *settled without producing any text*.

What is still untested is a run against a **real model**, which needs a key
this repository does not have. The stub proves the protocol and the
plumbing; it cannot tell you whether a rubric produces good verdicts. Treat
the milestones as scaffolding that is tested end to end and has never done
the actual job.

The project's subprocess needs drove
[KEP-0022](https://github.com/kaappi/keps/blob/main/keps/0022-subprocess-support.md)
— native `(kaappi process)` support — which **shipped in Kaappi v0.26.0**
(all four phases; the KEP is Final), so mesthiri requires **Kaappi ≥ 0.26**
to build.

You will not need Kaappi to *use* it. A release is three files — the binary
plus the two C-FFI shared objects it links against — which the reusable
workflow downloads and checksums for you.

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
It was written ahead of the code as a design tool and the code has now
caught up to it — but until mesthiri has triaged a real issue with a real
model, treat it as a design preview rather than instructions. The tests
parse the guide's sample configuration with mesthiri's own reader and
validate its triggers, so the parts you would copy are at least real.

## The pipeline

| Stage | Trigger | What it does |
|---|---|---|
| **Triage** | issue events + schedule | Classify incoming issues, verify their claims, apply priority labels per the project's rubric |
| **Prioritize** | schedule | Score and rank the ready backlog |
| **Code** | label or command | Drive a coding agent to a tested implementation, then push and open the PR from outside the sandbox |
| **Review** | PR events | Multi-dimensional review: correctness, security, performance, intent alignment |
| **Fix** | review findings | Apply findings, push, re-run tests until clean |
| **Retro** | schedule | Analyze completed runs, file process-improvement proposals as issues on the installed repo |

Five of the six can also be run on demand by slash command — `/triage`,
`/implement`, `/review`, `/fix`, `/retro` — by someone whose own permission
on the repo covers it, and only where their inputs exist: `/triage` and
`/implement` on an issue, `/review` and `/fix` on a pull request, `/retro`
on either. Prioritize is scheduled only; it ranks a
backlog, which is not a thing you ask for one of.

## Architecture (one paragraph)

Diagrams — trust zones, the dispatch path, the credential boundary, the
label state machine — are in
[docs/architecture.md](docs/architecture.md).

There is no server and no database. A thin shim workflow in your repository
subscribes to native forge events and a schedule, and calls a reusable
workflow that downloads one checksummed Kaappi-compiled binary and runs
`mesthiri dispatch`: normalize the event, authorize it against the actor's
own permission — the commenter's for a command, the labeler's for a label —
match it to exactly one stage, run that stage in
that job. The coding agent — [pi](https://pi.dev/) first, via its
`--mode rpc` JSON-over-stdio mode — runs inside a namespace sandbox within the job, with
the scratch clone as its only writable path. State lives in the repository:
workflow state in labels a human can read and change, those same labels
acting as the watermark for scheduled sweeps, and run history in your CI's
own run history — mesthiri keeps no state you cannot see. Guardrails are
structural: mesthiri has no code path that merges, the shim uses
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
   exact, because the run enforces them on itself. Caps *across* runs count
   runs started and are derived from recent run history, so they are
   approximate — enough to stop a
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
