;;; run.el --- Mindwtr live smoke suite entrypoint -*- lexical-binding: t; -*-
;;; Commentary:
;; Loaded via the Makefile:  make smoke  /  make smoke-write
;; Read-only phases always run; the write lifecycle runs when the
;; MINDWTR_SMOKE_WRITE environment variable is set (the smoke-write target).
;;; Code:

(require 'mindwtr-smoke)
(require 'mindwtr-parity)

(mindwtr-smoke-reset)
(mindwtr-smoke-configure)
(message "== Mindwtr live smoke suite ==")
(message "Server: %s" mindwtr-api-base-url)

;; Offline, and independent of whatever this instance happens to store: the
;; live schema-coverage phase below can only see fields some entity actually
;; carries, so it is blind to a field the server has learned but nobody has set
;; yet.  Run the fixture comparison first so that gap is reported even when the
;; server is unreachable.
(if (mindwtr-parity-report)
    (mindwtr-smoke-warn "synced-field parity" "model drifted from upstream fixtures")
  (when (mindwtr-parity-core-dir)
    (mindwtr-smoke-pass "synced-field parity (matches upstream fixtures)")))

(when (mindwtr-smoke-phase-connectivity)
  (let ((ad (mindwtr-smoke-phase-snapshot)))
    (when ad
      (mindwtr-smoke-phase-schema-coverage ad)
      (mindwtr-smoke-phase-roundtrip ad)
      (when (getenv "MINDWTR_SMOKE_WRITE")
        (mindwtr-smoke-phase-write-lifecycle)))))

(kill-emacs (mindwtr-smoke-summary))
;;; run.el ends here
