;;; git.sld is tested against a real repository rather than a fake, because
;;; the things worth checking here are what git actually does with our
;;; arguments — including whether a DCO checker would accept the commit.
(import (scheme base) (scheme write) (mesthiri git) (mesthiri proc))

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

(display "(mesthiri git)\n")

;; --- branch names ---------------------------------------------------------
;; Derived from the number, never the title: a title is attacker-writable.
(check "branch from the issue number" "mesthiri/issue-412" (branch-name-for 412))

;; --- trailers -------------------------------------------------------------
(define t (trailers "Test Operator" "op@example.org" "mesthiri[bot] <b@users.noreply.github.com>"
                    "0.1.2" "pi" "0.84.4" 'deepseek "deepseek-v4-flash"
                    "https://github.com/o/r/actions/runs/1"))
(check "the operator signs off" #t (has? t "Signed-off-by: Test Operator <op@example.org>"))
(check "the machine is disclosed as co-author" #t (has? t "Co-authored-by: mesthiri[bot]"))
(check "the model that ran is named" #t (has? t "deepseek/deepseek-v4-flash"))
(check "the run is linked" #t (has? t "actions/runs/1"))

;; --- a real commit, checked the way a DCO app would ----------------------
(define dir "/tmp/mesthiri-git-test")
(define _rm (proc-run (list "rm" "-rf" dir)))
(define _mk (proc-run (list "mkdir" "-p" dir)))
(define _init (proc-run (list "git" "-C" dir "init" "-q" "-b" "main")))
(call-with-output-file (string-append dir "/file.txt")
  (lambda (p) (write-string "hello" p)))
(git-add-all dir)
(git-commit dir "Fix the thing" (string-append "Because it was broken.\n\n" t)
            "Test Operator" "op@example.org")

(define author (proc-run/string (list "git" "-C" dir "log" "-1" "--format=%an <%ae>")))
(define sob (proc-run/string
             (list "git" "-C" dir "log" "-1" "--format=%(trailers:key=Signed-off-by,valueonly)")))

;; This is the assertion that matters: DCO checkers compare the sign-off
;; against the author and reject a mismatch, so a bot-authored commit signed
;; by a human fails the very check it was meant to satisfy.
(check "author and sign-off are the same identity"
       #t (has? author "Test Operator <op@example.org>"))
(check "the sign-off trailer is present and matches the author"
       #t (has? sob "Test Operator <op@example.org>"))
(check "the co-author trailer survives into the commit"
       #t (has? (proc-run/string (list "git" "-C" dir "log" "-1" "--format=%b"))
                "Co-authored-by: mesthiri[bot]"))

;; --- change detection -----------------------------------------------------
(check "a clean tree reports no changes" #f (git-has-changes? dir))
(call-with-output-file (string-append dir "/second.txt")
  (lambda (p) (write-string "more" p)))
(check "an untracked file is a change" #t (git-has-changes? dir))

(define _cleanup (proc-run (list "rm" "-rf" dir)))
;; --- what the deny-paths check must be able to see -------------------------
;;
;; The code stage commits with `git add -A`, so anything untracked in the
;; clone is committed too. `git diff --name-only` lists only modified tracked
;; files, and the gap between the two is where an agent's stray output lands:
;; unseen by the check, then swept into the pull request. That happened — a
;; run left pi's home and a stderr log in a repository.
(define gdir "/tmp/mesthiri-git-untracked")
(define _9164 (proc-run (list "rm" "-rf" gdir)))
(define _3883 (proc-run (list "mkdir" "-p" (string-append gdir "/sub"))))
(define _9018 (proc-run (list "git" "-C" gdir "init" "-q")))
(call-with-output-file (string-append gdir "/tracked.txt")
  (lambda (p) (display "one" p)))
(define _6562 (proc-run (list "git" "-C" gdir "add" "tracked.txt")))
(define _commit
  (proc-run (list "git" "-C" gdir "-c" "user.name=t" "-c" "user.email=t@e"
                "commit" "-q" "-m" "base")))
(call-with-output-file (string-append gdir "/tracked.txt")
  (lambda (p) (display "two" p)))
(call-with-output-file (string-append gdir "/sub/stray.log")
  (lambda (p) (display "agent output" p)))

(define seen (git-changed-files gdir))
(check "a modified tracked file is seen" #t (and (member "tracked.txt" seen) #t))
(check "and an untracked one is too, because add -A will commit it"
       #t (and (member "sub/stray.log" seen) #t))

(newline)
(display "  ") (display pass) (display " passed, ") (display fail) (display " failed") (newline)
(if (> fail 0) (exit 1) (exit 0))
