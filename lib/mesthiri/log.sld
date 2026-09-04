;;; (mesthiri log) — one line format, everywhere
;;;
;;; Every line carries the stage, the repository and the run URL, because the
;;; place these are read is a CI log where several stages may have written and
;;; nothing else says which one you are looking at.
;;;
;;; Nothing here ever logs a credential. An installation token is masked by
;;; the workflow via ::add-mask:: the moment it exists, but masking stops
;;; accidents rather than a deliberate `(log-info "token: " tok)` — so do not
;;; write that line.

(define-library (mesthiri log)
  (import (scheme base) (scheme write) (scheme process-context))
  (export log-context! log-info log-warn log-error log-line)
  (begin

    (define ctx-stage (list "-"))
    (define ctx-repo  (list "-"))
    (define ctx-run   (list "-"))

    (define (log-context! stage repo run-url)
      (set-car! ctx-stage (or stage "-"))
      (set-car! ctx-repo  (or repo "-"))
      (set-car! ctx-run   (or run-url "-")))

    (define (log-line level parts)
      ;; stderr, so that a command whose stdout is a result stays pipeable.
      (let ((p (current-error-port)))
        (display "[" p) (display level p)
        (display " " p) (display (car ctx-stage) p)
        (display " " p) (display (car ctx-repo) p)
        (display "] " p)
        (for-each (lambda (x) (display x p)) parts)
        (newline p)))

    (define (log-info  . parts) (log-line "info"  parts))
    (define (log-warn  . parts) (log-line "warn"  parts))
    (define (log-error . parts) (log-line "error" parts))))
