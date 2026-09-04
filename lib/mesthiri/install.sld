;;; (mesthiri install) — ordered layers, forward and reverse
;;;
;;; Installing touches several things in someone else's repository, and a
;;; half-installed one is worse than an uninstalled one. So the layers are
;;; declared in order, installed forward, uninstalled in reverse, and each is
;;; idempotent — running install twice must be the same as running it once.
;;;
;;; Everything that changes files arrives as a pull request. mesthiri does not
;;; push to a repository's default branch to install itself; the maintainers
;;; read the shim before it can run, which is the whole point of the shim
;;; being small.
;;;
;;; The layering idea is fullsend's ADR 0006.

(define-library (mesthiri install)
  (import (scheme base) (scheme write) (scheme char)
          (mesthiri forge) (mesthiri labels) (mesthiri log))
  (export install-layers layer-name layer-describe shim-workflow
          starter-harness scaffold-files
          split-operator under-mesthiri? kaappi-preset
          refuses-self? starter-config starter-rubric
          install-pr-body uninstall-pr-body)
  (begin

    ;; In dependency order. Labels come before the workflow because a shim
    ;; that runs before its labels exist would create them on its first run
    ;; anyway — but a maintainer reading the pull request should see the whole
    ;; shape, not discover half of it later.
    (define install-layers
      '((config    . "`.mesthiri/config.scm` — rubric path, budgets, deny-paths, App ids")
        (rubric    . "`.mesthiri/rubric.md` — a starter rubric, yours to rewrite")
        (harnesses . "`.mesthiri/harness/*.scm` — which model each role uses")
        (labels    . "the eight workflow labels, created through the API")
        (workflow  . "`.github/workflows/mesthiri.yml` — the shim")))

    (define (layer-name l) (car l))
    (define (layer-describe l) (cdr l))

    ;; mesthiri is never installed on its own repository. An orchestrator that
    ;; can modify the code deciding what it is allowed to do has no guardrail
    ;; it cannot reach. Matched as a string on the canonical name, so a fork
    ;; — which is somebody else's copy and somebody else's decision — is
    ;; unaffected.
    (define (refuses-self? repo)
      (and (string? repo) (string=? repo "mesthiri/mesthiri")))

    (define (starter-config operator-name operator-email reader-id writer-id)
      (string-append
       ";;; mesthiri configuration. Scaffolded by `mesthiri install`.\n"
       ";;;\n"
       ";;; Everything starts off except triage in dry-run: merging this must\n"
       ";;; not begin opening pull requests. Turning a stage on is a one-word\n"
       ";;; edit, and turning it off again is the same edit.\n"
       "(mesthiri\n"
       "  (version 1)\n\n"
       "  ;; Who certifies mesthiri's commits. A DCO sign-off is a person\n"
       "  ;; asserting where a contribution came from, so it names you.\n"
       "  (operator \"" operator-name "\" \"" operator-email "\")\n\n"
       "  (apps (reader " (number->string reader-id)
       ") (writer " (number->string writer-id) "))\n\n"
       "  (agent (backend pi) (version \"0.84.4\"))\n\n"
       "  ;; The sandbox's allowlist is derived from `endpoint` rather than\n"
       "  ;; kept in step by hand. Derived and reported; not enforced yet.\n"
       "  (providers\n"
       "    (main (endpoint \"https://api.deepseek.com\")\n"
       "          ;; The repository secret holding the key. List it in the\n"
       "          ;; shim's `model-secrets` so the job receives it.\n"
       "          (secret DEEPSEEK_API_KEY)\n"
       "          (key-env DEEPSEEK_API_KEY)\n"
       "          (api openai-completions)))\n\n"
       "  (rubric \".mesthiri/rubric.md\")\n\n"
       "  ;; Files no mesthiri change may touch. `.mesthiri/**` is on the list\n"
       "  ;; deliberately: mesthiri cannot widen its own limits.\n"
       "  (deny-paths \".mesthiri/**\" \".github/workflows/**\" \"CODEOWNERS\")\n\n"
       "  (budgets\n"
       "    (per-run (tokens 200000) (turns 40) (wall-clock \"20m\"))\n"
       "    (per-day (runs 12)))\n\n"
       "  (commands (triage    (min-permission triage))\n"
       "            (implement (min-permission write))\n"
       "            (review    (min-permission triage))\n"
       "            (fix       (min-permission write))\n"
       "            (retro     (min-permission triage)))\n\n"
       "  (stages\n"
       "    (triage     (on (or (issue-opened) (issue-reopened)\n"
       "                      (command \"/triage\")))\n"
       "                (mode dry-run))              ; <- the line to change\n"
       "    (prioritize (on (schedule \"08:00\"))       (mode off))\n"
       "    (code       (on (or (label \"ready-to-implement\") (command \"/implement\")))\n"
       "                (mode off) (max-tier 0))\n"
       "    (review     (on (pull-request-updated))  (mode off))\n"
       "    (fix        (on (command \"/fix\"))        (mode off))\n"
       "    (retro      (on (schedule \"sunday 06:00\")) (mode off))))\n"))

    (define (starter-rubric)
      (string-append
       "# Issue rubric\n\n"
       "A starting point. **Rewrite it.** Every triage verdict is only as good\n"
       "as this document, and a generic rubric produces generic verdicts —\n"
       "which is the most common reason people conclude the whole idea does\n"
       "not work.\n\n"
       "mesthiri reads this file and cites the clause it applied, so a verdict\n"
       "you disagree with points at the sentence that produced it.\n\n"
       "## §1 — priority: low\n\n"
       "Cosmetic or documentation-only. No behaviour change.\n\n"
       "## §2 — priority: high\n\n"
       "A reproducible crash, data loss, or incorrect output from library code\n"
       "on documented input. Reproducible means from the report alone.\n\n"
       "## §3 — priority: medium\n\n"
       "Wrong or surprising behaviour with a workaround, or a crash needing\n"
       "unusual input.\n\n"
       "## §4 — not a defect\n\n"
       "Feature requests, questions, design discussion. These are intent tier\n"
       "2: someone must decide the work is wanted before it is done.\n"))

    ;; The shim, verbatim. It also lives at `templates/mesthiri.yml` so it can
    ;; be read and linted as YAML; `tests/test-install.scm` asserts the two are
    ;; byte-identical, because two copies of anything in this project drift.
    (define shim-workflow
      (string-append
       "# mesthiri — installed shim workflow\n"
       "#\n"
       "# This file is deliberately tiny and should almost never change: it forwards\n"
       "# events to a reusable workflow that mesthiri maintains, so fixes reach you\n"
       "# without a pull request to this repository.\n"
       "#\n"
       "# SECURITY — the two rules this file exists to hold:\n"
       "#\n"
       "#   1. Pull-request events use `pull_request_target`, not `pull_request`. A\n"
       "#      `pull_request` workflow runs the copy of itself from the PR's own\n"
       "#      branch, so anyone opening a pull request could rewrite it and read the\n"
       "#      secrets it holds. `pull_request_target` runs this file as it exists on\n"
       "#      the base branch — the version you reviewed.\n"
       "#\n"
       "#   2. Because `pull_request_target` carries real secrets, this workflow\n"
       "#      NEVER checks out the pull request's code, and in fact contains no\n"
       "#      checkout at all. Adding one is how the secrets above end up in a\n"
       "#      contributor's hands. mesthiri's own test suite asserts this file has\n"
       "#      no checkout step.\n"
       "#\n"
       "# Schedules live in .mesthiri/config.scm, not here. This is a single hourly\n"
       "# tick; mesthiri matches it against each stage's configured time. Changing\n"
       "# when a stage runs is a config edit, and this file stays as it is.\n"
       "\n"
       "name: mesthiri\n"
       "\n"
       "on:\n"
       "  issues:\n"
       "    types: [opened, reopened, labeled]\n"
       "  issue_comment:\n"
       "    types: [created]\n"
       "  pull_request_target:\n"
       "    types: [opened, synchronize, reopened, labeled, ready_for_review]\n"
       "  pull_request_review:\n"
       "    types: [submitted]\n"
       "  schedule:\n"
       "    - cron: '7 * * * *'      # hourly; the minute is arbitrary and staggered\n"
       "\n"
       "# Collapse rapid edits to the same issue or pull request into one run.\n"
       "concurrency:\n"
       "  group: mesthiri-${{ github.event.issue.number || github.event.pull_request.number || github.run_id }}\n"
       "  cancel-in-progress: false\n"
       "\n"
       "jobs:\n"
       "  dispatch:\n"
       "    # Skip entirely when mesthiri's own comment caused this event. Every\n"
       "    # comment it posts fires `issue_comment`, and nothing it writes is ever an\n"
       "    # instruction to itself — so without this, each comment costs a run that\n"
       "    # downloads the release and then exits.\n"
       "    #\n"
       "    # Matched on the marker mesthiri stamps on its own comments rather than on\n"
       "    # an author name, which would need the App slugs hardcoded here. For any\n"
       "    # non-comment event `github.event.comment.body` is absent and `contains`\n"
       "    # is false, so this only ever skips comments.\n"
       "    #\n"
       "    # mesthiri checks this again itself. That is deliberate belt-and-braces:\n"
       "    # this condition saves the runner, and the in-binary check still holds for\n"
       "    # a repo running an older shim.\n"
       "    if: ${{ !contains(github.event.comment.body, '<!-- mesthiri:') }}\n"
       "    uses: mesthiri/mesthiri/.github/workflows/reusable-dispatch.yml@v0\n"
       "    # with:\n"
       "    #   # Whatever your own tests need in order to run. The code stage asks\n"
       "    #   # the agent to get them green, and it cannot do that with no\n"
       "    #   # toolchain.\n"
       "    #   setup: |\n"
       "    #     curl -fsSL -o /usr/local/bin/yourtool https://…\n"
       "    #     chmod +x /usr/local/bin/yourtool\n"
       "    #\n"
       "    #   # Repository secrets holding model API keys, by the names your\n"
       "    #   # .mesthiri/config.scm gives in each provider's `(secret …)`. Needs\n"
       "    #   # `secrets: inherit` below, because a reusable workflow cannot\n"
       "    #   # receive a secret whose name it does not declare, and mesthiri\n"
       "    #   # cannot declare names that belong to your repository. Only the\n"
       "    #   # names you list here are exported.\n"
       "    #   model-secrets: \"ANTHROPIC_API_KEY DEEPSEEK_API_KEY\"\n"
       "    # secrets: inherit\n"
       "    secrets:\n"
       "      reader-key: ${{ secrets.MESTHIRI_READER_KEY }}\n"
       "      writer-key: ${{ secrets.MESTHIRI_WRITER_KEY }}\n"
       "      model-key: ${{ secrets.MESTHIRI_MODEL_KEY }}\n"))


    ;; Which model plays each role. Separate from config.scm because these are
    ;; the files a repository will edit most often — swapping a model is not a
    ;; policy change and should not sit next to the deny-paths.
    (define (starter-harness role model)
      (string-append
       ";;; " (symbol->string role) " harness. Scaffolded by `mesthiri install`.\n"
       ";;;\n"
       ";;; The model is pinned exactly. A floating alias is refused: a verdict\n"
       ";;; you cannot reproduce six months later is not evidence.\n"
       "(harness\n"
       "  (provider main)\n"
       "  (model \"" model "\")\n"
       "  (budgets (tokens 60000) (turns 12)))\n"))

    ;; Path and content for every file layer, in install order.
    (define (scaffold-files operator-name operator-email reader-id writer-id)
      (list
       (cons ".mesthiri/config.scm"
             (starter-config operator-name operator-email reader-id writer-id))
       (cons ".mesthiri/rubric.md" (starter-rubric))
       (cons ".mesthiri/harness/triage.scm"  (starter-harness 'triage  "deepseek-v4-flash"))
       (cons ".mesthiri/harness/review.scm"  (starter-harness 'review  "deepseek-v4-flash"))
       (cons ".github/workflows/mesthiri.yml" shim-workflow)))

    (define (split-operator op)
      ;; "Name <email>" — the shape a DCO trailer already uses, so there is
      ;; nothing new to learn.
      (let loop ((i 0))
        (cond ((>= i (string-length op))
               (error "operator must be \"Name <email>\", got:" op))
              ((char=? (string-ref op i) #\<)
               (values (trim-right (substring op 0 i))
                       (let ((rest (substring op (+ i 1) (string-length op))))
                         (let scan ((j 0))
                           (cond ((>= j (string-length rest)) rest)
                                 ((char=? (string-ref rest j) #\>) (substring rest 0 j))
                                 (else (scan (+ j 1))))))))
              (else (loop (+ i 1))))))

    (define (trim-right s)
      (let loop ((n (string-length s)))
        (if (and (> n 0) (char=? (string-ref s (- n 1)) #\space))
            (loop (- n 1))
            (substring s 0 n))))

    (define (under-mesthiri? p)
      (and (string? p)
           (or (and (>= (string-length p) 10) (string=? (substring p 0 10) ".mesthiri/"))
               (string=? p ".github/workflows/mesthiri.yml"))))

    (define kaappi-preset
      ;; A preset is the org's answer to "what do we put in the blanks", not a
      ;; different install. The operator is a placeholder the org fills in;
      ;; rotating it afterwards is a config edit, not a reinstall.
      '(("operator-name"  . "kaappi maintainers")
        ("operator-email" . "maintainers@example.invalid")))

    (define (install-pr-body layers)
      (string-append
       "This pull request installs [mesthiri](https://github.com/mesthiri/mesthiri).\n\n"
       "**Merging it starts nothing.** Every stage is off except triage, which\n"
       "is in dry-run: it will comment its reasoning on new issues and apply\n"
       "no labels. Turning a stage on is a one-word edit in\n"
       "`.mesthiri/config.scm`.\n\n"
       "What it adds:\n\n"
       (let loop ((l layers) (acc ""))
         (if (null? l) acc
             (loop (cdr l)
                   (string-append acc "- " (layer-describe (car l)) "\n"))))
       "\n### The `pull_request_target` in the workflow\n\n"
       "If you know GitHub Actions security you will stop at that trigger, and\n"
       "you are right to. A `pull_request` workflow runs the copy of itself\n"
       "from the pull request's own branch, so anyone opening one could\n"
       "rewrite it and read your secrets. `pull_request_target` runs the base\n"
       "branch's copy — the version you are reading now.\n\n"
       "The other half matters as much: because it holds real secrets, the\n"
       "shim **never checks out a pull request's code**. It forwards the event\n"
       "and stops. mesthiri's own test suite asserts that file contains no\n"
       "checkout at all.\n\n"
       "### Before it can do anything\n\n"
       "Add the App private keys as repository secrets. Until then every run\n"
       "will fail at authentication, which is the safe direction to fail in.\n"))

    (define (uninstall-pr-body)
      (string-append
       "This pull request removes mesthiri.\n\n"
       "It deletes the shim workflow and `.mesthiri/`. Merging it stops\n"
       "everything — there is nothing running anywhere else, because there is\n"
       "nowhere else.\n\n"
       "**The labels are left alone.** They are your repository's data, not\n"
       "mesthiri's, and deleting them would throw away whatever state your\n"
       "issues are in. Delete them yourself if you want them gone.\n\n"
       "The App installations and secrets are also left: revoking access is\n"
       "yours to do, and doing it for you would be presumptuous about a\n"
       "credential.\n"))))
