;;; Run the triage stage on this machine, against a real clone.
;;;
;;; The CI path needs two App private keys to mint an installation token, and
;;; those are repository secrets — so this skips the forge entirely: it takes
;;; the issue as arguments and prints the verdict instead of commenting. What
;;; it does exercise is everything that actually costs a release to test: the
;;; prompt, the agent spawn, the sandbox, the drive loop, the budgets, and the
;;; model.
;;;
;;;   kaappi --lib-path ./lib --lib-path ../kaappi-json/lib \
;;;          tools/local-triage.scm <clone-dir> <issue-number>
;;;
;;; Reads MESTHIRI_MODEL_KEY. Without it, set MESTHIRI_STUB_PORT to a
;;; tests/support/stub-model.py and the whole path runs with no model at all.

(import (scheme base) (scheme write) (scheme file) (scheme read)
        (scheme process-context)
        (mesthiri config) (mesthiri harness) (mesthiri agent) (mesthiri triage)
        (mesthiri sandbox) (mesthiri proc) (mesthiri log))

(define (env k) (get-environment-variable k))
(define (die . parts)
  (for-each (lambda (p) (display p (current-error-port))) parts)
  (newline (current-error-port))
  (exit 1))

(define args (let ((cl (command-line))) (if (null? cl) '() (cdr cl))))
(define clone (if (pair? args) (car args) (die "usage: local-triage <clone-dir> <issue#>")))
(define number (if (and (pair? args) (pair? (cdr args))) (cadr args)
                   (die "usage: local-triage <clone-dir> <issue#>")))

(define cfg (read-config (string-append clone "/.mesthiri/config.scm")))
(define hn  (read-harness (string-append clone "/.mesthiri") 'triage))
(define pname (or (harness-provider hn) (car (config-provider-names cfg))))
(define model (or (harness-model hn) (die "no model in the triage harness")))
(define provider (config-provider cfg pname))

(define (slurp path)
  (call-with-input-file path
    (lambda (p) (let loop ((acc ""))
                  (let ((c (read-char p)))
                    (if (eof-object? c) acc (loop (string-append acc (string c)))))))))

;; `gh` rather than the forge module: this deliberately has no credential of
;; mesthiri's, and reading a public issue needs none of mesthiri's machinery.
(define (issue-field n field)
  (proc-run/string (list "gh" "issue" "view" n "--repo" "mesthiri/sandbox"
                         "--json" field "--jq" (string-append "." field))))

(define rubric (slurp (string-append clone "/.mesthiri/rubric.md")))
(define title (issue-field number "title"))
(define body  (issue-field number "body"))

(define home (string-append clone "/.agent-home"))
(define stub (env "MESTHIRI_STUB_PORT"))

(define agent-home
 (write-agent-home!
 home
 (if stub
     (string-append
      "{\"providers\":{\"stub\":{\"baseUrl\":\"http://127.0.0.1:" stub
      "\",\"apiKey\":\"$STUB_API_KEY\",\"api\":\"openai-completions\","
      "\"models\":[{\"id\":\"stub-1\",\"name\":\"S\",\"reasoning\":false,"
      "\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,"
      "\"cacheWrite\":0},\"contextWindow\":32000,\"maxTokens\":4096}]}}}\n")
     (render-models-json cfg (list (cons pname model))))))

(define argv (agent-argv hn (if stub 'stub pname) (if stub "stub-1" model) clone))
(define wrapped (or (sandbox-wrap argv clone (string-append clone "/secrets")) argv))
(log-context! "local-triage" "mesthiri/sandbox" "-")
(if (not (sandbox-available?))
    (log-warn "UNCONTAINED: " (sandbox-unavailable-reason)))

(define secret (or (env "MESTHIRI_MODEL_KEY") (and stub "x")
                   (die "set MESTHIRI_MODEL_KEY, or MESTHIRI_STUB_PORT to run"
                        " the whole path with no model")))
(define e (agent-env provider secret home))
(define env* (if stub (cons (cons "STUB_API_KEY" secret) e) e))

(display "provider ") (display (if stub 'stub pname))
(display "  model ") (display (if stub "stub-1" model))
(display "  contained ") (display (if (sandbox-available?) "yes" "NO"))
(newline) (newline)

(define rec (run-agent wrapped (triage-prompt rubric title body)
                       900
                       (list (cons 'tokens (harness-budget hn 'tokens))
                             (cons 'turns  (harness-budget hn 'turns)))
                       (string-append clone "/trace.jsonl")
                       env*
                       (string-append clone "/agent-stderr.log")))

(display "outcome  ") (display (run-record-outcome rec))
(display "\nturns    ") (display (run-record-turns rec))
(display "\ntokens   ") (display (run-record-tokens rec))
(display "\nmodel    ") (display (or (run-record-model rec) "-"))
(display "\n\n") (display (or (run-record-text rec) "(no text)")) (newline)
(display "\ntrace: ") (display clone) (display "/trace.jsonl\n")
