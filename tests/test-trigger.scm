(import (scheme base) (scheme write) (mesthiri trigger) (mesthiri event))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (refused? form ev)
  (guard (e ((trigger-error? e) #t)) (trigger-match? form ev) #f))

(display "(mesthiri trigger)\n")

(define (ev kind . opts)
  (make-event kind "o/r" "alice" 1
              (if (pair? opts) (car opts) '())
              (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) #f)
              "" 1
              (if (and (pair? opts) (pair? (cdr opts)) (pair? (cddr opts))) (caddr opts) #f)
              #f #f))

;; --- vocabulary -------------------------------------------------------
(check "event predicate matches its kind" #t (trigger-match? '(issue-opened) (ev 'issue-opened)))
(check "event predicate rejects another kind" #f (trigger-match? '(issue-opened) (ev 'issue-comment)))
(check "label present" #t (trigger-match? '(label "ready-to-implement")
                                          (ev 'issue-labeled '("ready-to-implement"))))
(check "label absent" #f (trigger-match? '(label "ready-to-implement") (ev 'issue-labeled '("bug"))))

;; --- combinators ------------------------------------------------------
(check "or" #t (trigger-match? '(or (issue-opened) (issue-reopened)) (ev 'issue-reopened)))
(check "and" #f (trigger-match? '(and (issue-opened) (label "x")) (ev 'issue-opened)))
(check "not" #t (trigger-match? '(not (issue-opened)) (ev 'issue-comment)))
(check "nesting" #t (trigger-match? '(or (and (issue-comment) (label "bug")) (issue-opened))
                                    (ev 'issue-comment '("bug"))))

;; --- commands: attacker-writable text, so parsing must be strict -------
(check "command at line start" #t
       (trigger-match? '(command "/implement") (ev 'issue-comment '() "/implement")))
(check "command with trailing text" #t
       (trigger-match? '(command "/implement") (ev 'issue-comment '() "/implement now please")))
(check "command on a later line" #t
       (trigger-match? '(command "/implement") (ev 'issue-comment '() "hello\n/implement")))
(check "command mid-sentence does NOT fire" #f
       (trigger-match? '(command "/implement") (ev 'issue-comment '() "you could /implement this")))
(check "a longer command is not a prefix match" #f
       (trigger-match? '(command "/fix") (ev 'issue-comment '() "/fixup the thing")))
(check "no body does not fire" #f
       (trigger-match? '(command "/implement") (ev 'issue-comment '() #f)))

;; --- schedules --------------------------------------------------------
(check "daily schedule matches the hour"
       #t (trigger-match? '(schedule "07:00") (ev 'schedule '() #f "friday 07:00")))
(check "daily schedule ignores the weekday"
       #t (trigger-match? '(schedule "07:00") (ev 'schedule '() #f "sunday 07:00")))
(check "weekly schedule needs the weekday"
       #f (trigger-match? '(schedule "sunday 06:00") (ev 'schedule '() #f "friday 06:00")))
(check "weekly schedule matches its day"
       #t (trigger-match? '(schedule "sunday 06:00") (ev 'schedule '() #f "sunday 06:00")))
(check "a schedule predicate never fires on a non-schedule event"
       #f (trigger-match? '(schedule "07:00") (ev 'issue-opened)))

;; --- the security property --------------------------------------------
;; Anything outside the vocabulary is refused, not ignored and not run.
(check "an arbitrary procedure call is refused"
       #t (refused? '(system "rm -rf /") (ev 'issue-opened)))
(check "a Scheme builtin is refused"
       #t (refused? '(display "pwned") (ev 'issue-opened)))
(check "eval is refused like anything else"
       #t (refused? '(eval '(+ 1 2)) (ev 'issue-opened)))
(check "an unknown predicate nested inside `or` is still refused"
       #t (refused? '(or (issue-opened) (launch-missiles)) (ev 'issue-comment)))
(check "a bare atom is refused" #t (refused? 'issue-opened (ev 'issue-opened)))
(check "wrong arity is refused" #t (refused? '(issue-opened "extra") (ev 'issue-opened)))
(check "a non-string label argument is refused" #t (refused? '(label bug) (ev 'issue-labeled)))

;; The refusal must name the offending form, or a config typo is unfindable.
(check "the refusal carries the form"
       '(launch-missiles)
       (guard (e ((trigger-error? e) (trigger-error-form e)))
         (trigger-match? '(launch-missiles) (ev 'issue-opened)) #f))

;; --- load-time validation ---------------------------------------------
(check "valid form validates" #t (trigger-valid? '(or (issue-opened) (schedule "07:00"))))
(check "invalid form fails validation" #f (trigger-valid? '(or (issue-opened) (system "x"))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
