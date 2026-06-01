;;; mindwtr-smoke.el --- Live smoke suite against a Mindwtr server -*- lexical-binding: t; -*-
;;; Commentary:
;; Reusable, committed smoke suite.  Read-only phases (connectivity,
;; snapshot+validate, schema coverage, render/parse round-trip) run by
;; default; an opt-in self-cleaning GTD write lifecycle exercises the PUT
;; path.  Run it via the Makefile so the token stays in your shell:
;;
;;   make smoke         ; read-only phases only
;;   make smoke-write   ; read-only phases + write lifecycle
;;
;; Config from the environment: MINDWTR_URL (required) and MINDWTR_TOKEN
;; (falls back to auth-source for the URL host when unset).
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-reconcile)
(require 'mindwtr-sync)
(require 'mindwtr)

;;;; Reporting + exit

(defvar mindwtr-smoke--counts nil
  "Plist (:pass N :fail N :warn N) of results for the current run.")

(defun mindwtr-smoke-reset ()
  "Reset the result counters."
  (setq mindwtr-smoke--counts (list :pass 0 :fail 0 :warn 0)))

(defun mindwtr-smoke--bump (key)
  (setq mindwtr-smoke--counts
        (plist-put mindwtr-smoke--counts key
                   (1+ (plist-get mindwtr-smoke--counts key)))))

(defun mindwtr-smoke-info (msg)
  "Print an indented diagnostic/info line MSG (not counted)."
  (message "       %s" msg))

(defun mindwtr-smoke-pass (label &rest details)
  "Record a pass for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :pass)
  (message "[PASS] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-fail (label &rest details)
  "Record a fail for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :fail)
  (message "[FAIL] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-warn (label &rest details)
  "Record a warning for LABEL (never affects exit code)."
  (mindwtr-smoke--bump :warn)
  (message "[WARN] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-summary ()
  "Print the run summary; return 1 if any fail was recorded, else 0."
  (message "---")
  (message "Summary: %d pass, %d fail, %d warn"
           (plist-get mindwtr-smoke--counts :pass)
           (plist-get mindwtr-smoke--counts :fail)
           (plist-get mindwtr-smoke--counts :warn))
  (if (> (plist-get mindwtr-smoke--counts :fail) 0) 1 0))

;;;; Config

(defun mindwtr-smoke-configure ()
  "Set `mindwtr-api-base-url' and `mindwtr-api-token' from the environment."
  (setq mindwtr-api-base-url
        (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
  (setq mindwtr-api-token
        (or (getenv "MINDWTR_TOKEN")
            (let ((mindwtr-server-url mindwtr-api-base-url))
              (ignore-errors (mindwtr--resolve-token)))
            (error "No token: set MINDWTR_TOKEN or an auth-source entry for the host"))))

(provide 'mindwtr-smoke)
;;; mindwtr-smoke.el ends here
