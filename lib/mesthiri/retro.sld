;;; (mesthiri retro) — mine the runs, propose improvements
;;;
;;; Retro reads what CI already keeps: completed runs and the JSONL trace each
;;; stage uploads. There is no database to query, and none is wanted — the run
;;; history is the record, and its retention is CI's.
;;;
;;; Proposals are filed as issues **on the repository mesthiri is installed
;;; in**, using the same repo-scoped token as every other stage. They are
;;; about that repository's own pipeline: a test that keeps failing, work that
;;; keeps escalating, a rubric that keeps producing arguments. Improvements to
;;; mesthiri itself reach it the ordinary way, from a human who read one.
;;;
;;; Two things retro deliberately does not do. It does not act on its own
;;; findings — mesthiri is never installed on its own repository, so it cannot
;;; implement proposals about itself. And it does not file the same
;;; observation twice: a retro that reopens its own issue every week is one
;;; nobody reads.

(define-library (mesthiri retro)
  (import (scheme base) (scheme write) (scheme char)
          (mesthiri forge) (mesthiri log))
  (export analyze-runs observation-kind observation-detail observation-count
          observation->title observation->body observation-marker
          already-filed? retro-window min-occurrences)
  (begin

    ;; How many recent runs to look at, and how often something must happen
    ;; before it is worth a human's attention. One failure is noise; three is
    ;; a pattern — and filing on the first would make retro the noisiest thing
    ;; in the repository.
    (define retro-window 50)
    (define min-occurrences 3)

    (define-record-type <observation>
      (make-observation kind detail count) observation?
      (kind   observation-kind)
      (detail observation-detail)
      (count  observation-count))

    (define (field o key) (let ((x (assoc key o))) (and x (cdr x))))

    ;; Runs come in as ((conclusion . "failure") (name . "...") (stage . "...")
    ;; (outcome . "...")) — whatever the caller could extract. Pure, so the
    ;; whole analysis is testable without a forge.
    (define (analyze-runs runs)
      (let ((obs (append (repeated 'failing-stage (map stage-of (failures runs)))
                         (repeated 'budget-exhausted
                                   (map stage-of (with-outcome runs "over-budget")))
                         (repeated 'escalated-to-human
                                   (map stage-of (with-outcome runs "needs-human")))
                         (repeated 'agent-never-settled
                                   (map stage-of (with-outcome runs "eof"))))))
        obs))

    (define (failures runs)
      (let loop ((r runs) (acc '()))
        (cond ((null? r) (reverse acc))
              ((equal? (field (car r) "conclusion") "failure")
               (loop (cdr r) (cons (car r) acc)))
              (else (loop (cdr r) acc)))))

    (define (with-outcome runs outcome)
      (let loop ((r runs) (acc '()))
        (cond ((null? r) (reverse acc))
              ((equal? (field (car r) "outcome") outcome)
               (loop (cdr r) (cons (car r) acc)))
              (else (loop (cdr r) acc)))))

    (define (stage-of r) (or (field r "stage") "unknown"))

    ;; Group and keep only what recurs.
    (define (repeated kind items)
      (let loop ((i items) (counts '()))
        (cond
         ((null? i)
          (let keep ((c counts) (acc '()))
            (cond ((null? c) acc)
                  ((>= (cdar c) min-occurrences)
                   (keep (cdr c) (cons (make-observation kind (caar c) (cdar c)) acc)))
                  (else (keep (cdr c) acc)))))
         (else
          (let ((hit (assoc (car i) counts)))
            (loop (cdr i)
                  (if hit
                      (map (lambda (e) (if (equal? (car e) (car i))
                                           (cons (car e) (+ (cdr e) 1)) e))
                           counts)
                      (cons (cons (car i) 1) counts))))))))

    ;; A stable marker so the same observation is not filed twice. It names
    ;; the kind and subject, not the count — a recurrence should update a
    ;; human's sense of urgency, not create a second issue.
    (define (observation-marker o)
      (string-append "<!-- mesthiri-retro:" (symbol->string (observation-kind o))
                     ":" (observation-detail o) " -->"))

    (define (observation->title o)
      (case (observation-kind o)
        ((failing-stage)
         (string-append "The " (observation-detail o) " stage keeps failing"))
        ((budget-exhausted)
         (string-append "The " (observation-detail o)
                        " stage keeps running out of budget"))
        ((escalated-to-human)
         (string-append "The " (observation-detail o)
                        " stage keeps handing work back"))
        ((agent-never-settled)
         (string-append "The agent keeps not finishing in the "
                        (observation-detail o) " stage"))
        (else "Pipeline observation")))

    (define (observation->body o window)
      (string-append
       "This happened **" (number->string (observation-count o))
       " times** in the last " (number->string window) " runs.\n\n"
       (advice (observation-kind o) (observation-detail o))
       "\n\nI cannot fix this myself — it is about how this repository's "
       "pipeline is configured or about the project's own tests, both of "
       "which are yours. Closing this issue is a fine answer if the pattern "
       "is expected.\n\n"
       (observation-marker o)))

    (define (advice kind stage)
      (case kind
        ((failing-stage)
         (string-append "A stage failing repeatedly usually means the "
                        "project's test command is flaky, or the stage is "
                        "being handed work it cannot do. The run logs for "
                        "`" stage "` will say which."))
        ((budget-exhausted)
         (string-append "Runs are hitting the token or turn cap rather than "
                        "finishing. Either the work is bigger than the budget "
                        "in `.mesthiri/config.scm`, or the model is going "
                        "round in circles — the JSONL trace shows which."))
        ((escalated-to-human)
         (string-append "Work reaching `needs-human` repeatedly is not a "
                        "failure, but it does mean the pipeline is not saving "
                        "anyone time on this class of issue. Consider turning "
                        "`" stage "` off for now."))
        ((agent-never-settled)
         "The agent is being killed on its deadline rather than finishing. That is a wall-clock limit, not a token one.")
        (else "")))

    ;; A retro that files the same issue every week is one nobody reads.
    (define (already-filed? open-issues o)
      (let ((marker (observation-marker o)))
        (let loop ((is open-issues))
          (cond ((null? is) #f)
                ((let ((b (field (car is) "body")))
                   (and (string? b) (contains? b marker))) #t)
                (else (loop (cdr is)))))))

    (define (contains? s sub)
      (let ((n (string-length s)) (m (string-length sub)))
        (let loop ((i 0))
          (cond ((> (+ i m) n) #f)
                ((string=? (substring s i (+ i m)) sub) #t)
                (else (loop (+ i 1)))))))))
