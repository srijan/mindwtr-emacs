;;; smoke-test.el --- Live read-only smoke test against a Mindwtr server -*- lexical-binding: t; -*-
;;; Commentary:
;; Throwaway harness (not part of the package, not committed).  Read-only:
;; HEAD + GET /v1/data, report the snapshot, then round-trip the REAL data
;; through render->parse and check each entity's content signature is stable.
;; It NEVER PUTs.  Run it yourself so the token stays in your shell:
;;
;;   MINDWTR_URL=https://your.server MINDWTR_TOKEN=xxxx \
;;     emacs -Q --batch -L . -l smoke-test.el
;;
;; If MINDWTR_TOKEN is unset it falls back to auth-source for the URL host
;; (may need gpg-agent to have your key cached).
;;; Code:

(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)
(require 'mindwtr-shadow)
(require 'mindwtr)

(defun smoke--token ()
  (or (getenv "MINDWTR_TOKEN")
      (let ((mindwtr-server-url mindwtr-api-base-url))
        (ignore-errors (mindwtr--resolve-token)))
      (error "No token: set MINDWTR_TOKEN or an auth-source entry for the host")))

(defun smoke--count (appdata key) (length (plist-get appdata key)))

(setq mindwtr-api-base-url (or (getenv "MINDWTR_URL")
                               (error "Set MINDWTR_URL")))
(setq mindwtr-api-token (smoke--token))

(message "== Mindwtr read-only smoke test ==")
(message "Server: %s" mindwtr-api-base-url)

;; 1. HEAD — connectivity + auth + etag
(let ((etag (mindwtr-api-head-etag)))
  (message "HEAD ok. ETag: %s" (or etag "(none)")))

;; 2. GET — full snapshot
(let* ((got (mindwtr-api-get-data))
       (ad (plist-get got :appdata)))
  (message "GET ok. ETag: %s" (or (plist-get got :etag) "(none)"))
  (message "Snapshot: %d tasks, %d projects, %d sections, %d areas, settings:%s"
           (smoke--count ad :tasks) (smoke--count ad :projects)
           (smoke--count ad :sections) (smoke--count ad :areas)
           (if (plist-get ad :settings) "present" "empty"))

  ;; 3. Validate the server snapshot against our model
  (condition-case err
      (progn (mindwtr-model-validate-appdata ad)
             (message "validate-appdata: OK"))
    (error (message "validate-appdata: FAILED -> %s" (error-message-string err))))

  ;; 4. Real-data round-trip: render the snapshot into an org buffer,
  ;;    parse it back, and compare per-entity content signatures.
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "#+TITLE: Mindwtr smoke\n")
      (org-mode))
    (mindwtr-parse-ensure-keywords)
    (condition-case err
        (mindwtr-reconcile-buffer ad)
      (error (message "RECONCILE/RENDER ERROR: %s" (error-message-string err))
             (kill-emacs 1)))
    (let* ((reparsed (mindwtr-parse-buffer))
           (orig-idx (make-hash-table :test 'equal))
           (mismatch 0) (checked 0) (missing 0))
      ;; index original entities by id
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (e (plist-get ad key))
          (puthash (plist-get e :id) e orig-idx)))
      ;; for each reparsed entity, compare signature to the original
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (re (plist-get reparsed key))
          (setq checked (1+ checked))
          (let ((orig (gethash (plist-get re :id) orig-idx)))
            (if (null orig)
                (progn (setq missing (1+ missing))
                       (message "  ! reparsed id not in snapshot: %s"
                                (plist-get re :id)))
              (unless (string= (mindwtr-signature re) (mindwtr-signature orig))
                (setq mismatch (1+ mismatch))
                (when (<= mismatch 10)
                  (message "  ~ signature drift id=%s title=%S"
                           (plist-get re :id)
                           (or (plist-get re :title) (plist-get re :name)))))))))
      (message "Round-trip: %d entities reparsed, %d signature mismatches, %d unknown ids"
               checked mismatch missing)
      (message "%s"
               (cond ((and (= mismatch 0) (= missing 0))
                      "RESULT: PASS — your real data round-trips cleanly.")
                     (t "RESULT: DRIFT — some entities did not round-trip; see lines above."))))))

(message "== smoke test complete (no writes performed) ==")
;;; smoke-test.el ends here
