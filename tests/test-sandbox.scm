(import (scheme base) (scheme file) (mesthiri proc) (scheme write) (mesthiri sandbox) (mesthiri config))

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


;; --- the boundary, asserted rather than described ---------------------------
;;
;; A sandbox nobody has tested is a paragraph. These run only where a
;; namespace can actually be created, and they say so loudly when they cannot
;; — because "installed" and "works" came apart once already: Ubuntu 24.04
;; ships kernel.apparmor_restrict_unprivileged_userns=1, under which bwrap is
;; present, executable, and fails at `setting up uid map: Permission denied`.
(define wd "/tmp/mesthiri-sandbox-test/work")
(define scratch "/tmp/mesthiri-sandbox-test/scratch")
(define outside "/tmp/mesthiri-sandbox-test/outside.txt")

;; True when the command could NOT do the thing — which is the passing case.
(define (blocked? argv)
  (let ((wrapped (sandbox-wrap argv wd (string-append wd "/secrets"))))
    (and wrapped (guard (e (#t #t)) (proc-run wrapped) #f))))

(cond
 ((not (sandbox-available?))
  (display "\n  SKIPPED the containment assertions: ")
  (display (sandbox-unavailable-reason)) (newline)
  (display "  On Linux, install bubblewrap and permit unprivileged user\n")
  (display "  namespaces. Nothing below ran.\n\n"))
 (else
  (proc-run (list "mkdir" "-p" (string-append wd "/secrets")))
  (proc-run (list "mkdir" "-p" scratch))
  (call-with-output-file outside (lambda (p) (display "a job secret" p)))

  ;; The baseline matters as much as the assertions: without it a wrap that
  ;; fails for an unrelated reason reads as perfect containment.
  (check "the sandbox can run anything at all"
         #f (blocked? (list "/bin/true")))
  (check "and the workdir is writable inside it"
         #f (blocked? (list "/usr/bin/touch" (string-append wd "/written"))))

  ;; What it is for.
  (check "a file outside the workdir cannot be written"
         #t (blocked? (list "/usr/bin/touch" "/tmp/mesthiri-sandbox-test/nope")))

  ;; The agent needs a writable HOME that is NOT the clone: pi keeps state
  ;; there, and anything in the clone ends up in a pull request. Two writable
  ;; mounts, for two purposes. Without the second, pi refuses at startup with
  ;; "EROFS: read-only file system, open '…/.pi/agent/auth.json'".
  (check "the scratch is writable when it is bound"
         #f (let ((wrapped (sandbox-wrap (list "/usr/bin/touch"
                                               (string-append scratch "/w"))
                                         wd (string-append wd "/secrets")
                                         scratch)))
              (and wrapped (guard (e (#t #t)) (proc-run wrapped) #f))))
  (check "and not writable when it is not"
         #t (let ((wrapped (sandbox-wrap (list "/usr/bin/touch"
                                               (string-append scratch "/x"))
                                         wd (string-append wd "/secrets"))))
              (and wrapped (guard (e (#t #t)) (proc-run wrapped) #f))))
  (check "the secrets directory is empty inside, whatever is in it outside"
         #t (blocked? (list "/bin/cat" (string-append wd "/secrets/key.pem"))))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
