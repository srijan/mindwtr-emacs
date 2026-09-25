;;; mindwtr-shadow.el --- Local shadow + sync state -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; The client's durable sync state: the Shadow (last-known-server AppData),
;; the remote ETag, the stable device id, the one-way Migration latches, and
;; the pre-sync backups.  Sync reads it all at once as a baseline at the
;; start of a cycle (`mindwtr-shadow-baseline') and commits it all at once
;; after every surface is durably saved (`mindwtr-shadow-commit'); the
;; latch-after-save rule lives here, not in the sync engine.
;;
;; Beneath the module sits a small internal seam, the store: a key/value
;; blob store addressed by relative names ("shadow.json", "etag",
;; "backups/mindwtr-<ts>.org").  Two adapters satisfy it: the file store
;; rooted at `mindwtr-shadow-directory' (the default, all writes atomic,
;; on-disk layout unchanged from earlier versions) and an in-memory store
;; for tests (`mindwtr-shadow-memory-store').  Everything above the store
;; -- JSON, the last-good copy, latch names, device-id minting, backup
;; naming and retention -- is shared by both.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)

(defvar mindwtr-shadow-directory
  (expand-file-name "mindwtr/" user-emacs-directory)
  "Directory holding shadow.json, etag, device-id, latch markers and backups/.")

