# Configuring

`.mesthiri/config.scm` lives in your repository, so it is reviewed like
code and a fork carries a copy. It is s-expressions, read as data.

```scheme
(mesthiri
  (version 1)

  ;; Who certifies mesthiri's commits. Exactly one operator per repository;
  ;; rotation is a config edit. A DCO sign-off is a person
  ;; asserting where a contribution came from, so it names you, not a bot.
  (operator "Your Name" "you@example.org")

  ;; The two GitHub App IDs. Public configuration — only the private keys
  ;; are secrets.
  (apps (reader 123456) (writer 123457))

  ;; Which agent program mesthiri drives. Not the model — see "Choosing models".
  (agent (backend pi) (version "0.84.4"))

  ;; Where models come from. `endpoint` is the one place the URL is
  ;; written; the sandbox's allowlist is derived from it rather than kept
  ;; in step by hand. (Derived and reported — not enforced yet.)
  (providers
    (main (endpoint "https://api.anthropic.com")
          (secret   ANTHROPIC_API_KEY)      ; your repository secret
          (key-env  ANTHROPIC_API_KEY)))    ; what the agent reads it from

  ;; Your rubric, in your repository. mesthiri does not bring one.
  (rubric "docs/dev/github-issues.md")

  ;; Files no mesthiri change may touch, ever. Checked against the diff
  ;; before a pull request is opened, and again during review.
  (deny-paths ".mesthiri/**"
              ".github/workflows/**"
              "src/auth/**"
              "CODEOWNERS")

  (budgets
    (per-run (tokens 200000) (turns 40) (wall-clock "20m"))
    (per-day (runs 12)))          ; approximate runs-started cap — see "About budgets"

  ;; Minimum repository permission to issue each command.
  (commands (triage    (min-permission triage))
            (implement (min-permission write))
            (review    (min-permission triage))
            (fix       (min-permission write))
            (retro     (min-permission triage)))

  ;; `mode` is off | dry-run | live, and defaults to off. This is what
  ;; install scaffolds: triage thinking out loud, nothing else running.
  (stages
    (triage     (on (or (issue-opened) (issue-reopened)
                        (command "/triage")))
                (mode dry-run))                    ; ← the line to change
    (prioritize (on (schedule "08:00"))            (mode off))
    (code       (on (or (label "ready-to-implement")
                        (command "/implement")))   (mode off)
                (max-tier 0))                      ; raise to 1 when ready
    (review     (on (or (pull-request-opened)
                        (pull-request-updated)
                        (command "/review")))     (mode off))
                ;; only PRs mesthiri opened — built into dispatch, not a predicate
    (fix        (on (command "/fix"))              (mode off))
    (retro      (on (schedule "sunday 06:00"))     (mode off))))
```

The expressions after `on` are predicates over the event, drawn from a
fixed vocabulary of short forms. A schedule is a whole-hour UTC time,
optionally preceded by a weekday — `"07:00"` every day, `"sunday 06:00"`
once a week. They are interpreted, not evaluated — a config file cannot
become a program. The shim carries a single hourly tick and dispatch
matches it against these schedules, so changing one is a config edit, not a
pull request. This sample is the scaffold contract: `install` produces it, down
to the deny-paths, `max-tier 0`, budgets and pinned versions.
