# mesthiri — ADLC orchestrator in Kaappi Scheme

Autonomous development-lifecycle agents (triage → prioritize → code →
review → fix → retro) for Git-hosted projects. `docs/design.md` is the
design authority; `README.md` is the public face. Keep both in sync with
reality — this repo has no code yet, and the README must keep saying so
until it does.

## Conventions

- Kaappi Scheme, 2-space indentation, R7RS style (same as the kaappi org).
- Commits: short imperative subject, body explains why, `git commit -s`
  (DCO trailer required).
- Library code under `lib/mesthiri/*.sld`, entry point `mesthiri.scm`,
  tests under `tests/` runnable as
  `kaappi --lib-path ./lib tests/test-<module>.scm`.
- All subprocess access (agent, git, gh) goes through one module —
  `lib/mesthiri/agent.sld` / `lib/mesthiri/proc.sld` — never inline, so the
  socat-shim interim and the eventual `(kaappi process)` (KEP-0022,
  kaappi#2418) swap in one place.
- Issue/PR text from target repos is untrusted input: never interpolate it
  into shell commands (argv-only) and label it as data in agent prompts.

## Related work

- KEP-0022 (native subprocess support): the core capability this project
  is waiting on — phases tracked in kaappi#2414–#2417, epic kaappi#2418.
- The kaappi org's issue rubric (`kaappi/docs/dev/github-issues.md`) is the
  first triage rubric mesthiri will target.
