;;; (mesthiri command) — slash commands, parsed by a plain grammar
;;;
;;; Never by a model. The text these come from is attacker-writable: anyone
;;; who can comment on an issue can put `/implement` in it, and anyone who can
;;; open one can put a command-shaped string in the body. So parsing is
;;; deliberately dull — a command counts only at the start of a line and only
;;; as a whole token, and the command *table below* is the whole vocabulary.
;;;
;;; Two rules live here because they are properties of the command, not of the
;;; stage that runs it:
;;;
;;;   - **Entity restriction.** A command runs only where its inputs exist:
;;;     `/implement` on an issue, `/fix` on a pull request. There is nothing
;;;     for `/fix` to read on an issue.
;;;   - **Minimum permission**, by one rule: a command that can change code
;;;     needs write; a command that only produces commentary needs triage.
;;;     Spend is not the test, since all of them cost tokens.

(define-library (mesthiri command)
  (import (scheme base) (scheme char) (scheme write))
  (export parse-commands command-name command-args command-line-text
          command-known? command-stage command-entity command-min-permission
          command-table permission>=? permission-rank normalize-permission)
  (begin

    ;; name          stage        entity           minimum permission
    (define command-table
      '((triage    triage     issue         triage)
        (implement code       issue         write)
        (review    review     pull-request  triage)
        (fix       fix        pull-request  write)
        (retro     retro      either        triage)))

    (define (entry name) (assq name command-table))
    (define (command-known? name) (and (entry name) #t))
    (define (command-stage name) (let ((e (entry name))) (and e (cadr e))))
    (define (command-entity name) (let ((e (entry name))) (and e (caddr e))))
    (define (command-min-permission name) (let ((e (entry name))) (and e (cadddr e))))

    ;; --- permission ordering ---------------------------------------------
    ;;
    ;; GitHub reports both a coarse `permission` ("admin"/"write"/"read"/"none")
    ;; and a finer `role_name` ("triage", "maintain"). Triage collapses to
    ;; "read" in the coarse field, which would silently under-grant, so the
    ;; caller should prefer role_name and this normalizes either.
    (define permission-order '(none read triage write maintain admin))

    (define (permission-rank p)
      (let loop ((o permission-order) (i 0))
        (cond ((null? o) 0)
              ((eq? (car o) p) i)
              (else (loop (cdr o) (+ i 1))))))

    (define (normalize-permission s)
      (cond ((symbol? s) s)
            ((not (string? s)) 'none)
            ((string=? s "admin") 'admin)
            ((string=? s "maintain") 'maintain)
            ((string=? s "write") 'write)
            ((string=? s "triage") 'triage)
            ((string=? s "read") 'read)
            (else 'none)))

    (define (permission>=? actual required)
      (>= (permission-rank (normalize-permission actual))
          (permission-rank (normalize-permission required))))

    ;; --- parsing -----------------------------------------------------------

    (define-record-type <command>
      (make-command name args line) command?
      (name command-name)       ; symbol, e.g. triage
      (args command-args)       ; the rest of the line, trimmed
      (line command-line-text)) ; the whole line, for the refusal message

    (define (trim s)
      (let* ((n (string-length s))
             (a (let loop ((i 0))
                  (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
             (b (let loop ((i n))
                  (if (and (> i a) (char-whitespace? (string-ref s (- i 1)))) (loop (- i 1)) i))))
        (substring s a b)))

    (define (split-lines s)
      (let ((n (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond ((>= i n) (reverse (cons (substring s start n) acc)))
                ((char=? (string-ref s i) #\newline)
                 (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
                (else (loop (+ i 1) start acc))))))

    ;; Every command invoked in `body`, in order.
    ;;
    ;; A line must *begin* with the slash. Prose mentioning a command is prose:
    ;; "you could /implement this" invokes nothing, which matters because issue
    ;; bodies are quoted back to agents and pasted between issues.
    ;;
    ;; Unknown slash words are not returned at all rather than returned and
    ;; rejected later — `/deploy` is somebody else's bot, not our refusal to
    ;; make.
    (define (parse-commands body)
      (if (not (string? body))
          '()
          (let loop ((ls (split-lines body)) (acc '()))
            (if (null? ls)
                (reverse acc)
                (let ((l (trim (car ls))))
                  (if (and (> (string-length l) 1) (char=? (string-ref l 0) #\/))
                      (let* ((sp (let scan ((i 1))
                                   (cond ((>= i (string-length l)) i)
                                         ((char-whitespace? (string-ref l i)) i)
                                         (else (scan (+ i 1))))))
                             (word (substring l 1 sp))
                             (rest (trim (substring l sp (string-length l))))
                             (name (string->symbol word)))
                        (loop (cdr ls)
                              (if (command-known? name)
                                  (cons (make-command name rest l) acc)
                                  acc)))
                      (loop (cdr ls) acc)))))))))
