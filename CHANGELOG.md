# Changelog

Written at release time from the commit log, never edited in a pull request.
Commit bodies in this project explain *why*, which is what a release note
needs — so the log is the source and `[Unreleased]` stays empty by design.

The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/), and
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.12] — 2026-09-04

### Fixed

- **A handler is told which command ran it.** It read a module-level box
  that nothing ever set, so the answer was always "none". Review uses that
  to tell an explicit `/review` from a trigger, and an explicit `/review` is
  the only thing authorizing review of a pull request mesthiri did not
  author — so every such request was skipped in silence, saying "not a
  mesthiri pull request and no /review" to someone who had just typed
  `/review`.
- **Review writes a trace**, where every other stage already did. Without
  one its reasoning was unauditable, retro could not read it, and "no
  findings" was indistinguishable from "did not run".

### Added

- The reusable workflow takes `model-secrets`, so a repository can fund more
  than one provider — see 0.1.11's note; the two changes together are what
  let review run on a different provider from code.

## [0.1.11] — 2026-09-04

### Fixed

- **A comment on a pull request is recognised as one.** GitHub delivers it
  as `issue_comment`, with the issue carrying a `pull_request` key, and
  mesthiri never looked at that key — so `/review` and `/fix`, both
  pull-request commands, were refused with "run it on the pull request" when
  they had been. Two of the five commands were unreachable.

## [0.1.10] — 2026-09-04

### Fixed

- **The agent's scratch is writable inside the sandbox.** v0.1.9 moved HOME
  out of the clone and under the read-only root, so pi refused at startup
  with `EROFS: read-only file system, open '…/.pi/agent/auth.json'`. There
  are two writable mounts now, for two reasons: the clone because the
  agent's output is the point, and the scratch because pi keeps state and it
  must not be the clone.
- **An untriaged issue says so.** The code stage logged `refused: tier #f
  needs a human`, where `#f` is not a tier — it means no mesthiri verdict
  exists on the issue yet. It now says that, and what to do about it.

## [0.1.9] — 2026-09-04

### Fixed

- **The code stage can open a pull request.** It could not: `authed-forge`
  minted an installation token and returned only the forge, so
  `MESTHIRI_WRITER_TOKEN` — the variable the stage read to clone and push
  with — was set by nothing. The clone was anonymous and `git push origin`
  had no credential. The stage now mints a writer token itself; dispatch
  still runs on the reader, and the writer is the only App that pushes or
  opens anything.
- **The push credential never lands in the clone.** It reached git through
  the remote URL, which git writes into the clone's `.git/config` — and the
  clone is the directory the agent runs in with read tools. It now travels
  as a file read by a credential helper: not in the URL, and not in argv
  either.
- **The deny-paths check sees untracked files.** The stage commits with `git
  add -A` while the check ran on `git diff --name-only`, which lists only
  modified tracked files. The gap is where an agent's stray output lands —
  unseen by the check, then swept into the pull request.
- **The agent's scratch moved out of the clone.** HOME and the stderr log
  were written inside the working tree; a real run put pi's home and a
  stderr log into a repository.

## [0.1.8] — 2026-09-04

### Fixed

- **`dry-run` comments its verdict.** It only logged, which made it
  indistinguishable from `off` to anyone reading the issue — and `dry-run` is
  what a fresh install ships, so that was the guide's entire first five
  minutes: a stage that ran, reached a verdict, and left no trace where a
  reader would look. `verdict->comment` had rendered the dry-run wording
  since M4 and nothing called it. The test asserted "dry-run makes no forge
  call at all", which is to say it asserted the defect.

## [0.1.7] — 2026-09-04

Everything here came from watching the agent triage real issues with a real
model, which is a class of defect no test written beforehand had found.

### Fixed

- **The agent runs in the directory it was given.** `agent-argv` took a
  `workdir` and ignored it; the only thing setting a working directory was
  bwrap's `--chdir`, so an uncontained run inherited whatever directory
  mesthiri was launched from. Locally that meant the agent read the
  operator's own checkout instead of the clone it was meant to judge — and
  reached the right verdict from the wrong evidence, which a green result
  would have hidden.
