(import (scheme base) (scheme write) (mesthiri install) (mesthiri config) (mesthiri harness)
        (mesthiri proc) (mesthiri trigger) (mesthiri event) (scheme file))
(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (has? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                            ((string=? (substring s i (+ i m)) sub) #t)
                            (else (loop (+ i 1)))))))
(display "(mesthiri install)\n")

;; --- mesthiri never installs on itself ------------------------------------
(check "the canonical repository is refused" #t (refuses-self? "mesthiri/mesthiri"))
;; A fork is somebody else's copy and somebody else's decision.
(check "a fork is not refused" #f (refuses-self? "someone/mesthiri"))
(check "an unrelated repo is not refused" #f (refuses-self? "mesthiri/sandbox"))

;; --- the scaffolded config must be one mesthiri can actually read ---------
;; The guide calls this the scaffold contract, so it has to parse.
(define text (starter-config "Test Operator" "op@example.org" 111 222))
(define cfg (parse-config (read (open-input-string text)) "scaffold"))
(check "the scaffold parses with mesthiri's own reader" 1 (config-version cfg))
(check "the operator lands" "Test Operator" (config-operator-name cfg))
(check "both App ids land" '(111 222) (list (config-app cfg 'reader) (config-app cfg 'writer)))
(check "a provider is declared" '(main) (config-provider-names cfg))
(check "the rubric path points at the file install also writes"
       ".mesthiri/rubric.md" (config-rubric cfg))

;; Merging an install must not start opening pull requests.
(check "triage is scaffolded in dry-run" 'dry-run (stage-mode (config-stage cfg 'triage)))
(check "code is off" 'off (stage-mode (config-stage cfg 'code)))
(check "review is off" 'off (stage-mode (config-stage cfg 'review)))
(check "every non-triage stage is off"
       #t (let loop ((s '(prioritize code review fix retro)))
            (cond ((null? s) #t)
                  ((eq? (stage-mode (config-stage cfg (car s))) 'off) (loop (cdr s)))
                  (else #f))))
;; mesthiri must not be able to widen its own limits.
(check "the deny list protects .mesthiri itself"
       #t (and (member ".mesthiri/**" (config-deny-paths cfg)) #t))
(check "and the workflows directory"
       #t (and (member ".github/workflows/**" (config-deny-paths cfg)) #t))

;; Every trigger in the scaffold must survive the interpreter that will read
;; it. A predicate that is not in the vocabulary parses as a list and is
;; refused at run time, so the scaffold would install and then refuse itself.
;; This is how `findings-posted` was caught in the guide's sample.

;; `pull-request-updated` matches only the `synchronize` action — a push to
;; an existing branch. A review stage triggered on that alone never fires
;; when a pull request is OPENED, which is the moment a reviewer is most
;; wanted, and the name does not warn you: "updated" reads as "changed in
;; any way, opening included". The scaffold shipped exactly that, so every
;; adopter who turned review on would have got a reviewer that ignored new
;; pull requests. Caught by running the chain on the sandbox, where a live
;; review stage logged `no stage trigger matched this event` on a freshly
;; opened pull request.
(define (opened-pr)
  (make-event 'pull-request-opened "o/r" "alice" 1 '() #f "" 1 #f #f #t))

(check "the scaffolded review trigger fires on an OPENED pull request"
       #t (trigger-match? (stage-trigger (config-stage cfg 'review)) (opened-pr)))

(check "every scaffolded trigger validates"
       #t (let loop ((s '(triage prioritize code review fix retro)))
            (cond ((null? s) #t)
                  ((trigger-valid? (stage-trigger (config-stage cfg (car s))))
                   (loop (cdr s)))
                  (else (car s)))))

;; --- the rubric says the thing that actually matters ----------------------
(check "the starter rubric tells you to rewrite it" #t (has? (starter-rubric) "Rewrite it"))
(check "and says why a generic one fails"
       #t (has? (starter-rubric) "generic verdicts"))

;; A scaffolded harness has to read back through mesthiri's own reader, so
;; write it out and read it. The key is `budgets`, not `budget`: the singular
;; parses without complaint, returns #f, and silently disables the budget —
;; a scaffold bug whose only symptom is a run that never stops.
(define hdir "/tmp/mesthiri-scaffold-test/.mesthiri")
(proc-run (list "mkdir" "-p" (string-append hdir "/harness")))
(for-each
 (lambda (p)
   (call-with-output-file (string-append "/tmp/mesthiri-scaffold-test/" (car p))
     (lambda (o) (display (cdr p) o))))
 (list (assoc ".mesthiri/harness/triage.scm" (scaffold-files "N" "e@x" 1 2))
       (assoc ".mesthiri/harness/review.scm" (scaffold-files "N" "e@x" 1 2))))
(define hn (read-harness hdir 'triage))
(check "a scaffolded harness names a declared provider" 'main (harness-provider hn))
(check "and its model reads back" "deepseek-v4-flash" (harness-model hn))
(check "and its token budget is a number, not #f" #t (number? (harness-budget hn 'tokens)))
(check "every role the scaffold ships validates"
       #t (begin (validate-harnesses cfg hdir) #t))

;; --- the pull request a maintainer reads ---------------------------------
(define b (install-pr-body install-layers))
(check "it says merging starts nothing" #t (has? b "Merging it starts nothing"))
;; A maintainer who knows Actions security will stop at that trigger.
(check "pull_request_target is explained, not hidden" #t (has? b "pull_request_target"))
(check "including why the shim has no checkout" #t (has? b "never checks out"))
(check "it lists every layer" 5 (length install-layers))
(check "and warns runs fail until the secrets exist" #t (has? b "fail at authentication"))

;; --- the operator, which is what the sign-off names ------------------------
(define-syntax check2
  (syntax-rules ()
    ((_ name a b expr)
     (call-with-values (lambda () expr)
       (lambda (x y) (check name (list a b) (list x y)))))))
(check2 "a plain \"Name <email>\" splits" "Ada Lovelace" "ada@example.org"
        (split-operator "Ada Lovelace <ada@example.org>"))
;; The space before the bracket is not part of the name; a trailer with a
;; trailing space in it is not the trailer DCO checkers match.
(check2 "trailing space before the bracket is dropped" "Ada" "a@x"
        (split-operator "Ada   <a@x>"))
(check2 "anything after the closing bracket is ignored" "Ada" "a@x"
        (split-operator "Ada <a@x> (maintainer)"))

;; --- what uninstall removes, and what it must not ------------------------
(check "uninstall claims the config" #t (under-mesthiri? ".mesthiri/config.scm"))
(check "and nested harness files" #t (under-mesthiri? ".mesthiri/harness/triage.scm"))
(check "and the shim" #t (under-mesthiri? ".github/workflows/mesthiri.yml"))
;; A prefix match on ".mesthiri" without the slash would delete this.
(check "but not a lookalike sibling" #f (under-mesthiri? ".mesthiri-notes.md"))
;; Deleting somebody else's workflows would be the worst possible bug here.
(check "and no other workflow" #f (under-mesthiri? ".github/workflows/ci.yml"))
(check "and nothing at the root" #f (under-mesthiri? "README.md"))

;; --- the org preset fills blanks; it is not a different install ----------
(check "the preset ships a placeholder operator the org replaces"
       #t (and (assoc "operator-name" kaappi-preset) #t))

;; --- uninstall is honest about what it leaves ----------------------------
(define u (uninstall-pr-body))
(check "uninstall leaves the labels" #t (has? u "labels are left alone"))
(check "and does not revoke credentials for you" #t (has? u "presumptuous about a"))

;; --- the shim must not have two versions -----------------------------------
;; It also lives at templates/mesthiri.yml so it can be linted as YAML. Two
;; copies of anything in this project drift, so the drift fails here.
(define (slurp path)
  (call-with-input-file path
    (lambda (p) (let loop ((acc ""))
                  (let ((c (read-char p)))
                    (if (eof-object? c) acc (loop (string-append acc (string c)))))))))
(check "the embedded shim matches templates/mesthiri.yml byte for byte"
       #t (string=? shim-workflow (slurp "templates/mesthiri.yml")))
;; The rule the shim exists to hold. Asserted here, not just documented there.
(check "the shim contains no checkout at all" #f (has? shim-workflow "actions/checkout"))
(check "and uses pull_request_target" #t (has? shim-workflow "pull_request_target:"))
(check "and never plain pull_request as a trigger" #f (has? shim-workflow "\n  pull_request:"))

;; --- harnesses --------------------------------------------------------------
(check "a scaffolded harness pins the model exactly"
       #t (has? (starter-harness 'triage "deepseek-v4-flash") "deepseek-v4-flash"))
(check "and says why a floating alias is refused"
       #t (has? (starter-harness 'triage "x") "cannot reproduce"))
(check "every declared file layer has content"
       #t (let loop ((f (scaffold-files "N" "e@x" 1 2)))
            (cond ((null? f) #t)
                  ((> (string-length (cdar f)) 0) (loop (cdr f)))
                  (else #f))))
(check "the shim goes where GitHub will run it"
       #t (and (assoc ".github/workflows/mesthiri.yml" (scaffold-files "N" "e@x" 1 2)) #t))


(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
