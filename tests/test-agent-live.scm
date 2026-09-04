;;; The live agent path: a real pi process, spawned by run-agent.
;;;
;;; Every other test in this suite hands a stage an injected runner, which
;;; proves the caller and not the thing being called. This one spawns pi for
;;; real — pipes, the NDJSON drive loop, the deadline, the group kill — and
;;; talks to a stub model server over a socket. The only fiction is what the
;;; model says back.
;;;
;;; Writing it found four defects that the fixture-driven tests could not:
;;;
;;;   1. `run-agent` passed no `env:`, so the agent inherited the CI job's
;;;      whole environment — App private keys and forge token included. The
;;;      design says the agent never holds a credential; nothing enforced it.
;;;   2. A prompt pi refuses is answered with a `response` frame and then
;;;      silence. Waiting only for `agent_settled` hung the run until a
;;;      deadline that was never implemented — the parameter was accepted and
;;;      dropped.
;;;   3. `message.content` is a list of blocks, not a string, so the agent's
;;;      reply was never found: every real run would have died at "settled
;;;      without producing any text".
;;;   4. `message_end` fires for the user's message too. Without a role check
;;;      the "answer" can be the prompt handed back.

(import (scheme base) (scheme write) (scheme file) (scheme process-context)
        (kaappi process) (mesthiri agent) (mesthiri proc))

(define pass 0) (define fail 0)
(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1)) (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1)) (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))
(define (has? s sub)
  (and (string? s)
       (let ((n (string-length s)) (m (string-length sub)))
         (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                                 ((string=? (substring s i (+ i m)) sub) #t)
                                 (else (loop (+ i 1))))))))

(display "the live agent path\n")

;; pi is a runtime dependency, not a build one, so it can be absent. Skipping
;; is loud on purpose: a quietly-skipped test is how this path went nine
;; milestones without ever running.
;; proc-run raises on a non-zero exit and returns stdout otherwise, so the
;; guard is the whole test: pi absent means an exception, not a status.
(define (have-pi?)
  (guard (e (#t #f)) (proc-run (list "pi" "--version")) #t))

(define scratch "/tmp/mesthiri-agent-live")
(define home (string-append scratch "/home"))

(define (model-json port)
  (string-append
   "{\"providers\":{\"stub\":{\"baseUrl\":\"http://127.0.0.1:" port "\","
   "\"apiKey\":\"$STUB_API_KEY\",\"api\":\"openai-completions\","
   "\"models\":[{\"id\":\"stub-1\",\"name\":\"Stub\",\"reasoning\":false,"
   "\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,"
   "\"cacheWrite\":0},\"contextWindow\":32000,\"maxTokens\":4096}]}}}\n"))

;; The stub prints `PORT <n>` and then serves until killed.
(define (start-stub mode)
  (let* ((p (spawn-process (list "python3" "tests/support/stub-model.py" mode
                                 "the stub replies")
                           'stdout: 'pipe 'stderr: 'null 'new-group: #t))
         (line (read-line (process-stdout p))))
    (values p (substring line 5 (string-length line)))))

(define (env-for) 
  (list (cons "PATH" (or (get-environment-variable "PATH") "/usr/bin:/bin"))
        (cons "HOME" home)
        (cons "STUB_API_KEY" "not-a-real-key-and-never-leaves-localhost")
        (cons "NO_COLOR" "1")))

;; The flags agent-argv actually ships, so what is tested is what runs.
;; `--offline` in particular is worth having here: it says "disable startup
;; network operations", and whether that also blocks the model call is the
;; sort of thing to find out from a test rather than from a stalled run.
(define (pi-argv)
  (list "pi" "--mode" "rpc" "--no-session" "--no-context-files" "--offline"
        "--no-tools" "--provider" "stub" "--model" "stub-1"))

(cond
 ((not (have-pi?))
  (display "\n  SKIPPED: pi is not on PATH, so the live agent path did not run.\n")
  (display "  This is the one test that proves run-agent spawns anything.\n")
  (display "  Install it: npm i -g @earendil-works/pi-coding-agent\n\n")
  (display "  0 passed, 0 failed\n"))
 (else
  (proc-run (list "mkdir" "-p" (string-append home "/.pi/agent")))

  ;; --- a run that settles ------------------------------------------------
  (let-values (((stub port) (start-stub "serve")))
    (write-agent-home! home (model-json port))
    (let ((rec (run-agent (pi-argv) "say hi" 60
                          '((tokens . 100000) (turns . 5))
                          (string-append scratch "/trace.jsonl")
                          (env-for)
                          (string-append scratch "/stderr.log"))))
      (check "a real pi run reaches its terminal frame"
             'settled (run-record-outcome rec))
      (check "the turn is counted" 1 (run-record-turns rec))
      ;; From the stub's usage block, through pi, into the record.
      (check "tokens come back from the provider" 18 (run-record-tokens rec))
      ;; What the Generated-by trailer records: what ran, not what was asked for.
      (check "the model that ran is recorded" "stub-1" (run-record-model rec))
      ;; Defects 3 and 4: blocks, not a string; assistant, not the user.
      (check "the agent's own words come back"
             "the stub replies" (agent-final-text rec))
      (check "and not the prompt echoed back"
             #f (has? (agent-final-text rec) "say hi"))
      (check "the trace is written for retro to read"
             #t (file-exists? (string-append scratch "/trace.jsonl"))))
    (process-kill stub 'group: #t))

  ;; --- a model that never answers ----------------------------------------
  ;; The deadline is the only way out: pi has no in-band cancel, so this is
  ;; a group kill or it is nothing.
  (let-values (((stub port) (start-stub "hang")))
    (write-agent-home! home (model-json port))
    (let ((rec (run-agent (pi-argv) "say hi" 3
                          '((tokens . 100000) (turns . 5))
                          #f (env-for) #f)))
      (check "a hung model ends at the deadline, not never"
             'deadline (run-record-outcome rec)))
    ;; If the group kill missed, pi is still running now.
    ;; pgrep exits non-zero when nothing matches, which proc-run raises on —
    ;; so the exception is the passing case here.
    (check "and leaves no agent process behind"
           'none (guard (e (#t 'none))
                   (proc-run (list "pgrep" "-f" "pi --mode rpc"))
                   'still-running))
    (process-kill stub 'group: #t))

  ;; --- a prompt pi will not run ------------------------------------------
  ;; With no provider configured pi answers `success:false` and then waits
  ;; for another command forever. Reporting that in a quarter of a second,
  ;; in pi's own words, is the difference between a fixable setup mistake
  ;; and a twenty-minute timeout with no reason attached.
  ;; A declared provider whose key is simply not in the environment — the
  ;; exact shape of a repository that installed mesthiri and has not added
  ;; MESTHIRI_MODEL_KEY yet. (An *undeclared* provider is a different and
  ;; less interesting failure: pi exits, and the run ends at eof.)
  (let ((rec (run-agent (pi-argv) "say hi" 30 '((turns . 5)) #f
                        (list (cons "PATH" (or (get-environment-variable "PATH")
                                               "/usr/bin:/bin"))
                              (cons "HOME" home)
                              (cons "NO_COLOR" "1"))
                        #f)))
    (check "an unrunnable prompt is refused, not waited out"
           'refused (run-record-outcome rec))
    (check "and pi's own explanation is what comes back"
           #t (has? (run-record-text rec) "API key")))

  (newline)
  (display "  ") (display pass) (display " passed, ")
  (display fail) (display " failed") (newline)))

(if (> fail 0) (exit 1) (exit 0))
