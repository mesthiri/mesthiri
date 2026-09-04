(import (scheme base) (scheme write) (mesthiri sandbox) (mesthiri config))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri sandbox)\n")

;; --- the allowlist is derived, never written ----------------------------
(check "host from an https endpoint" "api.deepseek.com"
       (endpoint-host "https://api.deepseek.com"))
(check "path is stripped" "api.z.ai"
       (endpoint-host "https://api.z.ai/api/paas/v4/"))
(check "port is stripped" "localhost"
       (endpoint-host "http://localhost:8080/v1"))
(check "a bare host is left alone" "example.org" (endpoint-host "example.org"))

(define cfg
  (parse-config
   '(mesthiri (version 1)
      (providers
        (deepseek (endpoint "https://api.deepseek.com") (key-env DEEPSEEK_API_KEY))
        (zai (endpoint "https://api.z.ai/api/paas/v4/") (key-env GLM_API_KEY))))
   "test"))

(check "every provider's host is allowed"
       '("api.deepseek.com" "api.z.ai") (allowed-hosts cfg '()))
(check "extras are appended, not substituted"
       '("api.deepseek.com" "api.z.ai" "registry.npmjs.org")
       (allowed-hosts cfg '("registry.npmjs.org")))

;; The forge must never be on the list. The agent writes commits; the job
;; pushes. If GitHub appears here, the credential boundary has a hole.
(check "the forge is NOT allowed"
       #f (and (member "api.github.com" (allowed-hosts cfg '())) #t))

;; --- wrapping ------------------------------------------------------------
;; The wrap is only offered where it can actually contain something; a caller
;; that gets #f must decide, not silently run unconfined.
(check "unavailable sandbox yields #f rather than a bare command"
       #t (let ((w (sandbox-wrap '("pi") "/w" "/s")))
            (if (sandbox-available?) (pair? w) (not w))))

(check "when available, the inner command is wrapped not replaced"
       #t (let ((w (sandbox-wrap '("pi" "--mode" "rpc") "/w" "/s")))
            (if w
                (and (string=? (car w) "/usr/bin/bwrap")
                     (member "--ro-bind" w)
                     (member "pi" w)
                     #t)
                #t)))

(check "an unavailable sandbox says why"
       #t (if (sandbox-available?)
              (not (sandbox-unavailable-reason))
              (string? (sandbox-unavailable-reason))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
