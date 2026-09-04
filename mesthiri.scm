;;; mesthiri — entry point
;;;
;;; This is the only place that imports `kaappi-http`. Everything else takes a
;;; transport, so the rest of the codebase loads and tests without the C-FFI
;;; shared object built and installed.

(import (scheme base) (scheme write) (scheme process-context) (scheme file)
        (kaappi http) (kaappi json)
        (mesthiri config) (mesthiri jwt) (mesthiri forge)
        (mesthiri log) (mesthiri proc))

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

(define (usage)
  (display "mesthiri — CI-native ADLC orchestrator\n\n")
  (display "  whoami [--app reader|writer] [--key <pem>] [--config <path>]\n")
  (display "      Mint an installation token and report the installation,\n")
  (display "      its permissions and the remaining rate limit.\n")
  (exit 1))

(let ((args (cdr (command-line))))
  (cond ((null? args) (usage))
        ((string=? (car args) "whoami") (cmd-whoami (cdr args)))
        (else (usage))))
