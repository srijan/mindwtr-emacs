;;; mindwtr-shadow.el --- Local shadow + sync state -*- lexical-binding: t; -*-
;;; Commentary:
;; Persists the last-synced AppData (the shadow), the remote ETag, and a
;; stable device id.  All writes are atomic.
;;; Code:

(require 'mindwtr-util)

(defvar mindwtr-shadow-directory
  (expand-file-name "mindwtr/" user-emacs-directory)
  "Directory holding shadow.json, etag, and device-id.")

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

(provide 'mindwtr-shadow)
;;; mindwtr-shadow.el ends here
