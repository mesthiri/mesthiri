# Try it before installing anything

Installation asks for two GitHub Apps and a pull request. Before any of
that, you can see what mesthiri would say about your repository without
changing it at all:

```bash
mesthiri try owner/repo --rubric docs/dev/github-issues.md
```

Releases ship a macOS arm64 binary for this local step alongside the Linux
builds for CI. Your laptop has no sandbox, and that is exactly why `try`
calls a model directly (see [Choosing models](models.md)) rather than spawning an agent — there is
nothing running here that would need containing. It reads your open issues
with a personal access token, applies your rubric to each one, and prints
the result. It writes nothing — no labels,
no comments, no branches — and it does not clone your repository.

```
mesthiri try — rubric only, nothing written, no checkout

#412  Segfault when parsing empty vectors
      priority: high     tier 1     rubric §2
      Reproducible crash in library code. Taking the report at face
      value: not verified against the code.

#418  Add a --json flag to `kaappi features`
      priority: low      tier 2     rubric §5
      A feature, not a defect. Tier 2 — needs a human to authorize the
      work before the code stage may claim it.

#421  Docs typo in cookbook/testing.md
      priority: low      tier 0     rubric §1
      One-word change, additive, trivially revertible.

3 issues read, 3 verdicts, 0 writes. Spent 9k tokens (~20 seconds).
```

**This is not what installed triage does, and the difference matters.**
Real triage checks the issue's claims against a checkout before trusting
them — a reporter's diagnosis is a hypothesis, and a good share of them are
wrong about where the bug is. `try` cannot do that: verifying claims means
running a coding agent with tools against attacker-writable text, and that
belongs in a sandbox on a CI runner, not on your laptop. So `try` calls a
model directly with no shell, no file access and nothing to contain, and
tells you the one thing it honestly can — **whether your rubric produces
sane priorities**. That is usually what is wrong at the start, and it is
worth twenty seconds to find out.
