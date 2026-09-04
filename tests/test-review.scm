(import (scheme base) (scheme write) (mesthiri review) (mesthiri fix))
(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (has? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                            ((string=? (substring s i (+ i m)) sub) #t)
                            (else (loop (+ i 1)))))))
(display "(mesthiri review) and (mesthiri fix)\n")

(check "four dimensions" 4 (length review-dimensions))

;; --- one dimension per pass, not one prompt asking for everything --------
(define p (dimension-prompt 'security "- old\n+ new" "fix the crash"))
(check "the pass is told its one dimension" #t (has? p "security"))
(check "and told to ignore the others" #t (has? p "Ignore every other dimension"))
(check "an empty finding list is stated to be a good answer"
       #t (has? p "empty list is a good answer"))
;; Independent tier re-derivation is what catches scope creep.
(check "the pass re-derives the tier from the diff, not the issue"
       #t (has? p "not from what the issue claimed"))
(check "the issue text is quoted as untrusted" #t (has? p "<untrusted-input"))

;; A truncated diff must be declared, not silently reviewed in part.
(define big (make-string (+ review-diff-limit 500) #\x))
(check "an oversized diff says it was truncated"
       #t (has? (dimension-prompt 'correctness big "s") "diff truncated"))

;; --- refutation ----------------------------------------------------------
(define rp (refutation-prompt '(("claim" . "off by one") ("file" . "a.scm")
                                ("why" . "loop ends early")) "diff"))
(check "the refutation pass is asked to destroy the claim" #t (has? rp "REFUTE"))
(check "it carries the claim it must attack" #t (has? rp "off by one"))
(check "and is told an unchallenged finding is not worth posting"
       #t (has? rp "never challenged"))

(check "a refuted finding does not survive"
       #f (survives-refutation? '(("refuted" . #t) ("reason" . "already handled"))))
(check "an unrefuted finding survives"
       #t (survives-refutation? '(("refuted" . #f) ("reason" . "the claim holds"))))
;; A malformed refutation must not silently drop a real finding.
(check "a missing verdict is treated as surviving, not as refuted"
       #t (survives-refutation? '(("reason" . "unclear"))))

;; --- who gets reviewed ---------------------------------------------------
(check "a mesthiri pull request is reviewed"
       #t (mesthiri-authored? '(("user" ("login" . "mesthiri-writer[bot]")))))
;; pull_request_target fires for forks; reviewing everything would let anyone
;; spend the repository's budget.
(check "a human's pull request is not automatically reviewed"
       #f (mesthiri-authored? '(("user" ("login" . "alice")))))

;; --- the comment ---------------------------------------------------------
(define c (findings->comment 'intent
                             (list '(("file" . "a.scm") ("claim" . "scope creep")
                                     ("why" . "touches unrelated code")))
                             2 1))
(check "the finding is shown" #t (has? c "scope creep"))
(check "a grown tier is called out" #t (has? c "grew past its authorization"))
(check "the reader is told findings were refuted first" #t (has? c "failed to refute"))
(check "and that mesthiri cannot approve" #t (has? c "no approve or merge permission"))
(check "no findings is stated plainly, not omitted"
       #t (has? (findings->comment 'security '() 1 1) "No findings"))

;; --- the fix loop is bounded ---------------------------------------------
(check "depth counts mesthiri's own fix commits"
       2 (depth-from-commits '("Fix #1" "Add feature" "Fix #1 again")))
(check "an unrelated history is depth zero" 0 (depth-from-commits '("Initial" "Docs")))
(check "the limit is small on purpose" #t (<= fix-depth-limit 3))
(define h (handover-comment 3 "tried narrowing the guard"))
(check "the handover says why it stopped" #t (has? h "more likely to churn"))
(check "and that the PR is left open with findings" #t (has? h "left open"))
;; Disagreeing must be allowed; silently ignoring must not.
(check "the fix prompt allows disagreement but not silence"
       #t (has? (fix-prompt "f" "d" "t") "Disagreeing is allowed; ignoring is not"))


;; The branch a pull request lives on comes from the pull request.
;;
;; `branch-name-for` derives a branch from an ISSUE number, and a pull
;; request's number is not its issue's — PR #10 fixed issue #9 and lived on
;; `mesthiri/issue-9`. Fix computed `mesthiri/issue-10`, asked git for a
;; branch that does not exist, and the run died in under three seconds with
;; a bare "runtime error" before any agent started. The logic was in
;; mesthiri.scm, where no test could reach it; that is why it lives here now.
(check "the head ref comes from the pull request"
       "mesthiri/issue-9"
       (pr-head-ref '(("number" . 10)
                      ("head" . (("ref" . "mesthiri/issue-9"))))))

(check "a pull request with no head ref is an error, not a guess"
       #t (guard (e (#t #t))
            (pr-head-ref '(("number" . 10)))
            #f))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
