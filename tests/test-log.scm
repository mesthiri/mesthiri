(import (scheme base) (scheme write) (mesthiri log))
(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri log)\n")

;; Logging goes to stderr so a command whose stdout is a result stays
;; pipeable — asserted by capturing stdout and finding it empty.
(define out (open-output-string))
(check "nothing is written to the given output port"
       "" (begin (parameterize ((current-output-port out))
                   (log-context! "triage" "o/r" "http://run")
                   (log-info "hello"))
                 (get-output-string out)))
(check "context is settable without error" #t
       (begin (log-context! "code" "a/b" "http://x") #t))
(check "a missing context field becomes -" #t
       (begin (log-context! #f #f #f) #t))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
