# Installing

## What you need first

- A repository with GitHub Actions enabled.
- Permission to register GitHub Apps in your account or organization.
- An API key for whichever model backend you use, as a repository secret,
  and the endpoint it belongs to.
  This is the one credential that goes *into* the agent's sandbox, because
  the agent cannot work without it. It buys model tokens and nothing else —
  it grants no access to your repository.

## Register the two Apps

mesthiri uses two Apps rather than one so that the stages which only read
code cannot write it:

| App | Used by | Permissions |
|---|---|---|
| `mesthiri-reader` | triage, prioritize, review, retro | issues and pull requests: write (for comments and labels); contents: **read** |
| `mesthiri-writer` | code, fix | contents: write; pull requests: write; issues: write (state comments on the issue) |

Neither App is given more than it needs — but note what that does *not*
buy you. GitHub has no separate merge permission: merging is authorised by
`contents: write`, which the writer needs to push a branch at all. mesthiri
never merges because it has no code path that calls the merge endpoint, and
because your branch protection stops it. Keep branch protection on; it is the
control that actually enforces this, rather than a permission you withheld.

```bash
mesthiri apps create
```

This prints the App creation page's URL and exactly what to put on it: the
name, the four permissions, and webhooks off. It does not pre-fill the form
and it does not create anything, which is deliberate rather than unfinished.
GitHub's App-manifest flow — the mechanism that *would* pre-fill it — ends by
handing the private key to whatever completed the flow. That has to be you,
at a browser, not a command that could log it. So the command does the part
that is easy to get wrong and stops where a person must be present.

`--org your-org` prints the organization's App page instead of your personal
one. One pair per repository is the default because an App's installation set
is its blast radius — see the note below. Sharing a pair across repositories
is right when they have the same maintainers and wrong when they do not.

## Store the keys

mesthiri does not set your secrets for you. GitHub's secrets API requires
sealed-box encryption that would pull a cryptography dependency into a
binary whose only other need for one is a JWT signature — so for a
one-time setup step, you paste them:

```
Add these to Settings → Secrets and variables → Actions:

  MESTHIRI_READER_KEY   contents of mesthiri-reader.private-key.pem
  MESTHIRI_WRITER_KEY   contents of mesthiri-writer.private-key.pem
  ANTHROPIC_API_KEY     your model backend's API key — name it whatever
                        your config's `(secret …)` says, and list it in
                        the shim's `model-secrets`

Then delete the .pem files. They are not needed again, and GitHub will
not show them to you a second time either.
```

The two App IDs are not secrets — they go in `.mesthiri/config.scm` as
`(apps (reader <id>) (writer <id>))`, which `install` scaffolds for you.

Two things worth knowing about that.

**Anyone with write access to this repository can obtain these secrets.**
That is true of every Actions secret — masking stops them appearing in a log
by accident, not someone deliberately exfiltrating them. It is acceptable
here because neither App grants more on *this* repository than a write-access
maintainer already has. It stops being acceptable if you install the same
pair of Apps on several repositories and store the keys in each: a
maintainer of the least-guarded one can then act on all of them. Sharing a
pair across repositories with the same maintainers is fine; sharing across
trust boundaries is a privilege escalation. Register separate Apps for
those.

**The model key is the one secret the agent itself can see**, because it
cannot call a model without it. Everything else stays in the job, outside
the sandbox. Budget it accordingly — a prompt-injected agent could spend it,
which is why per-run token caps exist, and it is also why that key should
not be one that unlocks anything else you own.

## Install

`install` runs on your machine with your own `GITHUB_TOKEN`, not with an App
token — the Apps are not installed on the repository yet, so there is no App
credential to use. Enrolling a repository is a decision a person makes, and
it carries their name.

```bash
mesthiri install owner/repo --operator "Your Name <you@example.org>"
```

The operator is required because the scaffolded config signs mesthiri's
commits with it, and a sign-off names a person.

This opens a pull request against your repository adding five files: a shim
workflow under `.github/workflows/`, a starter `.mesthiri/config.scm`, a
starter rubric, and a harness file per role saying which model that role
uses. Read it like any other pull request. The 8 workflow labels
dispatch and the sweeps coordinate through are created through the API when
the pull request is opened — they are inert until the workflow exists, and
dispatch re-creates any you delete rather than failing a run. Merging the
pull request is what turns mesthiri on. (`install` refuses
`mesthiri/mesthiri` itself.)

```
mesthiri install — opening a pull request, changing nothing directly

  labels      created
  added       .mesthiri/config.scm
  added       .mesthiri/rubric.md
  added       .mesthiri/harness/triage.scm
  added       .mesthiri/harness/review.scm
  added       .github/workflows/mesthiri.yml

https://github.com/owner/repo/pull/1204

Everything starts in dry-run: triage will comment its reasoning and apply
no labels until you change one line. Nothing else runs at all until you
enable it.
```

The rubric is a generic starting point, and rewriting it is the highest-value
thing you can do in your first week — every triage verdict is only as good
as the document it is applying. It lives under `.mesthiri/`, which is on the
default deny list, so mesthiri can never edit the rubric it is judged
against.

## About the `pull_request_target` in that workflow

If you read the workflow carefully you will see `pull_request_target`, and
if you know GitHub Actions security you will pause at it. Good — that
trigger is genuinely dangerous when it is used carelessly, and it is worth
knowing why it is here.

A workflow triggered by the ordinary `pull_request` event runs the copy of
itself *from the pull request's branch*. Any secret it can see is therefore
readable by anyone who opens a pull request, simply by editing the workflow
in their own branch. `pull_request_target` runs the base branch's copy
instead, which is the version you reviewed.

The danger with `pull_request_target` is the other half: because it holds
real secrets, checking out and running the pull request's code under it
hands those secrets to the contributor's code. mesthiri's shim therefore
**never checks out the pull request's code** — it passes the event through
and stops. The pull request's code is only ever fetched later, inside the
sandbox, by an agent that holds no repository credential at all.

Both halves matter, and neither is optional. If you ever find yourself
editing the shim to add a checkout step, that is the mistake this paragraph
exists to prevent.
