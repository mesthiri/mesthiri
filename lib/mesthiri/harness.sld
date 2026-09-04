;;; (mesthiri harness) — what turns a generic model into a role
;;;
;;; One file per role under `.mesthiri/harness/<role>.scm`, holding the
;;; provider and model that role uses, its effort level and its budgets.
;;; mesthiri ships a default for every role, so a repository works with a
;;; `config.scm` alone: nobody should have to write a system prompt to see a
;;; first verdict. A repo file overrides whichever parts it names and inherits
;;; the rest.
;;;
;;; Which model a stage uses is a property of the stage, not the repository.
;;; Triage applies a rubric to an issue; review argues with a diff. Paying for
;;; the strongest model in both is the most common way to make this expensive
;;; for no benefit.

(define-library (mesthiri harness)
  (import (scheme base) (scheme read) (scheme file) (scheme write) (scheme char)
          (mesthiri config))
  (export read-harness harness-provider harness-model harness-effort
          harness-budget default-harness harness-roles
          validate-harnesses harness-error? harness-error-message
          render-models-json)
  (begin

    (define-record-type <harness-error>
      (make-harness-error message) harness-error?
      (message harness-error-message))

    (define (fail . parts)
      (raise (make-harness-error (apply string-append parts))))

    (define harness-roles '(triage prioritize code review fix retro))

    ;; Shipped defaults. Deliberately modest: the cheap model everywhere, so a
    ;; repository that never writes a harness file spends the least, and the
    ;; expensive choice is one somebody made on purpose.
    (define (default-harness role)
      `((effort . low)
        (budgets (tokens . 60000) (turns . 12))))

    (define (form-ref forms key)
      (let loop ((f forms))
        (cond ((null? f) #f)
              ((and (pair? (car f)) (eq? (caar f) key)) (car f))
              (else (loop (cdr f))))))

    (define (form-arg1 forms key)
      (let ((f (form-ref forms key))) (and f (pair? (cdr f)) (cadr f))))

    ;; `.mesthiri/harness/<role>.scm`, or #f when the repo has not written one.
    (define (read-harness dir role)
      (let ((path (string-append dir "/harness/" (symbol->string role) ".scm")))
        (and (file-exists? path)
             (let ((datum (call-with-input-file path read)))
               (if (not (and (pair? datum) (eq? (car datum) 'harness)))
                   (fail path " must be a single (harness ...) form")
                   (cdr datum))))))

    (define (harness-provider h) (and h (form-arg1 h 'provider)))
    (define (harness-effort h)
      (or (and h (form-arg1 h 'effort)) 'low))

    ;; A model must be named in full. A floating alias is rejected rather than
    ;; resolved: an alias that moves under you changes every verdict and every
    ;; review afterwards, with nothing in the repository recording that
    ;; anything changed — the same failure as rubric drift, which mesthiri
    ;; already guards by recording the rubric's commit SHA.
    (define (harness-model h)
      (let ((m (and h (form-arg1 h 'model))))
        (cond ((not m) #f)
              ((not (string? m)) (fail "model must be a string"))
              ((alias? m)
               (fail "model \"" m "\" looks like a floating alias; name an "
                     "exact model so a verdict can be traced to what produced it"))
              (else m))))

    (define (alias? m)
      (let ((n (string-length m)))
        (or (suffix? m "-latest") (suffix? m "latest")
            (string=? m "auto") (suffix? m "-preview"))))

    (define (suffix? s suf)
      (let ((n (string-length s)) (m (string-length suf)))
        (and (>= n m) (string=? (substring s (- n m) n) suf))))

    (define (harness-budget h key)
      (let ((b (and h (form-ref h 'budgets))))
        ;; (budgets (tokens 60000) (turns 12)) — the entry is a list, so the
        ;; value is its cadr. `cdr` here returns (60000), which compares
        ;; unequal to every number and silently disables the budget.
        (and b (let ((e (assq key (cdr b))))
                 (and e (pair? (cdr e)) (cadr e))))))

    ;; Resolve the provider a role uses: the one it names, or the sole declared
    ;; provider when it names none. With several declared and none named there
    ;; is nothing to guess at, so it is an error rather than a coin toss.
    (define (resolve-provider config h role)
      (let ((named (harness-provider h))
            (all   (config-provider-names config)))
        (cond (named
               (if (config-provider config named)
                   named
                   (fail "harness for " (symbol->string role) " names provider `"
                         (symbol->string named) "`, which config.scm does not declare")))
              ((= (length all) 1) (car all))
              ((null? all) (fail "no providers declared in config.scm"))
              (else (fail "harness for " (symbol->string role)
                          " must name a provider: config.scm declares "
                          (number->string (length all)) " of them")))))

    ;; Checks that can only be made across roles.
    (define (validate-harnesses config dir)
      (let* ((code   (read-harness dir 'code))
             (review (read-harness dir 'review))
             (cm (and review (harness-model review)))
             (km (and code (harness-model code)))
             (cp (and review (resolve-provider config review 'review)))
             (kp (and code (resolve-provider config code 'code))))
        ;; The reviewer must not be the implementer. Not because mesthiri could
        ;; approve its own work — it cannot, findings are comments and no App
        ;; merges — but because a reviewer sharing the implementer's blind
        ;; spots is exactly what adversarial verification is meant to catch.
        (if (and cm km cp kp (eq? cp kp) (string=? cm km))
            (fail "the review harness uses the same provider and model as the "
                  "code harness (" (symbol->string cp) "/" cm
                  "); review must differ, or it shares the blind spots it "
                  "exists to catch"))
        #t))

    ;; Render pi's `models.json`, which is how a provider's base URL and key
    ;; reach it. pi reads `$VAR` in `apiKey` from the environment, so the key
    ;; itself never passes through mesthiri.
    (define (render-models-json config roles-and-models)
      (let ((out (open-output-string)))
        (write-string "{\n  \"providers\": {" out)
        (let loop ((ps (config-provider-names config)) (first #t))
          (if (null? ps)
              (begin (write-string "\n  }\n}\n" out) (get-output-string out))
              (let* ((name (car ps))
                     (p (config-provider config name))
                     (models (models-for name roles-and-models)))
                (if (not first) (write-string "," out))
                (write-string "\n    \"" out)
                (write-string (symbol->string name) out)
                (write-string "\": {\n      \"baseUrl\": \"" out)
                ;; pi appends "/chat/completions", so a trailing slash in the
                ;; config becomes a double slash in the request path. Some
                ;; gateways 404 on that and some do not, which is the worst
                ;; kind of difference — so the config may end either way and
                ;; this decides.
                (write-string (strip-trailing-slash (provider-endpoint p)) out)
                (write-string "\",\n      \"apiKey\": \"$" out)
                (write-string (symbol->string (provider-key-env p)) out)
                (write-string "\",\n      \"api\": \"" out)
                (write-string (or (provider-api p) "openai-completions") out)
                (write-string "\",\n      \"models\": [" out)
                (let mloop ((m models) (mfirst #t))
                  (if (null? m)
                      (write-string "]\n    }" out)
                      (begin
                        (if (not mfirst) (write-string ", " out))
                        (write-string "{\"id\": \"" out)
                        (write-string (car m) out)
                        (write-string "\"}" out)
                        (mloop (cdr m) #f))))
                (loop (cdr ps) #f))))))

    (define (strip-trailing-slash s)
      (let loop ((n (string-length s)))
        (if (and (> n 1) (char=? (string-ref s (- n 1)) #\/))
            (loop (- n 1))
            (substring s 0 n))))

    (define (models-for provider roles-and-models)
      (let loop ((r roles-and-models) (acc '()))
        (cond ((null? r) (reverse acc))
              ((and (eq? (caar r) provider)
                    (not (member (cdar r) acc)))
               (loop (cdr r) (cons (cdar r) acc)))
              (else (loop (cdr r) acc)))))))
