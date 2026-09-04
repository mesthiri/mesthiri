;;; (mesthiri labels) — workflow state, on the repository
;;;
;;; State lives in labels rather than a database, so a human can read what
;;; mesthiri thinks and change it by changing a label. Transitions are
;;; declared, states are mutually exclusive, and a write is read back to
;;; confirm it took.
;;;
;;; The rule that earns the machine its keep: **a new commit clears every
;;; downstream label**, so a `ready-for-merge` earned by one head cannot
;;; survive the push that invalidated it.
;;;
;;; Note what is NOT here. A verdict's intent tier is recorded in the verdict
;;; and the run record, never as a label — a tier is an authorization fact,
;;; and putting it in a label anyone with triage permission can apply would
;;; make it self-granting.

(define-library (mesthiri labels)
  (import (scheme base) (scheme write) (mesthiri forge))
  (export workflow-labels label-exists? legal-transition? downstream-of
          apply-label! clear-downstream! ensure-labels!
          label-error? label-error-message)
  (begin

    (define-record-type <label-error>
      (make-label-error message) label-error?
      (message label-error-message))

    ;; The eight, in pipeline order. Order matters: "downstream" is defined by
    ;; it, which is what makes the clear-on-new-commit rule expressible.
    (define workflow-labels
      '("ready-for-triage" "triaged" "ready-to-implement" "in-progress"
        "ready-for-review" "needs-fix" "ready-for-merge" "needs-human"))

    ;; Declared legal moves. Anything not here is refused rather than
    ;; performed — a stage moving an issue somewhere the machine does not
    ;; describe is a bug, and silently allowing it hides it.
    (define transitions
      '(("ready-for-triage"   . ("triaged" "needs-human"))
        ("triaged"            . ("ready-to-implement" "needs-human"))
        ("ready-to-implement" . ("in-progress" "needs-human"))
        ("in-progress"        . ("ready-for-review" "needs-human"))
        ("ready-for-review"   . ("needs-fix" "ready-for-merge" "needs-human"))
        ("needs-fix"          . ("ready-for-review" "needs-human"))
        ("ready-for-merge"    . ("needs-fix" "needs-human"))
        ("needs-human"        . ())))

    (define (label-exists? name) (and (member name workflow-labels) #t))

    (define (legal-transition? from to)
      (and (label-exists? to)
           (cond ((not from) (string=? to "ready-for-triage"))
                 (else (let ((e (assoc from transitions)))
                         (and e (member to (cdr e)) #t))))))

    ;; Everything after `label` in pipeline order. A new commit clears these.
    (define (downstream-of label)
      (let loop ((l workflow-labels) (seen #f) (acc '()))
        (cond ((null? l) (reverse acc))
              ((and seen (not (string=? (car l) "needs-human")))
               (loop (cdr l) seen (cons (car l) acc)))
              ((string=? (car l) label) (loop (cdr l) #t acc))
              (else (loop (cdr l) seen acc)))))

    ;; --- forge operations ---------------------------------------------------

    (define (issue-path repo number suffix)
      (string-append "/repos/" repo "/issues/" (number->string number) suffix))

    ;; Created through the API when install opens its pull request, and
    ;; re-created here if one has been deleted — a missing label should not
    ;; fail a run.
    (define (ensure-labels! forge repo)
      (for-each
       (lambda (name)
         (guard (e ((forge-error? e) #t))
           (forge-post forge (string-append "/repos/" repo "/labels")
                       (string-append "{\"name\":\"" name
                                      "\",\"color\":\"ededed\"}"))))
       workflow-labels))

    ;; Apply `to`, removing any other workflow label — the states are mutually
    ;; exclusive, so this is one operation rather than two a caller might
    ;; half-perform. The write is read back: a label that did not take is a
    ;; pipeline that has silently stalled.
    (define (apply-label! forge repo number from to)
      (if (not (legal-transition? from to))
          (raise (make-label-error
                  (string-append "illegal transition: "
                                 (or from "(none)") " -> " to)))
          (begin
            (for-each
             (lambda (old)
               (if (and old (not (string=? old to)))
                   (guard (e ((forge-error? e) #t))
                     (forge-request forge "DELETE"
                                    (issue-path repo number
                                                (string-append "/labels/" old))))))
             workflow-labels)
            (forge-post forge (issue-path repo number "/labels")
                        (string-append "{\"labels\":[\"" to "\"]}"))
            (verify-label forge repo number to))))

    (define (verify-label forge repo number expected)
      (let ((current (forge-get forge (issue-path repo number "/labels"))))
        (let loop ((l (if (list? current) current '())))
          (cond ((null? l)
                 (raise (make-label-error
                         (string-append "label `" expected
                                        "` did not take on issue "
                                        (number->string number)))))
                ((let ((n (assoc "name" (car l))))
                   (and n (equal? (cdr n) expected))) #t)
                (else (loop (cdr l)))))))

    ;; A new commit invalidates every downstream state.
    (define (clear-downstream! forge repo number from)
      (for-each
       (lambda (l)
         (guard (e ((forge-error? e) #t))
           (forge-request forge "DELETE"
                          (issue-path repo number (string-append "/labels/" l)))))
       (downstream-of from)))))
