;;; (mesthiri authz) — who is allowed to make mesthiri do something
;;;
;;; Authorization is against **the actor's** permission on the repository —
;;; the commenter for a command, the labeler for a label — and never against
;;; mesthiri's own. mesthiri's Apps hold write; the question is whether the
;;; human asking is entitled to spend it.
;;;
;;; The label case is the one that is easy to miss. GitHub's *triage* role can
;;; apply labels, and the code stage fires on `ready-to-implement` — so
;;; without checking the labeler, anyone with triage could trigger a
;;; code-changing stage that `/implement` would have required write for. A
;;; label a human applies is checked exactly like the matching command.
;;;
;;; Labels mesthiri's own Apps apply are exempt, and that is not a hole: it is
;;; the pipeline moving work that a schedule or an already-authorized command
;;; set in motion. Prioritize promoting an issue to `ready-to-implement` is
;;; not a new claim, and requiring a permission for it would deadlock.

(define-library (mesthiri authz)
  (import (scheme base) (scheme write) (mesthiri command) (mesthiri event)
          (mesthiri forge))
  (export actor-permission authorize-command authorize-label
          authz-ok? authz-reason make-authz)
  (begin

    (define-record-type <authz>
      (make-authz ok? reason) authz?
      (ok?    authz-ok?)
      (reason authz-reason))

    (define (ok) (make-authz #t #f))
    (define (no reason) (make-authz #f reason))

    ;; GitHub reports a coarse `permission` and a finer `role_name`. Triage
    ;; collapses to "read" in the coarse field, so preferring role_name is the
    ;; difference between a triage-role human being able to run `/triage` and
    ;; being told they cannot.
    (define (actor-permission forge repo login)
      (guard (e ((forge-error? e) 'none))
        (let ((r (forge-get forge (string-append "/repos/" repo
                                                 "/collaborators/" login
                                                 "/permission"))))
          (normalize-permission
           (or (let ((rn (assoc "role_name" r))) (and rn (cdr rn)))
               (let ((p (assoc "permission" r))) (and p (cdr p)))
               "none")))))

    ;; Is this command allowed, here, by this person?
    (define (authorize-command forge event cmd)
      (let* ((name   (command-name cmd))
             (entity (command-entity name))
             (kind   (event-kind event))
             (on-pr? (or (event-on-pull-request? event)
                         (memq kind '(pull-request-opened pull-request-updated
                                  pull-request-labeled pull-request-other
                                  pull-request-review))))
             (actor  (event-actor event)))
        (cond
         ;; Entity first: a command in the wrong place is refused before a
         ;; permission lookup, so a typo costs no API call.
         ((and (eq? entity 'issue) on-pr?)
          (no (string-append "/" (symbol->string name)
                             " is an issue command; run it on the issue")))
         ((and (eq? entity 'pull-request) (not on-pr?))
          (no (string-append "/" (symbol->string name)
                             " is a pull-request command; run it on the pull request")))
         ((not actor) (no "no actor on the event"))
         (else
          (let* ((need (command-min-permission name))
                 (have (actor-permission forge (event-repo event) actor)))
            (if (permission>=? have need)
                (ok)
                (no (string-append
                     "/" (symbol->string name) " needs "
                     (symbol->string need) " permission and "
                     actor " has " (symbol->string have)))))))))

    ;; A label that triggers a stage needs whatever the matching command would
    ;; need. `stage-permission` is passed in rather than derived here so the
    ;; mapping lives with the command table.
    (define (authorize-label forge event needed)
      (cond
       ;; mesthiri's own Apps moving work forward
       ((event-bot? event) (ok))
       ((not (event-actor event)) (no "no actor on the event"))
       (else
        (let ((have (actor-permission forge (event-repo event) (event-actor event))))
          (if (permission>=? have needed)
              (ok)
              (no (string-append
                   "applying that label runs a stage needing "
                   (symbol->string needed) " permission, and "
                   (event-actor event) " has " (symbol->string have))))))))))
