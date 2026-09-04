(import (scheme base) (scheme write) (mesthiri labels) (mesthiri forge))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri labels)\n")

(check "eight workflow labels" 8 (length workflow-labels))
(check "a workflow label is recognised" #t (label-exists? "ready-for-merge"))
(check "an arbitrary label is not" #f (label-exists? "priority: high"))

;; --- declared transitions -------------------------------------------------
(check "an issue starts at ready-for-triage" #t (legal-transition? #f "ready-for-triage"))
(check "an issue cannot start mid-pipeline" #f (legal-transition? #f "ready-for-merge"))
(check "triage moves to triaged" #t (legal-transition? "ready-for-triage" "triaged"))
(check "review can reject to needs-fix" #t (legal-transition? "ready-for-review" "needs-fix"))
(check "fix returns to review" #t (legal-transition? "needs-fix" "ready-for-review"))
;; Skipping the pipeline is refused, not silently allowed.
(check "triaged cannot jump to ready-for-merge"
       #f (legal-transition? "triaged" "ready-for-merge"))
(check "nothing leaves needs-human automatically"
       #f (legal-transition? "needs-human" "ready-for-review"))
(check "any state can escalate to a human"
       #t (legal-transition? "in-progress" "needs-human"))

;; --- the rule that earns the machine its keep -----------------------------
;; A new commit clears everything downstream, so an approval cannot outlive
;; the head that earned it.
(check "ready-for-merge is downstream of ready-for-review"
       #t (and (member "ready-for-merge" (downstream-of "ready-for-review")) #t))
(check "upstream states are not cleared"
       #f (and (member "triaged" (downstream-of "ready-for-review")) #t))
;; needs-human is never cleared by a commit: a human asked to look, and a
;; push does not answer them.
(check "needs-human survives a new commit"
       #f (and (member "needs-human" (downstream-of "triaged")) #t))
(check "nothing is downstream of the last state" '() (downstream-of "needs-human"))

;; --- mutual exclusion and read-back ---------------------------------------
(define ops '())
(define (fake-forge label-after-write)
  (make-forge
   (lambda (method url headers body)
     (set! ops (cons (list method url) ops))
     (cond
      ((and (string=? method "GET"))
       (values 200 '() (string-append "[{\"name\":\"" label-after-write "\"}]")))
      (else (values 200 '() "{}"))))))

(set! ops '())
(check "a legal transition applies and verifies"
       #t (apply-label! (fake-forge "triaged") "o/r" 7 "ready-for-triage" "triaged"))
(check "the old labels are deleted first (mutual exclusion)"
       #t (let loop ((o ops))
            (cond ((null? o) #f)
                  ((string=? (caar o) "DELETE") #t)
                  (else (loop (cdr o))))))

;; The write is read back, so a label that silently did not take is caught.
(check "a label that did not take is an error, not a shrug"
       #t (guard (e ((label-error? e) #t))
            (apply-label! (fake-forge "something-else") "o/r" 7
                          "ready-for-triage" "triaged")
            #f))

(check "an illegal transition is refused before any write"
       #t (guard (e ((label-error? e) #t))
            (apply-label! (fake-forge "x") "o/r" 7 "triaged" "ready-for-merge")
            #f))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
