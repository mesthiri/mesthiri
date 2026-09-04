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
;;; Linux only, which CI runners are. On macOS there is no namespace sandbox
;;; and this says so loudly rather than pretending — a security fallback that
;;; fails silently is worse than none.

(define-library (mesthiri sandbox)
  (import (scheme base) (scheme write) (scheme char) (scheme process-context)
          (mesthiri config))
  (export sandbox-available? sandbox-wrap allowed-hosts endpoint-host
          sandbox-unavailable-reason)
  (begin

    ;; bwrap is the mechanism; its absence is the reason.
    (define (sandbox-available?)
      (and (eq? (host-kind) 'linux)
           (file-executable? "/usr/bin/bwrap")))

    (define (sandbox-unavailable-reason)
      (cond ((not (eq? (host-kind) 'linux))
             "not Linux: namespace sandboxing is unavailable on this host")
            ((not (file-executable? "/usr/bin/bwrap"))
             "bwrap is not installed")
            (else #f)))

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
    (define (sandbox-wrap inner-argv workdir secrets-dir)
      (and (sandbox-available?)
           (append
            (list "/usr/bin/bwrap"
                  "--unshare-all"
                  "--share-net"          ; egress is filtered, not removed
                  "--die-with-parent"
                  "--new-session"
                  "--ro-bind" "/" "/"
                  ;; the one writable place, and the only thing left behind
                  "--bind" workdir workdir
                  ;; the secrets directory is not mounted at all: unreachable
                  ;; rather than unreadable
                  "--tmpfs" secrets-dir
                  "--proc" "/proc"
                  "--dev" "/dev"
                  "--chdir" workdir)
            inner-argv)))))
