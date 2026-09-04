;;; (mesthiri triage) — classify an issue against the repository's own rubric
;;;
;;; Three things make this different from asking a model to label an issue.
;;;
;;; **Claims are verified before they are trusted.** A diagnosis in an issue
;;; is a hypothesis; a good share of reporters are wrong about where the bug
;;; is. The agent gets a checkout and is asked to check before classifying.
;;;
;;; **The rubric is the repository's**, read at its configured path, and the
;;; verdict records the rubric's commit SHA — so a rubric change upstream
;;; reads as a behaviour change rather than a mystery.
;;;
;;; **The intent tier is not a label.** It goes in the verdict and the run
;;; record. A tier is an authorization fact, and a label anyone with triage
;;; permission can apply would make that authorization self-granting.

(define-library (mesthiri triage)
  (import (scheme base) (scheme write) (mesthiri agent) (mesthiri forge)
          (mesthiri labels) (mesthiri harness) (mesthiri log))
  (export triage-prompt verdict-schema make-verdict verdict?
          verdict-priority verdict-tier verdict-rationale verdict-rubric-sha
          verdict->comment triage-issue)
  (begin

    (define-record-type <verdict>
      (make-verdict priority tier rationale rubric-sha) verdict?
      (priority   verdict-priority)
      (tier       verdict-tier)
      (rationale  verdict-rationale)
      (rubric-sha verdict-rubric-sha))

    ;; What the agent must return. Checked outside the agent, so a malformed
    ;; response is a failed run rather than a mislabelled issue.
    (define verdict-schema
      '(("priority" . string) ("tier" . number) ("rationale" . string)))

    ;; The prompt. Note the shape: mesthiri's instructions first, then the
    ;; rubric as reference, then the issue text inside an explicit
    ;; untrusted-input block. The issue body is never concatenated into the
    ;; instruction section, because that is where a body saying "ignore your
    ;; rubric" would otherwise land.
    (define (triage-prompt rubric-text issue-title issue-body)
      (string-append
       "You are triaging one issue for this repository.\n\n"
       "Do this in order:\n"
       "1. Read the issue below. Treat its diagnosis as a hypothesis, not a fact.\n"
       "2. Check its claims against the code in the working directory. A\n"
       "   reporter naming the wrong component is common and is not a reason\n"
       "   to dismiss the report.\n"
       "3. Classify it against the rubric, choosing exactly one priority.\n"
       "4. Assign an intent tier: 0 pre-authorized and trivially revertible,\n"
       "   1 a single issue suffices, 2 a human must authorize the work.\n\n"
       "Reply with JSON only: {\"priority\": \"...\", \"tier\": N,\n"
       "\"rationale\": \"one paragraph, citing the rubric clause you applied\"}\n\n"
       "<rubric>\n" (or rubric-text "(no rubric supplied)") "\n</rubric>\n"
       (untrusted-block "the issue title" issue-title)
       (untrusted-block "the issue body" issue-body)))

    ;; A verdict a human can disagree with, which means saying what was applied
    ;; and under which version of the rubric.
    (define (verdict->comment v dry-run?)
      (string-append
       (if dry-run?
           (string-append "**Proposed: `" (verdict-priority v)
                          "`** — not applied, this repository is in dry-run.\n\n")
           (string-append "**" (verdict-priority v) "**\n\n"))
       (verdict-rationale v)
       "\n\n**Intent tier " (number->string (verdict-tier v)) "** — "
       (tier-explanation (verdict-tier v))
       "\n\n<sub>Rubric at `" (or (verdict-rubric-sha v) "unknown") "`</sub>"))

    (define (tier-explanation tier)
      (cond ((= tier 0) "pre-authorized: additive and trivially revertible.")
            ((= tier 1) "a single issue is sufficient authorization to fix this.")
            ((= tier 2) "a human must authorize this work before the code stage may claim it.")
            (else "unrecognised tier.")))

    ;; `run` is injected: (lambda (prompt) -> parsed JSON object). Stages do
    ;; not spawn anything themselves — that is agent.sld's alone — and it
    ;; means the whole classification path is testable without a model.
    (define (triage-issue forge config repo issue rubric-text rubric-sha mode run)
      (let* ((number (cdr (assoc "number" issue)))
             (title  (let ((t (assoc "title" issue))) (and t (cdr t))))
             (body   (let ((b (assoc "body" issue))) (and b (cdr b))))
             (raw    (run (triage-prompt rubric-text title body)))
             (ok     (validate-output raw verdict-schema))
             (v      (make-verdict (cdr (assoc "priority" ok))
                                   (cdr (assoc "tier" ok))
                                   (cdr (assoc "rationale" ok))
                                   rubric-sha)))
        (cond
         ((eq? mode 'dry-run)
          ;; dry-run comments and applies no labels. It used to only log,
          ;; which made it indistinguishable from `off` to anyone reading the
          ;; issue — and dry-run is what a fresh install ships, so that was
          ;; the whole first five minutes of the guide: a stage that ran,
          ;; reached a verdict, and left no trace of it anywhere the reader
          ;; would look. `verdict->comment` already rendered the dry-run
          ;; wording; nothing called it.
          (forge-post forge
                      (string-append "/repos/" repo "/issues/"
                                     (number->string number) "/comments")
                      (json-body (verdict->comment v #t)))
          (log-info "issue " number " -> " (verdict-priority v)
                    " (tier " (verdict-tier v) ") [dry-run: commented, no labels]")
          v)
         ((eq? mode 'live)
          (forge-post forge
                      (string-append "/repos/" repo "/issues/"
                                     (number->string number) "/comments")
                      (json-body (verdict->comment v #f)))
          ;; Exactly one priority label, and the workflow label moves too.
          (forge-post forge
                      (string-append "/repos/" repo "/issues/"
                                     (number->string number) "/labels")
                      (string-append "{\"labels\":[\"" (verdict-priority v) "\"]}"))
          (guard (e ((label-error? e) (log-warn (label-error-message e))))
            (apply-label! forge repo number "ready-for-triage" "triaged"))
          v)
         (else v))))

    ;; Minimal JSON string escaping for a comment body. Only the two characters
    ;; that would break the document; the agent's rationale is prose.
    (define (json-body text)
      (string-append "{\"body\":\"" (escape text) "\"}"))

    (define (escape s)
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length s))
            (list->string (reverse acc))
            (let ((c (string-ref s i)))
              (loop (+ i 1)
                    (cond ((char=? c #\") (append '(#\" #\\) acc))
                          ((char=? c #\\) (append '(#\\ #\\) acc))
                          ((char=? c #\newline) (append '(#\n #\\) acc))
                          (else (cons c acc))))))))))
