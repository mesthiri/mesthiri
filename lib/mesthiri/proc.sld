;;; (mesthiri proc) — the only wrapper over (kaappi process)
;;;
;;; Every subprocess mesthiri runs goes through here. Two rules the rest of
;;; the codebase depends on and cannot enforce for itself:
;;;
;;;   - argv only. There is no shell anywhere in mesthiri, because issue and
;;;     pull-request text reaches these calls and a shell would make that
;;;     text executable. `(kaappi process)` has no shell mode; do not add
;;;     one. The single exception is `agent.sld`'s FIXED `sh -c` script for
;;;     kaappi builds that cannot honour `directory:` — its text is a
;;;     constant and its variable parts are positional parameters, so no
;;;     word runs through the parser; see the comment there for why that
;;;     keeps this rule's substance.
;;;   - secrets are passed as file paths or on stdin, never as arguments.
;;;     Arguments are visible in the process table to anything else on the
;;;     machine.
;;;
;;; Spawning the coding agent is deliberately NOT here — that belongs to
;;; `(mesthiri agent)` alone, so a second backend is a new module rather than
;;; a change to stage code.

(define-library (mesthiri proc)
  (import (scheme base) (scheme write) (kaappi process))
  (export proc-run proc-run/string proc-error?
          proc-error-command proc-error-code proc-error-stderr)
  (begin

    ;; A failed subprocess carries what a human needs to see: what ran, how
    ;; it failed, and whatever it said on the way out.
    (define-record-type <proc-error>
      (make-proc-error command code stderr)
      proc-error?
      (command proc-error-command)
      (code    proc-error-code)
      (stderr  proc-error-stderr))

    ;; Run argv to completion, returning stdout as a bytevector.
    ;;
    ;; `input` is a string written to stdin, or #f for no stdin at all —
    ;; note `run-process` defaults stdin to 'null rather than inheriting,
    ;; so a child never blocks reading a terminal that is not there.
    ;;
    ;; Raises a <proc-error> on a non-zero exit rather than returning it: a
    ;; caller that forgets to check an exit code gets a crash, not a silent
    ;; empty result. Callers that expect failure catch it with guard.
    (define (proc-run argv . opts)
      (let ((input   (get-opt opts 'input: #f))
            (timeout (get-opt opts 'timeout: #f)))
        (let-values (((code out err)
                      (if input
                          (if timeout
                              (run-process argv 'input: input 'output: 'bytevector 'timeout: timeout)
                              (run-process argv 'input: input 'output: 'bytevector))
                          (if timeout
                              (run-process argv 'output: 'bytevector 'timeout: timeout)
                              (run-process argv 'output: 'bytevector)))))
          (if (= code 0)
              out
              (raise (make-proc-error argv code (utf8->string err)))))))

    ;; As `proc-run`, decoding stdout as UTF-8. Use `proc-run` for anything
    ;; binary — an RSA signature through `utf8->string` is silent corruption.
    (define (proc-run/string argv . opts)
      (utf8->string (apply proc-run argv opts)))

    ;; Tiny keyword-argument lookup over a flat (key: value ...) list, matching
    ;; the calling style `(kaappi process)` itself uses.
    (define (get-opt opts key default)
      (let loop ((o opts))
        (cond ((or (null? o) (null? (cdr o))) default)
              ((eq? (car o) key) (cadr o))
              (else (loop (cddr o))))))))
