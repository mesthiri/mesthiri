;;; (mesthiri version) — the single source of truth for the version string
;;;
;;; One definition, so a release bumps one line. It is read by `--version`,
;;; by the `Generated-by` trailer on every commit mesthiri makes, and by the
;;; run record — which is what lets a strange-looking pull request six months
;;; from now be traced to the release that produced it.
;;;
;;; The `/release` skill bumps this. Do not edit it by hand as part of other
;;; work: a version that moved without a tag behind it is worse than one that
;;; is briefly stale, because the trailer then names a release that does not
;;; exist.

(define-library (mesthiri version)
  (import (scheme base))
  (export mesthiri-version)
  (begin
    (define mesthiri-version "0.1.2")))
