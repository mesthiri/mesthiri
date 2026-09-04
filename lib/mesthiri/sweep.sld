;;; (mesthiri sweep) — finding work without a cursor
;;;
;;; Scheduled stages ask the forge what needs doing rather than remembering
;;; where they got to. Labels are the watermark: an issue with no workflow
;;; label has not been seen, and one carrying `ready-for-triage` is waiting.
;;;
;;; This costs more API calls per sweep than a stored cursor, and buys the
;;; property that mesthiri keeps no state a human cannot see in the
;;; repository — no orphan branch, nothing to get out of sync, and a
;;; maintainer can re-queue an issue by removing a label.

(define-library (mesthiri sweep)
  (import (scheme base) (scheme write) (mesthiri forge) (mesthiri labels))
  (export needs-triage? open-issues untriaged-issues sweep-limit)
  (begin

    ;; A sweep processes at most this many issues per run. A repository with
    ;; four hundred untriaged issues should not discover mesthiri by spending
    ;; a day's budget in one scheduled run.
    (define sweep-limit 10)

    ;; Pull requests come back from the issues endpoint too, and a pull
    ;; request is not something to triage.
    (define (issue? o) (not (assoc "pull_request" o)))

    (define (labels-of o)
      (let ((l (assoc "labels" o)))
        (if (and l (list? (cdr l)))
            (map (lambda (x) (let ((n (assoc "name" x))) (if n (cdr n) "")))
                 (cdr l))
            '())))

    ;; Untouched, or explicitly queued. An issue already carrying a later
    ;; workflow label is in flight and must not be re-triaged — that is what
    ;; makes a sweep idempotent without a cursor.
    (define (needs-triage? o)
      (and (issue? o)
           (let ((ls (labels-of o)))
             (or (null? (filter-workflow ls))
                 (and (member "ready-for-triage" ls) #t)))))

    (define (filter-workflow ls)
      (let loop ((l ls) (acc '()))
        (cond ((null? l) acc)
              ((label-exists? (car l)) (loop (cdr l) (cons (car l) acc)))
              (else (loop (cdr l) acc)))))

    (define (open-issues forge repo)
      (forge-get-all forge (string-append "/repos/" repo
                                          "/issues?state=open&per_page=100")))

    (define (untriaged-issues forge repo)
      (let loop ((os (open-issues forge repo)) (acc '()) (n 0))
        (cond ((or (null? os) (>= n sweep-limit)) (reverse acc))
              ((needs-triage? (car os))
               (loop (cdr os) (cons (car os) acc) (+ n 1)))
              (else (loop (cdr os) acc n)))))))
