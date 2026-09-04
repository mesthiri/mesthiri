;;; (mesthiri event) — the normalized event
;;;
;;; Every trigger becomes this one shape: an issue opened, a comment, a pull
;;; request, a review, or the hourly schedule tick. Stages and trigger
;;; predicates read this and never a raw forge payload, so routing and
;;; authorization are written once rather than per event type.
;;;
;;; The payload arrives as an already-parsed structure — a nested alist with
;;; string keys, which is what a JSON parser produces. Parsing is left to the
;;; caller on purpose: it keeps this module free of a JSON dependency and
;;; testable against literal fixtures.
;;;
;;; `actor` is the field authorization turns on, and it is deliberately the
;;; human who acted — the commenter, or whoever applied the label — never
;;; mesthiri's own identity.

(define-library (mesthiri event)
  (import (scheme base) (scheme write))
  (export make-event event? normalize-event
          event-kind event-repo event-actor event-number event-labels
          event-body event-action event-id event-schedule-tick
          event-bot? event-on-pull-request? payload-ref
          marker-prefix event-marker event-own-comment?)
  (begin

    (define-record-type <event>
      (make-event kind repo actor number labels body action id schedule-tick bot?
                  on-pull-request?)
      event?
      (kind          event-kind)          ; symbol, see normalize-event
      (repo          event-repo)          ; "owner/name"
      (actor         event-actor)         ; login of the human who acted
      (number        event-number)        ; issue or PR number, or #f
      (labels        event-labels)        ; list of label names
      (body          event-body)          ; comment or issue body, or #f
      (action        event-action)        ; the forge's action string
      (id            event-id)            ; for idempotency: comment/delivery id
      (schedule-tick event-schedule-tick) ; "YYYY-MM-DDTHH" of the tick, or #f
      (bot?          event-bot?)          ; did one of mesthiri's Apps act
      ;; A comment on a pull request arrives as `issue_comment`, with the
      ;; issue carrying a `pull_request` key. Nothing else distinguishes
      ;; the two, so without this a pull-request command like /review is
      ;; refused as "run it on the pull request" — when it was.
      (on-pull-request? event-on-pull-request?))

    ;; mesthiri stamps every comment it writes with this, so it can recognise
    ;; its own work later. It serves two purposes and they are related: the
    ;; entry point uses it for idempotency ("have I already replied to this
    ;; event"), and dispatch uses it to recognise an event *caused by* a
    ;; comment it wrote.
    (define marker-prefix "<!-- mesthiri:")

    (define (event-marker event)
      (string-append marker-prefix
                     (if (number? (event-id event))
                         (number->string (event-id event))
                         "?")
                     " -->"))

    ;; A comment mesthiri itself posted.
    ;;
    ;; Every comment mesthiri writes fires an `issue_comment` event that
    ;; dispatches, matches nothing, and exits — correct, but a CI run per
    ;; comment, which with six live stages is noise.
    ;;
    ;; Identified by the marker rather than by the author's name, for two
    ;; reasons. Name matching would need the App slugs, which config does not
    ;; carry (only the ids). And suppressing every bot would silence a
    ;; third-party bot that legitimately holds write permission and may issue
    ;; a command — authorization is by permission here, not by being human.
    ;; Both signals are required: a bot author *and* mesthiri's own marker.
    (define (event-own-comment? event)
      (and (eq? (event-kind event) 'issue-comment)
           (event-bot? event)
           (let ((b (event-body event)))
             (and (string? b) (contains? b marker-prefix)))))

    (define (contains? s sub)
      (let ((n (string-length s)) (m (string-length sub)))
        (let loop ((i 0))
          (cond ((> (+ i m) n) #f)
                ((string=? (substring s i (+ i m)) sub) #t)
                (else (loop (+ i 1)))))))

    ;; Nested lookup: (payload-ref p "issue" "user" "login")
    (define (payload-ref payload . keys)
      (let loop ((p payload) (k keys))
        (cond ((null? k) p)
              ((not (pair? p)) #f)
              (else (let ((hit (assoc (car k) p)))
                      (and hit (loop (cdr hit) (cdr k))))))))

    ;; A login ending in "[bot]" is an App. Labels mesthiri's own Apps apply
    ;; are the pipeline moving work a schedule or an already-authorized
    ;; command set in motion, not a new claim — so they are marked here and
    ;; skip the permission check, rather than each stage remembering to.
    (define (bot-login? login)
      (and (string? login)
           (let ((n (string-length login)))
             (and (> n 5) (string=? (substring login (- n 5) n) "[bot]")))))

    ;; Map a GitHub event name plus its payload onto one shape.
    ;;
    ;; `tick` is the schedule hour, supplied by the caller from the CI
    ;; environment rather than read from a clock here, so a replayed event
    ;; normalizes identically.
    (define (normalize-event name payload . opts)
      (let* ((tick   (if (pair? opts) (car opts) #f))
             (action (payload-ref payload "action"))
             (repo   (payload-ref payload "repository" "full_name"))
             (issue  (payload-ref payload "issue"))
             (pr     (payload-ref payload "pull_request"))
             ;; Present only when the commented-on issue is a pull request.
             (issue-is-pr (and (payload-ref payload "issue" "pull_request") #t))
             (actor  (or (payload-ref payload "comment" "user" "login")
                         (payload-ref payload "sender" "login")))
             (labels (map (lambda (l) (or (payload-ref l "name") ""))
                          (or (payload-ref payload "issue" "labels")
                              (payload-ref payload "pull_request" "labels")
                              '())))
             (kind
              (cond
               ((string=? name "schedule") 'schedule)
               ((string=? name "issue_comment") 'issue-comment)
               ((string=? name "issues")
                (cond ((equal? action "opened")   'issue-opened)
                      ((equal? action "reopened") 'issue-reopened)
                      ((equal? action "labeled")  'issue-labeled)
                      (else 'issue-other)))
               ((or (string=? name "pull_request")
                    (string=? name "pull_request_target"))
                (cond ((equal? action "opened") 'pull-request-opened)
                      ((equal? action "synchronize") 'pull-request-updated)
                      ((equal? action "labeled") 'pull-request-labeled)
                      (else 'pull-request-other)))
               ((string=? name "pull_request_review") 'pull-request-review)
               (else 'unknown))))
        (make-event kind repo actor
                    (or (payload-ref issue "number") (payload-ref pr "number"))
                    labels
                    (or (payload-ref payload "comment" "body")
                        (payload-ref issue "body"))
                    action
                    (or (payload-ref payload "comment" "id")
                        (payload-ref issue "number")
                        (payload-ref pr "number"))
                    tick
                    (bot-login? actor)
                    (or issue-is-pr (and pr #t)))))))
