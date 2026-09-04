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
name for something that already has one; `docs/guide/` (one page per
topic, `README.md` as its index) is the end-user experience,
written ahead of the code as a design tool — when it disagrees with
reality, change the guide first and ask whether the design or the wording
was wrong; `README.md` is the public face. Keep all six in sync with
reality. M0-M9 have landed (`lib/mesthiri/*.sld`, 511 assertions), and
`run-agent` really does spawn pi — `tests/test-agent-live.scm` drives a live
process against a stub model server.

mesthiri has now run against **real models on a real repository**
(`mesthiri/sandbox`): triage produced verdicts on four issues, code opened
pull requests, review found real defects on them, and fix consumed those
findings and pushed. Four stages of six. **`prioritize` and `retro` have
never run against a real model**, and there is **no adopter outside the
sandbox**. Every transcript in the guide is still designed, not captured.

The README, the guide and the site's landing page carry that same statement
and `docs-sync` greps all three, so it moves as one thing. Keep it exact in
both directions: overclaiming misleads a reader who takes the guide at face
value, and underclaiming — which this file did for three releases after the
first live run — is just as wrong and harder to notice, because nobody
re-reads a caveat to check it is still true.

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
  the job pushes. Containment covers the **environment** as well as the
  filesystem — the agent's environment is constructed by `agent-env`, never
  inherited, because a child inherits every variable the job holds
  (both App keys, the forge token) no matter what is mounted, and nothing
  fails to indicate it. Adding a variable there is a security decision.
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
- **A protocol recorded by probing is half a protocol.** Probing pi found
  the frame *names*; the first run driven to completion found the frame
  *shapes*, and three of them were wrong — `message.content` is a list of
  blocks rather than a string, `message_end` fires for the user's message
  too, and a refused command is answered with `success:false` and then
  silence rather than a terminal frame. Each failed silently and each was
  invisible to fixtures written from the recon. Drive the real thing before
  writing code against notes about it, and when a document abbreviates a
  shape, say in the document that it is abbreviated.
- **A deadline needs a fiber, not a SRFI-18 thread.** A kaappi process may
  only be used by the thread that spawned it, so `process-kill` from a
  watchdog thread does not kill — the run hangs past its deadline. Fibers
  (`(kaappi fibers)` `spawn`) share the heap, and a blocking `read-line`
  parks the fiber rather than stalling the scheduler, which is what lets the
  watchdog run at all.

  kaappi is *loud* about this: it raises `process-kill: process belongs to
  another thread; a process may only be used by the thread that spawned it`.
  Say so, because this rule used to describe a watchdog that "reports that
  it fired, kills nothing, and the run hangs anyway" — which reads as kaappi
  failing silently. The silence was ours: `agent.sld` wraps the kill in
  `(guard (e (#t #f)) …)`, and that discards the diagnostic. **Check whether
  your own error handling produced a symptom before attributing it to a
  dependency** — this one nearly cost kaappi a bug report for something it
  does well, and the wrong version had been written down as verified.
- **`set!` returns an unspecified value, and kaappi's unspecified is
  truthy.** The dangerous shape is a one-armed `if` that fills a cache
  and means to read it as the next expression: one missing paren makes
  the read the `if`'s else-arm, and the first call returns the truthy
  unspecified instead. It parses, and it passes on every platform where
  the garbage happens to equal the right answer — `a38c742` did exactly
  this to the directory probe, macOS stayed green because a truthy
  unspecified behaves like `#t` there, and only the Linux CI leg caught
  it (`105ef37` fixes it). A procedure whose value answers a yes/no
  question asserts its return type on its first call —
  `(boolean? (directory-spawn-supported?))` — so the day that shape
  returns, every platform fails, not just the one that pays.
- Issue/PR text from target repos is untrusted input: never interpolate it
  into shell commands (argv-only) and label it as data in agent prompts.
- **A kaappi defect goes upstream, not just into a workaround.** File it at
  [kaappi/kaappi](https://github.com/kaappi/kaappi/issues) — the workspace
  CLAUDE.md has the rule and what a good report needs. This file carried
  "a raised error inside a test is NOT a failing exit code" as a fact of
  life, and `tests/run-all.sh` greps stderr for `error[KP` because of it,
  for months before the underlying behaviour was reported (kaappi#2510).
  The workaround was right and filing it was still owed: every other repo
  in the workspace was rediscovering the same thing. It cost a real defect
  here — a weak model submitted a library that fails `KP2001` on import,
  the test file's duplicate import made it load on the retry, the suite
  printed "4 passed, 0 failed", and the code stage honestly reported green.
- **A change that exists because of a platform difference is verified
  against that platform's pinned artifact before it is pushed.** The
  `directory:` fallback was reworked on macOS, where its probe succeeds
  and the path the change exists for never runs; local green and a
  pushed branch let Linux CI discover what an amd64 container holding
  the pinned `kaappi-x86_64-linux` would have shown first — which is how
  the reviewer proved the defect, running the pinned binary where this
  session only inferred. Green on the development platform is the
  accident, not the evidence, when the change's subject is the other
  platform.

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

## Website

mesthiri.org is the guide and a landing page, nothing else: the design
documents stay on GitHub. MkDocs Material builds it from this repository —
`mkdocs.yml` at the root, `docs/index.md` (rendered by
`overrides/home.html`) and `docs/guide/`. `.github/workflows/site.yml`
builds with `--strict` on every push and pull request, and deploys to
GitHub Pages from `main`.

```
pip install -r requirements.txt   # pinned; the same pins as kaappi-lang.org
mkdocs build --strict             # what CI runs; fails on any broken link
mkdocs serve                      # http://127.0.0.1:8000
```

- Everything else under `docs/` is kept out by `exclude_docs`, so a guide
  page that links to `terminology.md` or `design.md` with a relative link
  fails the strict build. Link to the file on GitHub instead.
- The nav in `mkdocs.yml` and the page list in `docs/guide/README.md` are
  two copies of one list; `docs-sync` has the command that compares them.
  A guide page missing from the nav fails the build
  (`validation.nav.omitted_files: warn`).
- `docs/assets` and `overrides/partials/mascot.html` are symlinks into
  `assets/`, so the marks have one source (the second has a template name
  because MkDocs copies any other file under `overrides/` to the site
  root). The landing page inlines the mascot and recolours it for dark
  mode with attribute selectors on its fill values — a redrawn mascot with
  different hex values silently loses its dark variant on the site.
- The landing page is prose too. It carries the status statement (no real
  model, no real repository yet) in the guide's and README's own words
  rather than a third phrasing, and `docs-sync` greps all three.

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
