;;; Argument handling differs between running as a script and running as a
;;; bundled binary, and mesthiri must behave identically in both. This was a
;;; real defect: `(cdr (command-line))` worked as a script and, in a binary,
;;; both dropped the subcommand and crashed on no arguments.
(import (scheme base) (scheme write))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "argument handling\n")

;; Mirrors the entry point's logic; kept here so the rule is tested without
;; needing a built binary.
(define (script-path? s)
  (let ((n (string-length s)))
    (and (> n 4) (string=? (substring s (- n 4) n) ".scm"))))
(define (args-of cl)
  (cond ((null? cl) '())
        ((script-path? (car cl)) (cdr cl))
        (else cl)))

(check "script, no args"        '()            (args-of '("mesthiri.scm")))
(check "script, one arg"        '("dispatch")  (args-of '("mesthiri.scm" "dispatch")))
(check "script, path prefix"    '("whoami")    (args-of '("/a/b/mesthiri.scm" "whoami")))
;; The binary case: no program name at all.
(check "binary, no args"        '()            (args-of '()))
(check "binary, one arg"        '("dispatch")  (args-of '("dispatch")))
(check "binary, flag"           '("--version") (args-of '("--version")))
(check "binary, several"        '("whoami" "--app" "reader")
       (args-of '("whoami" "--app" "reader")))
;; An empty list must not crash, which is what the original cdr did.
(check "empty list is safe"     '()            (args-of '()))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
