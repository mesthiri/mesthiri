;;; (mesthiri dispatch) — one event, one stage, one job
;;;
;;; The order of the gates is deliberate and each one is cheaper than the
;;; next: match a stage before asking the forge anything, check the mode
;;; before authorizing, authorize before checking idempotency, and only then
;;; run. A refused command costs no API call beyond the permission lookup, and
;;; an `off` stage costs none at all.
;;;
;;; Every path returns a decision rather than just acting, so `explain-event`
;;; and the log can say *why* nothing happened. "A stage did nothing and said
;;; nothing" is the failure this architecture makes easiest to hit.

(define-library (mesthiri dispatch)
  (import (scheme base) (scheme write)
          (mesthiri config) (mesthiri event) (mesthiri trigger)
          (mesthiri command) (mesthiri authz) (mesthiri forge))
  (export dispatch decision? decision-outcome decision-stage decision-reason
          decision-command make-decision
          stage-candidates explain-event)
  (begin

    (define-record-type <decision>
      (make-decision outcome stage reason command) decision?
      (outcome decision-outcome)   ; symbol, see below
      (stage   decision-stage)
      (reason  decision-reason)
      (command decision-command))

    ;; Which stages this event could run, and why.
    ;;
    ;; A command names its stage directly. Otherwise every configured stage's
    ;; trigger is evaluated. A malformed trigger is reported rather than
    ;; silently failing to match — a config typo must not look like an event
    ;; that simply did not apply.
    (define all-stages '(triage prioritize code review fix retro))

    (define (stage-candidates config event)
      (let loop ((s all-stages) (acc '()))
        (if (null? s)
            (reverse acc)
            (let* ((name (car s))
                   (st   (config-stage config name))
                   (trig (and st (stage-trigger st))))
              (loop (cdr s)
                    (if (not trig)
                        acc
                        (let ((m (guard (e ((trigger-error? e) (list 'invalid (trigger-error-message e))))
                                   (if (trigger-match? trig event) 'match 'no-match))))
                          (cons (list name (stage-mode st) trig m) acc))))))))

    ;; The permission a label-triggered stage demands: the same as the command
    ;; that would run it, so there is one rule rather than two.
    (define (stage-permission name)
      (let loop ((c command-table))
        (cond ((null? c) 'write)                 ; unknown stage: demand the most
              ((eq? (cadr (car c)) name) (cadddr (car c)))
              (else (loop (cdr c))))))

    ;; `already-handled?` is injected: without a database, idempotency is a
    ;; question for the forge (has mesthiri already replied to this comment
    ;; id), and a test should not need one.
    (define (dispatch forge config event handlers already-handled?)
      (if (event-own-comment? event)
          ;; Cheapest possible exit: mesthiri's own comment fired this, and
          ;; nothing it writes is ever an instruction to itself. Checked
          ;; before anything is parsed or asked of the forge.
          (make-decision 'own-comment #f
                         "this event was caused by mesthiri's own comment" #f)
          (dispatch-event forge config event handlers already-handled?)))

    (define (dispatch-event forge config event handlers already-handled?)
      (let* ((body  (event-body event))
             (cmds  (if (memq (event-kind event) '(issue-comment))
                        (parse-commands body) '()))
             (cmd   (if (pair? cmds) (car cmds) #f)))
        (if cmd
            (dispatch-command forge config event cmd handlers already-handled?)
            (dispatch-trigger forge config event handlers already-handled?))))

    (define (run-if-fresh forge config event stage cmd handlers already-handled?)
      (if (already-handled? event stage)
          (make-decision 'already-handled stage
                         "this event was already acted on" cmd)
          (let ((h (assq stage handlers)))
            (if (not h)
                (make-decision 'no-handler stage
                               "no handler registered for this stage" cmd)
                (begin ((cdr h) forge config event)
                       (make-decision 'ran stage #f cmd))))))

    (define (dispatch-command forge config event cmd handlers already-handled?)
      (let* ((name  (command-name cmd))
             (stage (command-stage name))
             (st    (config-stage config stage))
             (mode  (stage-mode st)))
        (cond
         ;; An explicit command on an `off` stage is refused *with a reason*
         ;; rather than ignored: someone typed it and deserves an answer.
         ((eq? mode 'off)
          (make-decision 'stage-off stage
                         (string-append "the " (symbol->string stage)
                                        " stage is off in .mesthiri/config.scm")
                         cmd))
         (else
          (let ((a (authorize-command forge event cmd)))
            (if (not (authz-ok? a))
                (make-decision 'unauthorized stage (authz-reason a) cmd)
                (run-if-fresh forge config event stage cmd handlers already-handled?)))))))

    (define (dispatch-trigger forge config event handlers already-handled?)
      (let ((matched (let loop ((c (stage-candidates config event)))
                       (cond ((null? c) #f)
                             ((eq? (cadddr (car c)) 'match) (car c))
                             (else (loop (cdr c)))))))
        (cond
         ((not matched)
          (make-decision 'no-match #f "no stage trigger matched this event" #f))
         ((eq? (cadr matched) 'off)
          (make-decision 'stage-off (car matched)
                         "the stage matched but is off" #f))
         (else
          (let* ((stage (car matched))
                 ;; A label a human applied is authorized like the command
                 ;; that would run the same stage.
                 (a (if (memq (event-kind event) '(issue-labeled pull-request-labeled))
                        (authorize-label forge event (stage-permission stage))
                        (make-authz #t #f))))
            (if (not (authz-ok? a))
                (make-decision 'unauthorized stage (authz-reason a) #f)
                (run-if-fresh forge config event stage #f handlers already-handled?)))))))

    ;; What dispatch would do, and why — printed rather than performed.
    (define (explain-event config event)
      (display "event\n")
      (display "  kind          ") (write (event-kind event)) (newline)
      (display "  repo          ") (write (event-repo event)) (newline)
      (display "  actor         ") (write (event-actor event)) (newline)
      (display "  number        ") (write (event-number event)) (newline)
      (display "  labels        ") (write (event-labels event)) (newline)
      (display "  schedule tick ") (write (event-schedule-tick event)) (newline)
      (display "  by a bot      ") (write (event-bot? event)) (newline)
      (display "commands parsed from the body\n")
      (let ((cmds (parse-commands (event-body event))))
        (if (null? cmds)
            (display "  (none)\n")
            (for-each (lambda (c)
                        (display "  /") (display (command-name c)) (newline))
                      cmds)))
      (display "stage triggers\n")
      (let ((cs (stage-candidates config event)))
        (if (null? cs)
            (display "  (no stages configured)\n")
            (for-each
             (lambda (c)
               (display "  ") (display (car c))
               (display "  mode=") (display (cadr c))
               (display "  ") (write (cadddr c))
               (newline)
               (display "      trigger ") (write (caddr c)) (newline))
             cs))))))
