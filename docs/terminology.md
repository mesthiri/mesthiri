# mesthiri — terminology

A descriptive document. [design.md](design.md) decides what these things
*are*; this file records what they are *called*, so that four documents and
a codebase use one word per concept. If a definition here disagrees with
design.md, design.md is right.

The last section is the useful one: words that are easy to confuse, and how
to tell them apart.

## The pipeline

**Stage** — one of the six units of work: triage, prioritize, code, review,
fix, retro. Exactly one stage runs per event.

**Run** — one execution of one stage, which is also exactly one CI job.
Budgets are per-run in this sense: a run's token, turn and wall-clock caps
cover everything that stage spends, including every agent turn inside it.
Where the docs say "run" they mean this; where GitHub says "job" it means
the same thing.

**Mode** — a stage's setting: `off`, `dry-run` or `live`. Defaults to
`off`. Dry-run does the work and reports it without writing to the forge.

**Verdict** — what triage produces for one issue: a priority label, an
intent tier, a rationale, and the commit SHA of the rubric it applied.

**Finding** — what review produces: one defect claim about a diff, posted
as a PR comment only after it survives an adversarial refutation attempt.

## Execution

**Shim** (shim workflow) — the thin workflow committed to the repository
being worked on. Subscribes to native events and a schedule, calls the
reusable workflow, and does nothing else. Never checks out a pull request's
code.

**Reusable workflow** — the workflow hosted in mesthiri's own repository
that the shim calls. Downloads the pinned release binary, verifies its
checksum, runs it. Distribution is layered through this: fixes ship here
and reach installed repositories without a pull request to each.

**Dispatch** — what the binary does with an event: normalize, authorize,
check the stage's mode, match trigger predicates, run the one matching
stage.

**Normalized event** — the single shape every trigger becomes, whether it
arrived from an issue, a comment, a pull request, a review or a schedule.
Stages read this rather than raw forge payloads.

**Trigger predicate** — the expression deciding whether a stage runs: short
forms over a fixed vocabulary, composed with `and`/`or` — the code stage's
is `(or (label "ready-to-implement") (command "/implement"))`.
**Interpreted, never `eval`ed**.

**Schedule** — a stage's `(schedule …)` trigger: a whole-hour UTC time,
optionally preceded by a weekday (`"07:00"`, `"sunday 06:00"`). The shim
carries one hourly tick and dispatch matches it against these, so changing a
schedule is a config edit rather than a workflow change. GitHub's scheduler
is best-effort, so a delayed tick runs its stages late rather than never.

**Command** — a slash command in a comment: `/triage`, `/implement`,
`/review`, `/fix`, `/retro`. Parsed by a plain grammar, never by a model.
`/triage` and `/implement` are issue commands; `/review` and `/fix` are
pull-request commands; `/retro` runs on either. Prioritize has no command.

## The agent

**Agent** — the coding agent, a subprocess speaking JSON over stdio.

**Backend** — *which agent program* mesthiri drives. `pi` is the first.
This is not the model.

**Provider** — *where models come from*: an endpoint, the secret holding
its key, and the environment variable name the backend expects to read that
key from. Declared once in config and referenced by name.

**Model** — the exact model a role uses, named in full. Floating aliases
are rejected rather than resolved.

**Harness** — one file per role holding everything that turns a generic
model into that role: system prompt, allowed tools, provider and model,
effort, budgets, sandbox policy. mesthiri ships a default for every role;
`.mesthiri/harness/<role>.scm` overrides any subset and inherits the rest.

**Role** — the identity a harness configures. Roles correspond to stages,
but the word points at the configuration rather than the work.

**Sandbox** — the namespace isolation around a running agent inside the CI
job: read-only root, the scratch clone as the only writable mount,
repository credentials outside the mount namespace, egress denied by
default.

**Scratch clone** — the working copy the agent may write to. The only part
of the filesystem it can change, and the only thing it leaves behind.

## Policy and gates

**Rubric** — the repository's own document describing how to classify
issues. mesthiri consumes it and does not author it, though `install`
writes a starter one the repository then owns.

**Priority label** — the rubric's output on an issue: how urgent it is.

**Intent tier** — how much authorization the work needs, independent of
urgency. Tier 0 is pre-authorized and trivially revertible; tier 1 is
authorized by the issue itself; tier 2 needs a human to say so explicitly —
and that saying-so is `/implement` from someone with write access. The
proposed tier is recorded in the verdict and the run record, never as a
label.

**Max-tier** — the code stage's ceiling, defaulting to 0, capping what the
label-driven path may claim; a human's explicit `/implement` is not capped
by it. What the fourth and fifth rungs of the adoption ladder actually
change.

**Deny-paths** — files no mesthiri change may touch, checked against the
finished diff before a pull request is opened and again in review.