(defcustom mindwtr-backup-retention-days 3
  "Delete pre-sync backups older than this many days after each sync.
Age is measured from the timestamp encoded in the backup filename.
nil or any non-positive value disables cleanup (backups are kept forever)."
  :type '(choice (const :tag "Keep forever" nil) integer)
  :group 'mindwtr)

;;; The store seam

(cl-defstruct (mindwtr-shadow-store (:constructor mindwtr-shadow-store--make)
                                    (:copier nil))
  "A key/value blob store beneath the shadow module.
Keys are relative names; values are strings.  GET takes a key and returns
the string or nil.  PUT takes a key and a string, writes durably, and
returns a human-readable location (a path for files).  DELETE takes a key.
KEYS takes a prefix and returns the keys under it."
  get put delete keys)

(defvar mindwtr-shadow-store nil
  "The active store; nil means the file store under `mindwtr-shadow-directory'.
Tests bind this to `(mindwtr-shadow-memory-store)' so a full sync cycle
touches no files.")

(defun mindwtr-shadow--file-path (key)
  (expand-file-name key mindwtr-shadow-directory))

(defconst mindwtr-shadow--file-store
  (mindwtr-shadow-store--make
   :get (lambda (key) (mindwtr-util-read-file (mindwtr-shadow--file-path key)))
   :put (lambda (key content)
          (let ((path (mindwtr-shadow--file-path key)))
            (make-directory (file-name-directory path) t)
            (mindwtr-util-atomic-write path content)
            path))
   :delete (lambda (key)
             (let ((path (mindwtr-shadow--file-path key)))
               (when (file-regular-p path) (delete-file path))))
   :keys (lambda (prefix)
           (let ((dir (mindwtr-shadow--file-path prefix)))
             (when (file-directory-p dir)
               (mapcar (lambda (f) (concat prefix (file-name-nondirectory f)))
                       (seq-filter #'file-regular-p
                                   (directory-files dir t nil t)))))))
  "The file adapter.  Resolves `mindwtr-shadow-directory' on every call, so a
dynamic binding of the directory (as the tests do) takes effect immediately.")

(defun mindwtr-shadow-memory-store ()
  "Return a fresh in-memory store: the second adapter at the store seam."
  (let ((h (make-hash-table :test 'equal)))
    (mindwtr-shadow-store--make
     :get (lambda (key) (gethash key h))
     :put (lambda (key content) (puthash key content h) key)
     :delete (lambda (key) (remhash key h))
     :keys (lambda (prefix)
             (let (ks)
               (maphash (lambda (k _) (when (string-prefix-p prefix k) (push k ks))) h)
               (nreverse ks))))))

(defun mindwtr-shadow--store () (or mindwtr-shadow-store mindwtr-shadow--file-store))
(defun mindwtr-shadow--get (key)
  (funcall (mindwtr-shadow-store-get (mindwtr-shadow--store)) key))
(defun mindwtr-shadow--put (key content)
  (funcall (mindwtr-shadow-store-put (mindwtr-shadow--store)) key content))
(defun mindwtr-shadow--delete (key)
  (funcall (mindwtr-shadow-store-delete (mindwtr-shadow--store)) key))
(defun mindwtr-shadow--keys (prefix)
  (funcall (mindwtr-shadow-store-keys (mindwtr-shadow--store)) prefix))

;;; Shadow, ETag, device id

(defconst mindwtr-shadow--empty
  '(:tasks nil :projects nil :sections nil :areas nil :people nil :settings nil))

(defun mindwtr-shadow-load ()
  "Load and return the shadow AppData plist (empty appdata if absent)."
  (let ((s (mindwtr-shadow--get "shadow.json")))
    (if s (mindwtr-util-json-decode s) (copy-sequence mindwtr-shadow--empty))))

(defun mindwtr-shadow-save (appdata)
  "Persist APPDATA as the shadow, keeping one last-good copy (shadow.bak.json)."
  (let ((prev (mindwtr-shadow--get "shadow.json")))
    (when prev (mindwtr-shadow--put "shadow.bak.json" prev)))
  (mindwtr-shadow--put "shadow.json" (mindwtr-util-json-encode appdata)))

(defun mindwtr-shadow-get-etag ()
  "Return the remote ETag recorded by the last commit, or nil."
  (mindwtr-shadow--get "etag"))

(defun mindwtr-shadow-set-etag (etag)
  "Record ETAG (nil writes an empty tag)."
  (mindwtr-shadow--put "etag" (or etag "")))

(defun mindwtr-shadow-device-id ()
  "Return the stable device id, generating and persisting one if needed."
  (or (mindwtr-shadow--get "device-id")
      (let ((id (format "emacs-%s-%s" (or (system-name) "host")
                        (substring (mindwtr-util-uuid) 0 8))))
        (mindwtr-shadow--put "device-id" id)
        id)))

;;; Migration latches

(defconst mindwtr-shadow-latches
  '((notes . "notes-migrated")
    (fields . "fields-migrated")
    (archive . "archive-migrated")
    (cancel . "cancel-migrated"))
  "The one-way, per-client Migration latches, as (NAME . MARKER-FILE).

Each records \"this client has rendered X at least once\" and guards the
deploy seam created when a field or surface starts being synced: until the
latch is set, an empty parse of that thing means \"not yet migrated\" (keep
the server value) rather than \"the user cleared it\" (push the empty value).

  notes    project/section notes bodies (`mindwtr-model-notes-field').  Before
           the first render by a notes-capable client, an empty parsed note
           must not clear a server-authored note.
  fields   the reserved boolean drawer fields (MW_FOCUS_TODAY, MW_SEQUENTIAL,
           MW_FOCUSED; `mindwtr-model-protected-boolean-fields').  Same false-
           empty seam; `:reviewAt' is deliberately NOT covered, it always
           rendered.
  cancel   task/project `:cancelledAt' (the CANCELLED keyword).  Older
           renders showed a cancelled item as a plain ARCH, which parses
           with no cancellation; that must not clear the server's.
  archive  the Archive surface has been rendered AND saved once.  Before
           that, an archived entity absent from local state is the not-yet-
           rendered backlog and must be echoed, never tombstoned (R8); after,
           strict absence semantics may activate.

A latch flips only through `mindwtr-shadow-commit', after every surface is
confirmed durably on disk: flipping on intent would drop the protection
while the on-disk buffer is still the old render, re-exposing the clobber on
the next reload (KTD5).  A new latch is one more row here.")

(defun mindwtr-shadow--latch-key (latch)
  (or (cdr (assq latch mindwtr-shadow-latches))
      (error "mindwtr-shadow: unknown latch %S" latch)))

(defun mindwtr-shadow-latched-p (latch)
  "Non-nil once LATCH (a name from `mindwtr-shadow-latches') has been set."
  (and (mindwtr-shadow--get (mindwtr-shadow--latch-key latch)) t))

(defun mindwtr-shadow-latch (latch)
  "Set LATCH (a name from `mindwtr-shadow-latches').  One-way."
  (mindwtr-shadow--put (mindwtr-shadow--latch-key latch) "1"))

(defun mindwtr-shadow-latched-names ()
  "Return the list of latch names currently set."
  (seq-filter #'mindwtr-shadow-latched-p (mapcar #'car mindwtr-shadow-latches)))

;;; Baseline and commit: what a sync cycle reads and writes

(cl-defstruct (mindwtr-shadow-baseline (:constructor mindwtr-shadow-baseline--make)
                                       (:copier nil))
  "Everything a sync cycle needs from durable state, read once at the start.
APPDATA is the Shadow, ETAG the last committed remote tag (nil if none),
DEVICE-ID the stable client id, LATCHES the list of latch names already set."
  appdata etag device-id latches)

(defun mindwtr-shadow-baseline ()
  "Read the durable sync state as a `mindwtr-shadow-baseline'."
  (mindwtr-shadow-baseline--make
   :appdata (mindwtr-shadow-load)
   :etag (mindwtr-shadow-get-etag)
   :device-id (mindwtr-shadow-device-id)
   :latches (mindwtr-shadow-latched-names)))

(defun mindwtr-shadow-commit (appdata etag &optional latches)
  "Commit a full sync cycle: APPDATA becomes the Shadow, then ETAG, then LATCHES.
APPDATA is the server's merged result the buffers were just reconciled to;
ETAG its tag.  LATCHES is the list of latch names to flip -- pass it only
when every surface is durably saved; pass nil when a save failed, so
protection stays on until a later cycle rewrites the files.

The shadow and etag writes may signal (the caller runs post-PUT and decides
what a failed durable write means).  Each latch flip is guarded on its own:
a latch write failure is messaged, never thrown, because the server has
already committed and the worst case is one more protected cycle.  Returns
the list of latches that were flipped."
  (mindwtr-shadow-save appdata)
  (mindwtr-shadow-set-etag etag)
  (let (flipped)
    (dolist (l latches)
      (condition-case err
          (progn (mindwtr-shadow-latch l) (push l flipped))
        (error (message "mindwtr: %s latch write failed: %s"
                        (mindwtr-shadow--latch-key l) (error-message-string err)))))
    (nreverse flipped)))

;;; Backups

(defun mindwtr-shadow-backup (prefix &optional now)
  "Store the current buffer's text as the pre-sync backup PREFIX-<timestamp>.org.
Distinct prefixes (\"mindwtr\" vs \"mindwtr-archive\") keep the two surfaces'
backups from colliding.  NOW defaults to the current time.  Returns the
backup's location (its path under the file store)."
  (mindwtr-shadow--put
   (format "backups/%s-%s.org" prefix (format-time-string "%Y%m%dT%H%M%S" now))
   (buffer-substring-no-properties (point-min) (point-max))))

(defun mindwtr-shadow--backup-time (filename)
  "Return the encoded time parsed from a backup FILENAME, or nil.
FILENAME is a non-directory name like \"mindwtr-20260604T080500.org\" or the
archive surface's \"mindwtr-archive-20260604T080500.org\".  Returns nil for any
name that does not match the mindwtr backup pattern."
  (when (string-match
         "\\`mindwtr\\(?:-archive\\)?-\\([0-9]\\{8\\}\\)T\\([0-9]\\{6\\}\\)\\.org\\'"
         filename)
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
retention is nil or <= 0, or when there are no backups.  Only entries
matching the mindwtr-<timestamp>.org pattern with a parseable timestamp are
candidates; anything else is left untouched.  Never signals: cleanup runs in
the post-PUT path, so a failure is messaged and the cycle continues."
  (condition-case err
      (let ((days mindwtr-backup-retention-days))
        (when (and days (> days 0))
          (let ((cutoff (time-subtract (or now (current-time))
                                       (* days 24 60 60))))
            (dolist (key (mindwtr-shadow--keys "backups/"))
              (let ((btime (mindwtr-shadow--backup-time
                            (substring key (length "backups/")))))
                (when (and btime (time-less-p btime cutoff))
                  (mindwtr-shadow--delete key)))))))
    (error (message "mindwtr: backup cleanup skipped: %s"
                    (error-message-string err)))))

(defun mindwtr-shadow-log-report (entry &optional now)
  "Append the sync report ENTRY (text, or nil for none) to the report log.
The log is one org file per month, reports/YYYY-MM.org, kept forever: it
holds each change's before and after values, so it outlives the pre-sync
backups as the record to recover a lost field from.  NOW picks the month.
Never signals (post-PUT path)."
  (when entry
    (condition-case err
        (let ((key (format "reports/%s.org" (format-time-string "%Y-%m" now))))
          (mindwtr-shadow--put key (concat (mindwtr-shadow--get key) entry)))
      (error (message "mindwtr: report log not written: %s"
                      (error-message-string err))))))

;;; Pure helpers

(defun mindwtr-shadow-index (appdata key)
  "Return a hash table id->entity for APPDATA's KEY list (e.g. :tasks)."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e (plist-get appdata key))
      (puthash (plist-get e :id) e h))
    h))

(provide 'mindwtr-shadow)
;;; mindwtr-shadow.el ends here
