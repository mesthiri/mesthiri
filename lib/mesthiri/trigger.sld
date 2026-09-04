;;; (mesthiri trigger) — the trigger predicate language
;;;
;;; Decides whether a stage runs for a normalized event. The expressions come
;;; from `.mesthiri/config.scm` in the repository being worked on, which means
;;; they are maintainer-controlled but not mesthiri-controlled.
;;;
;;; **They are interpreted over a fixed vocabulary and never `eval`ed.** The
;;; data is already s-expressions, so `eval` would be one line and would work
;;; first time. It would also turn a config file into arbitrary code execution
;;; inside a job holding installation tokens and an App private key. An
;;; interpreter over a closed vocabulary cannot be talked into anything the
;;; vocabulary does not contain, and an unknown form is refused rather than
;;; ignored — silently ignoring it would make a typo look like a stage that
;;; simply never matches.

(define-library (mesthiri trigger)
  (import (scheme base) (scheme write) (scheme char) (mesthiri event))
  (export trigger-match? trigger-valid? trigger-vocabulary
          trigger-error? trigger-error-message trigger-error-form)
  (begin

    (define-record-type <trigger-error>
      (make-trigger-error message form) trigger-error?
      (message trigger-error-message)
      (form    trigger-error-form))

    (define (refuse form . parts)
      (raise (make-trigger-error (apply string-append parts) form)))

    ;; The whole vocabulary. Adding to this list is the only way to add a
    ;; predicate, which is the point: there is no path from config text to a
    ;; procedure that is not named here.
    (define event-predicates
      '(issue-opened issue-reopened issue-comment issue-labeled
        pull-request-opened pull-request-updated pull-request-labeled
        pull-request-review))

    (define (trigger-vocabulary)
      (append '(and or not label command schedule) event-predicates))

    ;; --- helpers ----------------------------------------------------------

    (define (string-index-of s sub)
      (let ((n (string-length s)) (m (string-length sub)))
        (let loop ((i 0))
          (cond ((> (+ i m) n) #f)
                ((string=? (substring s i (+ i m)) sub) i)
                (else (loop (+ i 1)))))))

    (define (trim s)
      (let* ((n (string-length s))
             (start (let loop ((i 0))
                      (if (and (< i n) (char-whitespace? (string-ref s i)))
                          (loop (+ i 1)) i)))
             (end (let loop ((i n))
                    (if (and (> i start) (char-whitespace? (string-ref s (- i 1))))
                        (loop (- i 1)) i))))
        (substring s start end)))

    (define (lines s)
      (let ((n (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((>= i n) (reverse (cons (substring s start n) acc)))
                ((char=? (string-ref s i) #\newline)
                 (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
                (else (loop (+ i 1) start acc))))))

    ;; A command counts only at the start of a line, and only as a whole
    ;; token. Prose mentioning `/implement` mid-sentence is not an
    ;; instruction, and this is parsed rather than pattern-matched loosely
    ;; because the body is attacker-writable text.
    (define (body-invokes-command? body cmd)
      (and (string? body)
           (let loop ((ls (lines body)))
             (cond ((null? ls) #f)
                   (else
                    (let* ((l (trim (car ls)))
                           (n (string-length cmd)))
                      (if (and (>= (string-length l) n)
                               (string=? (substring l 0 n) cmd)
                               (or (= (string-length l) n)
                                   (char-whitespace? (string-ref l n))))
                          #t
                          (loop (cdr ls)))))))))

    ;; The tick is "<weekday> <HH>:MM", supplied by the caller from the CI
    ;; environment. A bare "07:00" is daily; "sunday 06:00" is weekly. Date
    ;; arithmetic stays out of here.
    (define (schedule-matches? spec tick)
      (and (string? tick) (string? spec)
           (or (string=? spec tick)
               (let ((sp (string-index-of tick " ")))
                 (and sp (string=? spec (substring tick (+ sp 1)
                                                   (string-length tick))))))))

    ;; --- the interpreter --------------------------------------------------

    (define (trigger-match? form event)
      (cond
       ((not (pair? form))
        (refuse form "trigger must be a list form, got a bare atom"))
       (else
        (let ((head (car form)) (args (cdr form)))
          (case head
            ((and) (let loop ((f args))
                     (cond ((null? f) #t)
                           ((trigger-match? (car f) event) (loop (cdr f)))
                           (else #f))))
            ((or)  (let loop ((f args))
                     (cond ((null? f) #f)
                           ((trigger-match? (car f) event) #t)
                           (else (loop (cdr f))))))
            ((not) (if (= (length args) 1)
                       (not (trigger-match? (car args) event))
                       (refuse form "(not ...) takes exactly one form")))
            ((label)
             (if (and (= (length args) 1) (string? (car args)))
                 (and (member (car args) (event-labels event)) #t)
                 (refuse form "(label \"name\") takes one string")))
            ((command)
             (if (and (= (length args) 1) (string? (car args)))
                 (body-invokes-command? (event-body event) (car args))
                 (refuse form "(command \"/name\") takes one string")))
            ((schedule)
             (if (and (= (length args) 1) (string? (car args)))
                 (and (eq? (event-kind event) 'schedule)
                      (schedule-matches? (car args) (event-schedule-tick event)))
                 (refuse form "(schedule \"HH:MM\") takes one string")))
            (else
             (if (memq head event-predicates)
                 (if (null? args)
                     (eq? (event-kind event) head)
                     (refuse form "(" (symbol->string head) ") takes no arguments"))
                 (refuse form "unknown trigger predicate `"
                         (symbol->string head)
                         "` — the vocabulary is fixed and this is not in it")))))))) 

    ;; Check a form without an event, for load-time validation.
    (define (trigger-valid? form)
      (guard (e ((trigger-error? e) #f))
        (trigger-match? form
                        (make-event 'schedule "o/r" "x" 1 '() "" "" 1 "monday 00:00" #f #f))
        #t))))
