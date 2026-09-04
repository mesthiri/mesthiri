(import (scheme base) (scheme write) (mesthiri prioritize) (mesthiri config)
        (mesthiri forge))

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

(display "(mesthiri prioritize)\n")

(define (iss n . labels)
  (list (cons "number" n)
        (cons "labels" (map (lambda (l) (list (cons "name" l))) labels))))
(define (numbers os) (map (lambda (o) (cdr (assoc "number" o))) os))

(define order '("priority: high" "priority: medium" "priority: low"))

;; --- ranking --------------------------------------------------------------
(check "the repository's ordering wins"
       '(2 1) (numbers (rank-issues (list (iss 1 "triaged" "priority: low")
                                          (iss 2 "triaged" "priority: high"))
                                    order)))
(check "age breaks a tie within a priority"
       '(3 7) (numbers (rank-issues (list (iss 7 "triaged" "priority: high")
                                          (iss 3 "triaged" "priority: high"))
                                    order)))
;; With no declared ordering, oldest first — mesthiri does not invent one.
(check "no ordering means oldest first"
       '(2 5 9) (numbers (rank-issues (list (iss 9 "triaged" "priority: high")
                                            (iss 2 "triaged" "priority: low")
                                            (iss 5 "triaged"))
                                      '())))
;; An unrecognised priority must not jump the queue.
(check "an unranked priority sorts after every ranked one"
       '(4 8) (numbers (rank-issues (list (iss 8 "triaged" "priority: urgent")
                                          (iss 4 "triaged" "priority: low"))
                                    order)))
(check "an issue with no priority label is handled" #f (issue-priority (iss 1 "triaged")))

;; The order is written into comments, so two runs over an unchanged queue
;; must produce the same order.
(define fixed (list (iss 5 "triaged" "priority: high") (iss 2 "triaged" "priority: high")
                    (iss 9 "triaged" "priority: low")))
(check "ranking is stable across runs"
       (numbers (rank-issues fixed order)) (numbers (rank-issues fixed order)))

;; --- the reason a human argues with ---------------------------------------
(define r (promotion-reason (iss 3 "triaged" "priority: high") 1 order))
(check "the reason names the position" #t (has? r "position 1"))
(check "the reason names what ranked it" #t (has? r "priority: high"))
(check "and says how to disagree" #t (has? r "remove the label"))
(define r2 (promotion-reason (iss 3 "triaged") 2 order))
(check "an unlabelled issue says it was ranked by age" #t (has? r2 "oldest first"))
(define r3 (promotion-reason (iss 3 "triaged" "priority: urgent") 1 order))
(check "an unranked priority says why it fell back to age"
       #t (has? r3 "not in the configured"))

;; --- dry-run writes nothing -----------------------------------------------
(define writes '())
(define (forge-with issues)
  (make-forge (lambda (m u h b)
                (if (not (string=? m "GET")) (set! writes (cons m writes)))
                (values 200 '() issues))))
(define cfg (parse-config '(mesthiri (version 1)
                             (priorities "priority: high" "priority: low")) "t"))
(set! writes '())
(define promoted
  (prioritize! (forge-with "[{\"number\":4,\"labels\":[{\"name\":\"triaged\"}]}]")
               cfg "o/r" 'dry-run "<!-- mesthiri:9 -->"))
(check "dry-run promotes nothing to the forge" '() writes)
(check "but reports what it would have promoted" '(4) promoted)

;; A backlog must not be relabelled wholesale in one scheduled run.
(check "promotion is capped" #t (<= promote-limit 10))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
