;;; mesthiri — entry point
;;;
;;; This is the only place that imports `kaappi-http`. Everything else takes a
;;; transport, so the rest of the codebase loads and tests without the C-FFI
;;; shared object built and installed.

(import (scheme base) (scheme write) (scheme read) (scheme time)
        (scheme process-context) (scheme file)
        (kaappi http) (kaappi json)
        (mesthiri config) (mesthiri jwt) (mesthiri forge) (mesthiri event)
        (mesthiri command) (mesthiri dispatch) (mesthiri log) (mesthiri proc)
        (mesthiri version) (mesthiri agent) (mesthiri sandbox)
        (mesthiri harness) (mesthiri triage) (mesthiri labels)
        (mesthiri sweep) (mesthiri prioritize))

;; Adapt kaappi-http's response record to the transport contract forge wants.
(define (http-transport method url headers body)
  (let ((r (http-request method url headers body)))
    (values (response-status r) (response-headers r) (response-body r))))

(define (die . parts)
  (apply log-error parts)
  (exit 1))

(define (arg-after args flag)
  (let loop ((a args))
    (cond ((or (null? a) (null? (cdr a))) #f)
          ((string=? (car a) flag) (cadr a))
          (else (loop (cdr a))))))

;; --- whoami --------------------------------------------------------------
;;
;; Mints a real installation token and reports what it is. This exercises the
;; whole of M1 in one command — config for the App id and key path, jwt for
;; the RS256 signature through openssl, forge for auth, pagination and
;; rate-limit headers — and it is the first thing to run after registering an
;; App, because a mismatched id and key is the likeliest setup mistake.
(define (cmd-whoami args)
  (let* ((role     (string->symbol (or (arg-after args "--app") "reader")))
         (key-path (or (arg-after args "--key")
                       (get-environment-variable "MESTHIRI_KEY_FILE")))
         (cfg-path (or (arg-after args "--config") ".mesthiri/config.scm")))
    (if (not key-path)
        (die "no private key: pass --key <path> or set MESTHIRI_KEY_FILE"))
    (if (not (file-exists? key-path))
        (die "no such key file: " key-path))
    (let* ((cfg    (read-config cfg-path))
           (app-id (config-app cfg role)))
      (if (not app-id)
          (die "config has no App id for role `" role
               "` — expected (apps (reader <id>) (writer <id>))"))
      (log-context! "whoami" "-" "-")
      (let ((f (make-forge http-transport)))
        ;; 1. authenticate as the App itself
        (forge-auth! f (bearer (make-app-jwt (number->string app-id) key-path)))
        (let ((installs (forge-get-all f "/app/installations")))
          (if (null? installs)
              (die "App " (number->string app-id)
                   " is registered but installed on nothing"))
          (for-each
           (lambda (inst)
             (let ((id      (cdr (assoc "id" inst)))
                   (account (cdr (assoc "login" (cdr (assoc "account" inst))))))
               (display "installation ") (display id)
               (display "  account ") (display account) (newline)
               ;; 2. exchange for an installation token
               (let* ((tok-resp (forge-post
                                 f (string-append "/app/installations/"
                                                  (number->string id)
                                                  "/access_tokens")
                                 "{}"))
                      (token (cdr (assoc "token" tok-resp)))
                      (perms (cdr (assoc "permissions" tok-resp))))
                 (display "  permissions:") (newline)
                 (for-each (lambda (p)
                             (display "    ") (display (car p))
                             (display ": ") (display (cdr p)) (newline))
                           perms)
                 ;; 3. use it, and report the budget it reports back
                 (let ((g (make-forge http-transport)))
                   (forge-auth! g (bearer token))
                   (forge-get g "/rate_limit")
                   (display "  rate limit remaining: ")
                   (display (forge-rate-limit-remaining g)) (newline)))))
           installs))))))

;; --- the CI environment --------------------------------------------------

(define (env name) (get-environment-variable name))

;; The schedule tick, as "<weekday> <HH>:00" in UTC.
;;
;; Computed from epoch seconds rather than read from a date library, because
;; the shape mesthiri needs is small and the arithmetic is exact: epoch day 0
;; was a Thursday, so (days + 4) mod 7 gives Sunday = 0.
(define weekday-names
  '#("sunday" "monday" "tuesday" "wednesday" "thursday" "friday" "saturday"))

(define (utc-tick . opts)
  (let* ((secs (if (pair? opts) (car opts) (exact (floor (current-second)))))
         (days (quotient secs 86400))
         (hour (quotient (modulo secs 86400) 3600))
         (dow  (modulo (+ days 4) 7)))
    (string-append (vector-ref weekday-names dow)
                   " "
                   (if (< hour 10) "0" "")
                   (number->string hour)
                   ":00")))

(define (read-json-file path)
  (call-with-input-file path json-read))

;; The App private key arrives as a secret in the environment and `openssl`
;; needs a path, so it lands on disk for exactly as long as it takes to sign.
;; 0600 before the content is written, in the runner's temp directory, outside
;; anything the agent will later be able to see.
(define (with-key-file pem proc)
  (let ((path (string-append (or (env "RUNNER_TEMP") "/tmp")
                             "/mesthiri-key-"
                             (number->string (exact (floor (current-second))))
                             ".pem")))
    (call-with-output-file path (lambda (p) (write-string pem p)))
    (proc-run (list "chmod" "600" path))
    (let ((result (proc path)))
      (proc-run (list "rm" "-f" path))
      result)))

(define (authed-forge role)
  (let* ((cfg-path (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))
         (cfg      (read-config cfg-path))
         (app-id   (config-app cfg role))
         (pem      (env (if (eq? role 'writer) "MESTHIRI_WRITER_KEY" "MESTHIRI_READER_KEY"))))
    (if (not app-id) (die "config has no App id for role " role))
    (if (not pem) (die "no key in the environment for role " role))
    (let* ((jwt (with-key-file pem (lambda (path)
                                     (make-app-jwt (number->string app-id) path))))
           (f   (make-forge http-transport)))
      (forge-auth! f (bearer jwt))
      ;; Exchange the App JWT for an installation token scoped to this repo.
      (let* ((repo (or (env "MESTHIRI_REPO") (die "MESTHIRI_REPO is not set")))
             (inst (forge-get f (string-append "/repos/" repo "/installation")))
             (id   (cdr (assoc "id" inst)))
             (tok  (cdr (assoc "token"
                               (forge-post f (string-append "/app/installations/"
                                                            (number->string id)
                                                            "/access_tokens")
                                           "{}")))))
        ;; Actions masks secrets it already knows about; a token minted at
        ;; runtime is not one, and on a public repository the log is public.
        (display (string-append "::add-mask::" tok)) (newline)
        (let ((g (make-forge http-transport)))
          (forge-auth! g (bearer tok))
          (values g cfg))))))

;; --- idempotency ---------------------------------------------------------
;;
;; With no database, "have I already acted on this?" is a question for the
;; forge: mesthiri leaves an HTML marker in every comment it posts, and finds
;; it again by looking.
;; The marker itself lives in (mesthiri event), because dispatch needs it too
;; — it is how a comment mesthiri wrote is recognised and skipped rather than
;; dispatched. Two definitions would drift and the symptom would be a run per
;; comment coming back.
(define (marker event) (event-marker event))

(define (contains? s sub)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length sub)))
         (let loop ((i 0))
           (cond ((> (+ i m) n) #f)
                 ((string=? (substring s i (+ i m)) sub) #t)
                 (else (loop (+ i 1))))))))

(define (make-already-handled? forge)
  (lambda (event stage)
    (and (event-number event)
         (guard (e ((forge-error? e) #f))
           (let ((comments (forge-get-all
                            forge (string-append "/repos/" (event-repo event)
                                                 "/issues/"
                                                 (number->string (event-number event))
                                                 "/comments"))))
             (let loop ((c comments))
               (cond ((null? c) #f)
                     ((contains? (let ((b (assoc "body" (car c)))) (and b (cdr b)))
                                 (marker event)) #t)
                     (else (loop (cdr c))))))))))

(define (post-comment forge event text)
  (forge-post forge
              (string-append "/repos/" (event-repo event) "/issues/"
                             (number->string (event-number event)) "/comments")
              (json-write-string (list (cons "body" (string-append text "\n\n" (marker event)))))))

;; --- dispatch ------------------------------------------------------------

(define (load-event)
  (let ((name (or (env "MESTHIRI_EVENT_NAME") (die "MESTHIRI_EVENT_NAME is not set")))
        (path (or (env "MESTHIRI_EVENT_PATH") (die "MESTHIRI_EVENT_PATH is not set"))))
    (if (not (file-exists? path)) (die "no event payload at " path))
    (normalize-event name (read-json-file path) (utc-tick))))

;; M2 has no stages. This placeholder proves the whole path — parse,
;; authorize, mode, idempotency, handler — and is replaced by the real triage
;; stage in M4. It is not a separate demo command precisely so that the demo
;; exercises the shipped path rather than a bypass of it.
;; The triage stage, replacing M2's probe. The agent is spawned by agent.sld
;; and nothing else; this hands triage a runner rather than a process.
(define (fetch-rubric forge repo path)
  ;; The verdict records the rubric's commit SHA, so a rubric change upstream
  ;; reads as a behaviour change rather than a mystery.
  (guard (e ((forge-error? e) (values #f #f)))
    (let* ((r (forge-get forge (string-append "/repos/" repo "/contents/" path)))
           (sha (let ((x (assoc "sha" r))) (and x (cdr x))))
           (enc (let ((x (assoc "content" r))) (and x (cdr x)))))
      (values enc sha))))

(define (agent-runner harness provider-name model workdir trace)
  (lambda (prompt)
    (let* ((argv (agent-argv harness provider-name model workdir))
           (wrapped (or (sandbox-wrap argv workdir
                                      (string-append workdir "/secrets"))
                        argv)))
      (if (not (sandbox-available?))
          (log-warn "no namespace sandbox on this host: the agent is UNCONTAINED"))
      (let ((rec (run-agent wrapped prompt 1200
                            (list (cons 'tokens (harness-budget harness 'tokens))
                                  (cons 'turns  (harness-budget harness 'turns)))
                            trace)))
        (log-info "agent " (run-record-outcome rec)
                  " turns=" (run-record-turns rec)
                  " tokens=" (run-record-tokens rec)
                  " model=" (or (run-record-model rec) "-"))
        (if (not (eq? (run-record-outcome rec) 'settled))
            (die "agent run did not settle: " (run-record-outcome rec)))
        ;; The agent's reply is the last assistant message; parsed and then
        ;; validated by triage against its schema.
        (json-read-string (agent-final-text rec))))))

(define (prioritize-handler forge config event)
  (let* ((repo (event-repo event))
         (mode (stage-mode (config-stage config 'prioritize)))
         (promoted (prioritize! forge config repo mode)))
    (log-info "prioritize " mode ": " (length promoted) " issue(s) promoted")))

(define (triage-handler forge config event)
  (let* ((repo (event-repo event))
         (st (config-stage config 'triage))
         (mode (stage-mode st))
         (hn (read-harness ".mesthiri" 'triage))
         (pname (or (harness-provider hn) (car (config-provider-names config))))
         (model (harness-model hn))
         (workdir (or (env "RUNNER_TEMP") "/tmp"))
         (trace (string-append workdir "/mesthiri-trace-"
                               (number->string (event-id event)) ".jsonl")))
    (let-values (((rubric sha) (fetch-rubric forge repo (config-rubric config))))
      (let ((issue (forge-get forge (string-append "/repos/" repo "/issues/"
                                                   (number->string (event-number event))))))
        (triage-issue forge config repo issue rubric sha mode
                      (agent-runner hn pname model workdir trace))))))

(define (cmd-dispatch args)
  (let ((ev (load-event)))
    (log-context! "dispatch" (event-repo ev) (env "MESTHIRI_RUN_URL"))
    (let-values (((forge cfg) (authed-forge 'reader)))
      (let* ((handlers (list (cons 'triage triage-handler)
                             (cons 'prioritize prioritize-handler)))
             (d (dispatch forge cfg ev handlers (make-already-handled? forge))))
        (log-info "outcome=" (decision-outcome d)
                  " stage=" (or (decision-stage d) "-")
                  (if (decision-reason d) (string-append " reason=" (decision-reason d)) ""))
        ;; An unauthorized command gets an explanation, not silence. Only for
        ;; commands: nobody typed a label expecting a reply.
        (if (and (eq? (decision-outcome d) 'unauthorized) (decision-command d))
            (post-comment forge ev (string-append "Not run: " (decision-reason d) ".")))
        (if (eq? (decision-outcome d) 'stage-off)
            (if (decision-command d)
                (post-comment forge ev (string-append "Not run: " (decision-reason d) "."))))))))

(define (cmd-explain args)
  (let ((ev (load-event))
        (cfg (read-config (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))))
    (explain-event cfg ev)))

;; --- the model, called directly ------------------------------------------
;;
;; Used by `try` only. It calls a model over HTTP with no agent subprocess:
;; verifying an issue's claims needs tools against attacker-writable text,
;; which belongs in a sandbox on a runner rather than on someone's laptop.
;; So `try` answers the narrower question honestly — does this rubric produce
;; sane priorities — and says in its output that claims are unverified.
(define (model-call provider model prompt)
  (let* ((key (or (env (symbol->string (provider-key-env provider)))
                  (die "no key in the environment: "
                       (symbol->string (provider-key-env provider)))))
         (url (string-append (trim-slash (provider-endpoint provider))
                             "/chat/completions"))
         (body (json-write-string
                (list (cons "model" model)
                      (cons "messages"
                            (list (list (cons "role" "user")
                                        (cons "content" prompt))))))))
    (let-values (((status headers resp) (http-transport "POST" url
                    (list (cons "Content-Type" "application/json")
                          (cons "Authorization" (string-append "Bearer " key)))
                    body)))
      (if (>= status 400) (die "model call failed with " status ": " resp))
      (let* ((parsed (json-read-string resp))
             (choices (cdr (assoc "choices" parsed)))
             (msg (cdr (assoc "message" (car choices)))))
        (cdr (assoc "content" msg))))))

(define (trim-slash s)
  (let ((n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\/))
        (substring s 0 (- n 1)) s)))

;; --- try ------------------------------------------------------------------
(define (cmd-try args)
  (let* ((repo (if (pair? args) (car args) (die "usage: mesthiri try <owner/repo>")))
         (rubric-path (or (arg-after args "--rubric") ".mesthiri/rubric.md"))
         (cfg (read-config (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm")))
         (pat (or (env "GITHUB_TOKEN") (env "GH_TOKEN")
                  (die "set GITHUB_TOKEN: try reads issues with a personal token")))
         (hn (read-harness ".mesthiri" 'triage))
         (pname (or (harness-provider hn) (car (config-provider-names cfg))))
         (provider (config-provider cfg pname))
         (model (or (harness-model hn) (die "no model in the triage harness")))
         (f (make-forge http-transport)))
    (forge-auth! f (bearer pat))
    (display "mesthiri try — rubric only, nothing written, no checkout\n")
    (display "  provider ") (display pname)
    (display "  model ") (display model) (newline) (newline)
    (let* ((rubric (guard (e (#t "(no rubric found)"))
                     (call-with-input-file rubric-path
                       (lambda (p) (let loop ((acc ""))
                                     (let ((l (read-line p)))
                                       (if (eof-object? l) acc
                                           (loop (string-append acc l "\n")))))))))
           (issues (untriaged-issues f repo)))
      (for-each
       (lambda (i)
         (let* ((n (cdr (assoc "number" i)))
                (title (let ((t (assoc "title" i))) (and t (cdr t))))
                (body  (let ((b (assoc "body" i))) (and b (cdr b))))
                (out (model-call provider model
                                 (triage-prompt rubric title body))))
           (display "#") (display n) (display "  ") (display title) (newline)
           (display "      ") (display out) (newline)
           (display "      (claims NOT verified — try does not check out the code)")
           (newline) (newline)))
       issues)
      (display (number->string (length issues)))
      (display " issues read, 0 writes.\n"))))

;; --- agent-smoke ---------------------------------------------------------
;;
;; Runs a trivial task through the real agent path and prints the run record.
;; `--prove-sandbox` does something different and more useful: it asserts the
;; boundary rather than describing it. A sandbox nobody has tested is a
;; paragraph, not a control.

(define (probe-fails? argv workdir secrets)
  ;; True when the command could NOT do the thing — which is the passing case.
  (let ((wrapped (sandbox-wrap argv workdir secrets)))
    (and wrapped
         (guard (e (#t #t))
           (proc-run wrapped)
           #f))))

(define (cmd-agent-smoke args)
  (let* ((prove (and (pair? args) (string=? (car args) "--prove-sandbox")))
         (cfg-path (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))
         (cfg (read-config cfg-path))
         (workdir (or (env "RUNNER_TEMP") "/tmp"))
         (secrets (string-append workdir "/mesthiri-secrets")))
    (log-context! "agent-smoke" (or (env "MESTHIRI_REPO") "-") (env "MESTHIRI_RUN_URL"))

    (display "sandbox: ")
    (if (sandbox-available?)
        (display "available\n")
        (begin (display "UNAVAILABLE — ")
               (display (sandbox-unavailable-reason))
               (newline)
               ;; Loud, per design.md: a security fallback that fails silently
               ;; is worse than none.
               (log-warn "the agent would run UNCONTAINED on this host")))

    (display "egress allowlist (derived from provider endpoints):\n")
    (for-each (lambda (h) (display "  ") (display h) (newline))
              (allowed-hosts cfg '()))
    (display "  (note: the forge is deliberately absent)\n")

    (if prove
        (begin
          (display "\nproving the boundary\n")
          (if (not (sandbox-available?))
              (die "cannot prove a sandbox that is not available"))
          (let ((r1 (probe-fails? (list "cat" (string-append secrets "/key.pem"))
                                  workdir secrets))
                (r2 (probe-fails? (list "touch" "/etc/mesthiri-probe")
                                  workdir secrets)))
            (display "  cannot read the secrets directory: ")
            (display (if r1 "yes" "NO — BOUNDARY BROKEN")) (newline)
            (display "  cannot write outside the clone:     ")
            (display (if r2 "yes" "NO — BOUNDARY BROKEN")) (newline)
            (if (not (and r1 r2)) (die "sandbox boundary assertions failed"))
            (display "\nboundary holds.\n")))
        (display "\n(pass --prove-sandbox to assert the boundary)\n"))))

(define (usage)
  (display "mesthiri ") (display mesthiri-version)
  (display " — CI-native ADLC orchestrator\n\n")
  (display "  dispatch\n")
  (display "      Normalize the CI event, authorize it, match one stage, run it.\n")
  (display "      Reads MESTHIRI_EVENT_NAME, MESTHIRI_EVENT_PATH, MESTHIRI_REPO.\n\n")
  (display "  explain-event\n")
  (display "      Print the normalized event and how each stage trigger matched.\n")
  (display "      The first thing to run when a stage did nothing and said nothing.\n\n")
  (display "  try <owner/repo> [--rubric <path>]\n")
  (display "      Apply the rubric to open issues and print the result.\n")
  (display "      Writes nothing, clones nothing, and says so: it cannot\n")
  (display "      verify claims, which is what installed triage does.\n\n")
  (display "  agent-smoke [--prove-sandbox]\n")
  (display "      Report the sandbox and the derived egress allowlist.\n")
  (display "      --prove-sandbox asserts the boundary instead of describing it.\n\n")
  (display "  whoami [--app reader|writer] [--key <pem>] [--config <path>]\n")
  (display "      Mint an installation token and report the installation,\n")
  (display "      its permissions and the remaining rate limit.\n")
  (exit 1))

;; `command-line` differs between the two ways mesthiri runs. As a script,
;; `kaappi mesthiri.scm dispatch` gives ("mesthiri.scm" "dispatch"). Bundled
;; into a standalone binary it gives ("dispatch") — the program name is not
;; there at all, so a blind `cdr` drops the subcommand, and with no arguments
;; it crashes on the empty list. Both were live bugs until a release smoke
;; test ran the binary; every earlier check had run the script.
(define (invocation-args)
  (let ((cl (command-line)))
    (cond ((null? cl) '())
          ((script-path? (car cl)) (cdr cl))
          (else cl))))

(define (script-path? s)
  (let ((n (string-length s)))
    (and (> n 4) (string=? (substring s (- n 4) n) ".scm"))))

(let ((args (invocation-args)))
  (cond ((null? args) (usage))
        ((or (string=? (car args) "--version") (string=? (car args) "version"))
         (display mesthiri-version) (newline))
        ((string=? (car args) "whoami") (cmd-whoami (cdr args)))
        ((string=? (car args) "dispatch") (cmd-dispatch (cdr args)))
        ((string=? (car args) "explain-event") (cmd-explain (cdr args)))
        ((string=? (car args) "agent-smoke") (cmd-agent-smoke (cdr args)))
        ((string=? (car args) "try") (cmd-try (cdr args)))
        (else (usage))))
