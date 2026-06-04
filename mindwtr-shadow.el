;;; mindwtr-shadow.el --- Local shadow + sync state -*- lexical-binding: t; -*-
;;; Commentary:
;; Persists the last-synced AppData (the shadow), the remote ETag, and a
;; stable device id.  All writes are atomic.
;;; Code:

(require 'mindwtr-util)

(defvar mindwtr-shadow-directory
  (expand-file-name "mindwtr/" user-emacs-directory)
  "Directory holding shadow.json, etag, and device-id.")

(defcustom mindwtr-backup-retention-days 3
  "Delete pre-sync backups older than this many days after each sync.
Age is measured from the timestamp encoded in the backup filename.
nil or 0 disables cleanup (backups are kept forever)."
  :type '(choice (const :tag "Keep forever" nil) integer)
  :group 'mindwtr)

(defun mindwtr-shadow--path (name)
  (expand-file-name name mindwtr-shadow-directory))

(defun mindwtr-shadow--ensure-dir ()
  (unless (file-directory-p mindwtr-shadow-directory)
    (make-directory mindwtr-shadow-directory t)))

(defun mindwtr-shadow-load ()
  "Load and return the shadow AppData plist (empty appdata if absent)."
  (let ((s (mindwtr-util-read-file (mindwtr-shadow--path "shadow.json"))))
    (if s (mindwtr-util-json-decode s)
      '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))

(defun mindwtr-shadow-save (appdata)
  "Persist APPDATA as the shadow, keeping one last-good backup."
  (mindwtr-shadow--ensure-dir)
  (let ((path (mindwtr-shadow--path "shadow.json")))
    (when (file-exists-p path)
      (copy-file path (mindwtr-shadow--path "shadow.bak.json") t))
    (mindwtr-util-atomic-write path (mindwtr-util-json-encode appdata))))

(defun mindwtr-shadow-get-etag ()
  (mindwtr-util-read-file (mindwtr-shadow--path "etag")))

(defun mindwtr-shadow-set-etag (etag)
  (mindwtr-shadow--ensure-dir)
  (mindwtr-util-atomic-write (mindwtr-shadow--path "etag") (or etag "")))

(defun mindwtr-shadow-device-id ()
  "Return the stable device id, generating and persisting one if needed."
  (let ((path (mindwtr-shadow--path "device-id")))
    (or (mindwtr-util-read-file path)
        (let ((id (format "emacs-%s-%s" (or (system-name) "host")
                          (substring (mindwtr-util-uuid) 0 8))))
          (mindwtr-shadow--ensure-dir)
          (mindwtr-util-atomic-write path id)
          id))))

(defun mindwtr-shadow-index (appdata key)
  "Return a hash table id->entity for APPDATA's KEY list (e.g. :tasks)."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e (plist-get appdata key))
      (puthash (plist-get e :id) e h))
    h))

(defun mindwtr-shadow--backup-time (filename)
  "Return the encoded time parsed from a backup FILENAME, or nil.
FILENAME is a non-directory name like \"mindwtr-20260604T080500.org\".
Returns nil for any name that does not match the mindwtr backup pattern."
  (when (string-match
         "\\`mindwtr-\\([0-9]\\{8\\}\\)T\\([0-9]\\{6\\}\\)\\.org\\'" filename)
    (let ((d (match-string 1 filename))
          (tm (match-string 2 filename)))
      (encode-time (string-to-number (substring tm 4 6))  ; sec
                   (string-to-number (substring tm 2 4))  ; min
                   (string-to-number (substring tm 0 2))  ; hour
                   (string-to-number (substring d 6 8))   ; day
                   (string-to-number (substring d 4 6))   ; month
                   (string-to-number (substring d 0 4)))))) ; year

(defun mindwtr-shadow-prune-backups (&optional now)
  "Delete pre-sync backups older than `mindwtr-backup-retention-days'.
NOW defaults to `current-time' and is injectable for tests.  A no-op when
retention is nil or <= 0, or when the backups directory is absent.  Only
files matching the mindwtr-<timestamp>.org pattern with a parseable
timestamp are candidates; anything else is left untouched."
  (let ((days mindwtr-backup-retention-days)
        (bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
    (when (and days (> days 0) (file-directory-p bdir))
      (let ((cutoff (time-subtract (or now (current-time))
                                   (* days 24 60 60))))
        (dolist (f (directory-files bdir t nil t))
          (let ((btime (mindwtr-shadow--backup-time (file-name-nondirectory f))))
            (when (and btime (time-less-p btime cutoff))
              (delete-file f))))))))

(provide 'mindwtr-shadow)
;;; mindwtr-shadow.el ends here
