;;; (mesthiri config) — reads `.mesthiri/config.scm` from the target repo
;;;
;;; The file is s-expressions read with `read` and inspected as data. It is
;;; never `eval`ed, and neither are the trigger predicates inside it — those
;;; go to `(mesthiri trigger)`, which interprets a fixed vocabulary. The
;;; temptation is real: the data is already s-expressions, so `eval` would be
;;; one line. That one line turns a config file in someone else's repository
;;; into arbitrary code execution in a job holding credentials.
;;;
;;; Note the pair of names: this module is `lib/mesthiri/config.sld`; the file
;;; it reads is `.mesthiri/config.scm` in the repository being worked on.
;;;
;;; Validation is strict and early. A config that is wrong should fail at
;;; startup with a sentence naming the problem, not halfway through a stage
;;; that has already commented on someone's issue.

(define-library (mesthiri config)
  (import (scheme base) (scheme read) (scheme file) (scheme write))
  (export read-config parse-config config?
          config-version config-operator config-operator-name config-operator-email
          config-app config-rubric config-deny-paths config-agent-backend
          config-agent-version config-provider-names config-provider
          provider-endpoint provider-secret provider-key-env provider-api
          config-command-permission config-stage stage-mode stage-trigger
          config-priority-order config-test-command
          stage-max-tier config-budget
          config-error? config-error-message)
  (begin

    (define supported-version 1)

    (define-record-type <config>
      (make-config version forms) config?
      (version config-version)
      (forms   config-forms))

    (define-record-type <config-error>
      (make-config-error message) config-error?
      (message config-error-message))

    (define (fail . parts)
      (raise (make-config-error (apply string-append parts))))

    ;; --- shape helpers over (key . rest) forms -----------------------------

    (define (form-ref forms key)
      (let loop ((f forms))
        (cond ((null? f) #f)
              ((and (pair? (car f)) (eq? (caar f) key)) (car f))
              (else (loop (cdr f))))))

    (define (form-args forms key)
      (let ((f (form-ref forms key))) (and f (cdr f))))

    (define (form-arg1 forms key)
      (let ((a (form-args forms key))) (and a (pair? a) (car a))))

    ;; --- reading ----------------------------------------------------------

    (define (read-config path)
      (if (not (file-exists? path))
          (fail "no config at " path
                " — mesthiri reads .mesthiri/config.scm from the repository "
                "it is installed in")
          (parse-config (call-with-input-file path read) path)))

    (define (parse-config datum where)
      (cond
       ((eof-object? datum) (fail where " is empty"))
       ((not (and (pair? datum) (eq? (car datum) 'mesthiri)))
        (fail where " must be a single (mesthiri ...) form"))
       (else
        (let* ((forms   (cdr datum))
               (version (form-arg1 forms 'version)))
          (cond
           ((not version)
            (fail where " has no (version N); mesthiri will not guess at a "
                  "schema it cannot name"))
           ((not (eqv? version supported-version))
            (fail where " declares version " (number->string version)
                  ", and this mesthiri understands version "
                  (number->string supported-version)
                  " — refusing rather than guessing at fields it may not know"))
           (else (make-config version forms)))))))

    ;; --- accessors --------------------------------------------------------

    (define (config-operator c) (form-args (config-forms c) 'operator))
    (define (config-operator-name c)
      (let ((o (config-operator c))) (and o (pair? o) (car o))))
    (define (config-operator-email c)
      (let ((o (config-operator c))) (and o (pair? o) (pair? (cdr o)) (cadr o))))

    ;; (apps (reader 123456) (writer 123457)) — public configuration; only
    ;; the private keys are secrets.
    (define (config-app c role)
      (let ((apps (form-args (config-forms c) 'apps)))
        (and apps (let ((r (form-ref apps role))) (and r (cadr r))))))

    (define (config-rubric c) (form-arg1 (config-forms c) 'rubric))
    (define (config-deny-paths c) (or (form-args (config-forms c) 'deny-paths) '()))

    (define (config-agent-backend c)
      (let ((a (form-args (config-forms c) 'agent)))
        (and a (form-arg1 a 'backend))))
    (define (config-agent-version c)
      (let ((a (form-args (config-forms c) 'agent)))
        (and a (form-arg1 a 'version))))

    (define (config-provider-names c)
      (let ((ps (form-args (config-forms c) 'providers)))
        (if ps (map car ps) '())))
    (define (config-provider c name)
      (let ((ps (form-args (config-forms c) 'providers)))
        (and ps (let ((p (form-ref ps name))) (and p (cdr p))))))
    (define (provider-endpoint p) (form-arg1 p 'endpoint))
    (define (provider-secret p)   (form-arg1 p 'secret))
    (define (provider-key-env p)  (form-arg1 p 'key-env))
    ;; Which wire protocol the endpoint speaks. Defaults to
    ;; openai-completions, which is what most providers offer; a provider
    ;; speaking Anthropic's Messages API declares (api "anthropic-messages").
    (define (provider-api p)
      (let ((a (form-arg1 p 'api))) (and a (if (symbol? a) (symbol->string a) a))))

    ;; A command with no entry has no default: an unlisted command is not
    ;; runnable rather than runnable by anyone.
    (define (config-command-permission c command)
      (let ((cs (form-args (config-forms c) 'commands)))
        (and cs (let ((e (form-ref cs command)))
                  (and e (form-arg1 (cdr e) 'min-permission))))))

    ;; The repository's own priority ordering, if it declares one. Absent
    ;; means rank by age: mesthiri does not invent an ordering for a project
    ;; that has not stated one.
    (define (config-priority-order c)
      (form-args (config-forms c) 'priorities))

    ;; The target project's own test command. mesthiri runs the project's
    ;; tests rather than inventing a definition of green.
    (define (config-test-command c) (form-arg1 (config-forms c) 'test-command))

    (define (config-stage c name)
      (let ((ss (form-args (config-forms c) 'stages)))
        (and ss (let ((s (form-ref ss name))) (and s (cdr s))))))

    ;; Absent mode is `off`, so a stage nobody configured does not run. A
    ;; freshly installed repository is triage in dry-run and nothing else.
    (define (stage-mode s) (or (and s (form-arg1 s 'mode)) 'off))
    (define (stage-trigger s) (and s (form-arg1 s 'on)))
    (define (stage-max-tier s) (or (and s (form-arg1 s 'max-tier)) 0))

    ;; (config-budget c 'per-run 'tokens)
    (define (config-budget c scope key)
      (let ((b (form-args (config-forms c) 'budgets)))
        (and b (let ((sc (form-ref b scope)))
                 (and sc (form-arg1 (cdr sc) key))))))))
