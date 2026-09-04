;;; The shim template is a security control, so it is tested like one.
;;;
;;; These assertions are about a YAML file rather than Scheme code, which is
;;; unusual — but the failure they prevent is the worst one mesthiri has: a
;;; checkout added to a `pull_request_target` workflow hands the repository's
;;; secrets to anyone who can open a pull request. Review catches that on a
;;; good day. A test catches it every day.

(import (scheme base) (scheme write) (scheme file) (scheme char))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "shim template\n")

(define (read-file path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((c (read-char p)))
          (if (eof-object? c)
              (list->string (reverse acc))
              (loop (cons c acc))))))))

(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(define shim (read-file "templates/mesthiri.yml"))

;; The control itself.
(check "the shim contains NO checkout step at all" #f (contains? shim "actions/checkout"))
(check "pull-request events use pull_request_target" #t (contains? shim "pull_request_target:"))
;; A bare `pull_request:` trigger would run the PR's own copy of this file.
;; Checked as a whole trigger key so `pull_request_target:` does not match it.
(check "there is no bare pull_request trigger" #f (contains? shim "\n  pull_request:"))
(check "no `ref:` is ever supplied" #f (contains? shim "ref:"))

;; A comment mesthiri wrote must not start a run at all.
(check "the job is skipped for mesthiri's own comments"
       #t (contains? shim "!contains(github.event.comment.body, '<!-- mesthiri:')"))

;; The shape the design depends on.
(check "it calls the reusable workflow" #t (contains? shim "uses: mesthiri/mesthiri/.github/workflows/reusable-dispatch.yml"))
(check "one hourly schedule tick, not per-stage crons" #t (contains? shim "cron: '7 * * * *'"))
(check "issue_comment is subscribed, or commands cannot arrive"
       #t (contains? shim "issue_comment:"))
(check "labeled is subscribed, or label triggers cannot arrive"
       #t (contains? shim "labeled"))
(check "a concurrency group collapses rapid edits" #t (contains? shim "concurrency:"))

(display "reusable workflow\n")
(define reuse (read-file ".github/workflows/reusable-dispatch.yml"))
(check "the binary's checksum is verified" #t (contains? reuse "sha256sum -c"))
;; Verify before chmod +x: a binary that fails its checksum must never have
;; been made executable.
(check "verification comes before chmod"
       #t (let loop ((i 0) (seen-verify #f))
            (cond ((> (+ i 14) (string-length reuse)) #f)
                  ((and (not seen-verify)
                        (string=? (substring reuse i (+ i 14)) "sha256sum -c e"))
                   (loop (+ i 1) #t))
                  ((and seen-verify
                        (string=? (substring reuse i (+ i 8)) "chmod +x"))
                   #t)
                  (else (loop (+ i 1) seen-verify)))))
(check "the checkout does not persist credentials"
       #t (contains? reuse "persist-credentials: false"))
(check "the job asks only for contents: read" #t (contains? reuse "contents: read"))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
