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

## Report and record

Report only what a command established, most severe first: contradictions
before stale wording, and anything permissive-direction (a doc allowing more
than the design does) before anything restrictive.

**Then improve this file.** If you found drift that no pattern above
describes, add it to the list with a one-line concrete example, and commit
that alongside the fix. If a check would have caught it mechanically, add
the command. A pattern that recurs a third time is a candidate for a script
in `scripts/` and a CI job, the way the Mermaid check became one.
