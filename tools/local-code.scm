;;; Run the code stage on this machine, and stop before anything is pushed.
;;;
;;; The CI path clones, runs the agent, checks the diff against `deny-paths`,
;;; and only then pushes and opens a pull request. This does everything up to
;;; the check and prints the diff instead of pushing — so the first time the
;;; code stage meets a real model, the output is a patch on this laptop rather
;;; than a branch in someone's repository.
;;;
;;;   kaappi --lib-path ./lib --lib-path ../kaappi-json/lib \
;;;          tools/local-code.scm <clone-dir> <issue#> [model]
;;;
;;; Reads MESTHIRI_MODEL_KEY, or MESTHIRI_STUB_PORT for a run with no model.

(import (scheme base) (scheme write) (scheme file) (scheme read)
        (scheme process-context)
        (mesthiri config) (mesthiri harness) (mesthiri agent) (mesthiri code)
        (mesthiri sandbox) (mesthiri proc) (mesthiri log))

(define (env k) (get-environment-variable k))
(define (die . p) (for-each (lambda (x) (display x (current-error-port))) p)
                  (newline (current-error-port)) (exit 1))

(define args (let ((cl (command-line))) (if (null? cl) '() (cdr cl))))
(define clone  (if (pair? args) (car args) (die "usage: local-code <clone> <issue#> [model]")))
(define number (if (> (length args) 1) (cadr args) (die "usage: local-code <clone> <issue#> [model]")))

(define cfg (read-config (string-append clone "/.mesthiri/config.scm")))
;; The sandbox has no code harness yet. Rather than inventing one silently,
;; fall back to triage's provider and say so — a harness is a policy choice.
(define hn (or (read-harness (string-append clone "/.mesthiri") 'code)
               (begin (display ";; no code harness; using triage's provider\n")
                      (read-harness (string-append clone "/.mesthiri") 'triage))))
(define pname (or (harness-provider hn) (car (config-provider-names cfg))))
(define model (if (> (length args) 2) (caddr args) (harness-model hn)))
(define provider (config-provider cfg pname))

(define (issue-field n f)
  (proc-run/string (list "gh" "issue" "view" n "--repo" "mesthiri/sandbox"
                         "--json" f "--jq" (string-append "." f))))
(define title (issue-field number "title"))
(define body  (issue-field number "body"))

;; Beside the clone, never inside it: the clone is what the code stage
;; commits with `git add -A`, and a run once left pi's home and a stderr
;; log in a repository that way.
(define scratch (string-append clone "-scratch"))
(define home (string-append scratch "/home"))
(define stub (env "MESTHIRI_STUB_PORT"))
(define _ (write-agent-home!
           home
           (if stub
               (string-append "{\"providers\":{\"stub\":{\"baseUrl\":\"http://127.0.0.1:"
                              stub "\",\"apiKey\":\"$STUB_API_KEY\",\"api\":"
                              "\"openai-completions\",\"models\":[{\"id\":\"stub-1\"}]}}}\n")
               (render-models-json cfg (list (cons pname model))))))

(define argv (agent-argv hn (if stub 'stub pname) (if stub "stub-1" model)))
(define wrapped (or (sandbox-wrap argv clone (string-append clone "/secrets") scratch) argv))
(log-context! "local-code" "mesthiri/sandbox" "-")
(if (not (sandbox-available?)) (log-warn "UNCONTAINED: " (sandbox-unavailable-reason)))

(define secret (or (env "MESTHIRI_MODEL_KEY") (and stub "x")
                   (die "set MESTHIRI_MODEL_KEY or MESTHIRI_STUB_PORT")))
(define e (agent-env provider secret home))

(display "provider ") (display (if stub 'stub pname))
(display "  model ") (display (if stub "stub-1" model))
(display "  contained ") (display (if (sandbox-available?) "yes" "NO"))
(newline) (newline)

(define rec (run-agent wrapped
                       (code-prompt title body (config-test-command cfg))
                       1800
                       (list (cons 'tokens (harness-budget hn 'tokens))
                             (cons 'turns  (harness-budget hn 'turns)))
                       (string-append scratch "/trace.jsonl")
                       e
                       (string-append scratch "/agent-stderr.log")
                       clone))

(display "outcome  ") (display (run-record-outcome rec))
(display "\nturns    ") (display (run-record-turns rec))
(display "\ntokens   ") (display (run-record-tokens rec))
(newline) (newline)

(if (eq? (run-record-outcome rec) 'settled)
    (begin
      (display "--- the agent's report ---\n")
      (write (agent-json rec)) (newline) (newline)))

;; What the job does next, minus the push.
(display "--- files changed ---\n")
(define changed
  (let ((out (proc-run/string (list "git" "-C" clone "diff" "--name-only"))))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((>= i (string-length out))
             (reverse (if (> i start) (cons (substring out start i) acc) acc)))
            ((char=? (string-ref out i) #\newline)
             (loop (+ i 1) (+ i 1)
                   (if (> i start) (cons (substring out start i) acc) acc)))
            (else (loop (+ i 1) start acc))))))
(for-each (lambda (f) (display "  ") (display f) (newline)) changed)
(if (null? changed) (display "  (none)\n"))

(display "\n--- deny-paths check ---\n")
;; check-diff returns #t, or the refusal text a maintainer would be shown.
(let ((r (check-diff changed (config-deny-paths cfg))))
  (display (if (eq? r #t) "allowed\n" r)) (newline))
(display "\n--- diff ---\n")
(display (proc-run/string (list "git" "-C" clone "diff")))
