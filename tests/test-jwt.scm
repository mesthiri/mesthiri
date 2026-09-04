(import (scheme base) (scheme write) (scheme file) (mesthiri jwt) (mesthiri proc))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri jwt)\n")

;; base64url, against RFC 4648 §5 vectors, minus padding as JWT requires.
(check "b64url empty"  ""       (base64url-encode (string->utf8 "")))
(check "b64url 1 byte" "Zg"     (base64url-encode (string->utf8 "f")))
(check "b64url 2 bytes" "Zm8"   (base64url-encode (string->utf8 "fo")))
(check "b64url 3 bytes" "Zm9v"  (base64url-encode (string->utf8 "foo")))
(check "b64url 4 bytes" "Zm9vYg" (base64url-encode (string->utf8 "foob")))
(check "b64url 6 bytes" "Zm9vYmFy" (base64url-encode (string->utf8 "foobar")))
;; The url-safe alphabet is the whole point: these bytes are + and / in
;; standard base64 and would be rejected inside a JWT.
;; Value cross-checked against Python's base64.urlsafe_b64encode. These
;; bytes are `+` and `/` in standard base64 — the two characters a JWT
;; cannot carry — so this is the case that catches a plain-base64 encoder.
(check "b64url uses - and _ not + and /"
       "-_-_7w" (base64url-encode (bytevector #xfb #xff #xbf #xef)))

;; A real JWT, signed with the fixture key.
(define jwt (make-app-jwt "123456" "tests/fixtures/test-key.pem" 1756900000))

(check "three dot-separated segments"
       3 (let loop ((i 0) (n 1))
           (cond ((>= i (string-length jwt)) n)
                 ((char=? (string-ref jwt i) #\.) (loop (+ i 1) (+ n 1)))
                 (else (loop (+ i 1) n)))))
(check "header is the RS256 header"
       "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
       (let loop ((i 0)) (if (char=? (string-ref jwt i) #\.)
                             (substring jwt 0 i) (loop (+ i 1)))))
(check "deterministic for a fixed clock"
       jwt (make-app-jwt "123456" "tests/fixtures/test-key.pem" 1756900000))

;; The signature must satisfy openssl, not merely look like base64. Without
;; this the test would pass on a signature over the wrong bytes.
(define (split-last-dot s)
  (let loop ((i (- (string-length s) 1)))
    (if (char=? (string-ref s i) #\.)
        (cons (substring s 0 i) (substring s (+ i 1) (string-length s)))
        (loop (- i 1)))))
(define parts (split-last-dot jwt))
(call-with-output-file "/tmp/mesthiri-si.txt"
  (lambda (p) (write-string (car parts) p)))
;; re-pad and un-urlsafe so openssl base64 can decode it
(let* ((sig (cdr parts))
       (std (list->string (map (lambda (c) (case c ((#\-) #\+) ((#\_) #\/) (else c)))
                               (string->list sig))))
       (padded (string-append std (case (modulo (string-length std) 4)
                                    ((2) "==") ((3) "=") (else "")))))
  (call-with-output-file "/tmp/mesthiri-sig.b64"
    (lambda (p) (write-string padded p))))
(define _decoded
  (proc-run '("openssl" "base64" "-d" "-A" "-in" "/tmp/mesthiri-sig.b64"
              "-out" "/tmp/mesthiri-sig.bin")))
(check "openssl verifies the signature"
       #t (guard (e ((proc-error? e) #f))
            (proc-run '("openssl" "dgst" "-sha256"
                        "-verify" "tests/fixtures/test-key.pub"
                        "-signature" "/tmp/mesthiri-sig.bin"
                        "/tmp/mesthiri-si.txt"))
            #t))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
