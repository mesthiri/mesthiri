# Changelog

Written at release time from the commit log, never edited in a pull request.
Commit bodies in this project explain *why*, which is what a release note
needs — so the log is the source and `[Unreleased]` stays empty by design.

The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/), and
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
