(import (scheme base) (scheme write) (mesthiri harness) (mesthiri config))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (raises? thunk) (guard (e ((harness-error? e) #t)) (thunk) #f))

(display "(mesthiri harness)\n")

(define cfg
  (parse-config
   '(mesthiri (version 1)
      (providers
        (deepseek (endpoint "https://api.deepseek.com")
                  (secret DEEPSEEK_API_KEY) (key-env DEEPSEEK_API_KEY)
                  (api openai-completions))
        (zai (endpoint "https://api.z.ai/api/paas/v4/")
             (secret GLM_API_KEY) (key-env GLM_API_KEY)
             (api openai-completions))))
   "test"))

(define t (read-harness "tests/fixtures" 'triage))
(define r (read-harness "tests/fixtures" 'review))

;; --- per-role model selection -------------------------------------------
(check "triage provider" 'deepseek (harness-provider t))
(check "triage model" "deepseek-v4-flash" (harness-model t))
(check "review provider" 'zai (harness-provider r))
(check "review model" "glm-5.3" (harness-model r))
(check "different roles, different providers"
       #t (not (eq? (harness-provider t) (harness-provider r))))
(check "effort is per role" '(low high) (list (harness-effort t) (harness-effort r)))
(check "budgets are per role" 60000 (harness-budget t 'tokens))

;; --- defaults ------------------------------------------------------------
(check "a role with no file has none" #f (read-harness "tests/fixtures" 'retro))
(check "and gets a shipped default" #t (pair? (default-harness 'retro)))

;; --- a floating alias must be refused, not resolved ----------------------
(check "\"-latest\" is refused"
       #t (raises? (lambda () (harness-model '((model "glm-5.3-latest"))))))
(check "\"auto\" is refused"
       #t (raises? (lambda () (harness-model '((model "auto"))))))
(check "an exact name is fine" "glm-5.3" (harness-model '((model "glm-5.3"))))

;; --- reviewer independence ----------------------------------------------
(check "differing providers validate" #t (validate-harnesses cfg "tests/fixtures"))

;; --- models.json rendering ----------------------------------------------
(define json (render-models-json cfg (list (cons 'deepseek "deepseek-v4-flash")
                                           (cons 'zai "glm-5.3"))))
(define (has? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                            ((string=? (substring s i (+ i m)) sub) #t)
                            (else (loop (+ i 1)))))))
(check "both base URLs are rendered"
       #t (and (has? json "https://api.deepseek.com")
               (has? json "https://api.z.ai/api/paas/v4/")))
(check "keys are env references, never values"
       #t (and (has? json "\"$DEEPSEEK_API_KEY\"") (has? json "\"$GLM_API_KEY\"")))
(check "each model lands under its own provider"
       #t (and (has? json "deepseek-v4-flash") (has? json "glm-5.3")))
(check "the api type is carried" #t (has? json "openai-completions"))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
