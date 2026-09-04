(import (scheme base) (scheme write) (mesthiri forge))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri forge)\n")

;; A transport that records what it was asked and replays canned responses.
(define seen '())
(define (scripted responses)
  (lambda (method url headers body)
    (set! seen (cons (list method url headers body) seen))
    (let ((r (assoc url responses)))
      (if r
          (apply values (cdr r))
          (values 404 '() "{\"message\":\"not found\"}")))))

;; --- headers -------------------------------------------------------------
(check "header lookup is case-insensitive"
       "9" (header-ref '(("X-RateLimit-Remaining" . "9")) "x-ratelimit-remaining"))
(check "absent header is #f" #f (header-ref '(("A" . "1")) "B"))

;; --- request shaping -----------------------------------------------------
(set! seen '())
(define f (make-forge (scripted '(("https://api.github.com/rate_limit"
                                   200 (("X-RateLimit-Remaining" . "4999")) "{\"ok\":true}")))))
(forge-auth! f (bearer "tok123"))
(define rl (forge-get f "/rate_limit"))
(define req (car seen))
(check "path is joined to the base url"
       "https://api.github.com/rate_limit" (cadr req))
(check "Authorization is sent" "Bearer tok123"
       (header-ref (caddr req) "Authorization"))
(check "API version is pinned" "2022-11-28"
       (header-ref (caddr req) "X-GitHub-Api-Version"))
(check "body is parsed as JSON" '(("ok" . #t)) rl)

;; Rate limit is taken from the response headers rather than a second call —
;; asking for it would spend the budget being measured.
(check "rate limit is recorded from response headers" 4999 (forge-rate-limit-remaining f))

;; --- errors --------------------------------------------------------------
(define g (make-forge (scripted '())))
(check "a 4xx raises rather than returning a body"
       #t (guard (e ((forge-error? e) #t)) (forge-get g "/nope") #f))
(check "the error carries the status"
       404 (guard (e ((forge-error? e) (forge-error-status e))) (forge-get g "/nope") #f))
(check "the error carries the url"
       "https://api.github.com/nope"
       (guard (e ((forge-error? e) (forge-error-url e))) (forge-get g "/nope") #f))

;; --- pagination ----------------------------------------------------------
(check "link-next finds rel=next"
       "https://api.github.com/x?page=2"
       (link-next "<https://api.github.com/x?page=2>; rel=\"next\", <https://api.github.com/x?page=9>; rel=\"last\""))
(check "link-next ignores a header with only rel=prev"
       #f (link-next "<https://api.github.com/x?page=1>; rel=\"prev\""))
(check "no link header is #f" #f (link-next #f))

;; Following pages must concatenate, and must stop.
(define paged
  (make-forge
   (scripted '(("https://api.github.com/items"
                200 (("Link" . "<https://api.github.com/items?page=2>; rel=\"next\"")) "[1,2]")
               ("https://api.github.com/items?page=2"
                200 (("Link" . "<https://api.github.com/items?page=1>; rel=\"prev\"")) "[3]")))))
(check "pagination follows Link and concatenates" '(1 2 3) (forge-get-all paged "/items"))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
