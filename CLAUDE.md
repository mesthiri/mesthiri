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
rather than instead of it; `docs/terminology.md` fixes one word per concept
and lists the pairs that are easy to confuse — check it before inventing a
name for something that already has one; `docs/guide.md` is the end-user
experience,
written ahead of the code as a design tool — when it disagrees with
reality, change the guide first and ask whether the design or the wording
was wrong; `README.md` is the public face. Keep all six in sync with
reality — this repo has no code yet, and the README and the guide must both
keep saying so until it does.

`AGENTS.md` is a symlink to this file, so tools looking for either name get
the same instructions. Edit this file, not the link. Note that an
`/init`-style command which *generates* `AGENTS.md` writes through the
symlink and would overwrite everything here.

## Conventions

- Kaappi Scheme, 2-space indentation, R7RS style (same as the kaappi org).
- Commits: short imperative subject, body explains why, `git commit -s`
  (DCO trailer required).
- Library code under `lib/mesthiri/*.sld`, entry point `mesthiri.scm`,
  tests under `tests/` runnable as
  `kaappi --lib-path ./lib tests/test-<module>.scm`.
- All subprocess access goes through two modules and never inline:
  `lib/mesthiri/proc.sld` wraps `(kaappi process)`, and
  `lib/mesthiri/agent.sld` is the only caller allowed to spawn the coding
  agent. A second agent backend is then a new module, not a change to stage
  code. Built
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
- **Configuration is interpreted, never `eval`ed.** A target repo's
  `.mesthiri/config.scm` is s-expressions read with `read`, and its trigger
  predicates run through a small interpreter over a fixed vocabulary. Do not
  reach for `eval` because the data is already s-expressions and it would be
  one line — that one line turns a config file into arbitrary code
  execution. As load-bearing as the `pull_request_target` rule above.
- Two files are easy to confuse: `lib/mesthiri/config.sld` is mesthiri's
  reader module; `.mesthiri/config.scm` is the config file in the *target*
  repository that it reads.
- Issue/PR text from target repos is untrusted input: never interpolate it
  into shell commands (argv-only) and label it as data in agent prompts.
- After editing a doc with Mermaid blocks, validate them before committing —
  a broken diagram fails silently on GitHub and reads as a missing section:

  ```
  npm i --no-save mermaid jsdom
  node scripts/check-diagrams.mjs
  ```

  It runs both `parse` and `render`, because render catches references to
  things that do not exist — a `linkStyle` index past the last edge, an
  `activate` for a participant never introduced — which parse accepts.
  Neither step catches a malformed `classDef` or `style`; mermaid ignores
  those silently, so a fill that never appears is on you to notice.
  The script's comments explain the jsdom setup, which is fiddly in three
  ways that each fail looking like something else.

## Related work

- KEP-0022 (native subprocess support): **Final** — shipped in kaappi
  v0.26.0 (phases kaappi#2414–#2417, epic kaappi#2418, all closed). The
  KEP's As-implemented section records the shipped surface and its
  divergences (no `pass-fds:`; `run-process` gained `output:` and the
  `timeout:`-implies-`new-group:` rule).
- The kaappi org's issue rubric (`kaappi/docs/dev/github-issues.md`) is the
  first triage rubric mesthiri will target.
