;;; (mesthiri review) — four independent passes, then an attempt to refute
;;;
;;; Generation converges; review diverges. So the dimensions are separate
;;; passes rather than one prompt asking for everything: a single pass told to
;;; consider correctness, security, performance and intent produces a little
;;; of each and misses what a dedicated pass would catch.
;;;
;;; **A finding that cannot survive a refutation attempt is not posted.** That
;;; is the part that makes review usable rather than noisy — an unverified
;;; finding costs a human more than it saves, and enough of them make the
;;; whole stage something people mute.
;;;
;;; Each pass re-derives the intent tier from the diff independently, so a
;;; change that grew past its authorization is caught by something other than
;;; the agent that wrote it.

(define-library (mesthiri review)
  (import (scheme base) (scheme write)
          (mesthiri agent) (mesthiri forge) (mesthiri log))
  (export review-dimensions dimension-prompt refutation-prompt
          finding-schema refutation-schema
          mesthiri-authored? findings->comment survives-refutation?
          review-diff-limit)
  (begin

    (define review-dimensions '(correctness security performance intent))

    ;; A diff this large is not reviewed in one pass. Better to say so than to
    ;; silently review the first N lines and report as though the rest was
    ;; seen.
    (define review-diff-limit 4000)

    (define (dimension-prompt dimension diff issue-summary)
      (string-append
       "Review this diff for ONE dimension only: " (symbol->string dimension) ".\n\n"
       (dimension-brief dimension)
       "\n\nIgnore every other dimension. Another pass covers each of them, and\n"
       "a finding outside yours will be discarded.\n\n"
       "Also state the intent tier this diff actually represents — 0 trivial\n"
       "and revertible, 1 an ordinary fix, 2 a feature or migration — derived\n"
       "from what the diff does, not from what the issue claimed.\n\n"
       "Report only defects you can point at. An empty list is a good answer.\n\n"
       "Reply with JSON only:\n"
       "{\"tier\": N, \"findings\": [{\"file\": \"...\", \"line\": N,\n"
       " \"claim\": \"one sentence\", \"why\": \"why it is wrong\"}]}\n"
       (untrusted-block "the originating issue" issue-summary)
       "\n<diff>\n" (truncate-diff diff) "\n</diff>\n"))

    (define (dimension-brief d)
      (case d
        ((correctness) "Logic errors, wrong edge cases, off-by-one, a test that cannot fail, a fix that does not fix.")
        ((security)    "Injection, unvalidated input reaching a dangerous sink, secrets in code or logs, widened permissions.")
        ((performance) "Work in a loop that need not be, an obviously worse algorithm, unbounded growth.")
        ((intent)      "Does this do what the issue asked, and nothing more? Scope creep is a finding.")
        (else "")))

    (define (truncate-diff d)
      (if (and (string? d) (> (string-length d) review-diff-limit))
          (string-append (substring d 0 review-diff-limit)
                         "\n\n[diff truncated at " (number->string review-diff-limit)
                         " characters — say so in your findings rather than "
                         "reviewing as though you saw the rest]")
          (or d "")))

    ;; The second pass. Deliberately adversarial and deliberately separate: it
    ;; is given the finding and asked to destroy it, not to double-check it.
    (define (refutation-prompt finding diff)
      (string-append
       "A reviewer claims the following defect. Your job is to REFUTE it.\n\n"
       "Claim: " (or (assoc-str finding "claim") "(none)") "\n"
       "File: " (or (assoc-str finding "file") "(none)") "\n"
       "Reason given: " (or (assoc-str finding "why") "(none)") "\n\n"
       "Look at the diff and find the strongest reason the claim is wrong,\n"
       "irrelevant, or already handled elsewhere. If you genuinely cannot,\n"
       "say so — but try first. A finding that survives a real attempt is\n"
       "worth a human's time; one that was never challenged is not.\n\n"
       "Reply with JSON only: {\"refuted\": true|false, \"reason\": \"...\"}\n"
       "\n<diff>\n" (truncate-diff diff) "\n</diff>\n"))

    (define (assoc-str o key)
      (let ((x (assoc key o))) (and x (string? (cdr x)) (cdr x))))

    (define finding-schema '(("tier" . number) ("findings" . list)))
    (define refutation-schema '(("refuted" . boolean) ("reason" . string)))

    ;; A finding survives only when the refutation attempt failed.
    (define (survives-refutation? refutation)
      (let ((r (assoc "refuted" refutation)))
        (not (and r (eq? (cdr r) #t)))))

    ;; Review fires on pull requests mesthiri opened. `pull_request_target`
    ;; fires for fork pull requests too, so reviewing everything would let
    ;; anyone who can open one spend the repository's budget — the per-day cap
    ;; is approximate and is not a defence.
    (define (mesthiri-authored? pr)
      (let ((u (assoc "user" pr)))
        (and u (let ((l (assoc "login" (cdr u))))
                 (and l (string? (cdr l))
                      (bot-suffix? (cdr l)))))))

    (define (bot-suffix? login)
      (let ((n (string-length login)))
        (and (> n 5) (string=? (substring login (- n 5) n) "[bot]"))))

    (define (findings->comment dimension findings tier claimed-tier)
      (string-append
       "**Review: " (symbol->string dimension) "**\n\n"
       (if (null? findings)
           "No findings on this dimension.\n"
           (let loop ((f findings) (acc ""))
             (if (null? f) acc
                 (loop (cdr f)
                       (string-append
                        acc "- **" (or (assoc-str (car f) "file") "?") "** — "
                        (or (assoc-str (car f) "claim") "") "\n  "
                        (or (assoc-str (car f) "why") "") "\n")))))
       (if (and (number? tier) (number? claimed-tier) (> tier claimed-tier))
           (string-append
            "\n**Scope**: this diff looks like intent tier "
            (number->string tier) ", and it was authorized as tier "
            (number->string claimed-tier)
            ". A change that grew past its authorization needs a human to say "
            "whether that is wanted.\n")
           "")
       "\n<sub>Findings survive only if a separate pass failed to refute them. "
       "mesthiri holds no approve or merge permission.</sub>"))))
