(import (scheme base) (scheme write)
        (mesthiri dispatch) (mesthiri config) (mesthiri event)
        (mesthiri forge) (mesthiri command) (mesthiri event))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri dispatch)\n")

(define (forge-with perms)
  (make-forge
   (lambda (method url headers body)
     (let loop ((p perms))
       (cond ((null? p) (values 404 '() "{}"))
             ((let* ((needle (string-append "/collaborators/" (caar p) "/permission"))
                     (n (string-length needle)))
                (let scan ((i 0))
                  (cond ((> (+ i n) (string-length url)) #f)
                        ((string=? (substring url i (+ i n)) needle) #t)
                        (else (scan (+ i 1))))))
              (values 200 '() (string-append "{\"role_name\":\"" (cdar p) "\"}")))
             (else (loop (cdr p))))))))
(define f (forge-with '(("alice" . "write") ("bob" . "triage"))))

(define cfg
  (parse-config
   '(mesthiri (version 1)
      (stages
        (triage (on (or (issue-opened) (command "/triage"))) (mode live))
        (code   (on (or (label "ready-to-implement") (command "/implement")))
                (mode live))
        (retro  (on (schedule "06:00")) (mode off))))
   "test"))

(define ran '())
(define handlers
  (list (cons 'triage (lambda (fo c e) (set! ran (cons 'triage ran))))
        (cons 'code   (lambda (fo c e) (set! ran (cons 'code ran))))))
(define (never-handled e s) #f)
(define (always-handled e s) #t)

(define (ev kind actor . opts)
  (make-event kind "o/r" actor 1
              (if (pair? opts) (car opts) '())
              (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) #f)
              "" 1
              (if (and (pair? opts) (pair? (cdr opts)) (pair? (cddr opts)))
                  (caddr opts) #f)
              (equal? actor "mesthiri[bot]") #f))

(define (outcome-of e) (decision-outcome (dispatch f cfg e handlers never-handled)))

;; --- the happy paths ----------------------------------------------------
(set! ran '())
(check "an authorized command runs its stage"
       'ran (outcome-of (ev 'issue-comment "alice" '() "/implement")))
(check "the handler actually ran" '(code) ran)
(check "a trigger match runs its stage"
       'ran (outcome-of (ev 'issue-opened "alice")))

;; --- the gates, in order ------------------------------------------------
(check "no matching trigger" 'no-match (outcome-of (ev 'pull-request-updated "alice")))
;; The tick must match, or this would test trigger matching rather than the
;; mode gate — the first draft of this test did exactly that and passed for
;; the wrong reason.
(check "a matching trigger on an off stage does not run" 'stage-off
       (outcome-of (ev 'schedule "alice" '() #f "sunday 06:00")))
(check "an explicit command on an off stage is refused with a reason, not ignored"
       'stage-off (outcome-of (ev 'issue-comment "alice" '() "/retro")))
(check "an unauthorized command is refused"
       'unauthorized (outcome-of (ev 'issue-comment "bob" '() "/implement")))
(check "the refusal carries a reason a human can act on"
       #t (let ((d (dispatch f cfg (ev 'issue-comment "bob" '() "/implement")
                             handlers never-handled)))
            (and (string? (decision-reason d)) (> (string-length (decision-reason d)) 20))))

;; The label escalation, end to end through dispatch rather than authz alone.
(check "a triage-role human labelling ready-to-implement is refused"
       'unauthorized (outcome-of (ev 'issue-labeled "bob" '("ready-to-implement"))))
(check "a write-role human labelling it is allowed"
       'ran (outcome-of (ev 'issue-labeled "alice" '("ready-to-implement"))))
(check "mesthiri's own App labelling it passes"
       'ran (outcome-of (ev 'issue-labeled "mesthiri[bot]" '("ready-to-implement"))))

;; --- idempotency --------------------------------------------------------
(set! ran '())
(check "an already-handled event does not run again"
       'already-handled
       (decision-outcome (dispatch f cfg (ev 'issue-comment "alice" '() "/implement")
                                   handlers always-handled)))
(check "and the handler was not called" '() ran)

;; --- one event, one stage ------------------------------------------------
;; Two commands in one comment must not run two stages.
(set! ran '())
(define _two (dispatch f cfg (ev 'issue-comment "alice" '() "/triage\n/implement")
                       handlers never-handled))
(check "only the first command runs" 1 (length ran))

;; --- mesthiri's own comments must not dispatch ---------------------------
;; Every comment mesthiri writes fires an issue_comment event. Left alone it
;; dispatches, matches nothing and exits — correct but a CI run per comment.
(define marked (string-append "mesthiri reached the triage stage.\n\n"
                              marker-prefix "412 -->"))

(check "mesthiri's own comment is suppressed before anything is parsed"
       'own-comment
       (decision-outcome
        (dispatch f cfg (make-event 'issue-comment "o/r" "mesthiri-reader[bot]" 1
                                    '() marked "" 1 #f #t #f)
                  handlers never-handled)))

;; The two signals are both required, and each guards a different mistake.
(check "a human comment carrying the marker still dispatches"
       'ran
       (decision-outcome
        (dispatch f cfg (make-event 'issue-comment "o/r" "alice" 1 '()
                                    (string-append "/triage\n" marker-prefix "1 -->")
                                    "" 1 #f #f #f)
                  handlers never-handled)))
(check "another bot's command is NOT suppressed — authorization is by permission"
       'unauthorized
       (decision-outcome
        (dispatch f cfg (make-event 'issue-comment "o/r" "dependabot[bot]" 1 '()
                                    "/implement" "" 1 #f #t #f)
                  handlers never-handled)))
;; Labels mesthiri applies must still dispatch, or prioritize could never hand
;; work to the code stage.
(check "a label applied by mesthiri still dispatches"
       'ran
       (decision-outcome
        (dispatch f cfg (make-event 'issue-labeled "o/r" "mesthiri-reader[bot]" 1
                                    '("ready-to-implement") #f "" 1 #f #t #f)
                  handlers never-handled)))

;; --- a malformed trigger is reported, not silently non-matching ----------
(define bad-cfg
  (parse-config '(mesthiri (version 1)
                   (stages (triage (on (system "rm -rf /")) (mode live))))
                "test"))
(check "an invalid trigger does not match and does not crash"
       'no-match (decision-outcome (dispatch f bad-cfg (ev 'issue-opened "alice")
                                             handlers never-handled)))
(check "and stage-candidates reports it as invalid"
       'invalid (car (cadddr (car (stage-candidates bad-cfg (ev 'issue-opened "alice"))))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
