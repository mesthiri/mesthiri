# mesthiri — user guide

> **Nothing here has run for real yet.** Every milestone has landed —
> dispatch, the shim workflow, all six stages, the sandbox — and the test
> suite drives a live pi process against a stub model server. What has
> never happened is a run against a real model or a real repository. This
> guide describes the experience mesthiri is built to deliver, written
> ahead of the code as a design tool, because a command that reads badly
> on the page will read worse in a terminal. Every transcript in this
> guide is designed, not captured. When something here turns out to be
> wrong once it is real, the guide is what changes first.

If a word here is unfamiliar or looks like it might mean two things,
[terminology.md](https://github.com/mesthiri/mesthiri/blob/main/docs/terminology.md) defines it — including the several that
genuinely are easy to confuse.

## What you get

A repository that triages its own issues, implements the small ones, and
opens pull requests you review. mesthiri runs entirely inside your existing
CI — there is no server to operate, no database, and nothing listening on a
port.

It never merges anything.

## In this guide

- [Try it before installing anything](try.md)
- [Installing](installing.md)
- [Configuring](configuring.md)
- [Choosing models](models.md)
- [Your first triage](first-triage.md)
- [Commands](commands.md)
- [What a mesthiri pull request looks like](pull-requests.md)
- [Turning autonomy up](autonomy.md)
- [About budgets](budgets.md)
- [When something goes wrong](troubleshooting.md)
- [Turning it off](turning-off.md)
- [What mesthiri will never do](never.md)
