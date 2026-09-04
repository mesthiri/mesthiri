(mesthiri
  (version 1)
  (operator "Test Operator" "operator@example.org")
  (apps (reader 123456) (writer 123457))
  (agent (backend pi) (version "0.9.2"))
  (providers
    (main (endpoint "https://api.anthropic.com")
          (secret MESTHIRI_MODEL_KEY)
          (key-env ANTHROPIC_API_KEY)))
  (rubric "docs/dev/github-issues.md")
  (deny-paths ".mesthiri/**" ".github/workflows/**" "CODEOWNERS")
  (budgets
    (per-run (tokens 200000) (turns 40) (wall-clock "20m"))
    (per-day (runs 12)))
  (commands (triage    (min-permission triage))
            (implement (min-permission write))
            (review    (min-permission triage))
            (fix       (min-permission write))
            (retro     (min-permission triage)))
  (stages
    (triage     (on (or (issue-opened) (schedule "07:00"))) (mode dry-run))
    (prioritize (on (schedule "08:00"))                     (mode off))
    (code       (on (or (label "ready-to-implement") (command "/implement")))
                (mode off) (max-tier 0))))
