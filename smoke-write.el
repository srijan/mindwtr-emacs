;;; smoke-write.el --- GUARDED single-entity write round-trip -*- lexical-binding: t; -*-
;;; Commentary:
;; Throwaway harness.  Unlike smoke-test.el this DOES write to the server,
;; but only ever a single, intentional edit to ONE task, and only after a
;; pre-PUT safety gate proves the payload changes nothing else.
;;
;; Flow (the real sync code path):
;;   1. GET appdata (this is the shadow / server truth)
;;   2. render -> org buffer, append " [mw-test]" to the TARGET task's title
;;   3. parse -> build candidate via `mindwtr-sync-build-candidate'
;;   4. SAFETY GATE: assert exactly the target changed (title + rev bump),
;;      every other live entity is byte-identical, and no new tombstones.
;;      Abort WITHOUT writing if anything else differs.
;;   5. PUT, then GET again and verify the edit landed and nothing else moved.
;;   6. Print the original title for manual revert.  Does NOT auto-revert.
;;
;;   MINDWTR_URL=https://your.server MINDWTR_TOKEN=xxxx \
;;     emacs -Q --batch -L . -l smoke-write.el
;;; Code:

(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-reconcile)
(require 'mindwtr-signature)
(require 'mindwtr-sync)
(require 'mindwtr)

(defconst smoke-write--target-id "b1c2d3e4-0000-4000-8000-000000000002"
  "The \"test task in project without area\" task the user chose.")
(defconst smoke-write--marker " [mw-test]")

(setq mindwtr-api-base-url (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
(setq mindwtr-api-token
      (or (getenv "MINDWTR_TOKEN")
          (let ((mindwtr-server-url mindwtr-api-base-url))
            (ignore-errors (mindwtr--resolve-token)))
          (error "No token")))

(defun smoke-write--find (ad id)
  (catch 'hit
    (dolist (key '(:tasks :projects :sections :areas))
      (dolist (e (plist-get ad key))
        (when (string= (plist-get e :id) id) (throw 'hit e))))
    nil))

(defun smoke-write--keys (pl)
  (let (ks (i 0)) (while (< i (length pl)) (push (nth i pl) ks) (setq i (+ i 2)))
       ks))

(defun smoke-write--plist-same-p (a b)
  "Non-nil if plists A and B have identical key->value sets (order-insensitive)."
  (let ((ka (smoke-write--keys a)) (kb (smoke-write--keys b)))
    (and (= (length ka) (length kb))
         (seq-every-p (lambda (k) (and (plist-member b k)
                                       (equal (plist-get a k) (plist-get b k))))
                      ka))))

(defun smoke-write--abort (msg)
  (message "SAFETY GATE FAILED: %s" msg)
  (message "No write was performed.")
  (kill-emacs 1))

;; --- 1. GET ----------------------------------------------------------------
(message "== Mindwtr GUARDED write test ==")
(message "Server: %s" mindwtr-api-base-url)
(let* ((got (mindwtr-api-get-data))
       (ad (plist-get got :appdata))
       (etag (plist-get got :etag))
       (orig (smoke-write--find ad smoke-write--target-id)))
  (message "GET ok. ETag: %s" (or etag "(none)"))
  (unless orig (smoke-write--abort (format "target id %s not found on server"
                                           smoke-write--target-id)))
  (let* ((orig-title (plist-get orig :title))
         (orig-rev (plist-get orig :rev))
         (new-title (concat orig-title smoke-write--marker)))
    (message "Target: %S (rev %s)" orig-title orig-rev)

    ;; --- 2. render -> edit -> parse ----------------------------------------
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert "#+TITLE: mw write\n") (org-mode))
      (mindwtr-parse-ensure-keywords)
      (mindwtr-reconcile-buffer ad)
      ;; edit ONLY the target heading's title
      (let ((edited nil))
        (org-map-entries
         (lambda ()
           (when (string= (or (org-entry-get (point) "MW_ID") "")
                          smoke-write--target-id)
             (org-edit-headline new-title)
             (setq edited t))))
        (unless edited (smoke-write--abort "target heading not found in rendered org")))

      ;; --- 3. build candidate via the real sync path ----------------------
      (let* ((local (mindwtr-parse-buffer))
             (now (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
             (cand (mindwtr-sync-build-candidate local ad "mw-emacs-write-test" now))
             (wire (mindwtr-sync--strip-internal-keys cand)))
        (mindwtr-model-validate-appdata wire)

        ;; --- 4. SAFETY GATE -------------------------------------------------
        (let ((wire-idx (make-hash-table :test 'equal))
              (shadow-live (make-hash-table :test 'equal))
              (anomalies 0))
          (dolist (key '(:tasks :projects :sections :areas))
            (dolist (e (plist-get wire key)) (puthash (plist-get e :id) e wire-idx))
            (dolist (e (plist-get ad key))
              (unless (plist-get e :deletedAt)
                (puthash (plist-get e :id) e shadow-live))))
          ;; (a) every wire entity: target changed as intended, others identical,
          ;;     and no newly-introduced tombstone.
          (dolist (key '(:tasks :projects :sections :areas))
            (dolist (w (plist-get wire key))
              (let* ((id (plist-get w :id))
                     (s (smoke-write--find ad id)))
                (cond
                 ((string= id smoke-write--target-id)
                  (unless (string= (plist-get w :title) new-title)
                    (setq anomalies (1+ anomalies))
                    (message "  ! target title not applied: %S" (plist-get w :title)))
                  (unless (equal (plist-get w :rev) (1+ (or orig-rev 0)))
                    (setq anomalies (1+ anomalies))
                    (message "  ! target rev not bumped: %s -> %s"
                             orig-rev (plist-get w :rev)))
                  ;; checklist item ids must survive (fidelity)
                  (let ((cl (plist-get w :checklist)))
                    (when (and cl (not (plist-get (car cl) :id)))
                      (setq anomalies (1+ anomalies))
                      (message "  ! target checklist lost item ids"))))
                 ((and s (plist-get s :deletedAt)) nil) ; pre-existing tombstone echoed
                 ((and w (plist-get w :deletedAt) (not (and s (plist-get s :deletedAt))))
                  (setq anomalies (1+ anomalies))
                  (message "  ! UNEXPECTED tombstone for id=%s" id))
                 ((null s)
                  (setq anomalies (1+ anomalies))
                  (message "  ! wire entity not on server: id=%s" id))
                 ((not (smoke-write--plist-same-p w s))
                  (setq anomalies (1+ anomalies))
                  (message "  ! NON-TARGET entity changed: id=%s" id)
                  (dolist (k (smoke-write--keys w))
                    (unless (equal (plist-get w k) (plist-get s k))
                      (message "      %s: wire=%S server=%S"
                               k (plist-get w k) (plist-get s k)))))))))
          ;; (b) no live server entity may be missing from the wire (would drop/tombstone it)
          (maphash (lambda (id _)
                     (unless (gethash id wire-idx)
                       (setq anomalies (1+ anomalies))
                       (message "  ! live server entity MISSING from wire: id=%s" id)))
                   shadow-live)
          (unless (= anomalies 0)
            (smoke-write--abort (format "%d anomalies; payload would change more than the target"
                                        anomalies)))
          (message "Safety gate: OK — payload changes exactly the target task, nothing else."))

        ;; --- 5. PUT + verify ------------------------------------------------
        (message "PUT-ting (1 task changed)...")
        (mindwtr-api-put-data wire)
        (let* ((got2 (mindwtr-api-get-data))
               (ad2 (plist-get got2 :appdata))
               (after (smoke-write--find ad2 smoke-write--target-id)))
          (message "Re-GET ok.")
          (if (and after (string= (plist-get after :title) new-title))
              (message "VERIFIED: target title is now %S (rev %s)"
                       (plist-get after :title) (plist-get after :rev))
            (message "WARNING: target title after PUT is %S (expected %S)"
                     (and after (plist-get after :title)) new-title))
          ;; spot-check a few non-target entities are unchanged in content
          (let ((drift 0))
            (dolist (key '(:tasks :projects :sections :areas))
              (dolist (e (plist-get ad key))
                (let ((id (plist-get e :id)))
                  (unless (or (string= id smoke-write--target-id)
                              (plist-get e :deletedAt))
                    (let ((e2 (smoke-write--find ad2 id)))
                      (when (and e2 (not (string= (mindwtr-signature e)
                                                  (mindwtr-signature e2))))
                        (setq drift (1+ drift))
                        (message "  ~ post-write drift on non-target id=%s" id)))))))
            (message "Post-write non-target drift: %d" drift))
          (message "")
          (message ">>> TO REVERT MANUALLY: set the task title back to:")
          (message ">>>   %S" orig-title)
          (message ">>> (it currently has the %S marker appended)" smoke-write--marker))))))

(message "== write test complete ==")
;;; smoke-write.el ends here
