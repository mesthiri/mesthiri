;;; (mesthiri code) — one issue, one pull request, never a merge
;;;
;;; The stage splits at the credential boundary, and that split is the whole
;;; design: the agent writes commits in its clone and exits; the job reads the
;;; finished diff, checks it against the deny list, and only then pushes. The
;;; agent holds no credential and has no route to the forge, so this is the
;;; only path a change can take — the eligibility check sits *on* it rather
;;; than beside it.
;;;
;;; A compromised agent can therefore produce a bad diff, which is what review
;;; is for, but it cannot deliver one.

(define-library (mesthiri code)
  (import (scheme base) (scheme write)
          (mesthiri eligibility) (mesthiri git) (mesthiri agent)
          (mesthiri forge) (mesthiri labels) (mesthiri log))
  (export code-prompt implementation-schema pr-body
          check-diff failure-comment code-outcome)
  (begin

    ;; What the agent must return when it believes it is done.
    (define implementation-schema
      '(("summary" . string) ("tests_pass" . boolean)))

    (define (code-prompt issue-title issue-body test-command)
      (string-append
       "Implement the change this issue asks for, in the working directory.\n\n"
       "Rules:\n"
       "1. Write a test that fails without your change, then make it pass.\n"
       "   A fix with no failing test to justify it is not a fix.\n"
       "2. Run the project's own test command and get it green:\n"
       "     " (or test-command "(none configured)") "\n"
       "3. Do not commit. Leave your changes in the working tree.\n"
       "4. Change nothing beyond what the issue asks for. A diff that grows\n"
       "   past its issue is refused by review.\n\n"
       "Reply with JSON only: {\"summary\": \"what you changed and why\",\n"
       "\"tests_pass\": true|false}\n"
       (untrusted-block "the issue title" issue-title)
       (untrusted-block "the issue body" issue-body)))

    ;; The second denylist check, on the finished diff. The first ran before
    ;; the agent started; this one catches what it actually touched, which is
    ;; the only check that can.
    (define (check-diff changed-files deny-patterns)
      (let ((hits (denied-paths-in changed-files deny-patterns)))
        (if (null? hits)
            #t
            (eligibility-refusal
             'denylist
             (let loop ((h hits) (acc ""))
               (if (null? h) acc
                   (loop (cdr h)
                         (string-append acc "- `" (caar h) "` (matched `"
                                        (cdar h) "`)\n"))))))))

    ;; A run that cannot reach green tests reports its state on the issue
    ;; rather than opening a pull request nobody can merge. An honest "I got
    ;; this far" is worth more than a red PR that wastes a review.
    (define (failure-comment reason summary)
      (string-append
       "I could not finish this one.\n\n**" reason "**\n\n"
       (if summary (string-append "Where I got to:\n\n" summary "\n\n") "")
       "No pull request was opened: a change that cannot pass the project's "
       "own tests is not worth a review slot. The issue is unchanged."))

    (define (pr-body issue-number summary run-url)
      (string-append
       "Closes #" (number->string issue-number) "\n\n"
       summary "\n\n"
       "---\n\n"
       "**This change was written by a machine.** It was produced by mesthiri "
       "driving a coding agent, and the commit's `Generated-by` trailer names "
       "the model that wrote it.\n\n"
       "The tests were run by the agent and are run again by this "
       "repository's own CI on this pull request — that second run, not the "
       "agent's account of itself, is the evidence the change is good.\n\n"
       "mesthiri holds no merge permission. Merging is yours.\n\n"
       "<sub>[run](" run-url ")</sub>"))

    ;; The stage's decision, as data, so the caller logs and comments rather
    ;; than this module doing both.
    (define (code-outcome kind detail) (cons kind detail))))
