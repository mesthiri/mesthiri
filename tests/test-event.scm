(import (scheme base) (scheme write) (mesthiri event))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

(display "(mesthiri event)\n")

(define issue-opened-payload
  '(("action" . "opened")
    ("repository" ("full_name" . "mesthiri/sandbox"))
    ("sender" ("login" . "alice"))
    ("issue" ("number" . 412)
             ("body" . "Segfault when parsing empty vectors")
             ("labels" (("name" . "bug"))))))

(define e (normalize-event "issues" issue-opened-payload))
(check "kind" 'issue-opened (event-kind e))
(check "repo" "mesthiri/sandbox" (event-repo e))
(check "actor" "alice" (event-actor e))
(check "number" 412 (event-number e))
(check "labels" '("bug") (event-labels e))
(check "not a bot" #f (event-bot? e))

(define comment-payload
  '(("action" . "created")
    ("repository" ("full_name" . "mesthiri/sandbox"))
    ("sender" ("login" . "alice"))
    ("comment" ("id" . 99001) ("body" . "/implement please") ("user" ("login" . "bob")))
    ("issue" ("number" . 412) ("labels" ()))))
(define c (normalize-event "issue_comment" comment-payload))
(check "comment kind" 'issue-comment (event-kind c))
;; Authorization turns on this: the commenter, not the sender of the webhook.
(check "actor is the commenter, not the sender" "bob" (event-actor c))
(check "body is the comment" "/implement please" (event-body c))
(check "id is the comment id, for idempotency" 99001 (event-id c))

(define bot-payload
  '(("action" . "labeled")
    ("repository" ("full_name" . "mesthiri/sandbox"))
    ("sender" ("login" . "mesthiri[bot]"))
    ("issue" ("number" . 7) ("labels" (("name" . "ready-to-implement"))))))
(define b (normalize-event "issues" bot-payload))
(check "labeled kind" 'issue-labeled (event-kind b))
(check "a [bot] actor is marked" #t (event-bot? b))

;; pull_request_target must normalize the same as pull_request — the shim uses
;; the former and stages must not care which fired.
(define pr-payload
  '(("action" . "synchronize")
    ("repository" ("full_name" . "mesthiri/sandbox"))
    ("sender" ("login" . "alice"))
    ("pull_request" ("number" . 1204) ("labels" ()))))
(check "pull_request_target normalizes like pull_request"
       (event-kind (normalize-event "pull_request" pr-payload))
       (event-kind (normalize-event "pull_request_target" pr-payload)))
(check "synchronize is pull-request-updated"
       'pull-request-updated (event-kind (normalize-event "pull_request_target" pr-payload)))

(check "schedule carries its tick"
       "sunday 06:00"
       (event-schedule-tick (normalize-event "schedule" '() "sunday 06:00")))

;; Missing fields must yield #f rather than crashing: payloads vary by action.
(check "absent fields are #f, not an error"
       #f (event-number (normalize-event "issues" '(("action" . "opened")))))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
