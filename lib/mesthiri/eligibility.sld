;;; (mesthiri eligibility) — what mesthiri may attempt
;;;
;;; Branch protection stops a bad change merging. It says nothing about what
;;; should be attempted, and an orchestrator that tries anything an issue asks
;;; for is one well-written issue away from proposing a change to its own
;;; guardrails.
;;;
;;; Two checks, both before an agent is spawned, and the denylist again on the
;;; finished diff. Neither is a substitute for review; they exist so review is
;;; not the *only* thing between an issue and a change.

(define-library (mesthiri eligibility)
  (import (scheme base) (scheme write) (scheme char))
  (export path-denied? denied-paths-in glob-match?
          tier-allowed? eligibility-refusal)
  (begin

    ;; A deliberately small glob: `*` within a segment, `**` across segments.
    ;; Small because a denylist nobody can predict is one people work around,
    ;; and because a regex here would be a second language in a config file.
    (define (glob-match? pattern path)
      (m (string->list pattern) (string->list path)))

    (define (m p s)
      (cond
       ((null? p) (null? s))
       ;; `**` — any run of characters, separators included
       ((and (pair? (cdr p)) (char=? (car p) #\*) (char=? (cadr p) #\*))
        (let ((rest (skip-slash (cddr p))))
          (let loop ((s s))
            (cond ((m rest s) #t)
                  ((null? s) #f)
                  (else (loop (cdr s)))))))
       ;; `*` — any run within one segment
       ((char=? (car p) #\*)
        (let loop ((s s))
          (cond ((m (cdr p) s) #t)
                ((null? s) #f)
                ((char=? (car s) #\/) #f)
                (else (loop (cdr s))))))
       ((null? s) #f)
       ((char=? (car p) (car s)) (m (cdr p) (cdr s)))
       (else #f)))

    ;; `.mesthiri/**` should match `.mesthiri/config.scm`, so a `/` directly
    ;; after `**` is optional.
    (define (skip-slash p)
      (if (and (pair? p) (char=? (car p) #\/)) (cdr p) p))

    (define (path-denied? path patterns)
      (let loop ((ps patterns))
        (cond ((null? ps) #f)
              ((glob-match? (car ps) path) (car ps))
              (else (loop (cdr ps))))))

    ;; Every denied path in a changed-file list, with the pattern that caught
    ;; it — a refusal naming only the first would send someone round twice.
    (define (denied-paths-in paths patterns)
      (let loop ((ps paths) (acc '()))
        (cond ((null? ps) (reverse acc))
              (else
               (let ((hit (path-denied? (car ps) patterns)))
                 (loop (cdr ps)
                       (if hit (cons (cons (car ps) hit) acc) acc)))))))

    ;; Tier 2 needs a human saying so by name. `max-tier` caps the
    ;; label-driven path only: a write-permission `/implement` IS the
    ;; authorization, and capping a human's own command would make the
    ;; ceiling a second veto over a decision already taken.
    (define (tier-allowed? tier max-tier by-command?)
      (cond ((not (number? tier)) #f)
            ((>= tier 2) by-command?)
            (else (or by-command? (<= tier max-tier)))))

    (define (eligibility-refusal kind detail)
      (case kind
        ((tier)
         (string-append
          "Not implemented: this issue is intent tier " detail
          ", which needs a human to authorize the work by name.\n\n"
          "Someone with write permission can run `/implement` on this issue. "
          "Applying a label will not do it — a tier is an authorization fact, "
          "and a label anyone with triage permission can apply would make "
          "that authorization self-granting."))
        ((denylist)
         (string-append
          "Not implemented: the change touches paths this repository has "
          "placed out of bounds.\n\n" detail
          "\n\nThat list is `deny-paths` in `.mesthiri/config.scm` — which is "
          "itself on the list, so mesthiri cannot widen its own limits."))
        (else "Not implemented.")))))
