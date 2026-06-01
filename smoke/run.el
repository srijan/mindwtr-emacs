;;; run.el --- Mindwtr live smoke suite entrypoint -*- lexical-binding: t; -*-
;;; Commentary:
;; Loaded via the Makefile:  make smoke  /  make smoke-write
;; Read-only phases always run; the write lifecycle runs when the
;; MINDWTR_SMOKE_WRITE environment variable is set (the smoke-write target).
;;; Code:

(require 'mindwtr-smoke)

(mindwtr-smoke-reset)
(mindwtr-smoke-configure)
(message "== Mindwtr live smoke suite ==")
(message "Server: %s" mindwtr-api-base-url)

(when (mindwtr-smoke-phase-connectivity)
  (let ((ad (mindwtr-smoke-phase-snapshot)))
    (when ad
      (mindwtr-smoke-phase-schema-coverage ad)
      (mindwtr-smoke-phase-roundtrip ad))
    (when (getenv "MINDWTR_SMOKE_WRITE")
      (mindwtr-smoke-phase-write-lifecycle))))

(kill-emacs (mindwtr-smoke-summary))
;;; run.el ends here
