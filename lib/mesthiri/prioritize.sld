;;; (mesthiri prioritize) — turn triaged issues into an ordered ready queue
;;;
;;; The queue is labels, not rows: promoting an issue means moving it from
;;; `triaged` to `ready-to-implement`, which a maintainer can undo by removing
;;; a label.
;;;
;;; Ranking uses the repository's own priority ordering where it declares one,
;;; and oldest-triaged-first where it does not — with age breaking ties in
;;; both cases. Age is the fallback rather than, say, a score mesthiri
;;; invents: a queue that reorders itself for reasons the repository never
;;; stated is one nobody can predict or argue with.
;;;
;;; Every promotion says what moved it. A maintainer who disagrees should be
;;; able to disagree with the *reason*, not just the outcome.

(define-library (mesthiri prioritize)
  (import (scheme base) (scheme write) (scheme char)
          (mesthiri forge) (mesthiri labels) (mesthiri config) (mesthiri log))
  (export rank-issues promotion-reason promote-limit
          triaged-issues prioritize! issue-priority)
  (begin

    ;; One scheduled run promotes at most this many. The queue is meant to be
    ;; a short list a human can look at, not the whole backlog relabelled.
    (define promote-limit 5)

    (define (labels-of o)
      (let ((l (assoc "labels" o)))
        (if (and l (list? (cdr l)))
            (map (lambda (x) (let ((n (assoc "name" x))) (if n (cdr n) ""))) (cdr l))
            '())))

    (define (issue-priority o)
      (let loop ((ls (labels-of o)))
        (cond ((null? ls) #f)
              ((prefix? (car ls) "priority: ") (car ls))
              (else (loop (cdr ls))))))

    (define (prefix? s p)
      (and (>= (string-length s) (string-length p))
           (string=? (substring s 0 (string-length p)) p)))

    (define (triaged? o) (and (member "triaged" (labels-of o)) #t))

    (define (triaged-issues forge repo)
      (let loop ((os (forge-get-all forge
                       (string-append "/repos/" repo
                                      "/issues?state=open&labels=triaged&per_page=100")))
                 (acc '()))
        (cond ((null? os) (reverse acc))
              ((triaged? (car os)) (loop (cdr os) (cons (car os) acc)))
              (else (loop (cdr os) acc)))))

    ;; Position in the declared ordering; unranked priorities sort after every
    ;; ranked one rather than before, so an unrecognised label never jumps the
    ;; queue.
    (define (priority-rank p order)
      (let loop ((o order) (i 0))
        (cond ((null? o) 9999)
              ((and p (string=? (car o) p)) i)
              (else (loop (cdr o) (+ i 1))))))

    ;; Issue number stands in for age: GitHub numbers ascend, so a lower
    ;; number is older. It needs no extra API call and cannot disagree with
    ;; itself the way a mutable updated_at can.
    (define (issue-age o)
      (let ((n (assoc "number" o))) (if n (cdr n) 999999)))

    ;; Stable insertion sort. The list is a handful of issues, and a stable
    ;; sort means two runs over an unchanged queue produce the same order —
    ;; which matters, because the order is written into comments.
    (define (rank-issues issues order)
      (let insert-all ((in issues) (out '()))
        (if (null? in)
            ;; `out` is already in order — `insert` places each element. An
            ;; earlier version reversed it here and produced a perfectly
            ;; backwards queue: highest priority last.
            out
            (insert-all (cdr in) (insert (car in) out order)))))

    (define (insert x out order)
      (let loop ((seen '()) (rest out))
        (cond ((null? rest) (append (reverse seen) (list x)))
              ((before? x (car rest) order)
               (append (reverse seen) (list x) rest))
              (else (loop (cons (car rest) seen) (cdr rest))))))

    (define (before? a b order)
      (let ((ra (priority-rank (issue-priority a) order))
            (rb (priority-rank (issue-priority b) order)))
        (cond ((< ra rb) #t)
              ((> ra rb) #f)
              (else (< (issue-age a) (issue-age b))))))

    (define (promotion-reason o position order)
      (let ((p (issue-priority o)))
        (string-append
         "Promoted to `ready-to-implement` (position "
         (number->string position) ").\n\n"
         (if (and p (< (priority-rank p order) 9999))
             (string-append "Ranked by this repository's priority ordering: `" p "`.")
             (if p
                 (string-append "Priority `" p "` is not in the configured "
                                "ordering, so this was ranked by age.")
                 "No priority label, so this was ranked by age (oldest first)."))
         "\n\nIf that is the wrong order, remove the label — the queue is "
         "labels, and yours to change.")))

    ;; Promote the head of the queue. In dry-run nothing is written, which is
    ;; asserted rather than assumed.
    (define (prioritize! forge config repo mode)
      (let* ((order (or (config-priority-order config) '()))
             (ranked (rank-issues (triaged-issues forge repo) order)))
        (let loop ((is ranked) (n 0) (done '()))
          (cond
           ((or (null? is) (>= n promote-limit)) (reverse done))
           (else
            (let* ((o (car is))
                   (number (issue-age o))
                   (reason (promotion-reason o (+ n 1) order)))
              (cond
               ((eq? mode 'live)
                (forge-post forge
                            (string-append "/repos/" repo "/issues/"
                                           (number->string number) "/comments")
                            (string-append "{\"body\":\"" (escape reason) "\"}"))
                (guard (e ((label-error? e) (log-warn (label-error-message e))))
                  (apply-label! forge repo number "triaged" "ready-to-implement")))
               (else
                (log-info "would promote #" number " (position " (+ n 1) ") [dry-run]")))
              (loop (cdr is) (+ n 1) (cons number done))))))))

    (define (escape s)
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length s))
            (list->string (reverse acc))
            (let ((c (string-ref s i)))
              (loop (+ i 1)
                    (cond ((char=? c #\") (append '(#\" #\\) acc))
                          ((char=? c #\\) (append '(#\\ #\\) acc))
                          ((char=? c #\newline) (append '(#\n #\\) acc))
                          (else (cons c acc))))))))))
