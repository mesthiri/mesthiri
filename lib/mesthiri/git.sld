;;; (mesthiri git) — git through argv, never a shell
;;;
;;; Every call here goes through (mesthiri proc), which has no shell mode.
;;; That matters because issue text reaches this stage: a branch name derived
;;; from an issue title, passed through a shell, is a command injection.
;;;
;;; The push is deliberately here and not in the agent's reach. The agent
;;; writes commits in its clone and exits; the job reads the diff, checks it,
;;; and only then pushes.

(define-library (mesthiri git)
  (import (scheme base) (scheme write) (scheme char) (mesthiri proc))
  (export git-clone git-branch git-add-all git-commit git-push
          git-changed-files git-has-changes? branch-name-for
          commit-message trailers)
  (begin

    (define (git dir . args)
      (proc-run/string (append (list "git" "-C" dir) args)))

    ;; A shallow clone of the default branch.
    ;;
    ;; The token reaches git through a credential helper reading a FILE, not
    ;; through the URL. Embedding it in the remote — which is what this used
    ;; to do — writes it into the clone's `.git/config`, and the clone is the
    ;; directory the agent then runs in with read tools: the credential the
    ;; whole design keeps away from the agent would be sitting in its working
    ;; directory. It is not in argv either, per this project's rule that
    ;; secrets travel as paths or on stdin; only the path is.
    (define (git-clone url dir token-file)
      (proc-run/string
       (append (list "git")
               (credential-args token-file)
               (list "clone" "--depth" "1" url dir))))

    ;; `git -c credential.helper=` first, to discard any helper the host has
    ;; configured rather than adding to it.
    (define (credential-args token-file)
      (if token-file
          (list "-c" "credential.helper="
                "-c" (string-append
                      "credential.helper=!f(){ echo username=x-access-token; "
                      "echo password=\"$(cat " token-file ")\"; };f"))
          '()))

    (define (after prefix s)
      (if (and (>= (string-length s) (string-length prefix))
               (string=? (substring s 0 (string-length prefix)) prefix))
          (substring s (string-length prefix) (string-length s))
          s))

    ;; Derived from the issue number, never its title. A title is
    ;; attacker-writable and a branch name has its own grammar; the number is
    ;; unambiguous and cannot carry anything.
    (define (branch-name-for issue-number)
      (string-append "mesthiri/issue-" (number->string issue-number)))

    (define (git-branch dir name) (git dir "checkout" "-b" name))
    (define (git-add-all dir) (git dir "add" "-A"))

    ;; Author and committer are both the operator, because DCO checkers
    ;; compare the sign-off against the author and reject a mismatch. The
    ;; machine authorship is disclosed by trailers rather than by the author
    ;; field.
    (define (git-commit dir subject body operator-name operator-email)
      (proc-run/string
       (list "git" "-C" dir
             "-c" (string-append "user.name=" operator-name)
             "-c" (string-append "user.email=" operator-email)
             "commit" "-m" (commit-message subject body))))

    ;; Same discipline as the clone: the credential is a file the helper
    ;; reads, and the agent has exited by the time this runs.
    (define (git-push dir branch token-file)
      (proc-run/string
       (append (list "git" "-C" dir)
               (credential-args token-file)
               (list "push" "origin" branch))))

    ;; Everything `git add -A` would commit, which is what the deny-paths
    ;; check has to inspect — so untracked files too, not just modified
    ;; tracked ones. `diff --name-only` lists only the latter, and the gap
    ;; between the two is exactly where an agent's stray output lands: unseen
    ;; by the check, then swept into the commit.
    (define (git-changed-files dir)
      (append (lines (git dir "diff" "--name-only" "HEAD"))
              (lines (git dir "ls-files" "--others" "--exclude-standard"))))

    (define (git-has-changes? dir)
      (> (string-length (git dir "status" "--porcelain")) 0))

    (define (lines s)
      (let ((n (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((>= i n)
                 (reverse (if (> i start) (cons (substring s start i) acc) acc)))
                ((char=? (string-ref s i) #\newline)
                 (loop (+ i 1) (+ i 1)
                       (if (> i start) (cons (substring s start i) acc) acc)))
                (else (loop (+ i 1) start acc))))))

    (define (commit-message subject body)
      (string-append subject "\n\n" body))

    ;; The three trailers, in the order a reader wants them: who certifies,
    ;; what co-authored, and what actually produced it.
    (define (trailers operator-name operator-email bot-login
                      mesthiri-version backend backend-version
                      provider model run-url)
      (string-append
       "Signed-off-by: " operator-name " <" operator-email ">\n"
       "Co-authored-by: " bot-login "\n"
       "Generated-by: mesthiri " mesthiri-version "; agent " backend " "
       backend-version "; model " (symbol->string provider) "/" model
       "; run " run-url "\n"))))
