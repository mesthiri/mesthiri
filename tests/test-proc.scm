(import (scheme base) (scheme write) (mesthiri proc))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri proc)\n")

(check "captures stdout" "hello\n" (proc-run/string '("echo" "hello")))
(check "writes stdin" "hi" (proc-run/string '("cat") 'input: "hi"))
(check "binary stdout stays a bytevector"
       #t (bytevector? (proc-run '("printf" "\\001\\002\\377"))))

;; A non-zero exit must raise rather than return an empty result.
(check "non-zero exit raises"
       #t (guard (e ((proc-error? e) #t)) (proc-run '("false")) #f))
(check "the error carries the exit code"
       1 (guard (e ((proc-error? e) (proc-error-code e))) (proc-run '("false")) 'no-raise))
(check "the error carries the command"
       '("false") (guard (e ((proc-error? e) (proc-error-command e))) (proc-run '("false")) 'no-raise))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
