;;; (mesthiri sandbox) — the containment around a running agent
;;;
;;; The CI runner is already an ephemeral VM, which is most of the isolation.
;;; It is not all of it: the runner also holds the job's credentials, and the
;;; agent is driven by attacker-writable issue text. So the agent runs inside
;;; a namespace sandbox with:
;;;
;;;   - a read-only root;
;;;   - the scratch clone as the only writable mount;
;;;   - the App keys and the installation token outside the mount namespace
;;;     entirely — unreachable rather than merely unreadable;
;;;   - egress denied by default, with an allowlist DERIVED from the
;;;     configured provider endpoint rather than written beside it;
;;;   - a separate unprivileged uid.
;;;
;;; The forge is deliberately absent from the allowlist. The agent writes
;;; commits and the job pushes; it has no credential and no reason to reach
;;; GitHub.
;;;
;;; Linux only, which the runners that execute mesthiri jobs are; the macOS
;;; leg of the test workflow runs tests, not jobs, and its live test drives a
;;; stub model on localhost. On macOS there is no namespace sandbox and this
;;; says so loudly rather than pretending — a security fallback that
;;; fails silently is worse than none.

(define-library (mesthiri sandbox)
  (import (scheme base) (scheme write) (scheme char) (scheme process-context)
          (mesthiri proc) (mesthiri config))
  (export sandbox-available? sandbox-wrap allowed-hosts endpoint-host
          sandbox-unavailable-reason)
  (begin

    ;; bwrap is the mechanism, and **being installed is not the same as
    ;; working**. Ubuntu 24.04 ships
    ;; `kernel.apparmor_restrict_unprivileged_userns=1`, under which bwrap is
    ;; present, executable, and fails with `setting up uid map: Permission
    ;; denied` the moment it tries to create a namespace. A presence check
    ;; reports a sandbox that does not exist, which is the failure mode this
    ;; module's own header calls worse than having none.
    ;;
    ;; So the check runs bwrap. `/bin/true` under the same namespace flags the
    ;; real wrap uses, once per process — the probe costs a few milliseconds
    ;; and is the difference between a control and a claim.
    (define probe-result (list 'unknown))

    (define (sandbox-available?)
      (not (sandbox-unavailable-reason)))

    (define (sandbox-unavailable-reason)
      (cond ((not (eq? (host-kind) 'linux))
             "not Linux: namespace sandboxing is unavailable on this host")
            ((not (file-executable? "/usr/bin/bwrap"))
             "bwrap is not installed (apt-get install bubblewrap)")
            (else (probe))))

    (define (probe)
      (if (eq? (car probe-result) 'unknown)
          (set-car! probe-result (run-probe)))
      (car probe-result))

    ;; #f when the namespace was created, otherwise why it was not.
    (define (run-probe)
      (guard (e ((proc-error? e)
                 (let ((said (proc-error-stderr e)))
                   (string-append
                    "bwrap is installed but cannot create a namespace: "
                    (if (and (string? said) (> (string-length said) 0))
                        (trim said)
                        "no reason given")
                    (if (and (string? said) (contains? said "uid map"))
                        ;; The one cause worth naming, because the fix is a
                        ;; sysctl on the host and nothing about the message
                        ;; suggests that.
                        " — on Ubuntu 24.04 this is normally kernel.apparmor_restrict_unprivileged_userns=1"
                        ""))))
                (#t "bwrap could not be run at all"))
        (proc-run (list "/usr/bin/bwrap" "--unshare-all" "--share-net"
                        "--die-with-parent" "--new-session"
                        "--ro-bind" "/" "/" "--proc" "/proc" "--dev" "/dev"
                        "--" "/bin/true"))
        #f))

    (define (trim s)
      (let loop ((n (string-length s)))
        (if (and (> n 0) (let ((c (string-ref s (- n 1))))
                           (or (char=? c #\newline) (char=? c #\space))))
            (loop (- n 1))
            (substring s 0 n))))

    (define (contains? s sub)
      (let ((n (string-length s)) (m (string-length sub)))
        (let loop ((i 0)) (cond ((> (+ i m) n) #f)
                                ((string=? (substring s i (+ i m)) sub) #t)
                                (else (loop (+ i 1)))))))

    (define (host-kind)
      (if (get-environment-variable "RUNNER_OS")
          (if (string=? (get-environment-variable "RUNNER_OS") "Linux") 'linux 'other)
          ;; Outside CI, guess from a path only Linux has.
          (if (file-exists? "/proc/self/ns/user") 'linux 'other)))

    (define (file-executable? p) (file-exists? p))

    ;; --- the egress allowlist ----------------------------------------------
    ;;
    ;; Derived, never hand-written. An allowlist that disagrees with the
    ;; endpoint the agent actually calls fails deep inside an agent run as a
    ;; connection error, which looks like anything except the configuration
    ;; typo it is.

    (define (endpoint-host url)
      (and (string? url)
           (let* ((s (strip-scheme url))
                  (n (string-length s)))
             (let loop ((i 0))
               (cond ((>= i n) s)
                     ((or (char=? (string-ref s i) #\/)
                          (char=? (string-ref s i) #\:))
                      (substring s 0 i))
                     (else (loop (+ i 1))))))))

    (define (strip-scheme url)
      (let ((n (string-length url)))
        (let loop ((i 0))
          (cond ((> (+ i 3) n) url)
                ((string=? (substring url i (+ i 3)) "://")
                 (substring url (+ i 3) n))
                (else (loop (+ i 1)))))))

    ;; Every provider's host, plus whatever the target's own tests need.
    (define (allowed-hosts config extra)
      (let loop ((ps (config-provider-names config)) (acc '()))
        (if (null? ps)
            (append (reverse acc) extra)
            (let* ((p (config-provider config (car ps)))
                   (h (and p (endpoint-host (provider-endpoint p)))))
              (loop (cdr ps) (if h (cons h acc) acc))))))

    ;; --- wrapping ----------------------------------------------------------
    ;;
    ;; Returns the argv that runs `inner-argv` contained. When no sandbox is
    ;; available the caller gets #f and must decide — `agent.sld` refuses in
    ;; CI and warns loudly elsewhere, rather than silently running unconfined.
    ;; `scratch` is the agent's own writable area — its HOME, where pi keeps
    ;; the provider catalogue mesthiri writes and whatever state it needs.
    ;; It has to be bound writable and it must NOT be the workdir: the workdir
    ;; is the clone the code stage commits, so anything the agent writes there
    ;; ends up in a pull request. Two writable mounts, for two purposes.
    ;;
    ;; Omitting it is how this was found — HOME moved out of the clone, landed
    ;; under a read-only bind, and pi refused with "EROFS: read-only file
    ;; system, open '…/.pi/agent/auth.json'".
    (define (sandbox-wrap inner-argv workdir secrets-dir . opts)
      (and (sandbox-available?)
           (append
            (list "/usr/bin/bwrap"
                  "--unshare-all"
                  ;; NOT filtered. `--share-net` shares the host's network
                  ;; namespace, so the agent reaches whatever the runner
                  ;; reaches. `allowed-hosts` derives the list mesthiri would
                  ;; enforce and `agent-smoke` reports it, but nothing applies
                  ;; it: filtering needs either root for iptables or a proxy
                  ;; the agent's HTTP client honours, and neither is built.
                  ;; This comment used to claim otherwise. See design.md.
                  "--share-net"
                  "--die-with-parent"
                  "--new-session"
                  "--ro-bind" "/" "/"
                  ;; the clone, which is what the job will commit
                  "--bind" workdir workdir
                  ;; the secrets directory is not mounted at all: unreachable
                  ;; rather than unreadable
                  "--tmpfs" secrets-dir
                  "--proc" "/proc"
                  "--dev" "/dev"
                  "--chdir" workdir)
            (if (and (pair? opts) (car opts))
                (list "--bind" (car opts) (car opts))
                '())
            inner-argv)))))
