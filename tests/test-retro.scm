(import (scheme base) (scheme write) (mesthiri retro))
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
(display "(mesthiri retro)\n")

(define (run stage conclusion outcome)
  (list (cons "stage" stage) (cons "conclusion" conclusion) (cons "outcome" outcome)))

;; --- one failure is noise, a pattern is not ------------------------------
;; Filing on the first occurrence would make retro the noisiest thing in the
;; repository.
(check "a single failure is not reported"
       0 (length (analyze-runs (list (run "code" "failure" "ran")))))
(check "two are still not reported"
       0 (length (analyze-runs (list (run "code" "failure" "ran")
                                     (run "code" "failure" "ran")))))
(check "three is a pattern"
       1 (length (analyze-runs (list (run "code" "failure" "ran")
                                     (run "code" "failure" "ran")
                                     (run "code" "failure" "ran")))))
(check "and it counts them"
       3 (observation-count (car (analyze-runs (list (run "code" "failure" "ran")
                                                     (run "code" "failure" "ran")
                                                     (run "code" "failure" "ran"))))))
;; Failures in different stages are different observations, not one.
(check "failures are grouped by stage"
       0 (length (analyze-runs (list (run "code" "failure" "ran")
                                     (run "review" "failure" "ran")
                                     (run "triage" "failure" "ran")))))

;; --- the classes worth telling apart -------------------------------------
(define (times n r) (let loop ((i 0) (acc '())) (if (>= i n) acc (loop (+ i 1) (cons r acc)))))
(check "budget exhaustion is its own class"
       'budget-exhausted
       (observation-kind (car (analyze-runs (times 3 (run "code" "success" "over-budget"))))))
(check "repeated escalation is its own class"
       'escalated-to-human
       (observation-kind (car (analyze-runs (times 3 (run "fix" "success" "needs-human"))))))
(check "an agent that never settles is its own class"
       'agent-never-settled
       (observation-kind (car (analyze-runs (times 3 (run "code" "success" "eof"))))))

;; --- what a human reads ---------------------------------------------------
(define o (car (analyze-runs (times 4 (run "code" "success" "over-budget")))))
(define body (observation->body o retro-window))
(check "the title names the stage" #t (has? (observation->title o) "code"))
(check "the body says how often" #t (has? body "4 times"))
(check "and points at where to look" #t (has? body "JSONL trace"))
;; Retro proposes; it does not act. Saying so keeps it from reading as a
;; demand.
(check "it says it cannot fix this itself" #t (has? body "cannot fix this myself"))
(check "and that closing is a fine answer" #t (has? body "Closing this issue is a fine answer"))

;; --- not filed twice ------------------------------------------------------
;; A retro that reopens its own issue every week is one nobody reads.
(check "an already-filed observation is recognised"
       #t (already-filed? (list (list (cons "body"
                        (string-append "old text\n" (observation-marker o))))) o))
(check "an unrelated issue is not mistaken for it"
       #f (already-filed? (list (list (cons "body" "something else"))) o))
;; The marker must not include the count, or every recurrence files afresh.
(check "the marker is stable as the count grows"
       (observation-marker o)
       (observation-marker (car (analyze-runs (times 9 (run "code" "success" "over-budget"))))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
