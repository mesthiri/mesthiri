(import (scheme base) (scheme write) (mesthiri eligibility))
(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(display "(mesthiri eligibility)\n")

;; --- globs ----------------------------------------------------------------
(check "exact match" #t (glob-match? "CODEOWNERS" "CODEOWNERS"))
(check "* stays within a segment" #t (glob-match? "src/*.zig" "src/main.zig"))
(check "* does not cross a separator" #f (glob-match? "src/*.zig" "src/a/b.zig"))
(check "** crosses separators" #t (glob-match? ".github/**" ".github/workflows/ci.yml"))
;; The case that matters most: the config protecting itself.
(check "**/ matches the directory's own files"
       #t (glob-match? ".mesthiri/**" ".mesthiri/config.scm"))
(check "an unrelated path is not caught" #f (glob-match? ".mesthiri/**" "src/main.scm"))

;; --- the denylist ----------------------------------------------------------
(define deny '(".mesthiri/**" ".github/workflows/**" "CODEOWNERS" "src/auth/*"))
(check "a protected path is caught" ".mesthiri/**" (path-denied? ".mesthiri/config.scm" deny))
(check "an ordinary path passes" #f (path-denied? "lib/sandbox/stats.sld" deny))
(check "mesthiri cannot edit its own workflow"
       #t (and (path-denied? ".github/workflows/mesthiri.yml" deny) #t))

;; A refusal naming only the first offender sends someone round twice.
(check "every offender is reported, with the pattern that caught it"
       2 (length (denied-paths-in
                  '("lib/ok.scm" ".mesthiri/config.scm" "CODEOWNERS") deny)))

;; --- tiers ------------------------------------------------------------------
(check "tier 0 runs under a max-tier of 0" #t (tier-allowed? 0 0 #f))
(check "tier 1 does not, at max-tier 0" #f (tier-allowed? 1 0 #f))
(check "tier 1 does at max-tier 1" #t (tier-allowed? 1 1 #f))
;; The label path can never reach tier 2, whatever max-tier says.
(check "tier 2 is refused on the label path even at max-tier 2"
       #f (tier-allowed? 2 2 #f))
;; A write-permission /implement IS the authorization.
(check "tier 2 is allowed when a human asked by name" #t (tier-allowed? 2 0 #t))
;; And max-tier does not second-guess that human.
(check "a command is not capped by max-tier" #t (tier-allowed? 1 0 #t))
(check "a missing tier is refused, not defaulted" #f (tier-allowed? #f 2 #f))

;; --- refusals say what fired and what to do -------------------------------
(define r (eligibility-refusal 'tier "2"))
(check "the tier refusal names the command that would work"
       #t (let loop ((i 0))
            (cond ((> (+ i 10) (string-length r)) #f)
                  ((string=? (substring r i (+ i 10)) "/implement") #t)
                  (else (loop (+ i 1))))))
(check "and says a label will not do it"
       #t (let loop ((i 0))
            (cond ((> (+ i 5) (string-length r)) #f)
                  ((string=? (substring r i (+ i 5)) "label") #t)
                  (else (loop (+ i 1))))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
