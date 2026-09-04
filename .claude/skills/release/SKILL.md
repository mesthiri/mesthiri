---
name: release
description: Cut a mesthiri release — bump the version, write the CHANGELOG section from the commit log, build and checksum the standalone binaries, publish the GitHub release, and then separately roll it out by bumping the pin every installed repository runs. Use when the user asks to make a release, cut a release, publish a version, tag a release, or ship a version.
---

# Release mesthiri

Modelled on the kaappi org's `github-release` skill, but mesthiri differs in
one way that governs the whole process, so read this first.

## The thing that makes this different from kaappi's release

Releasing a kaappi version publishes an artifact people choose to download.
Releasing a mesthiri version does that too — and then a *second*, separate
act changes what every installed repository executes on its next event:

```yaml
# .github/workflows/reusable-dispatch.yml
MESTHIRI_VERSION: v0.1.0
```

Installed repositories call that reusable workflow, which downloads the
pinned release and verifies its checksum. Bumping the pin is the rollout.
**Publish and roll out are separate steps here, in that order, with
verification in between** — because a bad pin does not break one user's
download, it breaks every installed repository's next run, and they will
find out through a failing job on someone else's pull request.

## Prerequisites

```bash
git status                  # must be clean
git branch --show-current   # must be main
gh auth status
./tests/run-all.sh          # must be green
```

A release from a red suite is not a release.

## Step 1 — Decide the version

```bash
grep 'define mesthiri-version' lib/mesthiri/version.sld
git tag -l 'v*' --sort=-v:refname | head -1
git log "$(git tag -l 'v*' --sort=-v:refname | head -1)"..HEAD --oneline --no-merges
```

No tags yet? Use `git log --oneline --no-merges` and the first release is
`v0.1.0`.

- **patch** — bug fixes only
- **minor** — new modules or milestones, no breaking changes
- **major** — breaking changes to `.mesthiri/config.scm`'s schema, the trigger
  vocabulary, or the shim's contract

Note the second and third of those: mesthiri's compatibility surface is
mostly *other people's config files and workflows*, not an API. A config
field that changes meaning is a breaking change even if no Scheme signature
moved. `(version N)` in a target's config is what mesthiri refuses on, so
bumping the schema is a major.

Present the analysis and the recommendation. **Wait for confirmation.**

## Step 2 — Write the release notes

`git log` is the only source; `[Unreleased]` is empty by design.

```bash
git log --no-merges --pretty='%h %s%n%b' "$(git describe --tags --abbrev=0)"..HEAD
```

Read the bodies, not just the subjects — this project's convention is that
the body explains *why*, which is what a release note needs. Group by
user-visible effect, drop pure test and CI commits. Present the draft and
**wait for confirmation.**

## Step 3 — Update CHANGELOG.md and the version

Insert a `## [X.Y.Z] — YYYY-MM-DD` section under `[Unreleased]`, keeping the
`[Unreleased]` heading empty. Then bump the one line:

```scheme
;; lib/mesthiri/version.sld
(define mesthiri-version "X.Y.Z")
```

Nothing else carries a version. `--version` and the `Generated-by` trailer
read it from there.

## Step 4 — Build the binaries

**Not `-Dbundle-src`.** That option compiles the `.scm` with no `--lib-path`,
so `(mesthiri config)` and `(kaappi http)` do not resolve. Compile first with
explicit lib paths, then embed the bytecode:

```bash
kaappi --lib-path ./lib \
       --lib-path ../kaappi-json/lib \
       --lib-path ../kaappi-http/lib \
       --lib-path ../kaappi-net/lib \
       --compile -o /tmp/mesthiri.sbc mesthiri.scm
```

Check two things before going on, because the failure is quiet:

- **exit code 0** — a missing library exits 1, and the message names the
  library rather than the symptom;
- **size** — a correct bundle is ~126 KB. A bundle around 14 KB means an
  import silently did not resolve and only the entry point got compiled.

### You cannot cross-compile a bundle

**Each target's `.sbc` must be compiled by a kaappi built for that same
target.** Kaappi stamps bytecode with
`compilerHashFor(version, build_id, target)` and refuses a mismatch at
startup, so a `.sbc` produced on macOS will not run inside a Linux binary
however it was cross-built. Verified: the error prints only the build id, so
it reads as `build id 14bce502; this binary is 14bce502` — identical, and
still refused, because the target differs and is not shown.

So the three artifacts must each be produced on their own platform. That is
what the release matrix in CI is for; doing it by hand needs a machine per
target.

| Target | Built on | Needed by |
|---|---|---|
| `x86_64-linux` | ubuntu runner | CI runners — the one every installed repo downloads |
| `aarch64-linux` | ubuntu-arm runner | ARM runners |
| `aarch64-macos` | macos runner | local `try` and `install` |

