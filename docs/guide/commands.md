# Commands

Five of the six stages can be run on demand from an issue or pull request
comment, by someone whose own permission on the repository covers it:

| Command | Where | Minimum permission |
|---|---|---|
| `/triage` | issue | triage |
| `/implement` | issue | write |
| `/review` | pull request | triage |
| `/fix` | pull request | write |
| `/retro` | either | triage |

Commands are matched by a plain grammar, never by a model, so a command
written inside an issue *body* is text and not an instruction. Prioritize
has no command: it ranks a backlog, which is not a thing you ask for one
of.

Your own permission is what counts, not mesthiri's:

> **mesthiri** commented on #418
>
> `/implement` needs **write** permission on this repository and you have
> **read**. Nothing has run.
>
> If this should go ahead, someone with write access can issue the command
> or apply `ready-to-implement`.

Labels are authorized the same way: applying `ready-to-implement` yourself
is checked like `/implement`, so a human's label needs write. Labels the
prioritize stage applies are mesthiri moving its own work forward and are
not re-checked.

## Why review only runs on mesthiri's pull requests

Review does not fire on pull requests other people open, and that is a
spend gate rather than a judgement about your contributors. The shim
subscribes to `pull_request_target`, which fires for fork pull requests too
— so reviewing everything would let anyone who can open a pull request start
an agent run on your budget. Fifty pull requests, fifty runs. Until there is
a spend gate worth trusting, review stays on the loop mesthiri owns; you can
always ask for one with `/review`, which is permission-checked. An explicit
`/review` on a foreign pull request fetches the diff through the API into a
read-only clone the agent cannot push from.
