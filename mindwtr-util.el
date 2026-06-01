;;; mindwtr-util.el --- Utilities for mindwtr sync -*- lexical-binding: t; -*-
;; Author: Srijan
;; Package-Requires: ((emacs "28.1"))
;;; Commentary:
;; Low-level helpers: identifiers, timestamps, JSON, atomic writes.
;;; Code:
(require 'org)
(require 'iso8601)

(defun mindwtr-util-uuid ()
  "Return a random RFC-4122 v4 UUID string."
  (let ((b (make-string 16 0)))
    (dotimes (i 16) (aset b i (random 256)))
    (aset b 6 (logior #x40 (logand (aref b 6) #x0f)))
    (aset b 8 (logior #x80 (logand (aref b 8) #x3f)))
    (let ((h (mapconcat (lambda (c) (format "%02x" c)) b "")))
      (format "%s-%s-%s-%s-%s"
              (substring h 0 8) (substring h 8 12) (substring h 12 16)
              (substring h 16 20) (substring h 20 32)))))

(defun mindwtr-util-iso-normalize (iso)
  "Normalize ISO-8601 string ISO to whole-second UTC `...Z' form."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (encode-time (iso8601-parse iso)) t))

(defun mindwtr-util-iso->org (iso)
  "Render ISO-8601 string ISO as an org inactive timestamp in local time."
  (format-time-string "[%Y-%m-%d %a %H:%M]" (encode-time (iso8601-parse iso))))

(defun mindwtr-util-org->iso (org-ts)
  "Parse org inactive/active timestamp ORG-TS to whole-second UTC ISO string."
  (let* ((clean (string-trim org-ts "[\\[<]" "[]>]"))
         (decoded (org-parse-time-string clean)))
    (format-time-string "%Y-%m-%dT%H:%M:%SZ" (encode-time decoded) t)))

(defun mindwtr-util--json-prep (obj)
  "Recursively convert OBJ so json-serialize can handle it.
Plists are kept as plists; plain lists (used as arrays) are
converted to vectors; all other values are passed through."
  (cond
   ((and (listp obj) (not (null obj)) (keywordp (car obj)))
    (let ((result nil))
      (while obj
        (let ((k (pop obj))
              (v (pop obj)))
          (setq result (append result (list k (mindwtr-util--json-prep v))))))
      result))
   ((listp obj)
    (apply #'vector (mapcar #'mindwtr-util--json-prep obj)))
   (t obj)))

(defun mindwtr-util-json-encode (obj)
  "Encode plist/list OBJ to a JSON string.
Plain lists nested inside the plist are treated as JSON arrays."
  (json-serialize (mindwtr-util--json-prep obj) :null-object nil :false-object :false))

(defun mindwtr-util-json-decode (s)
  "Decode JSON string S to a plist (arrays as lists)."
  (json-parse-string s :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun mindwtr-util-read-file (path)
  "Return the contents of PATH as a string, or nil if missing."
  (when (file-exists-p path)
    (with-temp-buffer
      (set-buffer-multibyte t)
      (insert-file-contents path)
      (buffer-string))))

(defun mindwtr-util-atomic-write (path content)
  "Write string CONTENT to PATH atomically (temp file + rename)."
  (let ((tmp (make-temp-file (concat (file-name-directory path) ".mw-tmp"))))
    (with-temp-file tmp
      (set-buffer-multibyte t)
      (insert content))
    (rename-file tmp path t)))

(provide 'mindwtr-util)
;;; mindwtr-util.el ends here
