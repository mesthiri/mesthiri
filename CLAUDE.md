# mesthiri — CI-native ADLC orchestrator in Kaappi Scheme

Autonomous development-lifecycle agents (triage → prioritize → code →
review → fix → retro) for Git-hosted projects. **There is no service and no
database**: mesthiri is a standalone binary that a shim workflow in the
target repo runs, with the forge as the coordinator. The execution model is
inspired by [fullsend](https://fullsend.sh) (Apache-2.0, Go) — ideas only,
independently implemented, mesthiri stays MIT; never copy their code, prose
or schemas. `docs/design.md` is the
design authority; `docs/plan.md` sequences it into milestones (M0–M9 —
check its boxes as work lands, and route scope changes through design.md
first); `docs/architecture.md` draws what design.md describes, as Mermaid
diagrams — it is derived, never authoritative, so update it after design.md
rather than instead of it; `README.md` is the public face. Keep all four in
sync with reality — this repo has no code yet, and the README must keep
saying so until it does.

## Conventions

- Kaappi Scheme, 2-space indentation, R7RS style (same as the kaappi org).
- Commits: short imperative subject, body explains why, `git commit -s`
  (DCO trailer required).
- Library code under `lib/mesthiri/*.sld`, entry point `mesthiri.scm`,
  tests under `tests/` runnable as
  `kaappi --lib-path ./lib tests/test-<module>.scm`.
- All subprocess access (agent, git, openssl) goes through one module —
  `lib/mesthiri/agent.sld` / `lib/mesthiri/proc.sld` — never inline, so a
  second agent backend is a new module, not a change to stage code. Built
  on `(kaappi process)` (KEP-0022, shipped in kaappi v0.26.0; requires
  kaappi ≥ 0.26): `spawn-process` for the long-lived agent, `run-process`
  for one-shot git and openssl calls. No `gh` — `forge.sld` is the only
  path to the API.
- `agent.sld` is also the only place that builds the sandbox: the agent
  never holds a credential and never reaches the forge. It writes commits;
  the job pushes.
- Shim workflows use `pull_request_target` and never check out the PR's
  code. This is the control that stops a pull request rewriting the
  workflow that holds the secrets — treat it as non-negotiable.
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