### And keep the compiler out of the way

`zig build -Dbundle=` writes to `zig-out/bin/kaappi`, **overwriting the plain
kaappi you just used as the compiler.** Copy it aside first:

```bash
cd ../kaappi
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/kaappi /tmp/kaappi-plain      # the compiler
# ...compile the .sbc with /tmp/kaappi-plain, then:
zig build -Dbundle=/tmp/mesthiri.sbc -Doptimize=ReleaseSafe
```

Skip the copy and the second compile runs *mesthiri* and prints its usage,
which looks like a broken build rather than the wrong binary.

## Step 5 — Checksums

```bash
cd /tmp/rel && shasum -a 256 mesthiri-* > SHA256SUMS && cat SHA256SUMS
```

**This file is load-bearing.** The reusable workflow verifies against it
before `chmod +x`, so a missing or wrong `SHA256SUMS` does not degrade
gracefully — it fails every installed repository's next run. Verify it
locally before publishing:

```bash
shasum -a 256 -c SHA256SUMS
```

## Step 6 — Smoke-test every artifact, on its own platform

Not just the one you can run locally. The argv handling differs between
running as a script and running as a bundled binary — `command-line` includes
the script path in the first case and omits the program name entirely in the
second — and that was a live bug found here, by this step, after every
earlier check had run the script.

```bash
/tmp/rel/mesthiri-aarch64-macos --version     # must print X.Y.Z, not 0.1.0-dev
/tmp/rel/mesthiri-aarch64-macos               # usage, no crash
```

A binary that prints the *previous* version means Step 3 was edited after the
compile in Step 4. Recompile; do not publish it.

## Step 7 — Commit, tag, publish (requires confirmation)

**STOP. Ask before pushing.** Explain that this publishes artifacts other
repositories will download.

```bash
git add CHANGELOG.md lib/mesthiri/version.sld
git commit -s -m "Release vX.Y.Z"
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main && git push origin vX.Y.Z
gh release create vX.Y.Z /tmp/rel/* --title "vX.Y.Z" --notes-file /tmp/notes.md
```

## Step 8 — Verify the published release before rolling it out

Download what you published, from the URL an installed repo will use, and
check it the way the workflow will:

```bash
cd "$(mktemp -d)"
base="https://github.com/mesthiri/mesthiri/releases/download/vX.Y.Z"
curl -fsSL -O "$base/mesthiri-x86_64-linux"
curl -fsSL -O "$base/SHA256SUMS"
grep " mesthiri-x86_64-linux$" SHA256SUMS | shasum -a 256 -c -
```

If that fails, stop. Do not proceed to Step 9 — an unrolled-out bad release
harms nobody.

## Step 9 — Roll out by moving the major tag

Installed repositories run a shim that says:

```yaml
uses: mesthiri/mesthiri/.github/workflows/reusable-dispatch.yml@v0
```

They resolve `@v0` and **never see `main`**, so editing anything on `main`
rolls out nothing. The rollout is moving that tag:

```bash
git tag -f v0 vX.Y.Z
git push -f origin v0
```

That moves the workflow *and* the `MESTHIRI_VERSION` pin inside it together,
which is the point: an installed repository gets a matched pair rather than a
new workflow fetching an old binary.

**Rolling back is moving `v0` back to the previous release**, not deleting
anything. Say so, because the instinct under pressure is to delete the bad
release — which breaks the checksum fetch for anyone mid-run and leaves `v0`
pointing at a workflow whose download 404s.

```bash
git tag -f v0 vPREVIOUS && git push -f origin v0
```

A force-push to a tag is the one place this project does that, and it is
deliberate: the major tag is a pointer, not history.

## Step 10 — Confirm a real repository still works

Watch the sandbox, which is the only installed repository until adopters
exist:

```bash
gh run list --repo mesthiri/sandbox --limit 3
```

Or provoke one: comment `/triage` on a sandbox issue and watch the run.

## Steps 4–7 are automated

`.github/workflows/release.yml` does the building, checksumming and
publishing: pushing a tag is the whole of it. It builds each artifact
natively on its own runner, for the cross-compilation reason above, and
smoke-tests each one on the platform it was built for.

Steps 4–6 above are still worth reading, because they are what the workflow
does and what its failures mean. Run them by hand only when debugging the
workflow.

**Steps 8, 9 and 10 are not automated and should not be**, because they are
judgement rather than mechanism: whether the published artifact is good,
whether to point every installed repository at it, and whether a real
repository still works afterwards. A workflow that rolled itself out would
remove the only gap in which a bad release harms nobody.
