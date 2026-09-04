;;; The guide's sample config must be one mesthiri can actually read.
;;;
;;; It is written ahead of the code as a design tool, which is the point of
;;; it — and which is exactly why it drifts. `(fix (on (findings-posted)))`
;;; sat in it through several revisions: a predicate that is not in the
;;; trigger vocabulary parses as an ordinary list and is only refused when a
;;; run reaches it, so nothing about reading the document says it is wrong.
;;; This is the check that says so.

(import (scheme base) (scheme file) (scheme write) (scheme read)
        (mesthiri config) (mesthiri trigger))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "the guide's sample configuration\n")

;; Pull the first fenced block that opens with `(mesthiri`.
(define (sample-config path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((line (read-line p)) (in #f) (acc ""))
        (cond ((eof-object? line) (if in acc #f))
              ((and (not in) (string=? line "(mesthiri"))
               (loop (read-line p) #t "(mesthiri\n"))
              ((and in (string=? line "```")) acc)
              (in (loop (read-line p) #t (string-append acc line "\n")))
              (else (loop (read-line p) #f acc)))))))

(define text (sample-config "docs/guide.md"))
(check "the guide still contains a sample config" #t (string? text))

(define cfg (parse-config (read (open-input-string text)) "docs/guide.md"))
(check "it parses" 1 (config-version cfg))
(check "it names an operator" #t (string? (config-operator-name cfg)))
(check "it declares both Apps"
       #t (and (config-app cfg 'reader) (config-app cfg 'writer) #t))
(check "it declares at least one provider" #t (pair? (config-provider-names cfg)))
(check "and every stage's provider reference resolves"
       #t (and (config-provider cfg (car (config-provider-names cfg))) #t))

;; The one that keeps breaking.
(for-each
 (lambda (stage)
   (let ((tr (stage-trigger (config-stage cfg stage))))
     (check (string-append "the " (symbol->string stage)
                           " trigger is in the vocabulary")
            #t (and (trigger-valid? tr) #t))))
 '(triage prioritize code review fix retro))

;; Nothing in the sample may be live: a reader who copies it verbatim must
;; not thereby enable anything.
(check "no stage in the sample is live"
       #t (let loop ((s '(triage prioritize code review fix retro)))
            (cond ((null? s) #t)
                  ((eq? (stage-mode (config-stage cfg (car s))) 'live) #f)
                  (else (loop (cdr s))))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
