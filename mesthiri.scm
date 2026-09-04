;;; mesthiri — entry point
;;;
;;; This is the only place that imports `kaappi-http`. Everything else takes a
;;; transport, so the rest of the codebase loads and tests without the C-FFI
;;; shared object built and installed.

(import (scheme base) (scheme write) (scheme read) (scheme time) (scheme char)
        (scheme process-context) (scheme file)
        (kaappi http) (kaappi json)
        (mesthiri config) (mesthiri jwt) (mesthiri forge) (mesthiri event)
        (mesthiri command) (mesthiri dispatch) (mesthiri log) (mesthiri proc)
        (mesthiri version) (mesthiri agent) (mesthiri sandbox)
        (mesthiri harness) (mesthiri triage) (mesthiri labels)
        (mesthiri install)
        (mesthiri sweep) (mesthiri prioritize) (mesthiri code)
        (mesthiri eligibility) (mesthiri git) (mesthiri review)
        (mesthiri fix) (mesthiri retro))

;; Adapt kaappi-http's response record to the transport contract forge wants.
(define (http-transport method url headers body)
  (let ((r (http-request method url headers body)))
    (values (response-status r) (response-headers r) (response-body r))))

(define (die . parts)
  (apply log-error parts)
  (exit 1))

(define (arg-after args flag)
  (let loop ((a args))
    (cond ((or (null? a) (null? (cdr a))) #f)
          ((string=? (car a) flag) (cadr a))
          (else (loop (cdr a))))))

;; --- whoami --------------------------------------------------------------
;;
;; Mints a real installation token and reports what it is. This exercises the
;; whole of M1 in one command — config for the App id and key path, jwt for
;; the RS256 signature through openssl, forge for auth, pagination and
;; rate-limit headers — and it is the first thing to run after registering an
;; App, because a mismatched id and key is the likeliest setup mistake.
(define (cmd-whoami args)
  (let* ((role     (string->symbol (or (arg-after args "--app") "reader")))
         (key-path (or (arg-after args "--key")
                       (get-environment-variable "MESTHIRI_KEY_FILE")))
         (cfg-path (or (arg-after args "--config") ".mesthiri/config.scm")))
    (if (not key-path)
        (die "no private key: pass --key <path> or set MESTHIRI_KEY_FILE"))
    (if (not (file-exists? key-path))
        (die "no such key file: " key-path))
    (let* ((cfg    (read-config cfg-path))
           (app-id (config-app cfg role)))
      (if (not app-id)
          (die "config has no App id for role `" role
               "` — expected (apps (reader <id>) (writer <id>))"))
      (log-context! "whoami" "-" "-")
      (let ((f (make-forge http-transport)))
        ;; 1. authenticate as the App itself
        (forge-auth! f (bearer (make-app-jwt (number->string app-id) key-path)))
        (let ((installs (forge-get-all f "/app/installations")))
          (if (null? installs)
              (die "App " (number->string app-id)
                   " is registered but installed on nothing"))
          (for-each
           (lambda (inst)
             (let ((id      (cdr (assoc "id" inst)))
                   (account (cdr (assoc "login" (cdr (assoc "account" inst))))))
               (display "installation ") (display id)
               (display "  account ") (display account) (newline)
               ;; 2. exchange for an installation token
               (let* ((tok-resp (forge-post
                                 f (string-append "/app/installations/"
                                                  (number->string id)
                                                  "/access_tokens")
                                 "{}"))
                      (token (cdr (assoc "token" tok-resp)))
                      (perms (cdr (assoc "permissions" tok-resp))))
                 (display "  permissions:") (newline)
                 (for-each (lambda (p)
                             (display "    ") (display (car p))
                             (display ": ") (display (cdr p)) (newline))
                           perms)
                 ;; 3. use it, and report the budget it reports back
                 (let ((g (make-forge http-transport)))
                   (forge-auth! g (bearer token))
                   (forge-get g "/rate_limit")
                   (display "  rate limit remaining: ")
                   (display (forge-rate-limit-remaining g)) (newline)))))
           installs))))))

;; --- the CI environment --------------------------------------------------

(define (env name) (get-environment-variable name))

;; The schedule tick, as "<weekday> <HH>:00" in UTC.
;;
;; Computed from epoch seconds rather than read from a date library, because
;; the shape mesthiri needs is small and the arithmetic is exact: epoch day 0
;; was a Thursday, so (days + 4) mod 7 gives Sunday = 0.
(define weekday-names
  '#("sunday" "monday" "tuesday" "wednesday" "thursday" "friday" "saturday"))

(define (utc-tick . opts)
  (let* ((secs (if (pair? opts) (car opts) (exact (floor (current-second)))))
         (days (quotient secs 86400))
         (hour (quotient (modulo secs 86400) 3600))
         (dow  (modulo (+ days 4) 7)))
    (string-append (vector-ref weekday-names dow)
                   " "
                   (if (< hour 10) "0" "")
                   (number->string hour)
                   ":00")))

(define (read-json-file path)
  (call-with-input-file path json-read))

;; The App private key arrives as a secret in the environment and `openssl`
;; needs a path, so it lands on disk for exactly as long as it takes to sign.
;; 0600 before the content is written, in the runner's temp directory, outside
;; anything the agent will later be able to see.
(define (with-key-file pem proc)
  (let ((path (string-append (or (env "RUNNER_TEMP") "/tmp")
                             "/mesthiri-key-"
                             (number->string (exact (floor (current-second))))
                             ".pem")))
    (call-with-output-file path (lambda (p) (write-string pem p)))
    (proc-run (list "chmod" "600" path))
    (let ((result (proc path)))
      (proc-run (list "rm" "-f" path))
      result)))

(define (authed-forge role)
  (let* ((cfg-path (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))
         (cfg      (read-config cfg-path))
         (app-id   (config-app cfg role))
         (pem      (env (if (eq? role 'writer) "MESTHIRI_WRITER_KEY" "MESTHIRI_READER_KEY"))))
    (if (not app-id) (die "config has no App id for role " role))
    (if (not pem) (die "no key in the environment for role " role))
    (let* ((jwt (with-key-file pem (lambda (path)
                                     (make-app-jwt (number->string app-id) path))))
           (f   (make-forge http-transport)))
      (forge-auth! f (bearer jwt))
      ;; Exchange the App JWT for an installation token scoped to this repo.
      (let* ((repo (or (env "MESTHIRI_REPO") (die "MESTHIRI_REPO is not set")))
             (inst (forge-get f (string-append "/repos/" repo "/installation")))
             (id   (cdr (assoc "id" inst)))
             (tok  (cdr (assoc "token"
                               (forge-post f (string-append "/app/installations/"
                                                            (number->string id)
                                                            "/access_tokens")
                                           "{}")))))
        ;; Actions masks secrets it already knows about; a token minted at
        ;; runtime is not one, and on a public repository the log is public.
        (display (string-append "::add-mask::" tok)) (newline)
        (let ((g (make-forge http-transport)))
          (forge-auth! g (bearer tok))
          ;; The token comes back too. It used to be minted and dropped, so
          ;; MESTHIRI_WRITER_TOKEN — which the code stage read to clone and
          ;; push with — was never set by anything, and the push had no
          ;; credential at all.
          (values g cfg tok))))))

;; --- idempotency ---------------------------------------------------------
;;
;; With no database, "have I already acted on this?" is a question for the
;; forge: mesthiri leaves an HTML marker in every comment it posts, and finds
;; it again by looking.
;; The marker itself lives in (mesthiri event), because dispatch needs it too
;; — it is how a comment mesthiri wrote is recognised and skipped rather than
;; dispatched. Two definitions would drift and the symptom would be a run per
;; comment coming back.
(define (marker event) (event-marker event))

(define (contains? s sub)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length sub)))
         (let loop ((i 0))
           (cond ((> (+ i m) n) #f)
                 ((string=? (substring s i (+ i m)) sub) #t)
                 (else (loop (+ i 1))))))))

(define (make-already-handled? forge)
  (lambda (event stage)
    (and (event-number event)
         (guard (e ((forge-error? e) #f))
           (let ((comments (forge-get-all
                            forge (string-append "/repos/" (event-repo event)
                                                 "/issues/"
                                                 (number->string (event-number event))
                                                 "/comments"))))
             (let loop ((c comments))
               (cond ((null? c) #f)
                     ((contains? (let ((b (assoc "body" (car c)))) (and b (cdr b)))
                                 (marker event)) #t)
                     (else (loop (cdr c))))))))))

(define (post-comment forge event text)
  (forge-post forge
              (string-append "/repos/" (event-repo event) "/issues/"
                             (number->string (event-number event)) "/comments")
              (json-write-string (list (cons "body" (string-append text "\n\n" (marker event)))))))

;; --- dispatch ------------------------------------------------------------

(define (load-event)
  (let ((name (or (env "MESTHIRI_EVENT_NAME") (die "MESTHIRI_EVENT_NAME is not set")))
        (path (or (env "MESTHIRI_EVENT_PATH") (die "MESTHIRI_EVENT_PATH is not set"))))
    (if (not (file-exists? path)) (die "no event payload at " path))
    (normalize-event name (read-json-file path) (utc-tick))))

;; M2 has no stages. This placeholder proves the whole path — parse,
;; authorize, mode, idempotency, handler — and is replaced by the real triage
;; stage in M4. It is not a separate demo command precisely so that the demo
;; exercises the shipped path rather than a bypass of it.
;; The triage stage, replacing M2's probe. The agent is spawned by agent.sld
;; and nothing else; this hands triage a runner rather than a process.
(define (fetch-rubric forge repo path)
  ;; The verdict records the rubric's commit SHA, so a rubric change upstream
  ;; reads as a behaviour change rather than a mystery.
  (guard (e ((forge-error? e) (values #f #f)))
    (let* ((r (forge-get forge (string-append "/repos/" repo "/contents/" path)))
           (sha (let ((x (assoc "sha" r))) (and x (cdr x))))
           (enc (let ((x (assoc "content" r))) (and x (cdr x)))))
      (values enc sha))))

(define (agent-runner config harness provider-name model workdir trace event)
  (lambda (prompt)
    (let* ((provider (config-provider config provider-name))
           ;; HOME and the stderr log go BESIDE the workdir, never inside it.
           ;; The workdir is the clone the code stage commits with `git add
           ;; -A`, so anything written there ends up in the pull request —
           ;; and untracked files are invisible to a diff-based deny-paths
           ;; check, so nothing would have objected. A local run put pi's home
           ;; and a stderr log into a repository before this was noticed.
           ;;
           ;; It is still a directory mesthiri controls, which is the other
           ;; half of the point: the agent gets the provider catalogue written
           ;; for it and none of an operator's real pi configuration —
           ;; extensions, logins, sessions are simply not there.
           (scratch (string-append (or (env "RUNNER_TEMP") "/tmp")
                                   "/mesthiri-agent-" (number->string (event-id event))))
           (home (string-append scratch "/home"))
           (stderr-path (string-append scratch "/agent-stderr.log"))
           (argv (agent-argv harness provider-name model))
           (wrapped (or (sandbox-wrap argv workdir
                                      (string-append workdir "/secrets")
                                      scratch)
                        argv)))
      ;; Fail closed in CI. A warning was the old behaviour and it was wrong:
      ;; the run continued, the agent was uncontained, and the only trace was
      ;; one line in a log nobody reads on a green run. Outside CI — someone
      ;; driving `agent-smoke` on a laptop — a warning is right, because there
      ;; is no namespace sandbox on macOS at all and refusing would make the
      ;; command useless rather than safe.
      (if (not (sandbox-available?))
          (let ((why (sandbox-unavailable-reason)))
            (if (env "CI")
                (die "refusing to run the agent uncontained: " why
                     "\n       The runner must install bubblewrap and permit"
                     " unprivileged user\n       namespaces; the reusable"
                     " workflow does both.")
                (log-warn "no namespace sandbox on this host (" why
                          "): the agent is UNCONTAINED"))))
      (write-agent-home! home (render-models-json
                               config (list (cons provider-name model))))
      ;; The one secret the agent can see, because it cannot call a model
      ;; without it. Everything else the job holds — both App keys and the
      ;; forge token — is left behind by `agent-env`, which builds the
      ;; child's environment rather than passing the job's along.
      (let* ((secret (and provider
                          (env (symbol->string (provider-secret provider)))))
             (rec (run-agent wrapped prompt 1200
                             (list (cons 'tokens (harness-budget harness 'tokens))
                                   (cons 'turns  (harness-budget harness 'turns)))
                             trace
                             (agent-env provider secret home)
                             stderr-path
                             workdir)))
        (log-info "agent " (run-record-outcome rec)
                  " turns=" (run-record-turns rec)
                  " tokens=" (run-record-tokens rec)
                  " model=" (or (run-record-model rec) "-"))
        (if (not (eq? (run-record-outcome rec) 'settled))
            (die "agent run did not settle: " (run-record-outcome rec)
                 (agent-failure-detail rec stderr-path)))
        ;; The agent's reply is the last assistant message. The object is
        ;; extracted rather than assumed: a schema in the prompt does not buy
        ;; a bare JSON reply, and half of the first real verdicts arrived
        ;; wrapped in prose or a ```json fence. Validated by the stage against
        ;; its schema after this.
        (agent-json rec)))))

;; Why a run ended, in the terms a maintainer can act on. An outcome alone
;; sends someone to the workflow log; `refused` carries pi's own sentence,
;; and anything else is worth checking stderr for, because pi is quiet when
;; it works.
(define (agent-failure-detail rec stderr-path)
  (case (run-record-outcome rec)
    ((refused) (string-append " — pi refused it: " (or (run-record-text rec) "")))
    ;; The provider answered, and what it answered was a complaint. Its own
    ;; words: an expired key, a rate limit and an empty account are three
    ;; different problems with three different fixes.
    ((model-error)
     (string-append " — the model provider rejected the request: "
                    (or (run-record-text rec) "")))
    ((deadline) " — the wall-clock deadline killed it; the model may be hanging")
    (else (let ((tail (stderr-tail stderr-path 400)))
            (if (> (string-length tail) 0)
                (string-append " — stderr: " tail)
                " — nothing on stderr; check the provider and model names")))))

(define (prioritize-handler forge config event cmd)
  (let* ((repo (event-repo event))
         (mode (stage-mode (config-stage config 'prioritize)))
         (promoted (prioritize! forge config repo mode)))
    (log-info "prioritize " mode ": " (length promoted) " issue(s) promoted")))

;; The code stage. The gates run in cost order and the agent is the last
;; thing reached: an ineligible issue costs no clone and no tokens.
(define (code-handler forge config event cmd)
  (let* ((repo (event-repo event))
         (st (config-stage config 'code))
         (mode (stage-mode st))
         (number (event-number event))
         (by-command? (and cmd #t))
         (issue (forge-get forge (string-append "/repos/" repo "/issues/"
                                                (number->string number))))
         (tier (issue-tier forge repo number)))
    (cond
     ((eq? mode 'off) (log-info "code stage is off"))
     ((not (tier-allowed? tier (stage-max-tier st) by-command?))
      (post-comment forge event
                    (eligibility-refusal 'tier (number->string (or tier 0))))
      (log-info (if tier
                    (string-append "refused: tier " (number->string tier)
                                   " needs a human")
                    (string-append "refused: issue " (number->string number)
                                   " has no mesthiri verdict, so its tier is"
                                   " unknown — run /triage on it first"))))
     (else (run-code-stage forge config event repo number issue mode)))))

;; The tier lives in the verdict, not a label — so it is read back from
;; mesthiri's own triage comment rather than from the issue's labels.
(define (issue-tier forge repo number)
  (guard (e (#t #f))
    (let loop ((cs (forge-get-all forge
                     (string-append "/repos/" repo "/issues/"
                                    (number->string number) "/comments"))))
      (cond ((null? cs) #f)
            (else
             (let ((b (let ((x (assoc "body" (car cs)))) (and x (cdr x)))))
               (or (parse-tier b) (loop (cdr cs)))))))))

(define (parse-tier body)
  (and (string? body)
       (let ((i (find-sub body "**Intent tier ")))
         (and i (let ((c (string-ref body (+ i 14))))
                  (and (char-numeric? c) (- (char->integer c) 48)))))))

(define (find-sub s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                            ((string=? (substring s i (+ i m)) sub) i)
                            (else (loop (+ i 1)))))))

;; Set by dispatch so the stage knows whether a human asked by name.

;; The stage proper. Note the order: clone, agent, THEN the diff check and
;; only then the push. The agent never holds the token and never pushes.
(define (run-code-stage forge config event repo number issue mode)
  (let* ((workdir (string-append (or (env "RUNNER_TEMP") "/tmp")
                                 "/mesthiri-work-" (number->string number)))
         (hn (read-harness ".mesthiri" 'code))
         (pname (or (harness-provider hn) (car (config-provider-names config))))
         (model (harness-model hn))
         (trace (string-append (or (env "RUNNER_TEMP") "/tmp")
                               "/mesthiri-trace-code-" (number->string number) ".jsonl"))
         ;; The writer App, minted here rather than read from an environment
         ;; variable nothing sets. Contents and pull-requests write live on
         ;; this App and nowhere else; the reader that dispatch runs on cannot
         ;; push or open anything.
         (wf (call-with-values (lambda () (authed-forge 'writer))
                               (lambda (f c t) (cons f t))))
         (writer (car wf))
         (token-file (string-append (or (env "RUNNER_TEMP") "/tmp")
                                    "/mesthiri-push-" (number->string number))))
    (proc-run (list "rm" "-rf" workdir))
    (call-with-output-file token-file (lambda (p) (write-string (cdr wf) p)))
    (proc-run (list "chmod" "600" token-file))
    (git-clone (string-append "https://github.com/" repo) workdir token-file)
    (git-branch workdir (branch-name-for number))
    (let* ((title (let ((t (assoc "title" issue))) (and t (cdr t))))
           (body  (let ((b (assoc "body" issue))) (and b (cdr b))))
           (run (agent-runner config hn pname model workdir trace event))
           (result (guard (e (#t (list (cons "summary" "the agent run failed")
                                       (cons "tests_pass" #f))))
                     (run (code-prompt title body (config-test-command config)))))
           (ok (guard (e ((output-error? e)
                          (list (cons "summary" (output-error-message e))
                                (cons "tests_pass" #f))))
                 (validate-output result implementation-schema)))
           (green (cdr (assoc "tests_pass" ok)))
           (summary (cdr (assoc "summary" ok))))
      (cond
       ((not green)
        ;; Failure honesty: say where it got to on the issue rather than
        ;; opening a pull request nobody can merge.
        (post-comment forge event
                      (failure-comment "The tests did not reach green." summary))
        (log-info "code: not green, reported on the issue"))
       ((not (git-has-changes? workdir))
        (post-comment forge event
                      (failure-comment "The agent reported success but changed nothing." #f))
        (log-info "code: no changes"))
       (else
        (let* ((changed (git-changed-files workdir))
               (verdict (check-diff changed (config-deny-paths config))))
          (cond
           ((string? verdict)
            ;; Caught on the finished diff — the only check that can see what
            ;; the agent actually touched.
            (post-comment forge event verdict)
            (log-warn "code: refused, diff touched a denied path"))
           ((eq? mode 'dry-run)
            (log-info "code: would open a PR with " (length changed)
                      " file(s) changed [dry-run]"))
           (else
            (git-add-all workdir)
            (git-commit workdir
                        (string-append "Fix #" (number->string number))
                        (string-append summary "\n\n"
                                       (trailers (config-operator-name config)
                                                 (config-operator-email config)
                                                 "mesthiri[bot] <mesthiri@users.noreply.github.com>"
                                                 mesthiri-version "pi"
                                                 (or (config-agent-version config) "?")
                                                 pname (or model "?")
                                                 (or (env "MESTHIRI_RUN_URL") "-")))
                        (config-operator-name config)
                        (config-operator-email config))
            (git-push workdir (branch-name-for number) token-file)
            ;; The writer opens the pull request. Dispatch runs on the reader,
            ;; which has no pull-requests write and would be refused here.
            (forge-post writer (string-append "/repos/" repo "/pulls")
                        (json-write-string
                         (list (cons "title" (string-append "Fix #" (number->string number)))
                               (cons "head" (branch-name-for number))
                               (cons "base" "main")
                               (cons "body" (pr-body number summary
                                                     (or (env "MESTHIRI_RUN_URL") "-"))))))
            (proc-run (list "rm" "-f" token-file))
            (log-info "code: pull request opened")))))))))

;; Review runs on pull requests mesthiri opened, plus an explicit /review.
;; An explicit /review on a foreign pull request fetches the diff through the
;; API into a read-only clone the agent cannot push from — the same sandbox
;; minus any write path.
(define (review-handler forge config event cmd)
  (let* ((repo (event-repo event))
         (number (event-number event))
         (mode (stage-mode (config-stage config 'review)))
         (pr (forge-get forge (string-append "/repos/" repo "/pulls/"
                                             (number->string number))))
         (by-command? (and cmd #t)))
    (cond
     ((eq? mode 'off) (log-info "review stage is off"))
     ((and (not (mesthiri-authored? pr)) (not by-command?))
      ;; Not a refusal to comment about: nobody asked.
      (log-info "review: not a mesthiri pull request and no /review; skipping"))
     (else
      (let* ((hn (read-harness ".mesthiri" 'review))
             (pname (or (harness-provider hn) (car (config-provider-names config))))
             (model (harness-model hn))
             (workdir (or (env "RUNNER_TEMP") "/tmp"))
             (diff (forge-request-diff forge repo number))
             ;; Review left no trace where every other stage writes one, so
             ;; its reasoning was unauditable and retro could not read it —
             ;; and "no findings" was indistinguishable from "did not run".
             (trace (string-append (or (env "RUNNER_TEMP") "/tmp")
                                   "/mesthiri-trace-review-"
                                   (number->string number) ".jsonl"))
             (run (agent-runner config hn pname model workdir trace event)))
        (for-each
         (lambda (dim)
           (guard (e (#t (log-warn "review pass " dim " failed; continuing")))
             (let* ((raw (validate-output (run (dimension-prompt dim diff ""))
                                          finding-schema))
                    (tier (cdr (assoc "tier" raw)))
                    (found (cdr (assoc "findings" raw)))
                    ;; Each finding faces a separate attempt to refute it.
                    (kept (filter-surviving run diff found)))
               (if (eq? mode 'live)
                   (post-comment forge event
                                 (findings->comment dim kept tier tier))
                   (log-info "review " dim ": " (length kept)
                             " finding(s) [dry-run]")))))
         review-dimensions))))))

(define (filter-surviving run diff findings)
  (let loop ((f findings) (acc '()))
    (cond ((null? f) (reverse acc))
          (else
           (let ((r (guard (e (#t '(("refuted" . #f))))
                      (run (refutation-prompt (car f) diff)))))
             (loop (cdr f) (if (survives-refutation? r) (cons (car f) acc) acc)))))))

(define (forge-request-diff forge repo number)
  (guard (e (#t ""))
    (let-values (((s h b) (forge-request forge "GET"
                            (string-append "/repos/" repo "/pulls/"
                                           (number->string number)))))
      b)))

;; Retro reads what CI already keeps — completed runs and the traces they
;; uploaded — and files proposals on this repository. It never acts on them:
;; mesthiri is not installed on its own repository, so a proposal about
;; mesthiri reaches it through a human who read one.
(define (retro-handler forge config event cmd)
  (let* ((repo (event-repo event))
         (mode (stage-mode (config-stage config 'retro)))
         (runs (recent-runs forge repo))
         (obs (analyze-runs runs))
         (open (guard (e (#t '()))
                 (forge-get-all forge (string-append "/repos/" repo
                                                     "/issues?state=open&per_page=100")))))
    (log-info "retro: " (length runs) " runs, " (length obs) " observation(s)")
    (for-each
     (lambda (o)
       (cond
        ((already-filed? open o)
         (log-info "retro: already filed — " (observation->title o)))
        ((eq? mode 'live)
         (forge-post forge (string-append "/repos/" repo "/issues")
                     (json-write-string
                      (list (cons "title" (observation->title o))
                            (cons "body" (observation->body o retro-window)))))
         (log-info "retro: filed — " (observation->title o)))
        (else
         (log-info "retro: would file — " (observation->title o) " [dry-run]"))))
     obs)))

;; Run summaries from the workflow-run API. The stage and outcome are not
;; fields GitHub keeps, so they come from the run name mesthiri sets — a
;; deliberate limitation recorded rather than papered over: retro sees what
;; CI kept, and CI keeps runs, not mesthiri's internal outcomes.
(define (recent-runs forge repo)
  (guard (e (#t '()))
    (let* ((r (forge-get forge
                (string-append "/repos/" repo
                               "/actions/runs?per_page="
                               (number->string retro-window))))
           (rs (let ((x (assoc "workflow_runs" r))) (if x (cdr x) '()))))
      (map (lambda (run)
             (list (cons "conclusion" (or (assoc-cdr run "conclusion") ""))
                   (cons "stage" (stage-from-name (assoc-cdr run "name")))
                   (cons "outcome" "")))
           rs))))

(define (assoc-cdr o k) (let ((x (assoc k o))) (and x (cdr x))))

(define (stage-from-name name)
  (if (string? name)
      (let loop ((stages '("triage" "prioritize" "code" "review" "fix" "retro")))
        (cond ((null? stages) "unknown")
              ((find-sub name (car stages)) (car stages))
              (else (loop (cdr stages)))))
      "unknown"))

(define (triage-handler forge config event cmd)
  (let* ((repo (event-repo event))
         (st (config-stage config 'triage))
         (mode (stage-mode st))
         (hn (read-harness ".mesthiri" 'triage))
         (pname (or (harness-provider hn) (car (config-provider-names config))))
         (model (harness-model hn))
         ;; Triage is asked to check an issue's claims against the code, so
         ;; it needs the code. It used to get RUNNER_TEMP — an empty
         ;; directory — and the first live run shows the agent working that
         ;; out for itself: "the working directory doesn't have the
         ;; repository code. Let me look around", then two turns hunting the
         ;; filesystem before it found the job's checkout. Two of twelve
         ;; turns, spent on a question mesthiri could have answered.
         ;;
         ;; It gets its own clone rather than the job's checkout. The sandbox
         ;; binds the workdir writable, and the job's checkout is where
         ;; mesthiri itself reads config.scm and the rubric from — an agent
         ;; able to edit those mid-run could rewrite the rules it is being
         ;; judged by.
         (workdir (string-append (or (env "RUNNER_TEMP") "/tmp")
                                 "/mesthiri-triage-"
                                 (number->string (event-number event))))
         (trace (string-append (or (env "RUNNER_TEMP") "/tmp")
                               "/mesthiri-trace-"
                               (number->string (event-id event)) ".jsonl")))
    (proc-run (list "rm" "-rf" workdir))
    ;; #f clones anonymously, which is right for a public repository and is
    ;; what the code stage already does with its own token variable.
    (git-clone (string-append "https://github.com/" repo) workdir
               (env "MESTHIRI_READER_TOKEN"))
    (let-values (((rubric sha) (fetch-rubric forge repo (config-rubric config))))
      (let ((issue (forge-get forge (string-append "/repos/" repo "/issues/"
                                                   (number->string (event-number event))))))
        (triage-issue forge config repo issue rubric sha mode
                      (agent-runner config hn pname model workdir trace event))))))

(define (cmd-dispatch args)
  (let ((ev (load-event)))
    (log-context! "dispatch" (event-repo ev) (env "MESTHIRI_RUN_URL"))
    (let-values (((forge cfg tok) (authed-forge 'reader)))
      (let* ((handlers (list (cons 'triage triage-handler)
                             (cons 'prioritize prioritize-handler)
                             (cons 'code code-handler)
                             (cons 'review review-handler)
                             (cons 'retro retro-handler)))
             (d (dispatch forge cfg ev handlers (make-already-handled? forge))))
        (log-info "outcome=" (decision-outcome d)
                  " stage=" (or (decision-stage d) "-")
                  (if (decision-reason d) (string-append " reason=" (decision-reason d)) ""))
        ;; An unauthorized command gets an explanation, not silence. Only for
        ;; commands: nobody typed a label expecting a reply.
        (if (and (eq? (decision-outcome d) 'unauthorized) (decision-command d))
            (post-comment forge ev (string-append "Not run: " (decision-reason d) ".")))
        (if (eq? (decision-outcome d) 'stage-off)
            (if (decision-command d)
                (post-comment forge ev (string-append "Not run: " (decision-reason d) "."))))))))

(define (cmd-explain args)
  (let ((ev (load-event))
        (cfg (read-config (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))))
    (explain-event cfg ev)))

;; --- the model, called directly ------------------------------------------
;;
;; Used by `try` only. It calls a model over HTTP with no agent subprocess:
;; verifying an issue's claims needs tools against attacker-writable text,
;; which belongs in a sandbox on a runner rather than on someone's laptop.
;; So `try` answers the narrower question honestly — does this rubric produce
;; sane priorities — and says in its output that claims are unverified.
(define (model-call provider model prompt)
  (let* ((key (or (env (symbol->string (provider-key-env provider)))
                  (die "no key in the environment: "
                       (symbol->string (provider-key-env provider)))))
         (url (string-append (trim-slash (provider-endpoint provider))
                             "/chat/completions"))
         (body (json-write-string
                (list (cons "model" model)
                      (cons "messages"
                            (list (list (cons "role" "user")
                                        (cons "content" prompt))))))))
    (let-values (((status headers resp) (http-transport "POST" url
                    (list (cons "Content-Type" "application/json")
                          (cons "Authorization" (string-append "Bearer " key)))
                    body)))
      (if (>= status 400) (die "model call failed with " status ": " resp))
      (let* ((parsed (json-read-string resp))
             (choices (cdr (assoc "choices" parsed)))
             (msg (cdr (assoc "message" (car choices)))))
        (cdr (assoc "content" msg))))))

(define (trim-slash s)
  (let ((n (string-length s)))
    (if (and (> n 0) (char=? (string-ref s (- n 1)) #\/))
        (substring s 0 (- n 1)) s)))

;; --- try ------------------------------------------------------------------
(define (cmd-try args)
  (let* ((repo (if (pair? args) (car args) (die "usage: mesthiri try <owner/repo>")))
         (rubric-path (or (arg-after args "--rubric") ".mesthiri/rubric.md"))
         (cfg (read-config (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm")))
         (pat (or (env "GITHUB_TOKEN") (env "GH_TOKEN")
                  (die "set GITHUB_TOKEN: try reads issues with a personal token")))
         (hn (read-harness ".mesthiri" 'triage))
         (pname (or (harness-provider hn) (car (config-provider-names cfg))))
         (provider (config-provider cfg pname))
         (model (or (harness-model hn) (die "no model in the triage harness")))
         (f (make-forge http-transport)))
    (forge-auth! f (bearer pat))
    (display "mesthiri try — rubric only, nothing written, no checkout\n")
    (display "  provider ") (display pname)
    (display "  model ") (display model) (newline) (newline)
    (let* ((rubric (guard (e (#t "(no rubric found)"))
                     (call-with-input-file rubric-path
                       (lambda (p) (let loop ((acc ""))
                                     (let ((l (read-line p)))
                                       (if (eof-object? l) acc
                                           (loop (string-append acc l "\n")))))))))
           (issues (untriaged-issues f repo)))
      (for-each
       (lambda (i)
         (let* ((n (cdr (assoc "number" i)))
                (title (let ((t (assoc "title" i))) (and t (cdr t))))
                (body  (let ((b (assoc "body" i))) (and b (cdr b))))
                (out (model-call provider model
                                 (triage-prompt rubric title body))))
           (display "#") (display n) (display "  ") (display title) (newline)
           (display "      ") (display out) (newline)
           (display "      (claims NOT verified — try does not check out the code)")
           (newline) (newline)))
       issues)
      (display (number->string (length issues)))
      (display " issues read, 0 writes.\n"))))

;; --- agent-smoke ---------------------------------------------------------
;;
;; Runs a trivial task through the real agent path and prints the run record.
;; `--prove-sandbox` does something different and more useful: it asserts the
;; boundary rather than describing it. A sandbox nobody has tested is a
;; paragraph, not a control.

(define (probe-fails? argv workdir secrets)
  ;; True when the command could NOT do the thing — which is the passing case.
  (let ((wrapped (sandbox-wrap argv workdir secrets)))
    (and wrapped
         (guard (e (#t #t))
           (proc-run wrapped)
           #f))))

(define (cmd-agent-smoke args)
  (let* ((prove (and (pair? args) (string=? (car args) "--prove-sandbox")))
         (cfg-path (or (env "MESTHIRI_CONFIG") ".mesthiri/config.scm"))
         (cfg (read-config cfg-path))
         (workdir (or (env "RUNNER_TEMP") "/tmp"))
         (secrets (string-append workdir "/mesthiri-secrets")))
    (log-context! "agent-smoke" (or (env "MESTHIRI_REPO") "-") (env "MESTHIRI_RUN_URL"))

    (display "sandbox: ")
    (if (sandbox-available?)
        (display "available\n")
        (begin (display "UNAVAILABLE — ")
               (display (sandbox-unavailable-reason))
               (newline)
               ;; Loud, per design.md: a security fallback that fails silently
               ;; is worse than none.
               (log-warn "the agent would run UNCONTAINED on this host")))

    (display "egress allowlist (derived from provider endpoints):\n")
    (for-each (lambda (h) (display "  ") (display h) (newline))
              (allowed-hosts cfg '()))
    (display "  (note: the forge is deliberately absent)\n")

    (if prove
        (begin
          (display "\nproving the boundary\n")
          (if (not (sandbox-available?))
              (die "cannot prove a sandbox that is not available"))
          (let ((r1 (probe-fails? (list "cat" (string-append secrets "/key.pem"))
                                  workdir secrets))
                (r2 (probe-fails? (list "touch" "/etc/mesthiri-probe")
                                  workdir secrets)))
            (display "  cannot read the secrets directory: ")
            (display (if r1 "yes" "NO — BOUNDARY BROKEN")) (newline)
            (display "  cannot write outside the clone:     ")
            (display (if r2 "yes" "NO — BOUNDARY BROKEN")) (newline)
            (if (not (and r1 r2)) (die "sandbox boundary assertions failed"))
            (display "\nboundary holds.\n")))
        (display "\n(pass --prove-sandbox to assert the boundary)\n"))))

;; --- install / uninstall --------------------------------------------------
;;
;; Installing runs on a person's machine with a personal token, not on a
;; runner with an App token: the App is not installed on the repository yet,
;; so there is no App credential to use. That is the honest shape anyway —
;; enrolling a repository is a decision someone makes, and it should carry
;; their name.
;;
;; Every file change arrives as a pull request. mesthiri does not push to a
;; default branch to install itself; maintainers read the shim before it can
;; run, which is the only reason it is worth keeping the shim small.

(define (install-token)
  (or (env "GITHUB_TOKEN") (env "GH_TOKEN")
      (die "set GITHUB_TOKEN: install uses your own token, not an App —\n"
           "       the App is not installed on that repository yet.")))

(define (api-get f path)      (forge-get f path))
(define (api-post f path obj) (forge-post f path (json-write-string obj)))
(define (jref o k)            (let ((e (assoc k o))) (and e (cdr e))))

(define (default-branch f repo)
  (or (jref (api-get f (string-append "/repos/" repo)) "default_branch")
      (die "cannot read " repo " — check the name and your token's access")))

(define (branch-head f repo branch)
  (jref (jref (api-get f (string-append "/repos/" repo "/git/ref/heads/" branch))
              "object")
        "sha"))

(define (commit-tree f repo sha)
  (jref (jref (api-get f (string-append "/repos/" repo "/git/commits/" sha)) "tree") "sha"))

(define (make-blob f repo text)
  (jref (api-post f (string-append "/repos/" repo "/git/blobs")
                  (list (cons "content" text) (cons "encoding" "utf-8")))
        "sha"))

;; entries: ((path . blob-sha-or-#f) ...). #f deletes the path, which is how
;; uninstall is the same code path as install run backwards.
(define (make-tree f repo base entries)
  (jref (api-post
         f (string-append "/repos/" repo "/git/trees")
         (list (cons "base_tree" base)
               (cons "tree"
                     (list->vector
                      (map (lambda (e)
                             (list (cons "path" (car e))
                                   (cons "mode" "100644")
                                   (cons "type" "blob")
                                   (cons "sha" (or (cdr e) json-null))))
                           entries)))))
        "sha"))

(define (make-commit f repo message tree parent)
  (jref (api-post f (string-append "/repos/" repo "/git/commits")
                  (list (cons "message" message)
                        (cons "tree" tree)
                        (cons "parents" (vector parent))))
        "sha"))

(define (make-branch! f repo name sha)
  ;; Idempotent by deletion: a leftover branch from an abandoned attempt would
  ;; otherwise make the second install fail with "reference already exists",
  ;; which reads as a permissions problem and is not one.
  (guard (e ((forge-error? e) #t))
    (forge-request f 'DELETE (string-append "/repos/" repo "/git/refs/heads/" name)))
  (api-post f (string-append "/repos/" repo "/git/refs")
            (list (cons "ref" (string-append "refs/heads/" name)) (cons "sha" sha))))

(define (open-pr! f repo head base title body)
  (jref (api-post f (string-append "/repos/" repo "/pulls")
                  (list (cons "title" title) (cons "head" head)
                        (cons "base" base) (cons "body" body)))
        "html_url"))

;; A commit made through the API gets no trailers of its own, so the sign-off
;; is written here. It names the operator because that is what a sign-off is:
;; a person asserting where a contribution came from.
(define (signed message operator-name operator-email)
  (string-append message "\n\nSigned-off-by: " operator-name
                 " <" operator-email ">\n"))

(define (path-present? f repo path)
  (guard (e ((forge-error? e) #f))
    (api-get f (string-append "/repos/" repo "/contents/" path)) #t))

(define (repo-tree-paths f repo sha)
  (let ((t (api-get f (string-append "/repos/" repo "/git/trees/" sha "?recursive=1"))))
    (map (lambda (e) (jref e "path"))
         (vector->list (or (jref t "tree") #())))))


(define (cmd-install args)
  (let* ((repo (if (and (pair? args) (not (char=? (string-ref (car args) 0) #\-)))
                   (car args)
                   (die "usage: mesthiri install <owner/repo> [--operator \"Name <email>\"]")))
         (preset (and (arg-after args "--preset") kaappi-preset))
         (op (or (arg-after args "--operator")
                 (and preset (string-append (cdr (assoc "operator-name" preset))
                                            " <" (cdr (assoc "operator-email" preset)) ">"))
                 (die "pass --operator \"Your Name <you@example.org>\" — the\n"
                      "       scaffolded config signs mesthiri's commits with it.")))
         (reader (string->number (or (arg-after args "--reader") "0")))
         (writer (string->number (or (arg-after args "--writer") "0")))
         (f (make-forge http-transport)))
    ;; mesthiri is never installed on the repository that decides what
    ;; mesthiri may do. A fork is somebody else's copy and is unaffected.
    (if (refuses-self? repo)
        (die "refusing to install on " repo ": an orchestrator that can edit\n"
             "       the code deciding its own limits has no limits."))
    (forge-auth! f (bearer (install-token)))
    (if (member "--status" args)
        (install-status f repo)
        (do-install f repo op reader writer))))


(define (install-status f repo)
  (display "mesthiri install status — ") (display repo) (newline)
  (for-each
   (lambda (l)
     (let* ((name (layer-name l))
            (present
             (if (eq? name 'labels)
                 (let ((have (map (lambda (x) (jref x "name"))
                                  (forge-get-all f (string-append "/repos/" repo "/labels")))))
                   (let loop ((w workflow-labels))
                     (cond ((null? w) #t)
                           ((member (car w) have) (loop (cdr w)))
                           (else #f))))
                 (path-present?
                  f repo (case name
                           ((config)    ".mesthiri/config.scm")
                           ((rubric)    ".mesthiri/rubric.md")
                           ((harnesses) ".mesthiri/harness/triage.scm")
                           (else        ".github/workflows/mesthiri.yml"))))))
       (display (if present "  installed  " "  missing    "))
       (display name) (newline)))
   install-layers))

(define (do-install f repo op reader writer)
  (let*-values (((oname omail) (split-operator op)))
    (let* ((base   (default-branch f repo))
           (head   (branch-head f repo base))
           (btree  (commit-tree f repo head))
           (files  (scaffold-files oname omail reader writer)))
      (display "installing mesthiri on ") (display repo)
      (display " (base ") (display base) (display ")\n")
      ;; The labels layer is applied directly, not through the pull request:
      ;; labels are not files, and creating one that already exists is a
      ;; no-op, so this stays idempotent.
      (ensure-labels! f repo)
      (display "  labels      created\n")
      (let* ((entries (map (lambda (p) (cons (car p) (make-blob f repo (cdr p)))) files))
             (tree    (make-tree f repo btree entries))
             (commit  (make-commit f repo
                                   (signed "Install mesthiri\n\nEvery stage off except triage in dry-run."
                                           oname omail)
                                   tree head)))
        (make-branch! f repo "mesthiri/install" commit)
        (for-each (lambda (p) (display "  added       ") (display (car p)) (newline)) files)
        (let ((url (open-pr! f repo "mesthiri/install" base
                             "Install mesthiri" (install-pr-body install-layers))))
          (display "\n") (display url) (newline)
          (display "Merging it starts nothing: triage is in dry-run and every\n")
          (display "other stage is off. Add the App keys as repository secrets\n")
          (display "before turning anything on.\n"))))))

(define (cmd-uninstall args)
  (let* ((repo (if (pair? args) (car args)
                   (die "usage: mesthiri uninstall <owner/repo>")))
         (op (or (arg-after args "--operator")
                 (die "pass --operator \"Your Name <you@example.org>\"")))
         (f (make-forge http-transport)))
    (forge-auth! f (bearer (install-token)))
    (let*-values (((oname omail) (split-operator op)))
      (let* ((base  (default-branch f repo))
             (head  (branch-head f repo base))
             (btree (commit-tree f repo head))
             (gone  (let loop ((p (repo-tree-paths f repo head)) (acc '()))
                      (cond ((null? p) (reverse acc))
                            ((under-mesthiri? (car p)) (loop (cdr p) (cons (car p) acc)))
                            (else (loop (cdr p) acc))))))
        (if (null? gone)
            (begin (display "nothing to remove: ") (display repo)
                   (display " has no mesthiri files\n") (exit 0)))
        ;; Reverse order, so the shim stops running before its config
        ;; disappears — irrelevant in one commit, but the layer model is only
        ;; worth having if it is actually followed.
        (let* ((entries (map (lambda (p) (cons p #f)) (reverse gone)))
               (tree    (make-tree f repo btree entries))
               (commit  (make-commit f repo
                                     (signed "Remove mesthiri" oname omail)
                                     tree head)))
          (make-branch! f repo "mesthiri/uninstall" commit)
          (for-each (lambda (p) (display "  removed     ") (display p) (newline)) gone)
          (let ((url (open-pr! f repo "mesthiri/uninstall" base
                               "Remove mesthiri" (uninstall-pr-body))))
            (display "\n") (display url) (newline)
            (display "The labels are left: they are your issues' state, not\n")
            (display "mesthiri's. Delete them yourself if you want them gone.\n")))))))

;; --- apps create ----------------------------------------------------------
;;
;; This prints URLs rather than creating anything. GitHub's App-manifest flow
;; ends by handing the private key to whoever completes it in the browser, and
;; that has to be the person who will hold it — not a process that could log
;; it. So the command does the tedious half (getting the permissions and event
;; subscriptions right) and stops at the point where a human must be present.

(define (cmd-apps args)
  (if (or (null? args) (not (string=? (car args) "create")))
      (die "usage: mesthiri apps create [--org <name>]"))
  (let* ((org  (arg-after args "--org"))
         (base (if org (string-append "https://github.com/organizations/" org
                                      "/settings/apps/new")
                   "https://github.com/settings/apps/new")))
    (display "Two Apps, because the split is the guardrail: the reader can\n")
    (display "never write, so an event that only needs to read cannot alter\n")
    (display "anything even if the code is wrong.\n\n")
    (display "1. reader — open:\n     ") (display base) (newline)
    (display "   name:         mesthiri-reader\n")
    (display "   permissions:  Contents: Read, Issues: Read, Pull requests: Read,\n")
    (display "                 Metadata: Read\n")
    (display "   webhooks:     off — mesthiri has no receiver to send them to\n\n")
    (display "2. writer — open the same page again:\n")
    (display "   name:         mesthiri-writer\n")
    (display "   permissions:  Contents: Write, Issues: Write, Pull requests: Write,\n")
    (display "                 Metadata: Read\n")
    (display "   webhooks:     off\n\n")
    (display "Then, for each: generate a private key, install it on the repos\n")
    (display "you want, and add the .pem as a repository secret —\n")
    (display "MESTHIRI_READER_KEY and MESTHIRI_WRITER_KEY.\n\n")
    (display "Check the pairing before anything else; a swapped id and key is\n")
    (display "the likeliest setup mistake and it fails obscurely:\n")
    (display "     mesthiri whoami --app reader --key reader.pem\n")))

(define (usage)
  (display "mesthiri ") (display mesthiri-version)
  (display " — CI-native ADLC orchestrator\n\n")
  (display "  dispatch\n")
  (display "      Normalize the CI event, authorize it, match one stage, run it.\n")
  (display "      Reads MESTHIRI_EVENT_NAME, MESTHIRI_EVENT_PATH, MESTHIRI_REPO.\n\n")
  (display "  explain-event\n")
  (display "      Print the normalized event and how each stage trigger matched.\n")
  (display "      The first thing to run when a stage did nothing and said nothing.\n\n")
  (display "  try <owner/repo> [--rubric <path>]\n")
  (display "      Apply the rubric to open issues and print the result.\n")
  (display "      Writes nothing, clones nothing, and says so: it cannot\n")
  (display "      verify claims, which is what installed triage does.\n\n")
  (display "  agent-smoke [--prove-sandbox]\n")
  (display "      Report the sandbox and the derived egress allowlist.\n")
  (display "      --prove-sandbox asserts the boundary instead of describing it.\n\n")
  (display "  install <owner/repo> --operator \"Name <email>\" [--status]\n")
  (display "      Scaffold .mesthiri/, create the labels, and open the shim\n")
      (display "      workflow as a pull request. Merging it starts nothing.\n\n")
  (display "  uninstall <owner/repo> --operator \"Name <email>\"\n")
  (display "      Open the reversing pull request. The labels are left alone.\n\n")
  (display "  apps create [--org <name>]\n")
  (display "      Print what the two GitHub Apps need. It creates nothing:\n")
  (display "      the manifest flow hands the private key to whoever\n")
  (display "      finishes it, and that must be you.\n\n")
  (display "  whoami [--app reader|writer] [--key <pem>] [--config <path>]\n")
  (display "      Mint an installation token and report the installation,\n")
  (display "      its permissions and the remaining rate limit.\n")
  (exit 1))

;; `command-line` differs between the two ways mesthiri runs. As a script,
;; `kaappi mesthiri.scm dispatch` gives ("mesthiri.scm" "dispatch"). Bundled
;; into a standalone binary it gives ("dispatch") — the program name is not
;; there at all, so a blind `cdr` drops the subcommand, and with no arguments
;; it crashes on the empty list. Both were live bugs until a release smoke
;; test ran the binary; every earlier check had run the script.
(define (invocation-args)
  (let ((cl (command-line)))
    (cond ((null? cl) '())
          ((script-path? (car cl)) (cdr cl))
          (else cl))))

(define (script-path? s)
  (let ((n (string-length s)))
    (and (> n 4) (string=? (substring s (- n 4) n) ".scm"))))

(let ((args (invocation-args)))
  (cond ((null? args) (usage))
        ((or (string=? (car args) "--version") (string=? (car args) "version"))
         (display mesthiri-version) (newline))
        ((string=? (car args) "whoami") (cmd-whoami (cdr args)))
        ((string=? (car args) "dispatch") (cmd-dispatch (cdr args)))
        ((string=? (car args) "explain-event") (cmd-explain (cdr args)))
        ((string=? (car args) "agent-smoke") (cmd-agent-smoke (cdr args)))
        ((string=? (car args) "try") (cmd-try (cdr args)))
        ((string=? (car args) "install") (cmd-install (cdr args)))
        ((string=? (car args) "uninstall") (cmd-uninstall (cdr args)))
        ((string=? (car args) "apps") (cmd-apps (cdr args)))
        (else (usage))))
