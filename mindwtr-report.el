;;; mindwtr-report.el --- Sync report buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Renders sync stats, conflicts (local edits the server overrode) with a
;; per-field diff, the pre-sync backup path, and clock-skew warnings into
;; *Mindwtr Sync Report*.  Each conflict line carries the data needed for a
;; one-key "restore my edit" action (\\[mindwtr-report-restore-conflict]),
;; which re-applies the local version into the synced buffer.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-reconcile)

(defvar-local mindwtr-report--target-buffer nil
  "The org buffer a restore action should write back into.")

(defvar-local mindwtr-report--backup-file nil
  "Path of the pre-sync buffer backup, surfaced when a restore is incomplete.")

(defun mindwtr-report--canon (k v)
  "Canonical signing form of content field K's value V, or nil if empty.
Mirrors the signature's empty-as-absent rule so equal content compares
equal regardless of how a producer spelled an empty value."
  (if (or (null v) (and (stringp v) (string-empty-p v)))
      nil
    (mindwtr-signature-canonical-value k v)))

(defun mindwtr-report--field-diff (mine theirs)
  "Return a list of (FIELD MINE-VALUE THEIRS-VALUE) for content fields that
differ between MINE and THEIRS.  Comparison is canonical (tag order,
sub-minute timestamps, and checklist item ids are normalized) so only
genuine content differences are reported; non-content fields (rev,
updatedAt, ...) are ignored by construction."
  (let (diffs)
    (dolist (k mindwtr-model-content-fields)
      (unless (equal (mindwtr-report--canon k (plist-get mine k))
                     (mindwtr-report--canon k (plist-get theirs k)))
        (push (list k (plist-get mine k) (plist-get theirs k)) diffs)))
    (nreverse diffs)))

(defun mindwtr-report--fmt (v)
  "Format a field value V for display in the diff."
  (cond ((null v) "(empty)")
        ((stringp v) v)
        (t (prin1-to-string v))))

(defvar mindwtr-report-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m special-mode-map)
    (define-key m "r" #'mindwtr-report-restore-conflict)
    m)
  "Keymap for `mindwtr-report-mode'.")

(define-derived-mode mindwtr-report-mode special-mode "Mindwtr-Report"
  "Major mode for the *Mindwtr Sync Report* buffer.")

(defun mindwtr-report--backup-hint ()
  "Return a ' Recover from backup: PATH' suffix, or empty when none is known."
  (if mindwtr-report--backup-file
      (format "  Recover from the pre-sync backup: %s" mindwtr-report--backup-file)
    ""))

(defun mindwtr-report-restore-conflict ()
  "Restore your overridden local edit for the conflict at point.
Re-applies your version into the synced buffer (save and sync to push it).
If your version cannot be fully reproduced -- a re-parented item, or an
entry the server deleted -- this says so and points at the backup rather
than falsely reporting success."
  (interactive)
  (let ((c (get-text-property (point) 'mindwtr-conflict))
        (buf mindwtr-report--target-buffer))
    (unless c (user-error "Point is not on a conflict"))
    (unless (buffer-live-p buf)
      (user-error "The synced buffer is no longer available"))
    (let ((id (plist-get c :id))
          (status (with-current-buffer buf
                    (mindwtr-reconcile-restore-entity
                     (plist-get c :mine) (plist-get c :kind)))))
      (pcase status
        ('restored
         (message "Restored your edit for %s — save and sync to push it" id))
        ('partial
         (message "%s rewritten, but your version could not be fully reproduced (e.g. a moved item).%s"
                  id (mindwtr-report--backup-hint)))
        (_
         (message "%s is no longer in the buffer (removed on the server).%s"
                  id (mindwtr-report--backup-hint)))))))

(defun mindwtr-report-show (stats conflicts skew-warning &optional backup-file target-buffer)
  "Display STATS, CONFLICTS, SKEW-WARNING; return the report buffer.
BACKUP-FILE, when given, is the pre-sync buffer snapshot and is surfaced
so a lost edit can be recovered from disk.  TARGET-BUFFER is the org
buffer a restore action writes back into."
  (let ((buf (get-buffer-create "*Mindwtr Sync Report*")))
    (with-current-buffer buf
      (mindwtr-report-mode)
      (setq mindwtr-report--target-buffer target-buffer
            mindwtr-report--backup-file backup-file)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Mindwtr Sync Report\n===================\n\n")
        ;; These count what this device PROPOSED (local vs shadow); the
        ;; conflicts below report what the server actually overrode.
        (insert (format "Proposed — Created: %d   Updated: %d   Deleted: %d\n\n"
                        (or (plist-get stats :created) 0)
                        (or (plist-get stats :updated) 0)
                        (or (plist-get stats :deleted) 0)))
        (when skew-warning
          (insert (format "⚠ Clock skew: %s\n\n" skew-warning)))
        (when backup-file
          (insert (format "Pre-sync backup: %s\n\n" backup-file)))
        (if (null conflicts)
            (insert "No conflicts. All local edits accepted.\n")
          (insert (format "%d local edit(s) overridden by newer remote edits.\n"
                          (length conflicts)))
          (insert "Press `r' on a conflict to restore your edit.\n\n")
          (dolist (c conflicts)
            (let ((start (point))
                  (mine (plist-get c :mine))
                  (theirs (plist-get c :theirs)))
              (insert (format "• %s%s\n"
                              (plist-get c :id)
                              (if (plist-get c :kind)
                                  (format " (%s)" (plist-get c :kind)) "")))
              (let ((diff (mindwtr-report--field-diff mine theirs)))
                (if (null diff)
                    (insert "    (no field-level difference)\n")
                  (dolist (d diff)
                    (insert (format "    %s\n        yours : %s\n        server: %s\n"
                                    (substring (symbol-name (nth 0 d)) 1)
                                    (mindwtr-report--fmt (nth 1 d))
                                    (mindwtr-report--fmt (nth 2 d)))))))
              (insert "\n")
              ;; Tag the whole block so `r' anywhere within it restores.
              (put-text-property start (point) 'mindwtr-conflict c))))
        (goto-char (point-min))))
    (display-buffer buf)
    buf))

(provide 'mindwtr-report)
;;; mindwtr-report.el ends here
