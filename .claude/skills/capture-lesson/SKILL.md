---
name: capture-lesson
description: Fold something learned during mesthiri work into the right home — a CLAUDE.md rule, a docs-sync check, a terminology entry, a script, or a new skill — so the next session does not rediscover it. Use after a review finds a defect, after a mistake is corrected, after a surprising verification result, at the end of a work session, or when asked to record a lesson or improve the skills.
---

# Record what was learned, where it will be found

This project's documents are its product, and its failure mode is knowing
something in one place and not another. That applies to how we work too: a
lesson that stays in a commit message is a lesson the next session repeats.

Run this when something was *learned*, not merely done. Signals: a review
found a defect, a claim turned out false when tested, a command failed in a
way that looked like something else, or a decision reversed because
circumstances changed.

## Is it a lesson

Only if it would change what someone does next time. Not a lesson: this
session's task, a decision already recorded in design.md, anything the
repository already states. **A fact about mesthiri's design belongs in
`docs/`, not here** — this is for how to work on it.

## Where it goes

| Kind of lesson | Home |
|---|---|
| A rule that must hold in all future work | `CLAUDE.md` Conventions |
| A drift pattern between documents | `.claude/skills/docs-sync/SKILL.md` |
| A word that was used two ways | `docs/terminology.md` |
| A check worth running mechanically | a script in `scripts/`, then CI |
| A procedure with more than three steps, repeated | a new skill |
| A design decision, or the reason for one | `docs/design.md` — not a skill |

When two homes fit, pick the one that is *loaded* at the moment it matters:
`CLAUDE.md` is always in context, a skill only when invoked. A rule nobody
can violate without seeing it belongs in `CLAUDE.md`.

## Write it so it survives

- **Name the temptation, not just the rule.** "Do not `eval` the config"
  is forgettable; "the config is already s-expressions, so reaching for
  `eval` is one line, and that line is arbitrary code execution" is not.
  A rule whose violation looks like a simplification must say so.
- **Say what the failure looks like.** Lessons are recognised by symptom.
  "Without a `getBBox` stub every render throws, which reads as *render
  does not work here*" is findable; "jsdom needs stubs" is not.
- **Keep the evidence.** If a claim was tested, say what the test was. If it
  was not, say that instead of implying it was.
- **Correct rather than accumulate.** A wrong rule is worse than none —
  when a lesson contradicts something already written, fix that text, do
  not add a second entry beside it.

## Then close the loop

1. Make the edit in the home the table names.
2. If it belongs in more than one, put the statement in one and a pointer in
   the other. Two copies drift; that is the failure this project keeps
   having.
3. Commit it with the work that produced it, so the reason is one `git log`
   away from the rule.

## Growing the skill set

New skills earn their place from repetition, not anticipation. Write one
when a procedure has been done three times, or when a task has a checklist
someone would otherwise reconstruct from memory. Two exist now:

- `docs-sync` — auditing the six documents against each other.
- `capture-lesson` — this one.

Expected next, once there is code to work on: a module-conventions skill for
`lib/mesthiri/*.sld` (the `proc.sld`/`agent.sld` boundary, argv-only
subprocess rules, the no-`eval` config rule, test layout). It is deliberately
not written yet — writing a skill for work nobody has done produces guesses
that read like conventions.
