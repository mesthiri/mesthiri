# Changelog

Written at release time from the commit log, never edited in a pull request.
Commit bodies in this project explain *why*, which is what a release note
needs — so the log is the source and `[Unreleased]` stays empty by design.

The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/), and
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
