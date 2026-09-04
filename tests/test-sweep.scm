(import (scheme base) (scheme write) (mesthiri sweep) (mesthiri forge))
(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri sweep)\n")

(define (issue . labels)
  (list (cons "number" 1)
        (cons "labels" (map (lambda (l) (list (cons "name" l))) labels))))

(check "an unlabelled issue has not been seen" #t (needs-triage? (issue)))
(check "a non-workflow label does not count as seen"
       #t (needs-triage? (issue "bug" "priority: high")))
(check "explicitly queued is picked up" #t (needs-triage? (issue "ready-for-triage")))
;; This is what makes a sweep idempotent without a cursor.
(check "an already-triaged issue is skipped" #f (needs-triage? (issue "triaged")))
(check "an in-flight issue is skipped" #f (needs-triage? (issue "in-progress")))
(check "one escalated to a human is skipped" #f (needs-triage? (issue "needs-human")))
;; The issues endpoint returns pull requests too.
(check "a pull request is not an issue to triage"
       #f (needs-triage? (list (cons "number" 2) (cons "labels" '())
                               (cons "pull_request" '()))))

;; A repository discovering mesthiri must not spend a day's budget at once.
(define many
  (make-forge (lambda (m u h b)
                (values 200 '()
                        (string-append "["
                          (let loop ((i 0) (acc ""))
                            (if (>= i 50) acc
                                (loop (+ i 1)
                                      (string-append acc (if (> i 0) "," "")
                                                     "{\"number\":" (number->string i)
                                                     ",\"labels\":[]}"))))
                          "]")))))
(check "a sweep is capped" sweep-limit (length (untriaged-issues many "o/r")))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
