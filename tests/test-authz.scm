(import (scheme base) (scheme write)
        (mesthiri authz) (mesthiri command) (mesthiri event) (mesthiri forge))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri authz)\n")

;; A forge whose permission endpoint answers from a table.
(define (forge-with perms)
  (make-forge
   (lambda (method url headers body)
     (let loop ((p perms))
       (cond ((null? p) (values 404 '() "{\"message\":\"Not Found\"}"))
             ((let ((needle (string-append "/collaborators/" (caar p) "/permission")))
                (let scan ((i 0))
                  (cond ((> (+ i (string-length needle)) (string-length url)) #f)
                        ((string=? (substring url i (+ i (string-length needle))) needle) #t)
                        (else (scan (+ i 1))))))
              (values 200 '() (string-append "{\"role_name\":\"" (cdar p) "\"}")))
             (else (loop (cdr p))))))))

(define f (forge-with '(("alice" . "write") ("bob" . "triage") ("carol" . "read"))))

(define (ev kind actor . opts)
  (make-event kind "o/r" actor 1 '() (if (pair? opts) (car opts) #f) "" 1 #f
              (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) #f)))

;; --- permission lookup --------------------------------------------------
(check "role_name is preferred over permission" 'write (actor-permission f "o/r" "alice"))
(check "triage role is seen as triage, not read" 'triage (actor-permission f "o/r" "bob"))
;; A 404 means not a collaborator, which is 'none rather than an error — a
;; stranger commenting must be refused, not crash the run.
(check "unknown user is none, not an error" 'none (actor-permission f "o/r" "mallory"))

;; --- commands -----------------------------------------------------------
(define (auth-cmd actor body)
  (let ((cmds (parse-commands body)))
    (authorize-command f (ev 'issue-comment actor body) (car cmds))))

(check "write may /implement" #t (authz-ok? (auth-cmd "alice" "/implement")))
(check "triage may not /implement" #f (authz-ok? (auth-cmd "bob" "/implement")))
(check "triage may /triage" #t (authz-ok? (auth-cmd "bob" "/triage")))
(check "read may not even /triage" #f (authz-ok? (auth-cmd "carol" "/triage")))
(check "a stranger is refused" #f (authz-ok? (auth-cmd "mallory" "/triage")))

;; The refusal has to say what is needed and what they have, or nobody can act
;; on it.
(check "the refusal names the requirement and the actual permission"
       #t (let ((r (authz-reason (auth-cmd "bob" "/implement"))))
            (and (string? r) (> (string-length r) 30))))

;; --- entity restriction -------------------------------------------------
(check "/implement on a pull request is refused"
       #f (authz-ok? (authorize-command
                      f (ev 'pull-request-updated "alice" "/implement")
                      (car (parse-commands "/implement")))))
(check "/fix on an issue is refused"
       #f (authz-ok? (authorize-command
                      f (ev 'issue-comment "alice" "/fix")
                      (car (parse-commands "/fix")))))
(check "/fix on a pull request is allowed"
       #t (authz-ok? (authorize-command
                      f (ev 'pull-request-updated "alice" "/fix")
                      (car (parse-commands "/fix")))))
(check "/retro is allowed on either"
       #t (authz-ok? (authorize-command
                      f (ev 'pull-request-updated "bob" "/retro")
                      (car (parse-commands "/retro")))))

;; --- labels: the escalation this exists to close ------------------------
;; GitHub's triage role can apply labels, and the code stage fires on one.
(check "a triage-role human cannot trigger the code stage by labelling"
       #f (authz-ok? (authorize-label f (ev 'issue-labeled "bob") 'write)))
(check "a write-role human can"
       #t (authz-ok? (authorize-label f (ev 'issue-labeled "alice") 'write)))
(check "a triage-role human can trigger a triage-level stage by labelling"
       #t (authz-ok? (authorize-label f (ev 'issue-labeled "bob") 'triage)))

;; mesthiri's own Apps are exempt: this is the pipeline moving its own work.
(define bot-ev (make-event 'issue-labeled "o/r" "mesthiri[bot]" 1 '() #f "" 1 #f #t))
(check "a label applied by mesthiri's App passes without a lookup"
       #t (authz-ok? (authorize-label f bot-ev 'write)))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
