;;; (mesthiri forge) — the GitHub REST client, and the only path to the API
;;;
;;; Everything that talks to the forge goes through here: pagination and
;;; rate-limit handling live in one place, and there is one credential path
;;; rather than two. There is deliberately no `gh` anywhere in mesthiri.
;;;
;;; The HTTP transport is *injected* rather than imported. Two reasons, and
;;; the second is the one that matters:
;;;
;;;   - `kaappi-http` is a C-FFI library, so importing it here would mean this
;;;     module could not be loaded or tested without its shared object built
;;;     and installed. The dependency belongs at the entry point instead.
;;;   - a test can hand in a transport that returns canned responses, so the
;;;     pagination, rate-limit and error paths are exercised for real without
;;;     a network or a token.
;;;
;;; A transport is `(lambda (method url headers body) -> (values status headers body))`.

(define-library (mesthiri forge)
  (import (scheme base) (scheme write) (scheme char) (kaappi json))
  (export make-forge forge? forge-auth! forge-rate-limit-remaining
          forge-request forge-get forge-post forge-get-all
          forge-post-comment
          bearer header-ref link-next
          forge-error? forge-error-status forge-error-url forge-error-body)
  (begin

    (define user-agent "mesthiri")
    (define api-version "2022-11-28")

    (define-record-type <forge>
      (%make-forge transport base auth rate) forge?
      (transport forge-transport)
      (base      forge-base)
      (auth      forge-auth set-forge-auth!)
      (rate      forge-rate set-forge-rate!))

    (define-record-type <forge-error>
      (make-forge-error status url body) forge-error?
      (status forge-error-status)
      (url    forge-error-url)
      (body   forge-error-body))

    (define (make-forge transport . opts)
      (%make-forge transport
                   (if (pair? opts) (car opts) "https://api.github.com")
                   #f #f))

    (define (forge-auth! f value) (set-forge-auth! f value))
    (define (forge-rate-limit-remaining f) (forge-rate f))

    ;; Both an App JWT and an installation token are sent as Bearer.
    (define (bearer token) (string-append "Bearer " token))

    ;; Header names are case-insensitive over the wire, so never compare them
    ;; with string=?; GitHub has changed the casing of these before.
    (define (header-ref headers name)
      (let ((want (string-downcase name)))
        (let loop ((h headers))
          (cond ((null? h) #f)
                ((and (pair? (car h)) (string? (caar h))
                      (string=? (string-downcase (caar h)) want))
                 (cdar h))
                (else (loop (cdr h)))))))

    (define (string-downcase s) (list->string (map char-downcase (string->list s))))

    ;; --- requests ---------------------------------------------------------

    (define (forge-request f method path . opts)
      (let* ((body    (if (pair? opts) (car opts) #f))
             (url     (if (and (> (string-length path) 4)
                               (string=? (substring path 0 4) "http"))
                          path
                          (string-append (forge-base f) path)))
             (headers (append
                       (list (cons "Accept" "application/vnd.github+json")
                             (cons "User-Agent" user-agent)
                             (cons "X-GitHub-Api-Version" api-version))
                       (if body (list (cons "Content-Type" "application/json")) '())
                       (if (forge-auth f)
                           (list (cons "Authorization" (forge-auth f)))
                           '()))))
        (let-values (((status resp-headers resp-body)
                      ((forge-transport f) method url headers body)))
          ;; Rate limit is recorded on every response, not fetched separately:
          ;; the number is in the headers already and asking for it costs a
          ;; request against the very budget being measured.
          (let ((remaining (header-ref resp-headers "X-RateLimit-Remaining")))
            (if remaining (set-forge-rate! f (string->number remaining))))
          (if (>= status 400)
              (raise (make-forge-error status url resp-body))
              (values status resp-headers resp-body)))))

    (define (forge-get f path)
      (let-values (((s h b) (forge-request f "GET" path)))
        (json-read-string b)))

    (define (forge-post f path body)
      (let-values (((s h b) (forge-request f "POST" path body)))
        (if (string=? b "") '() (json-read-string b))))

    ;; The one way to post a comment. `marker` is not optional, and that is
    ;; the whole point: every comment mesthiri writes must carry the marker
    ;; that lets mesthiri — and the shim — recognise its own voice.
    ;;
    ;; Two modules used to call `forge-post` directly with a hand-rolled body
    ;; and no marker. The consequences were not "an untidy comment":
    ;;
    ;;   * The shim skips a run when the comment body contains the marker.
    ;;     Unmarked, every triage comment cost a full runner job — download
    ;;     the release, install pi and bubblewrap, start, match nothing, exit.
    ;;   * Those jobs enter the workflow's per-issue concurrency group. GitHub
    ;;     keeps only ONE pending run per group, so the no-op evicted a queued
    ;;     run — and the queued run was a human's `/implement`. The command
    ;;     was discarded with no comment and no failure; the issue simply sat
    ;;     there. `cancel-in-progress: false` does not protect against this:
    ;;     it protects the RUNNING job, not the queued one.
    ;;   * `event-own-comment?` matches on the same marker, so mesthiri's
    ;;     second line of defence was blind to those comments too.
    ;;
    ;; Hence a required argument rather than a convention: an omission is now
    ;; a wrong-arity error at the call site, not silence three systems away.
    (define (forge-post-comment f repo number body marker)
      (if (not (string? marker))
          (error "forge-post-comment: every mesthiri comment needs a marker"))
      (forge-post f (string-append "/repos/" repo "/issues/"
                                   (number->string number) "/comments")
                  (string-append "{\"body\":\""
                                 (json-escape (string-append body "\n\n" marker))
                                 "\"}")))

    (define (json-escape s)
      (let loop ((i 0) (acc '()))
        (if (>= i (string-length s))
            (list->string (reverse acc))
            (let ((c (string-ref s i)))
              (loop (+ i 1)
                    (cond ((char=? c #\") (append '(#\" #\\) acc))
                          ((char=? c #\\) (append '(#\\ #\\) acc))
                          ((char=? c #\newline) (append '(#\n #\\) acc))
                          ((char=? c #\return) (append '(#\r #\\) acc))
                          ((char=? c #\tab) (append '(#\t #\\) acc))
                          (else (cons c acc))))))))

    ;; --- pagination -------------------------------------------------------

    ;; GitHub paginates with a Link header; following it is the only correct
    ;; way, since page counts are not returned and guessing at `?page=N`
    ;; breaks on any endpoint that uses cursors.
    (define (link-next link-header)
      (and (string? link-header)
           (let loop ((i 0))
             (cond
              ((>= i (string-length link-header)) #f)
              ((char=? (string-ref link-header i) #\<)
               (let close ((j (+ i 1)))
                 (cond
                  ((>= j (string-length link-header)) #f)
                  ((char=? (string-ref link-header j) #\>)
                   (let* ((url (substring link-header (+ i 1) j))
                          (rest-end (min (string-length link-header) (+ j 30)))
                          (rest (substring link-header j rest-end)))
                     (if (contains? rest "rel=\"next\"") url (loop (+ j 1)))))
                  (else (close (+ j 1))))))
              (else (loop (+ i 1)))))))

    (define (contains? s sub)
      (let ((n (string-length s)) (m (string-length sub)))
        (let loop ((i 0))
          (cond ((> (+ i m) n) #f)
                ((string=? (substring s i (+ i m)) sub) #t)
                (else (loop (+ i 1)))))))

    ;; Follow every page, appending the results. Callers get one list and
    ;; never think about pages, which is the point of it living here.
    (define (forge-get-all f path)
      (let loop ((p path) (acc '()))
        (let-values (((s h b) (forge-request f "GET" p)))
          (let* ((page (json-read-string b))
                 (acc  (append acc (if (list? page) page '())))
                 (next (link-next (header-ref h "Link"))))
            (if next (loop next acc) acc)))))))
