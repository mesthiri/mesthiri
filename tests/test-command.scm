(import (scheme base) (scheme write) (mesthiri command))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (names body) (map command-name (parse-commands body)))

(display "(mesthiri command)\n")

;; --- the table ----------------------------------------------------------
(check "five commands, no more" 5 (length command-table))
(check "/implement is an issue command" 'issue (command-entity 'implement))
(check "/fix is a pull-request command" 'pull-request (command-entity 'fix))
(check "/retro runs on either" 'either (command-entity 'retro))
;; The rule: code-changing needs write, commentary needs triage.
(check "/implement needs write" 'write (command-min-permission 'implement))
(check "/fix needs write" 'write (command-min-permission 'fix))
(check "/triage needs only triage" 'triage (command-min-permission 'triage))
(check "/review needs only triage" 'triage (command-min-permission 'review))
(check "/retro needs only triage" 'triage (command-min-permission 'retro))
(check "unknown command" #f (command-known? 'deploy))

;; --- permission ordering ------------------------------------------------
(check "write satisfies triage" #t (permission>=? "write" 'triage))
(check "triage does not satisfy write" #f (permission>=? "triage" 'write))
(check "admin satisfies everything" #t (permission>=? "admin" 'write))
(check "maintain satisfies write" #t (permission>=? "maintain" 'write))
(check "read does not satisfy triage" #f (permission>=? "read" 'triage))
(check "none satisfies nothing" #f (permission>=? "none" 'triage))
(check "an unknown permission string is treated as none"
       #f (permission>=? "wizard" 'triage))

;; --- parsing ------------------------------------------------------------
(check "a bare command" '(triage) (names "/triage"))
(check "command with arguments" '(implement) (names "/implement now"))
(check "arguments are captured" "now please"
       (command-args (car (parse-commands "/implement now please"))))
(check "command on a later line" '(fix) (names "hello\nthere\n/fix"))
(check "leading whitespace is allowed" '(triage) (names "   /triage"))
(check "several commands in order" '(triage review) (names "/triage\n/review"))

;; The security-relevant cases: attacker-writable text must not execute.
(check "mid-sentence mention does not parse" '() (names "you could /implement this"))
(check "a longer word is not a prefix match" '() (names "/fixup the thing"))
(check "an unknown slash word is ignored, not refused" '() (names "/deploy production"))
(check "no body parses to nothing" '() (names #f))
(check "empty body parses to nothing" '() (names ""))
(check "a lone slash is not a command" '() (names "/"))
;; An issue *body* containing a command must not be treated as an invocation
;; by anything that only looks at text — the caller decides whether a body is
;; an instruction, and for issue bodies it is not.
(check "a command inside quoted prose still only parses as text"
       '(implement) (names "> /implement\n/implement"))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
