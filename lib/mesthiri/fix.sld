;;; (mesthiri fix) — apply review findings, to a bounded depth
;;;
;;; The bound is the point. A fix loop with no ceiling is how an agent spends
;;; a budget rediscovering the same problem, and how a pull request
;;; accumulates twenty commits nobody wants to read. When the depth is spent,
;;; mesthiri hands over and says so rather than trying once more.
;;;
;;; Fix runs only on pull requests mesthiri authored. Pushing to someone
;;; else's branch is not mesthiri's to do.

(define-library (mesthiri fix)
  (import (scheme base) (scheme write) (mesthiri agent) (mesthiri log))
  (export fix-depth-limit fix-prompt fix-schema
          depth-from-commits handover-comment)
  (begin

    ;; Three attempts. Chosen small on purpose: if three passes have not
    ;; resolved a finding, the finding is probably about something the agent
    ;; cannot see, and a fourth is a worse use of a human's patience than a
    ;; handover.
    (define fix-depth-limit 3)

    (define fix-schema '(("summary" . string) ("tests_pass" . boolean)))

    (define (fix-prompt findings diff test-command)
      (string-append
       "A review of your change raised the findings below. Address them.\n\n"
       "Rules:\n"
       "1. Fix what the findings identify, and nothing else. A fix commit\n"
       "   that also refactors is a fix commit nobody can review.\n"
       "2. If you believe a finding is wrong, say so in your summary rather\n"
       "   than silently ignoring it. Disagreeing is allowed; ignoring is not.\n"
       "3. Run the project's tests and get them green:\n"
       "     " (or test-command "(none configured)") "\n"
       "4. Do not commit. Leave your changes in the working tree.\n\n"
       "Reply with JSON only: {\"summary\": \"...\", \"tests_pass\": true|false}\n"
       (untrusted-block "the review findings" findings)
       "\n<diff>\n" (or diff "") "\n</diff>\n"))

    ;; Depth is counted from mesthiri's own fix commits on the branch, so it
    ;; survives a job restart — there is no counter to lose.
    (define (depth-from-commits commit-subjects)
      (let loop ((c commit-subjects) (n 0))
        (cond ((null? c) n)
              ((fix-commit? (car c)) (loop (cdr c) (+ n 1)))
              (else (loop (cdr c) n)))))

    (define (fix-commit? subject)
      (and (string? subject)
           (>= (string-length subject) 4)
           (string=? (substring subject 0 4) "Fix ")))

    (define (handover-comment depth summary)
      (string-append
       "Handing this to a human.\n\n"
       "I have made " (number->string depth)
       " attempt" (if (= depth 1) "" "s")
       " at the review findings, which is the limit. "
       "A further pass is more likely to churn the diff than to resolve "
       "anything — if three have not fixed it, the problem is probably "
       "something I cannot see.\n\n"
       (if summary (string-append "Last attempt:\n\n" summary "\n\n") "")
       "The pull request is left open with the findings on it. "
       "`needs-human` is applied."))))
