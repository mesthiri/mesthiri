---
name: docs-sync
description: Audit mesthiri's six documents against each other after a design change, using the drift patterns that have actually produced defects here. Use after editing docs/design.md, after recording a decision, before committing a change that touches more than one doc, or when asked whether the docs are up to date, consistent, or in sync.
---

# Audit the docs against design.md

`docs/design.md` decides; `plan.md`, `architecture.md`, `guide.md`,
`terminology.md` and `README.md` follow. This audit has found real defects
every time it has been run, so run it rather than reasoning about whether it
is needed.

**Verify, do not recall.** Every check below is a command. A claim you did
not run a command to establish is a claim to leave out of the report.

## 1. Does anything promise what nothing builds

A doc describing a command, field or file that no milestone delivers is the
most common failure here — and it points either way.

```bash
# every CLI affordance the docs mention, and whether plan.md owns it
grep -rhoE 'mesthiri [a-z-]+' docs/*.md README.md | sort -u
# then for each: does plan.md have a milestone bullet for it?
```

Do the same for config keys: any key in the guide's sample must be described
in design.md's Configuration section, and vice versa.

## 2. Do the diagrams still say what design.md says

```bash
npm i --no-save mermaid jsdom && node scripts/check-diagrams.mjs
```

That only proves they render. Also read them: a diagram is wrong in a way
prose is not, because a reader checks whether the picture *permits*
something. Overstating a boundary is the dangerous direction.

## 3. Cross-references after any renumbering

```bash
grep -n "M[0-9]" docs/plan.md docs/*.md CLAUDE.md
```

Milestone numbers shift whenever a milestone is inserted or split, and the
references in Later/Risks/demos do not move themselves.

## 4. One word per concept

```bash
grep -c "<term>" docs/*.md    # for any term the change introduced
```

Anything named in a change must match `docs/terminology.md`. If the change
introduced a concept, terminology.md needs an entry — check the confusable
pairs section too.

## 5. Retired vocabulary

```bash
grep -rn "service\|daemon\|database\|store\|webhook receiver\|cursor" docs/ README.md
```

Hits are fine where the docs describe what was *replaced*. They are defects
where they name a live part of mesthiri.

## Drift patterns seen before

Each of these was a real defect. Check the ones a change could plausibly hit.

1. **A decision lands in design.md and nowhere else.** The model API key got
   a design paragraph while the trust-zone diagram still showed the sandbox
   holding no credential.
2. **A diagram overstates a boundary.** Same case — and it is worse than
   prose being stale, because a diagram is what people check permissions
   against.
3. **A gate exists in prose but not in the flow diagram.** Stage `mode`
   defaulted to `off` while the dispatch diagram ran an event straight from
   authorization to eligibility.
4. **Prose promises precision the mechanism lost.** "Per-run and per-night
   caps" survived after cross-run caps became derived and approximate.
5. **A quantifier goes stale.** "Every stage can be run by slash command" —
   there are five commands and six stages.
6. **A config field the ladder needs is never defined.** The adoption ladder
   said "tier 0 only" while no field expressed a tier ceiling.
7. **Two files, one name.** `lib/mesthiri/config.sld` versus
   `.mesthiri/config.scm`; the plan named the module after the file.
8. **A `Later` item overlaps something now shipped.** Foreign-PR review was
   deferred while explicit `/review` on one was specified.
9. **An install/demo step depends on tooling from a later milestone.** Every
   milestone from M2 needs a shim that nothing creates until M9.
10. **A claim asserted without a test.** "Parse alone misses classDef
    errors" was written into CLAUDE.md and turned out false when tested.
11. **A field attributed to the wrong file.** design.md described the config
    sample as pinning "pi and model versions"; the sample deliberately has
    no model, because models are per-role and live in harness files. Check
    any sentence that summarises one file's contents from inside another.
12. **A field in a declared contract that nothing defines.** `(version 1)`
    sat in the sample config — which design.md calls the scaffold contract —
    with no description of what it means or what a mismatch does.
13. **A retired word used for the live concept.** README called labels "the
    cursor" for scheduled sweeps after terminology.md retired `cursor` and
    made `watermark` the live word. Check 5 finds these; check 4 will not,
    because the live term is present elsewhere and the count looks fine.

14. **An affordance is built but never surfaced.** The inverse of 1, and
    check 1 shows it as a command with `plan:1` and `docs:0`. `mesthiri
    whoami` diagnoses exactly the credential mix-up most likely to break a
    first install, while the guide's troubleshooting section had nothing
    about credentials at all. A command users would want and never hear
    about is as much a defect as one promised and never built.

14. **A sample in a document is never run.** The guide's sample config
    carried `(fix (on (findings-posted)))` through several revisions —
    `findings-posted` is not in the trigger vocabulary, so it parses as an
    ordinary list and is refused only when a run reaches it. Nothing about
    reading the document says it is wrong. Any sample a reader would copy
    should be parsed by a test with the real reader:
    `tests/test-guide-config.scm` now does this, and it fails if the bad
    predicate goes back.
15. **A file embedded in code that also exists on disk.** The shim lives
    both in `install.sld` (to scaffold) and at `templates/mesthiri.yml` (to
    lint as YAML). Two copies of anything here drift, so assert
    byte-identity in a test rather than remembering to update both.
16. **A status claim that ages badly.** README said "M1 and M2 are in, 183
    tests" long after M8. A count or milestone list in prose needs a command
    behind it: `ls lib/mesthiri/*.sld | wc -l`, `grep -c "\[ \]" docs/plan.md`.


17. **A fixture that abbreviates the shape it stands in for.**
    `docs/pi-rpc.md` showed `message.content` as a string where it is a list
    of blocks. Code written against the document was wrong, and the tests
    written from the same document agreed with it — so the suite was green
    and every real run would have failed. A sample that simplifies is worse
    than no sample: it is believed. Where a document abbreviates, it must
    say so.
18. **A parameter accepted and never used.** `run-agent` took
    `deadline-secs`, documented enforcing it in a comment above the function,
    and did nothing with it. Nothing reads as more implemented than a
    parameter with a comment. Grep any newly-documented mechanism for a use
    of its own argument.


## Report and record

Report only what a command established, most severe first: contradictions
before stale wording, and anything permissive-direction (a doc allowing more
than the design does) before anything restrictive.

**Then improve this file.** If you found drift that no pattern above
describes, add it to the list with a one-line concrete example, and commit
that alongside the fix. If a check would have caught it mechanically, add
the command. A pattern that recurs a third time is a candidate for a script
in `scripts/` and a CI job, the way the Mermaid check became one.
