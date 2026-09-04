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
        (mesthiri version))

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
(define (marker event) (string-append "<!-- mesthiri:" (number->string (event-id event)) " -->"))

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
(define (probe-handler forge config event)
  (post-comment forge event
                (string-append "mesthiri reached the triage stage for this event ("
                               (symbol->string (event-kind event))
                               "). No stage is implemented yet — this is the M2 "
                               "dispatch probe.")))

(define (cmd-dispatch args)
  (let ((ev (load-event)))
    (log-context! "dispatch" (event-repo ev) (env "MESTHIRI_RUN_URL"))
    (let-values (((forge cfg) (authed-forge 'reader)))
      (let* ((handlers (list (cons 'triage probe-handler)))
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

(define (usage)
  (display "mesthiri ") (display mesthiri-version)
  (display " — CI-native ADLC orchestrator\n\n")
  (display "  dispatch\n")
  (display "      Normalize the CI event, authorize it, match one stage, run it.\n")
  (display "      Reads MESTHIRI_EVENT_NAME, MESTHIRI_EVENT_PATH, MESTHIRI_REPO.\n\n")
  (display "  explain-event\n")
  (display "      Print the normalized event and how each stage trigger matched.\n")
  (display "      The first thing to run when a stage did nothing and said nothing.\n\n")
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
        (else (usage))))
