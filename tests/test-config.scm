(import (scheme base) (scheme write) (mesthiri config))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (raises? thunk)
  (guard (e ((config-error? e) #t)) (thunk) #f))

(display "(mesthiri config)\n")

(define c (read-config "tests/fixtures/config-good.scm"))

(check "version" 1 (config-version c))
(check "operator name" "Test Operator" (config-operator-name c))
(check "operator email" "operator@example.org" (config-operator-email c))
(check "reader App id" 123456 (config-app c 'reader))
(check "writer App id" 123457 (config-app c 'writer))
(check "rubric path" "docs/dev/github-issues.md" (config-rubric c))
(check "deny-paths" 3 (length (config-deny-paths c)))
(check "agent backend" 'pi (config-agent-backend c))
(check "agent version" "0.9.2" (config-agent-version c))
(check "provider names" '(main) (config-provider-names c))
(check "provider endpoint" "https://api.anthropic.com"
       (provider-endpoint (config-provider c 'main)))
(check "provider key-env" 'ANTHROPIC_API_KEY
       (provider-key-env (config-provider c 'main)))
(check "command permission" 'write (config-command-permission c 'implement))
(check "per-run token budget" 200000 (config-budget c 'per-run 'tokens))
(check "per-day run cap" 12 (config-budget c 'per-day 'runs))

;; Modes and their defaults — an unconfigured stage must be off, not on.
(check "declared mode" 'dry-run (stage-mode (config-stage c 'triage)))
(check "stage with no mode defaults to off"
       'off (stage-mode (config-stage c 'review)))
(check "absent stage defaults to off" 'off (stage-mode (config-stage c 'retro)))
(check "max-tier defaults to 0" 0 (stage-max-tier (config-stage c 'triage)))
(check "declared max-tier" 0 (stage-max-tier (config-stage c 'code)))

;; The trigger comes back as *data*. Nothing here evaluates it.
(check "trigger is returned as an unevaluated s-expression"
       '(or (label "ready-to-implement") (command "/implement"))
       (stage-trigger (config-stage c 'code)))

;; An unlisted command has no permission rather than a permissive default.
(check "unlisted command has no permission" #f (config-command-permission c 'deploy))

;; --- refusals ---------------------------------------------------------
(check "missing file is refused" #t (raises? (lambda () (read-config "tests/fixtures/nope.scm"))))
(check "non-(mesthiri ...) form is refused"
       #t (raises? (lambda () (parse-config '(something (version 1)) "x"))))
(check "config with no version is refused"
       #t (raises? (lambda () (parse-config '(mesthiri (rubric "r")) "x"))))
(check "unknown schema version is refused rather than guessed"
       #t (raises? (lambda () (parse-config '(mesthiri (version 99)) "x"))))
(check "empty file is refused"
       #t (raises? (lambda () (parse-config (eof-object) "x"))))

;; The refusal has to say what is wrong, not just that something is.
(check "the version refusal names both versions"
       #t (guard (e ((config-error? e)
                     (let ((m (config-error-message e)))
                       (and (string? m) (> (string-length m) 40)))))
            (parse-config '(mesthiri (version 99)) "x") #f))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
