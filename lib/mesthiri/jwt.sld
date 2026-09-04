;;; (mesthiri jwt) — GitHub App JWTs, signed RS256
;;;
;;; A GitHub App authenticates by signing a short-lived JWT with its private
;;; key and exchanging that for an installation token. RS256 does not exist
;;; in the Kaappi ecosystem, and mesthiri does not add it: the signature comes
;;; from a one-shot `openssl` call through `(mesthiri proc)`.
;;;
;;; Two properties that are not obvious from the code:
;;;
;;;   - The key is passed as a *file path*, never on stdin or argv. `openssl
;;;     dgst -sign` needs a path (stdin already carries the data being
;;;     signed), and an argument would put the key in the process table.
;;;   - The signature is binary. It is captured as a bytevector and never
;;;     round-tripped through a string, which would corrupt it silently.
;;;
;;; base64url is here rather than in a utility module because this is its only
;;; caller; kaappi core exports no base64 (SRFI 207 ships without it).

(define-library (mesthiri jwt)
  (import (scheme base) (scheme time) (mesthiri proc))
  (export base64url-encode make-app-jwt)
  (begin

    (define alphabet
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    ;; base64url without padding, as JWT requires. Plain arithmetic rather
    ;; than SRFI 151 bit operations — one fewer import for two lines of gain.
    (define (base64url-encode bv)
      (let ((len (bytevector-length bv)))
        (let loop ((i 0) (acc '()))
          (if (>= i len)
              (list->string (reverse acc))
              (let* ((n  (- len i))
                     (b0 (bytevector-u8-ref bv i))
                     (b1 (if (> n 1) (bytevector-u8-ref bv (+ i 1)) 0))
                     (b2 (if (> n 2) (bytevector-u8-ref bv (+ i 2)) 0))
                     (t  (+ (* b0 65536) (* b1 256) b2))
                     (c  (lambda (shift)
                           (string-ref alphabet (modulo (quotient t shift) 64)))))
                (loop (+ i 3)
                      (append (reverse
                               (cond ((> n 2) (list (c 262144) (c 4096) (c 64) (c 1)))
                                     ((= n 2) (list (c 262144) (c 4096) (c 64)))
                                     (else    (list (c 262144) (c 4096)))))
                              acc)))))))

    (define (b64-string s) (base64url-encode (string->utf8 s)))

    ;; Mint a JWT for `app-id`, signed with the PEM at `key-path`.
    ;;
    ;; `now` is a parameter rather than read inside, so tests are deterministic
    ;; and a caller with a better clock can supply one. It defaults to the
    ;; current second.
    ;;
    ;; The window is deliberately narrow: `iat` is backdated 60 seconds because
    ;; GitHub rejects a token whose `iat` is in its future by even a little, and
    ;; a developer machine drifting is far more common than an attacker
    ;; replaying inside a nine-minute window. `exp` is 9 minutes out, under
    ;; GitHub's 10-minute ceiling.
    (define (make-app-jwt app-id key-path . opts)
      (let* ((now (if (pair? opts) (car opts) (exact (floor (current-second)))))
             (header  (b64-string "{\"alg\":\"RS256\",\"typ\":\"JWT\"}"))
             (payload (b64-string
                       (string-append
                        "{\"iat\":" (number->string (- now 60))
                        ",\"exp\":" (number->string (+ now 540))
                        ",\"iss\":\"" app-id "\"}")))
             (signing-input (string-append header "." payload))
             (signature (proc-run (list "openssl" "dgst" "-sha256"
                                        "-sign" key-path)
                                  'input: signing-input)))
        (string-append signing-input "." (base64url-encode signature))))))
