# mesthiri — design

Status: draft, 2026-08-29; substantially revised 2026-09-04, when the
execution model changed from a self-hosted service to CI-native dispatch.
This document is the design authority — [plan.md](plan.md) sequences it,
[architecture.md](architecture.md) draws it, and
[terminology.md](terminology.md) fixes what each thing is called.

**Inspiration.** The CI-native execution model, the layered install, the
per-role identity split and the harness-as-configuration idea are all
learned from [fullsend](https://fullsend.sh), an Apache-2.0 Go project
pursuing the same goal at much larger scale. mesthiri is an independent
implementation in Kaappi Scheme, not a port: no fullsend code, schema or
prose is copied, and mesthiri stays MIT. Where fullsend reached a
conclusion first, this document says so.

## What mesthiri is

An Agentic Development Lifecycle (ADLC) orchestrator: agents execute the
stages of the software development lifecycle for a Git-hosted project while
humans set intent, define guardrails, and review outcomes. It is:

- **CI-native**: there is no service, no server and no database. mesthiri is
  a single standalone binary that a workflow in your repository downloads
  and runs. Your CI is the event receiver, the scheduler and the compute
  plane, because it already is all three for your tests;
- **written in Kaappi Scheme**, dogfooding the language and its ecosystem
  (`kaappi-http`, `kaappi-json`, `kaappi-cli`, `kaappi-log`), and compiled
  compiled to a binary plus two shared objects, so a target repository needs
  three files rather than a Kaappi installation. The binary embeds mesthiri's
  Scheme bytecode; kaappi's HTTP and TLS support is a C library the runtime
  `dlopen`s, so it cannot be embedded and travels alongside. v0.1.0 shipped
  the binary alone and failed at startup with `ffi-open: libkaappi_net`,
  which is why this says three files rather than "standalone". The build is two steps rather than the obvious one:
  `kaappi --compile` with explicit `--lib-path`s, then `zig build -Dbundle=`
  to embed the bytecode. `-Dbundle-src=` cannot be used, because it compiles
  with no library path and mesthiri's own modules do not resolve. Releases ship Linux x86_64 and arm64 for CI plus
  macOS arm64 for local `try` and `install` — neither of which spawns an
  agent, which is precisely why those two can run on a laptop where there
  is no sandbox to spawn one into;
- **agent-agnostic**: the coding agent is a subprocess speaking JSON over
  stdio. The first backend is [pi](https://pi.dev/) (`pi --mode rpc`); the
  interface is small enough that other headless agents can slot in.

### Why not a long-lived service

An earlier revision of this document specified a systemd service on a
droplet, polling the forge and keeping state in SQLite. It was replaced
because nearly everything it needed, the target repository's CI already
provides and already secures: ephemeral compute, native event delivery,
scheduled runs, secret storage, an audit trail, and an isolation boundary
that is rebuilt from scratch for every job. A daemon reproduces those
badly, adds a server to operate and patch, and asks the operator to trust
one more thing. The trade is that mesthiri now depends on the forge's CI
rather than standing alone — which is a real dependency, and a fair price
for deleting a server.

## Execution model

```
forge event ──► shim workflow ──► reusable workflow ──► mesthiri dispatch
                (in your repo)     (from mesthiri)       (one binary)
                                                              │
                                          normalize ──► authorize ──► match
                                                                        │
                                                              run one stage
```

**The shim** is a thin workflow committed to the target repository. It
subscribes to native triggers (`issues`, `issue_comment`,
`pull_request_target`, `pull_request_review`) plus a single hourly
`schedule` tick, and does nothing but call the reusable workflow. It is
deliberately small so that upgrades ship upstream rather than through a
pull request to every repo. Stage schedules live in `config.scm` as a
whole-hour UTC time — `"07:00"` — optionally qualified by a weekday for
something that need not run daily — `"sunday 06:00"`. Dispatch matches each
tick against them and runs whatever is due, so a schedule change is a config
edit and the shim never changes. GitHub's scheduler is best-effort — a delayed tick runs its
stages late rather than never.

**PR events use `pull_request_target`, and the shim never checks out the
pull request's code.** A workflow triggered by `pull_request` runs the
version of itself from the PR's own branch, so anyone opening a PR could
rewrite it and read the secrets it holds. `pull_request_target` runs the
base branch's copy instead. This is fullsend's ADR 0009 and it is not
optional; getting it wrong hands credentials to anyone who can open a pull
request.

**The reusable workflow** comes from this repository, downloads the pinned
mesthiri release binary, verifies its checksum, and runs it. Distribution is
**layered**: fixes to the workflow or the binary reach every installed repo
without an install step or a pull request. The cost is that each run depends
on this repository and its release assets being reachable, and that adopters
are trusting a pinned tag — which is why the checksum is verified rather
than assumed. Vendoring everything into the target repo instead is a
reasonable thing to want and is listed under Later, not ruled out.

**`mesthiri dispatch`** normalizes the CI event into one shape, authorizes
it, matches it against the configured stage triggers, and runs the single
matching stage in that job. One event, one stage, one job.

## Stages

1. **Triage** (scheduled + on issue events): verify the issue's claims
   against the code before trusting them — a diagnosis in an issue is a
   hypothesis, not a fact — classify per the target's own rubric, and
   propose exactly one priority label with a one-paragraph rationale. Never
   edits code.
2. **Prioritize** (scheduled): rank triaged issues into a ready queue. The
   repository's rubric ranking wins where it has one; otherwise issues
   promote oldest-triaged-first, with age breaking ties.
3. **Code** (label or command): implement, run the *project's own* test
   command, open a PR. One issue, one PR.
4. **Review** (PR events, **on pull requests mesthiri opened**, plus explicit
   `/review`): correctness, security, performance and intent alignment as
   independent passes; findings verified adversarially before posting,
   because a finding that cannot survive a refutation attempt is noise. An
   explicit `/review` on a pull request mesthiri did not open fetches the
   diff through the API into a read-only clone the agent cannot push from —
   the same sandbox minus any write path. The restriction itself is a
   built-in dispatch check, not a trigger predicate — a config cannot relax
   it — and `explain-event` reports it alongside the predicates it tested.

   The restriction is a spend gate, not modesty. `pull_request_target` fires
   for fork pull requests, so reviewing every incoming PR would let anyone
   who can open one start an agent run — fifty pull requests, fifty runs —
   with only an approximate per-day cap in the way. Reviewing other people's
   pull requests is a genuinely useful thing to want and is listed under
   Later, behind a spend gate worth trusting.
5. **Fix** (review findings): apply, push, re-run tests, to a bounded depth,
   then hand to a human.
6. **Retro** (scheduled): mine completed runs for timings, iteration counts
   and failure classes, and file improvement proposals as issues **on the
   repository mesthiri is installed in** — flaky tests burning agent budget,
   issues that keep escalating to a human, gaps in the rubric. It writes
   where the work is, using the same repo-scoped token as every other stage,
   so its proposals can re-enter the pipeline like any other issue.

## State without a database

The repository is the coordinator. This is the part of the CI-native model
that looks like a loss and is mostly a gain: state that lives in the forge
is state a human can read, audit and correct without shell access.

- **Workflow state lives in labels**: `ready-for-triage`, `triaged`,
  `ready-to-implement`, `in-progress`, `ready-for-review`, `needs-fix`,
  `ready-for-merge`, `needs-human`. Transitions are guarded, states are
  mutually exclusive, and a write is read back to confirm it took. **A new
  commit clears every downstream label**, so an approval cannot outlive the
  head that earned it. The labels are created through the API when `install`
  opens its pull request — they are inert until the workflow exists — and
  dispatch re-creates a missing one rather than failing a run. Dispatch
  applies `ready-for-triage` on issue open, and the scheduled sweep
  backstops it by picking up unlabeled or updated issues it finds by query.
- **Idempotency** comes from the forge, not from a lock table: a job checks
  whether it has already acted on this comment, commit or event id before
  acting, and CI concurrency groups collapse rapid-fire edits into one run.
  Every handler is written to be safe to run twice, because it will be.
- **There is no cursor file.** A scheduled sweep finds its work by querying
  the forge — issues carrying a label, or updated since a timestamp it can
  read from the issues themselves. Labels are the watermark. This costs more
  API calls per sweep than a stored cursor and buys the property that
  mesthiri keeps *no* state a human cannot see in the repository, and adds
  no odd-looking orphan branch to someone else's project.
- **Run history** is CI run history. Retro reads completed workflow runs and
  the JSONL trace each stage uploads as an artifact, rather than a table it
  maintained itself. The trace *contains* the run record — stage, outcome,
  timings, spend, model, rubric SHA where relevant — plus the per-turn
  detail retro needs; retention follows CI artifact retention.

The honest cost is spend accounting. A per-run budget is exact, because the
run enforces it on itself. A cap *across* runs has nowhere to keep a
counter, so it is derived instead: before starting an expensive stage, a job
queries recent workflow runs and their traces and declines if the day's
spend already looks exhausted. The per-day cap counts **runs started**;
schedules are whole-hour UTC, optionally weekday-qualified, matched against
the shim's hourly tick.
Approximate, lagging, and defeatable by
concurrent jobs starting at once — good enough to stop a runaway, not to
bill against. The alternative was a database, and the database was the thing
being deleted.

## Configuration

Configuration lives in the target repository under `.mesthiri/`, so a
repository carries its own policy and a fork carries a copy. It is
S-expressions read with `read` — no parser, no dependency, and the obvious
choice in a Scheme project, at the cost of being less familiar to a
maintainer who expected YAML.

- `.mesthiri/config.scm` — rubric path, budgets, denylist, command
  permissions, pinned agent version, the reader and writer App IDs, operator
  identity. There is no list of targets: mesthiri is installed on a
  repository and acts on that repository. The App IDs are public
  configuration; only the private keys are secrets. The guide's sample —
  deny-paths, `max-tier 0`, budgets, the pinned agent version — is the
  scaffold contract `install` produces, not an illustration. No model
  appears in it: models are a per-role choice and live in harness files,
  which is the backend/provider/model distinction `terminology.md` warns is
  easy to collapse.
- **`version`** is the config schema's own version, and mesthiri refuses a
  config whose version it does not know rather than guessing at fields it
  may not understand. It is the one field that exists for mesthiri's benefit
  rather than the repository's.
- `.mesthiri/harness/<role>.scm` — one file per agent role: system prompt,
  allowed tools, which provider and model, effort, budgets, sandbox policy.
  A role is configured in one reviewable file rather than scattered across
  workflow YAML, which is fullsend's harness idea (their ADR 0024).

**The reviewer must not be the implementer.** Where two providers are
declared, the review harness must use the other one; where only one is,
review must at least name a different model from the code harness, and a
config where they match is rejected. Nothing here is about mesthiri
approving its own work — it cannot, since findings are comments and no App
can merge. It is that a reviewer sharing the implementer's model shares its
blind spots, and a blind spot is exactly what adversarial verification is
supposed to catch. The `providers` block exists partly to make this
affordable.

**Harnesses have defaults.** mesthiri ships a harness for every role, so a
repository works with a `config.scm` and nothing else; nobody should have to
write a system prompt to see a first verdict. A `.mesthiri/harness/<role>.scm`
overrides any subset of the shipped one and inherits the rest. Two
resolution rules keep that from becoming guesswork: a harness that names no
provider gets the sole declared provider, and must name one if several are
declared; and **budgets only tighten** — a harness may lower the per-run
caps in `config.scm` but never raise them, so the repository-level number is
a ceiling rather than a suggestion. Upgrading mesthiri can change a shipped
default, including its model, which is a release-note matter.

### Providers, models and the endpoint

`(agent (backend pi) …)` names the *harness program* mesthiri drives, not
the model it drives it with. Those are separate choices and are configured
separately.

Providers are named once in `config.scm`; roles reference one by name:

```scheme
(providers
  (main (endpoint "https://api.anthropic.com")
        (secret   MESTHIRI_MODEL_KEY)     ; the Actions secret holding it
        (key-env  ANTHROPIC_API_KEY)))    ; the name the agent reads it from
```

`secret` and `key-env` are separate because they answer different
questions — what GitHub calls the secret, and what the backend expects to
find in its environment. Collapsing them would tie mesthiri's secret naming
to one vendor's convention. Naming providers rather than assuming one also
leaves room for a role to use a different vendor later, which is the shape
adversarial review would want, without a redesign to get there.

Two properties matter more than the syntax:

**The sandbox's egress allowlist is derived from the provider endpoint, not
written by hand.** An allowlist that disagrees with the endpoint the agent
actually calls produces a connection failure deep inside an agent run, which
looks like anything except the configuration typo it is. Deriving it deletes
that failure mode. The only egress entries an operator writes are the
package registries their own test command needs.

**It is not yet enforced, and this document claimed otherwise.** `bwrap`
runs with `--share-net`, so the agent reaches whatever the runner reaches;
`allowed-hosts` computes the list and `agent-smoke` reports it, and nothing
applies it. Enforcing it needs either root for iptables inside the runner or
an HTTP proxy the agent's client honours, and neither is built. Until one
is, containment is filesystem and credentials — which is where the
repository risk lives — and **not** network. Stated here rather than left
implied, because a control that is described and absent is worse than one
that was never promised: it gets counted on.

**Models are pinned, not aliased.** A harness names an exact model, and a
floating alias is rejected: an alias that silently moves changes every
verdict and every review afterwards, with nothing in the repository
recording that anything changed. This is the same failure as rubric drift,
which mesthiri already guards against by recording the rubric's commit SHA —
so the model name goes into the run record and the `Generated-by` trailer
for the same reason.

**Trigger expressions** decide which stage an event runs. They are
predicates over the normalized event, written in a small s-expression
language of short forms composed with `and`/`or` — the code stage's is
`(or (label "ready-to-implement") (command "/implement"))` —
**interpreted, never `eval`ed**. The config comes from the repository's base
branch and is maintainer-controlled, but an interpreter over a fixed
predicate vocabulary cannot be talked into arbitrary execution, and `eval`
can.

## Identity

mesthiri authenticates as GitHub Apps that the operator registers and
installs. Permissions are split by role, following fullsend's ADR 0007:
a **reader** App for triage, prioritize, review and retro — which comments
and moves labels but cannot write code — and a **writer** App for code and
fix.

**A correction worth stating plainly.** Earlier revisions of this document
said no App holds merge permission, as though that were something to
withhold. GitHub has no separate merge permission: merging a pull request is
authorised by `contents: write`, which the writer App needs in order to push
a branch at all. So the writer App *can* technically merge, and the promise
that mesthiri never does rests on two things instead — mesthiri has no code
path that calls the merge endpoint, and the target repository keeps branch
protection on. The first is ours to keep; the second is the operator's, which
is why the guide tells them to keep it. Compromising the reviewer's credential
then grants nothing the reviewer did not already have.

The App private key is a repository or organization secret, and mesthiri
does **not** set it for you. GitHub's secrets API requires NaCl sealed-box
encryption, which would pull a cryptography dependency into a binary whose
only other asymmetric need is one JWT signature; for a step taken once per
repository, `install` prints instructions and you paste the key. Recorded
here so it reads as a decision rather than an omission. The workflow mints a
short-lived installation token per run. Minting needs an RS256 JWT,
which the Kaappi ecosystem does not provide, so `jwt.sld` signs with a
one-shot `openssl dgst -sha256 -sign` through `run-process`: signing input
on stdin, key as a file path, never on argv. There is deliberately no
central token-mint service — fullsend needs one because it serves many
organizations; a single operator does not.

### Where the keys actually live

Three secrets, all GitHub Actions repository secrets: the two App private
keys and the model backend's API key. The two App IDs are not secrets —
they live in `.mesthiri/config.scm` as `(apps (reader <id>) (writer <id>))`.
Three consequences follow, and each is
easy to get wrong by improvising.

**The PEM has to touch disk.** `openssl dgst -sha256 -sign` takes the key as
a *file path*: stdin is already carrying the data being signed, and
KEP-0022 shipped without `pass-fds:`, so there is no descriptor to hand it
either. So the key is written to a file under the runner's temp directory at
mode 0600, signed with, and unlinked immediately — never into the workspace,
which gets cloned, archived and uploaded, and never anywhere the sandbox
mounts. The window is one `openssl` invocation long, and it is not zero;
saying so is better than implying the key never lands.

**The installation token must be masked explicitly.** Actions masks
*registered* secrets in logs. A token minted at runtime is not one, so
nothing hides it automatically — and on a public repository the run log is
public. mesthiri emits `::add-mask::` for the token the moment it has one,
and treats logging it deliberately as a bug rather than a style problem.

**An App's installation set is its blast radius.** Anyone with write access
to a repository can obtain that repository's secrets — push a branch with a
workflow that uses them, and masking stops accidents, not intent. That is
tolerable here precisely because neither App grants more on the repository
than a write-access maintainer already has. It stops being tolerable the
moment one App is installed on *several* repositories with its key stored in
each: a maintainer of the least-guarded repo can then mint tokens for all of
them. Sharing a pair of Apps across repos is fine when those repos share a
trust boundary — one organization, one set of maintainers, which is the
common case — and is a privilege escalation when they do not. Register
separate Apps whenever the maintainer sets differ.

## Agent execution and containment

The CI runner is already an ephemeral, isolated VM, which is most of the
isolation a daemon had to build. It is not all of it: the runner also holds
the job's credentials, and the agent is driven by attacker-writable issue
text. So within the job, `agent.sld` — the only module that may spawn the
agent — wraps it in a namespace sandbox: read-only root, the scratch clone
as the only writable mount, the token and key file outside the mount
namespace entirely, and a separate unprivileged uid. Network egress is
**not** filtered today — see the note above; the agent reaches what the
runner reaches, and the forge is off-limits to it because it holds no
credential rather than because a packet filter says so.

**Exactly one model key travels, and that is a limitation, not a design.**
The shim has a single `model-key` input, so a repository can fund one
provider. A config may declare several — they differ in `key-env` and `api`
— but only the one whose key occupies that channel will answer. It bites
where two stages must differ: review is refused if it runs the implementer's
provider and model, so on an account funding a single model, review cannot
run at all. `docs/plan.md` carries the open item.

**One credential does go in.** The agent needs its model backend's API key
to work at all, so that key — and only that key — is passed into the
sandbox as an environment variable. It is worth being explicit that this is
not an exception being smuggled past the rule: the model key buys tokens
from a model provider and grants nothing on the repository, so an agent that
leaks it costs money rather than code. The App keys and the installation
token, which do grant repository access, stay outside the mount namespace
where the agent cannot reach them at all. If a second credential ever seems
to belong inside, that is the moment to re-read this paragraph.

The mount namespace is not what enforces this, and assuming it did was a
real hole. A child process inherits its parent's **environment** regardless
of what is mounted, and the job's environment holds both App keys and the
forge token — so for as long as `agent.sld` spawned pi without saying
otherwise, every one of them was readable inside the sandbox, and nothing
failed to indicate it. The agent's environment is therefore **constructed
rather than inherited**: `PATH`, `HOME`, a couple of display settings, and
the one model key. Everything else is absent, not merely unreadable. This is
the same discipline as the file layout, applied to the channel the file
layout does not cover.

**The agent writes; the job pushes.** The agent produces commits in its
clone and exits. The job, outside the sandbox, reads the finished diff,
checks it against the eligibility rules, and only then pushes and opens the
PR. The agent holds no credential and has no route to the forge, so this is
the only path a change can take — the eligibility check sits *on* it rather
than beside it. A compromised agent can produce a bad diff, which is what
review is for, but it cannot deliver one.

**Output validation**: everything the agent returns is checked against a
declared schema outside the agent, with capped retries and then hard
failure. No unvalidated or merely plausibly-shaped output reaches stage
code. fullsend enforces this at the harness level (their ADR 0022) for the
same reason.

## Autonomy is earned

Adoption is a ladder, and each rung is boring for a while before the next
one. `mesthiri try` reads a repository and writes nothing. Triage in
`dry-run` comments its reasoning and applies no labels. Triage `live`
applies them. The code stage opens pull requests for tier 0 work, then
tier 1. Review and fix follow.

Stages therefore carry a `mode`, and it has three values rather than two:
`off`, `dry-run`, `live`. **`off` is the default**, and a freshly installed
repository has every stage off except triage in `dry-run` — otherwise
merging the install pull request would start opening real ones, which is not
what "install" should mean. The code stage additionally carries `max-tier`,
defaulting to 0, which is what rungs four and five of the ladder actually
move. There is no rung on which
mesthiri merges, and tier 2 waits for a human at every rung — the wait ends
with `/implement` from someone with write access, and nothing else ends it.

## Eligibility: what mesthiri may attempt

Branch protection stops a bad change merging; it says nothing about what
should be attempted. Two checks run before an agent is spawned:

- **A path denylist**, per repository, of files no mesthiri change may
  touch: auth and policy code, public API surface, deploy and CI
  definitions, ownership files, `.mesthiri/` itself. Enforced when the job
  reads the diff, and again as an automatic escalation in review.
- **An intent tier**: 0 pre-authorized and trivially revertible, 1 a single
  issue suffices, 2 a human must explicitly authorize before the code stage
  may claim it. That authorization is `/implement`: an explicit act by
  someone with write permission on that very issue, which is what "a human
  authorized this" means — there is deliberately no second mechanism and no
  label for it. The tier a verdict proposes is recorded in the verdict and
  the run record, never as a label. `max-tier` caps what the label-driven
  path may claim; it does not cap a human's own command. Review re-derives
  the tier from the diff independently, so a change that grew past its
  authorization is caught by someone other than its author.

## Commands

`/triage` and `/implement` are issue commands; `/review` and `/fix` are
pull-request commands; `/retro` runs on either. Parsed by a plain grammar,
never by a model. Authorized against
**the commenter's** permission on the repository, by one rule: a command
that can **change code** needs write or better (`/implement`, `/fix`); a
command that only produces **commentary** — comments, labels, issues —
needs triage or better (`/triage`, `/review`, `/retro`). Spend is not the
test, since every one of them costs tokens. An unauthorized
command gets a refusal comment, not silence.

**Labels that trigger a stage are authorized the same way.** The code stage
fires on `ready-to-implement`, and anyone holding GitHub's triage role can
apply a label — so a label a human applies is checked against that human's
permission exactly as the matching command would be (write, for a stage
that changes code). Labels mesthiri's own Apps apply pass the check: that
is the pipeline moving work a schedule or an already-authorized command
set in motion, not a new claim. Prioritize has no command: it
ranks a backlog, which is not a thing you ask for one of
(fullsend's ADR 0076 reaches the same split for implement/fix).

## Rubrics

Triage rubrics live **in the target repository**, at a path named in
`.mesthiri/config.scm` — the first target is the kaappi org's
`docs/dev/github-issues.md`. mesthiri consumes the rubric a project already
maintains rather than authoring policy for projects it does not run. A
config naming a rubric that does not exist is a startup error rather than a
silent fallback.

Most repositories have no such document, though, and "first write a policy
document" is a poor first five minutes. So `install` writes a **starter
rubric** into `.mesthiri/rubric.md` as part of its pull request — generic,
plainly marked as a starting point, and yours to rewrite from the moment it
lands. That keeps the non-goal intact: mesthiri consumes a rubric the
repository owns, and it owns this one too. `.mesthiri/**` is on the default
deny list, so mesthiri can never edit the rubric it is judged against. Every verdict records the
rubric's commit SHA, so an upstream rubric change reads as a behaviour
change instead of a mystery.

## Attribution and sign-off

Every commit carries a DCO `Signed-off-by` naming **the operator** — the
human who registered the Apps and installed mesthiri on the repository —
from an explicit `operator:` field, never inferred. Exactly one operator per
repository; rotation is a config edit. The kaappi-org preset ships a
placeholder the org fills in.

The DCO's text does not anticipate this case. Its clauses assume a human
chain: I wrote it, it derives from compatible prior work, or a *person* who
certified one of those handed it to me unmodified. An agent is not a person,
so the third does not apply, and the only clause that fits is the first —
the operator treating the agent as a tool they used, as they would a code
generator. That reading is available only to someone accountable for the
output, which is exactly why the sign-off cannot be delegated to a bot: a
certification with no person behind it certifies nothing.

The operator asserts provenance and licensing, not that they read every
line; reading is what review and the human merge gate are for. Three
trailers, and the shape is not arbitrary:

```
Signed-off-by: Operator Name <operator@example.org>
Co-authored-by: mesthiri[bot] <…+mesthiri[bot]@users.noreply.github.com>
Generated-by: mesthiri <version>; agent <backend> <version>;
             model <provider>/<model>; run <run-url>
```

The commit **author** is the operator too, because DCO checkers compare
sign-off against author and reject a mismatch — a bot-authored commit signed
by a human fails the very check it was meant to satisfy. Machine authorship
is disclosed rather than hidden, by the trailers, by the PR body, and by
the App showing as the pusher. With no `operator:` configured, the code
stage refuses to run.

## Guardrails (structural, not aspirational)

| Guardrail | Mechanism |
|---|---|
| Humans gate merges | mesthiri has no code path that merges; branch protection is the enforcing control (see below) |
| Least privilege | reader and writer Apps, installed per repository, short-lived tokens |
| Shim cannot be hijacked | `pull_request_target`, and the PR's code is never checked out by it |
| Agent containment | namespace sandbox inside the runner, refused if it cannot be built; credentials outside its mount namespace and absent from its environment. Egress is **not** filtered yet |
| Credential boundary | the agent writes commits, the job pushes; there is no second path to the forge |
| Untrusted input | issue and PR text is data; prompts label it as such; no shell ever sees it |
| Output validation | schema-checked outside the agent, capped retries, then hard fail |
| Eligibility | path denylist and intent tier checked before an agent is spawned |
| Command authorization | deterministic parse, authorized against the commenter's permission |
| Stale approval | any new commit clears downstream workflow labels |
| Config integrity | trigger predicates interpreted, never `eval`ed; `.mesthiri/` is on the denylist |
| Sign-off | the configured operator certifies; never the bot |
| Spend | per-run budgets exact; cross-run caps derived from recent run history, approximate by design |

## Non-goals

- Auto-merge, even on green CI. A project may layer that on itself.
- A hosted multi-tenant service, a central token mint, or org-wide
  installation. mesthiri installs per repository, for one operator.
- Replacing the target project's CI, review culture or triage rubric —
  mesthiri consumes those; it does not define them.
- **Working on itself.** mesthiri is never installed on its own repository.
  `install` refuses `mesthiri/mesthiri` by string match; forks are
  unaffected. An orchestrator that can modify the code deciding what it is
  allowed to do has no guardrail it cannot reach, and a flat rule is easier
  to keep than a denylist is to get exhaustively right. Improvements to
  mesthiri arrive the ordinary way: a human reads a retro issue and reports
  it here.
- Matching fullsend's scope. It is years and an organization ahead on
  multi-forge support, org-scale installation and shared infrastructure.
  mesthiri's claim is narrower: one repository, one operator, one binary,
  in Scheme.

## Open questions

- The agent-backend protocol boundary: pi's RPC schema as-is, or a thin
  mesthiri envelope so backends swap without touching stage code. Decide
  when a second backend appears.
- Forge abstraction: GitHub first. GitLab CI can run the same binary, and
  fullsend's two-path model — native triggers where they exist, scheduled
  polling elsewhere — is the shape to copy when it matters.
