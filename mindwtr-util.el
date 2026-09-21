;;; mindwtr-util.el --- Utilities for mindwtr sync -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.
;; Author: Srijan
;; Package-Requires: ((emacs "28.1"))
;;; Commentary:
;; Low-level helpers: identifiers, timestamps, JSON, atomic writes.
;;; Code:
(require 'org)
(require 'iso8601)
(require 'time-date)

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

(defun mindwtr-util-iso->time (iso)
  "Parse ISO 8601 string ISO to an Emacs time value.
Missing components take `decoded-time-set-defaults' defaults, so a date-only
string yields midnight local time.  Signals on a malformed ISO -- callers that
read a hand-editable buffer value rather than the wire should guard."
  (encode-time (decoded-time-set-defaults (iso8601-parse iso))))

(defun mindwtr-util-iso-date-only-p (iso)
  "Non-nil if ISO is a date-only string (no time component)."
  (and (stringp iso) (not (string-search "T" iso))))

(defun mindwtr-util-iso-normalize (iso)
  "Normalize ISO to whole-second UTC `...Z', or keep a date-only value as-is."
  (if (mindwtr-util-iso-date-only-p iso)
      iso
    (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                        (mindwtr-util-iso->time iso)
                        t)))

(defun mindwtr-util-iso->org (iso)
  "Render ISO as an org inactive timestamp in local time.
Date-only values render without a time-of-day and never shift days."
  (let ((time (mindwtr-util-iso->time iso)))
    (if (mindwtr-util-iso-date-only-p iso)
        (format-time-string "[%Y-%m-%d %a]" time)
      (format-time-string "[%Y-%m-%d %a %H:%M]" time))))

(defun mindwtr-util-org->iso (org-ts)
  "Parse org inactive/active timestamp ORG-TS to ISO.
A timestamp with no time-of-day yields a date-only `YYYY-MM-DD' string;
one with a time yields whole-second UTC `...Z'."
  (let* ((clean (string-trim org-ts "[\\[<]" "[]>]"))
         (decoded (org-parse-time-string clean))
         (has-time (string-match-p "[0-9][0-9]:[0-9][0-9]" clean)))
    (if has-time
        (format-time-string "%Y-%m-%dT%H:%M:%SZ" (encode-time decoded) t)
      (format-time-string "%Y-%m-%d" (encode-time decoded)))))

(defun mindwtr-util-iso-coarsen-minute (iso)
  "Coarsen ISO to minute precision (drop seconds and sub-seconds), in UTC.
Date-only values are returned unchanged.  Org timestamps carry only
minute precision, so sub-minute components never survive a render/parse
cycle; coarsening here keeps content signatures stable across the trip."
  (if (mindwtr-util-iso-date-only-p iso)
      iso
    (format-time-string "%Y-%m-%dT%H:%MZ"
                        (mindwtr-util-iso->time iso)
                        t)))

(defconst mindwtr-util-json-array-fields
  '(:tasks :projects :sections :areas :people ; appdata top-level
    :tags :contexts :checklist :attachments ; task (attachments also project)
    :tagIds                                  ; project
    :byDay :byMonthDay                       ; recurrence
    :savedFilters :savedSearches             ; settings
    :externalCalendars :lastSyncHistory)     ; settings
  "Plist keys whose value is a JSON array.
Emacs cannot tell an empty list from JSON null: both read back as nil.
A nil value for one of these keys must serialize as `[]'; a nil value
for any OTHER key is dropped, because nil means \"absent\" everywhere in
this model and the server rejects `[]' where it expects a scalar (e.g.
a task's deletedAt must be an ISO timestamp when present).  The set is
the union of array-valued field names across the Mindwtr core types
\(Task, Project, Recurrence, Settings); `:order' is deliberately absent
\(a number on entities, an array only inside settings.taskEditor, which
is echoed verbatim and never emitted nil by us).")

(defun mindwtr-util--json-prep (obj)
  "Recursively convert OBJ so json-serialize can handle it.
Plists become JSON objects; plain lists become JSON arrays.  Within an
object, a nil-valued key in `mindwtr-util-json-array-fields' emits `[]',
and any other nil-valued key is omitted (nil means absent)."
  (cond
   ((and (consp obj) (keywordp (car obj)))
    (let ((result nil))
      (while obj
        (let ((k (pop obj))
              (v (pop obj)))
          (cond
           (v (setq result (append result (list k (mindwtr-util--json-prep v)))))
           ((memq k mindwtr-util-json-array-fields)
            (setq result (append result (list k []))))
           (t nil))))            ; drop nil scalar: absent, not [] or null
      result))
   ((listp obj)
    (apply #'vector (mapcar #'mindwtr-util--json-prep obj)))
   (t obj)))

(defun mindwtr-util-json-encode (obj)
  "Encode plist/list OBJ to a JSON string (multibyte text).
Plain lists nested inside the plist are treated as JSON arrays.
`json-serialize' returns UNIBYTE UTF-8 bytes; decode them to characters so
the result is text.  Returning raw bytes leaks `eight-bit' characters into
any multibyte buffer they are inserted in (e.g. the shadow temp file),
which the saver then cannot encode -- the bug that turned a `•' into
\\342\\200\\242 on disk."
  (decode-coding-string
   (json-serialize (mindwtr-util--json-prep obj)
                   :null-object nil :false-object :false)
   'utf-8))

(defun mindwtr-util-json-ascii (obj)
  "Encode OBJ to JSON with all non-ASCII escaped as \\uXXXX (pure ASCII).
Valid JSON that decodes identically server-side, but keeps the HTTP
request body unibyte: `url.el' concatenates the body with header strings
and signals \"Multibyte text in HTTP request\" if the body carries raw
UTF-8.  Astral characters are emitted as UTF-16 surrogate pairs."
  (mapconcat
   (lambda (ch)
     (cond
      ((< ch 128) (char-to-string ch))
      ((<= ch #xFFFF) (format "\\u%04x" ch))
      (t (let ((c (- ch #x10000)))
           (format "\\u%04x\\u%04x"
                   (+ #xD800 (ash c -10)) (+ #xDC00 (logand c #x3FF)))))))
   ;; `mindwtr-util-json-encode' already returns decoded characters.
   (mindwtr-util-json-encode obj) ""))

(defun mindwtr-util-json-decode (s)
  "Decode JSON string S to a plist (arrays as lists)."
  (json-parse-string s :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun mindwtr-util-read-file (path)
  "Return the UTF-8 contents of PATH as a multibyte string, or nil if missing."
  (when (file-exists-p path)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents path))
      (buffer-string))))

(defun mindwtr-util-atomic-write (path content)
  "Write string CONTENT to PATH atomically (temp file + rename), as UTF-8.
Pinning the coding system keeps shadow/etag writes deterministic and
prevents a coding-system prompt when CONTENT carries non-ASCII text."
  (let ((tmp (make-temp-file (concat (file-name-directory path) ".mw-tmp")))
        (coding-system-for-write 'utf-8))
    (with-temp-file tmp
      (insert content))
    (rename-file tmp path t)))

(defun mindwtr-util-plist-omit (plist keys)
  "Return a copy of PLIST without the entries whose key is in KEYS.
KEYS are compared with `memq' (keyword keys).  Single tail walk -- the
shared replacement for the O(n^2) `nth'-indexed strip loops that were
hand-rolled at several sites.  PLIST is not mutated; key order is preserved."
  (let (out)
    (while plist
      (unless (memq (car plist) keys)
        (setq out (cons (cadr plist) (cons (car plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

(provide 'mindwtr-util)
;;; mindwtr-util.el ends here