**Eligibility** — the combined check of intent tier against max-tier and
diff against deny-paths, run before an agent is spawned and again on its
output.

**Workflow labels** — the state machine on the repository:
`ready-for-triage`, `triaged`, `ready-to-implement`, `in-progress`,
`ready-for-review`, `needs-fix`, `ready-for-merge`, `needs-human`. Guarded
transitions, mutually exclusive, and a new commit clears every downstream
label. Created with the install pull request — and re-created on demand if
deleted — dispatch applies `ready-for-triage` on issue open and the sweep
backstops the rest.

**Adoption ladder** — the documented progression from `mesthiri try`
through dry-run, live, tier 0, tier 1, to review and fix. No rung merges.

## People

**Operator** — the human who registered the Apps and installed mesthiri on
the repository. Exactly one per repository; rotation is a config edit.
Their name is in `config.scm`, they sign off every commit
mesthiri makes, and they are the person accountable for its output.

**Commenter** — whoever issued a slash command. Authorization is checked
against *their* permission on the repository, never mesthiri's. A label a
human applies that triggers a stage authorizes the same way, against the
labeler's permission; labels mesthiri's own Apps apply pass.

**Maintainer** — anyone with write access. Relevant because a maintainer
can obtain the repository's secrets, which is why an App must never grant
more than a maintainer already has.

## Identity and secrets

**Reader App** — the GitHub App used by triage, prioritize, review and
retro. Comments and moves labels; cannot write code.

**Writer App** — the GitHub App used by code and fix. Neither App has merge
permission.

**Installation token** — the short-lived credential minted per run from an
App's key. Masked in logs explicitly, because Actions only masks secrets it
already knows about.

**Secret** vs **key-env** — two names for the same key: what GitHub calls
it (`MESTHIRI_MODEL_KEY`) and what the backend expects to find in its
environment (`ANTHROPIC_API_KEY`).

## Records

**Run record** — what a run leaves behind: stage, outcome, timings, spend,
model, and the rubric SHA where relevant. It is contained in the JSONL
trace, not a separate artifact.

**JSONL trace** — the per-run artifact uploaded to CI, which retro mines
instead of a database. Retention follows CI artifact retention.

**`Generated-by` trailer** — the commit trailer naming mesthiri's version,
the backend, the provider and model, and the run URL.

**Sign-off** — the DCO `Signed-off-by` trailer naming the operator. A
statement about provenance and licensing, not a claim to have read the
diff.

## Words that are easy to confuse

**Backend, provider, model.** Three different things, and all of them sound
like "the AI part". The backend is the *program* (pi). The provider is
*where models come from* (an endpoint and a key). The model is *which
model* (an exact name). Changing one rarely means changing another.

**Sandbox.** Two unrelated meanings: the namespace isolation around the
agent, and `mesthiri/sandbox`, the disposable repository the demos run
against. Context always separates them, but a sentence about "the sandbox
repo" means the second.

**`.mesthiri/config.scm` and `lib/mesthiri/config.sld`.** The first is the
configuration file in the repository being worked on. The second is
mesthiri's module that reads it. This pair has already caused one real
defect.

**Priority and tier.** Triage assigns both, and they answer different
questions. Priority is *how urgent* — the rubric's judgement. Tier is *how
much authorization it needs*. A typo fix is low priority and tier 0; a
security fix can be high priority and tier 2.

**Off and dry-run.** Off means the stage does not run. Dry-run means it
runs, spends tokens, and writes nothing. A stage in dry-run still costs
money.

**Run and job.** The same thing, named from two directions: mesthiri's
"run" is GitHub's "job". A "run record" describes one stage execution, not
a whole pipeline.

**Operator, maintainer, commenter.** The operator signs the commits. A
maintainer has write access. The commenter is whoever typed the command,
and is the person a command is authorized against. Often the same human,
never interchangeable in a sentence about permissions.

**Shim and reusable workflow.** The shim lives in the repository being
worked on and is deliberately tiny. The reusable workflow lives here and
does the real work. Upgrades change the second, not the first.

## Words the documents no longer use

Retired when the execution model changed on 2026-09-04. Commits before that
date use them as mesthiri's own vocabulary; the current documents use some
of them only to describe the design that was replaced. Either way, none of
them names a part of mesthiri now.

| Retired | Was | Now |
|---|---|---|
| service, daemon | the long-lived process on a droplet | there is none; a binary runs in CI |
| store, database | SQLite pipeline state | labels, the forge, and CI run history |
| webhook receiver | the inbound endpoint that was planned | native CI triggers; nothing listens |
| cursor, state branch | where scheduled sweeps kept their place | labels are the watermark |
| targets (plural) | the list of repos one instance watched | mesthiri is installed per repository |
