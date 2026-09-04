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

    ;; A shallow clone of the default branch, authenticated by embedding the
    ;; installation token in the remote. Tokens are short-lived and the clone
    ;; is discarded with the job.
    (define (git-clone url dir token)
      (proc-run/string
       (list "git" "clone" "--depth" "1"
             (if token (with-token url token) url) dir)))

    (define (with-token url token)
      ;; https://x-access-token:<token>@github.com/owner/repo
      (let ((rest (after "https://" url)))
        (string-append "https://x-access-token:" token "@" rest)))

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

    (define (git-push dir branch) (git dir "push" "origin" branch))

    (define (git-changed-files dir)
      (lines (git dir "diff" "--name-only" "HEAD")))

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