- **The verdict is extracted from the reply rather than assumed to be it.**
  Of the first four real verdicts, two were bare JSON, one opened with a
  paragraph of reasoning, and one was inside a ```` ```json ```` fence.
  Parsing the reply as-is raised on half of them, after the tokens were
  spent. A schema in the prompt does not buy a bare reply.
- **Triage gets the code it is asked to check.** It was handed an empty
  `RUNNER_TEMP`; the first live run shows the model working that out and
  spending two of its twelve turns hunting the filesystem. It now gets its
  own clone — its own rather than the job's checkout, since the sandbox
  binds the workdir writable and the checkout is where mesthiri reads the
  config and rubric from.

## [0.1.6] — 2026-09-04

### Fixed

- **Released binaries are built for the architecture baseline.** With no
  `-Dtarget`, Zig builds for the *host's* exact CPU features, and GitHub's
  runners are heterogeneous — so every release so far was specialised to
  whichever machine happened to build it and died with `SIGILL`, no message,
  on a runner that lacked those instructions. It looked like a code
  regression and was not: the same v0.1.4 binary dispatched cleanly at 08:03
  and core-dumped at 08:38. The release smoke test could never catch it,
  because it runs on the machine that did the build.

## [0.1.5] — 2026-09-04

### Fixed

- **The agent runs contained on GitHub's runners.** It did not: bubblewrap is
  not on the image, and installing it is not enough because Ubuntu 24.04
  ships `kernel.apparmor_restrict_unprivileged_userns=1`, under which bwrap
  is present, executable, and fails at `setting up uid map: Permission
  denied`. The reusable workflow installs it, relaxes that sysctl for the
  ephemeral runner VM, and proves a namespace can be created before the job
  depends on it.
- **`sandbox-available?` proves bwrap works rather than that it exists.**
  Presence and function came apart exactly as above, and a presence check
  reports a sandbox that is not there — the failure mode the module's own
  header calls worse than having none.
- **An uncontained agent is refused in CI**, where it was previously a
  warning that left the run going and the agent uncontained.

### Changed

- **Egress is documented as unfiltered, because it is.** bwrap runs with
  `--share-net`; `allowed-hosts` derives the list and `agent-smoke` reports
  it, and nothing applies it. design.md, architecture.md, the guide and the
  guardrails table each described a network control that does not exist.
  Containment is the filesystem and the absence of any repository
  credential; enforcement of the allowlist is an open item.
- `tests/test-sandbox.scm` asserts the boundary — a file outside the workdir
  cannot be written, the secrets directory is empty inside — with a baseline
  that the wrap can run anything at all, since a wrap that fails for an
  unrelated reason otherwise reads as perfect containment.

## [0.1.4] — 2026-09-04

Cut from what the first run against a real model showed.

### Fixed

- **A provider failure is reported as one.** pi retries a turn that failed at
  the provider three times with backoff and then settles normally, so a run
  whose every call failed still reaches `agent_settled` with empty messages
  and zero usage. mesthiri reported "the agent settled without producing any
  text" and crashed on it — the symptom, while the cause sat in the trace it
  had just uploaded. The outcome is now `model-error` and it carries the
  provider's own words, because an expired key, a rate limit and an empty
  account are three problems with three different fixes.

### Changed

- `tests/run-all.sh` fails when a test **raises**. kaappi prints the error,
  abandons that top-level form and carries on, so the assertion never runs,
  the counters never see it, and the file still exits 0. That had already
  happened once without being noticed.
- `docs/pi-rpc.md` gains the failed-turn shape and pi's retry sequence, and
  the fixture for it is a recorded trace of a real run rather than one
  written from a description of one.

## [0.1.3] — 2026-09-04

The release that makes mesthiri able to do anything at all.

### Added

- **`run-agent` spawns pi for real.** It always looked as though it did, and
  it never had: every test drove a stage through an injected runner, which
  proves the caller and not the thing being called. A live pi process is now
  driven over its RPC protocol by `tests/test-agent-live.scm`, against a stub
  model server on localhost — a run that settles, a model that hangs until
  the deadline kills the process group, and a prompt pi refuses. CI installs
  the pinned pi so it runs on every push.
- **The reusable workflow installs pi.** It downloaded the mesthiri binary
  and not the agent, so an installed repository authorized its event, matched
  a stage, and then failed at the point of the exercise.
- **`mesthiri install`, `uninstall` and `apps create`.** Installing declares
  five layers once — config, rubric, harnesses, labels, workflow — installs
  them forward, removes them in reverse, and reports which are present.
  Every file change arrives as a pull request.

### Fixed

- **The agent inherited the CI job's entire environment**, App private keys
  and forge token included. The design said the agent holds no credential and
  named the mount namespace as the mechanism, but a child inherits its
  parent's environment regardless of what is mounted. The agent's environment
  is now constructed rather than inherited.
- **A prompt pi refuses no longer hangs the run.** pi answers `success:false`
  and then waits for another command forever; the drive loop watched only for
  `agent_settled`, against a wall-clock deadline that was accepted as a
  parameter and never implemented. Both halves are real now, and a refusal
  comes back in pi's own words.
- **The agent's reply is read from the right shape and the right role.**
  `message.content` is a list of blocks, not a string, and `message_end`
  fires for the user's message too — so every real run would have ended at
  "the agent settled without producing any text", or handed the prompt back
  as though the agent had said it.
- **A trailing slash in a provider endpoint is stripped**, since pi appends
  `/chat/completions` to it. z.ai's own documentation writes the endpoint
  with the slash.

## [0.1.2] — 2026-09-04

### Fixed

- **A comment from mesthiri no longer costs a CI run.** Every comment it
  wrote fired an `issue_comment` event that dispatched, matched nothing and
  exited — correct, but a run per comment, and with six live stages that is
  noise. Dispatch now recognises its own comments by the marker it already
  stamps for idempotency and exits before parsing anything.

  Deliberately narrow. A *label* mesthiri applies still dispatches, or
  prioritize could never hand work to the code stage. And another bot's
  command is still honoured, because authorization here is by repository
  permission rather than by being human.

## [0.1.1] — 2026-09-04

### Fixed

- **v0.1.0 did not run.** The binary embeds mesthiri's Scheme bytecode, but
  kaappi's HTTP and TLS support is a C library loaded at runtime, so v0.1.0
  started and immediately failed with
  `ffi-open: libkaappi_net: cannot open shared object file`. Releases now
  ship `libkaappi_net` and `libkaappi_http` alongside the binary, all three
  covered by `SHA256SUMS`, and the reusable workflow installs them where the
  loader looks. If you pinned v0.1.0, move to this one — v0.1.0 cannot work.

## [0.1.0] — 2026-09-04

First release. The plumbing and the dispatch path, with no stage behind them
yet — see *Known limitations*.

### Added

- **Dispatch.** `mesthiri dispatch` normalizes a CI event, authorizes it,
  checks the stage's mode, matches one trigger and runs one stage. One event,
  one stage, one job.
- **A shim workflow template** (`templates/mesthiri.yml`) for installed
  repositories, and the reusable workflow it calls.
- **Slash commands** — `/triage`, `/implement`, `/review`, `/fix`, `/retro` —
  parsed by a plain grammar, never by a model. Authorized against the
  commenter's own permission, and restricted to the entity holding their
  inputs.
- **Label authorization.** A label a human applies that would trigger a stage
  is checked against the labeler's permission, exactly like the matching
  command.
- **`mesthiri explain-event`** — prints the normalized event and how each
  stage's trigger matched. The first thing to run when a stage did nothing
  and said nothing.
- **`mesthiri whoami`** — mints an installation token and reports the
  installation, its permissions and the remaining rate limit.
- **Configuration** read from a target repository's `.mesthiri/config.scm` as
  s-expressions, with trigger predicates interpreted over a fixed vocabulary.
- **App authentication** — RS256 JWTs signed through `openssl`, exchanged for
  short-lived installation tokens.
- `--version`.

### Security properties

These are the ones worth stating because they are structural rather than
intended, and each is covered by a test:

- The shim uses `pull_request_target` and contains **no checkout at all**, so
  a pull request cannot rewrite the workflow that holds the secrets.
- The reusable workflow **verifies the binary's checksum before `chmod +x`**.
- Trigger predicates are **interpreted, never `eval`ed** — an unknown form is
  refused rather than ignored.
- Commands are matched only at the start of a line and only as whole tokens,
  so text quoting a command does not invoke it.
- The App private key is written at mode 0600, used, and unlinked; the
  installation token is masked in the log the moment it exists.

### Known limitations

- **No stage is implemented.** Triage, prioritize, code, review, fix and
  retro are all still ahead. A dispatched event is normalized, authorized and
  matched, and then finds nothing to run. Installing this release gives you a
  pipeline that is correct and idle.
- Every stage defaults to `off`, so this is safe to install; it is simply not
  yet useful.
- Linux and macOS only. There is no Windows build.
