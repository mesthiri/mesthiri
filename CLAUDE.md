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
reality. M1 and M2 have landed (`lib/mesthiri/*.sld`, 183 tests): dispatch,
the shim and commands work, but no stage does. The README and the guide must
keep saying so until a stage lands, because a reader who tries the guide
today gets a command that is parsed and authorized and then does nothing.

`AGENTS.md` is a symlink to this file, so tools looking for either name get
the same instructions. Edit this file, not the link. Note that an
`/init`-style command which *generates* `AGENTS.md` writes through the
symlink and would overwrite everything here.

## Conventions

- Kaappi Scheme, 2-space indentation, R7RS style (same as the kaappi org).
- Commits: short imperative subject, body explains why, `git commit -s`
  (DCO trailer required).
- **A failed edit must stop the commit.** Doc edits here are usually a
  `python3 - <<'PY'` block that asserts on the text it expects to replace.
  When that assertion fails it exits non-zero and prints a traceback — and a
  `git commit` on the *next line* runs anyway, committing whatever else
  changed under a message describing an edit that is not in the diff. That
  has happened: `6f7647e` claimed a preamble said something it did not, and
  `794f0da` had to correct the record. Chain the edit and the commit with
  `&&`, or read `git diff` before writing the message. Separate lines are
  the natural way to type it, which is exactly why this needs saying.
  A script making several edits must validate *all* of them before writing
  *any* — assert first, write second. Interleaving them leaves the earlier
  edits applied and the later ones not, so a retry re-asserts against text
  it already changed and fails for a second, unrelated-looking reason.
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
- **A sample in a document that a reader would copy must be parsed by a
  test**, not read. `.mesthiri/config.scm` samples go through
  `parse-config` and their triggers through `trigger-valid?` — a predicate
  outside the vocabulary parses as an ordinary list and is refused only at
  run time, so reading the document cannot catch it
  (`tests/test-guide-config.scm`).
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
  ways that each fail looking like something else. CI runs the same script
  on every push and pull request, so this is enforced rather than advisory —
  running it locally just saves you the round trip. The workflow is
  deliberately not path-filtered, so it is safe to mark as a required check;
  the reason is in a comment at the top of it.

## Skills

`.claude/skills/` holds this project's own skills, checked in so they improve
with the work rather than living in one session's head:

- **`docs-sync`** — audit the six documents against each other after a
  design change. It carries the drift patterns that have actually produced
  defects here, and gains one whenever a new kind is found.
- **`capture-lesson`** — decide where something learned belongs (a rule
  here, a check in `docs-sync`, a terminology entry, a script, a new skill)
  and write it there. Run it when a review finds a defect, a claim turns out
  false when tested, or a decision reverses.

- **`release`** — cut a release. Note it has two distinct halves: publishing
  the artifacts, and separately bumping the pin in
  `.github/workflows/reusable-dispatch.yml` that every installed repository
  runs. A bad pin breaks everyone's next job, so the skill verifies the
  published artifact between the two.

The first two end by updating themselves, which is the point: a lesson left
in a commit message is one the next session repeats.

Skills are discovered when a session starts, so one added mid-session is not
invokable until it registers — the file is on disk and the tool call still
says unknown skill. Follow the written procedure by hand until it appears.

## Related work

- KEP-0022 (native subprocess support): **Final** — shipped in kaappi
  v0.26.0 (phases kaappi#2414–#2417, epic kaappi#2418, all closed). The
  KEP's As-implemented section records the shipped surface and its
  divergences (no `pass-fds:`; `run-process` gained `output:` and the
  `timeout:`-implies-`new-group:` rule).
- The kaappi org's issue rubric (`kaappi/docs/dev/github-issues.md`) is the
  first triage rubric mesthiri will target.
