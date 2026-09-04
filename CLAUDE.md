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
  `lib/mesthiri/agent.sld` / `lib/mesthiri/proc.sld` — never inline, so a
  second agent backend is a new module, not a change to stage code. Built
  on `(kaappi process)` (KEP-0022, shipped in kaappi v0.26.0; requires
  kaappi ≥ 0.26): `spawn-process` for the long-lived agent, `run-process`
  for one-shot git/gh calls.
- Issue/PR text from target repos is untrusted input: never interpolate it
  into shell commands (argv-only) and label it as data in agent prompts.

## Related work

- KEP-0022 (native subprocess support): **Final** — shipped in kaappi
  v0.26.0 (phases kaappi#2414–#2417, epic kaappi#2418, all closed). The
  KEP's As-implemented section records the shipped surface and its
  divergences (no `pass-fds:`; `run-process` gained `output:` and the
  `timeout:`-implies-`new-group:` rule).
- The kaappi org's issue rubric (`kaappi/docs/dev/github-issues.md`) is the
  first triage rubric mesthiri will target.
