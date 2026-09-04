# Changelog

Written at release time from the commit log, never edited in a pull request.
Commit bodies in this project explain *why*, which is what a release note
needs — so the log is the source and `[Unreleased]` stays empty by design.

The format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/), and
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.0] — not released

Nothing has been released yet. M1 (the modules) and M2 (dispatch, the shim,
commands) are in; no stage is implemented, so a released binary would
authorize an event correctly and then find nothing to run.

The first release matters more than a version number usually does: the
reusable workflow pins a version, so publishing one and bumping that pin is
what every installed repository starts executing.
