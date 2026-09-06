;;; mindwtr-report.el --- Sync report buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Renders sync stats, incoming remote changes, conflicts (local edits the
;; server overrode) with a per-field diff, the pre-sync backup path, and
;; clock-skew warnings into *Mindwtr Sync Report*.  The buffer is an
;; append-only, org-structured log: each sync worth reporting adds a new
;; top-level heading stamped with the sync time, so the history of what came
;; in is browsable (and foldable) rather than overwritten.  Each conflict line
;; on the NEWEST entry carries the data needed for a one-key "restore my edit"
;; action (\\[mindwtr-report-restore-conflict]); older entries are read-only
;; history with the restore affordance stripped.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-reconcile)

(defvar-local mindwtr-report--target-buffer nil
  "The org buffer a restore action should write back into.")

(defvar-local mindwtr-report--backup-file nil
  "Path of the pre-sync buffer backup, surfaced when a restore is incomplete.")

(defvar-local mindwtr-report--newest-entry nil
  "Buffer position where the most recently appended sync entry begins.
Point is moved here when the report pops for an actionable event (R9).")

(defun mindwtr-report--field-diff (mine theirs)
  "Return a list of (FIELD MINE-VALUE THEIRS-VALUE) for content fields that
differ between MINE and THEIRS.  Comparison is canonical (tag order,
sub-minute timestamps, and checklist item ids are normalized) so only
genuine content differences are reported; non-content fields (rev,
updatedAt, ...) are ignored by construction."
  (let (diffs)
    (dolist (k mindwtr-model-content-fields)
      (unless (equal (mindwtr-signature-field-canonical k (plist-get mine k))
                     (mindwtr-signature-field-canonical k (plist-get theirs k)))
        (push (list k (plist-get mine k) (plist-get theirs k)) diffs)))
    (nreverse diffs)))

(defun mindwtr-report--fmt (v)
  "Format a field value V for display in the diff."
  (cond ((null v) "(empty)")
        ((stringp v) v)
        (t (prin1-to-string v))))

(defun mindwtr-report--cl-box (it)
  "Checkbox character (\"X\" or \" \") for checklist item IT."
  (if (eq (plist-get it :isCompleted) t) "X" " "))

(defun mindwtr-report--cl-title (it)
  "Title string for checklist item IT (empty string when absent)."
  (or (plist-get it :title) ""))

(defun mindwtr-report--cl-align (before after)
  "Align checklist item lists BEFORE and AFTER by title via LCS.
Returns an ordered list of ops: (match B A) | (del B) | (ins A).  Items
with equal titles anchor as `match' even when they moved, so insertions
and deletions stand out rather than shifting every later item."
  (let* ((b (vconcat before)) (a (vconcat after))
         (n (length b)) (m (length a))
         (w (1+ m))
         (dp (make-vector (* (1+ n) w) 0)))
    (cl-flet ((at (i j) (aref dp (+ (* i w) j))))
      (dotimes (ii n)
        (let ((i (- n 1 ii)))
          (dotimes (jj m)
            (let ((j (- m 1 jj)))
              (aset dp (+ (* i w) j)
                    (if (equal (mindwtr-report--cl-title (aref b i))
                               (mindwtr-report--cl-title (aref a j)))
                        (1+ (at (1+ i) (1+ j)))
                      (max (at (1+ i) j) (at i (1+ j)))))))))
      (let ((i 0) (j 0) ops)
        (while (and (< i n) (< j m))
          (cond
           ((equal (mindwtr-report--cl-title (aref b i))
                   (mindwtr-report--cl-title (aref a j)))
            (push (list 'match (aref b i) (aref a j)) ops)
            (cl-incf i) (cl-incf j))
           ((>= (at (1+ i) j) (at i (1+ j)))
            (push (list 'del (aref b i)) ops) (cl-incf i))
           (t (push (list 'ins (aref a j)) ops) (cl-incf j))))
        (while (< i n) (push (list 'del (aref b i)) ops) (cl-incf i))
        (while (< j m) (push (list 'ins (aref a j)) ops) (cl-incf j))
        (nreverse ops)))))

(defun mindwtr-report--cl-rename-p (s1 s2)
  "Non-nil when titles S1 and S2 look like a rename, not unrelated items.
Pairs a deletion with an adjacent insertion only when they share a
leading run or enough word tokens, so a genuine swap stays as `-'/`+'."
  (let ((a (downcase s1)) (b (downcase s2)))
    (or (string-prefix-p a b) (string-prefix-p b a)
        (>= (let ((k 0) (len (min (length a) (length b))))
              (while (and (< k len) (eq (aref a k) (aref b k))) (cl-incf k))
              k)
            4)
        (let* ((t1 (split-string a "[^[:alnum:]]+" t))
               (t2 (split-string b "[^[:alnum:]]+" t))
               (common (seq-intersection t1 t2 #'string=)))
          (and t1 t2 (>= (length common)
                         (max 1 (/ (min (length t1) (length t2)) 2))))))))

(defun mindwtr-report--cl-rename-line (b a)
  "One `~' rename line from checklist item B to item A.
Includes the `[ ]->[X]' completion marker only when it changed."
  (let ((bb (mindwtr-report--cl-box b)) (ab (mindwtr-report--cl-box a)))
    (if (string= bb ab)
        (format "~ %s → %s"
                (mindwtr-report--cl-title b) (mindwtr-report--cl-title a))
      (format "~ [%s]→[%s] %s → %s" bb ab
              (mindwtr-report--cl-title b) (mindwtr-report--cl-title a)))))

(defun mindwtr-report--cl-flush-block (dels inss)
  "Render a change block of deleted items DELS and inserted items INSS.
Pairs them positionally into rename lines where the titles look related
\(see `mindwtr-report--cl-rename-p'); unpaired items fall back to `-'/`+'."
  (let (lines)
    (dotimes (k (max (length dels) (length inss)))
      (let ((d (nth k dels)) (a (nth k inss)))
        (cond
         ((and d a (mindwtr-report--cl-rename-p
                    (mindwtr-report--cl-title d) (mindwtr-report--cl-title a)))
          (push (mindwtr-report--cl-rename-line d a) lines))
         (t
          (when d (push (format "- [%s] %s" (mindwtr-report--cl-box d)
                                (mindwtr-report--cl-title d))
                        lines))
          (when a (push (format "+ [%s] %s" (mindwtr-report--cl-box a)
                                (mindwtr-report--cl-title a))
                        lines))))))
    (nreverse lines)))

(defun mindwtr-report--checklist-summary-lines (before after)
  "Compact change lines for the checklist diff BEFORE → AFTER.
Each line is one of: `+ [X] T' (added), `- [ ] T' (removed),
`~ ... → ...' (renamed, optionally with a completion change), or a
`~ [ ]->[X] T' completion toggle.  Unchanged items are omitted.

Consecutive deletions and insertions form a change block that is paired
positionally, so two items renamed in place read as two `~' lines rather
than as deletions backwards-zipped against insertions."
  (let ((ops (mindwtr-report--cl-align before after))
        lines dels inss)
    (cl-flet ((flush ()
                (when (or dels inss)
                  (setq lines (nconc (nreverse (mindwtr-report--cl-flush-block
                                                (nreverse dels) (nreverse inss)))
                                     lines))
                  (setq dels nil inss nil))))
      (dolist (op ops)
        (pcase (car op)
          ('del (push (nth 1 op) dels))
          ('ins (push (nth 1 op) inss))
          ('match
           (flush)
           (let ((b (nth 1 op)) (a (nth 2 op)))
             (unless (eq (eq (plist-get b :isCompleted) t)
                         (eq (plist-get a :isCompleted) t))
               (push (format "~ [%s]→[%s] %s"
                             (mindwtr-report--cl-box b) (mindwtr-report--cl-box a)
                             (mindwtr-report--cl-title a))
                     lines))))))
      (flush))
    (nreverse lines)))

(defun mindwtr-report--insert-field-diff (d indent)
  "Insert diff tuple D (FIELD BEFORE AFTER) at point, prefixed by INDENT.
Most fields render as a single `field: before → after' line; the
checklist renders as a header plus one compact change line per item."
  (let ((field (substring (symbol-name (nth 0 d)) 1))
        (before (nth 1 d)) (after (nth 2 d)))
    (if (eq (nth 0 d) :checklist)
        (let ((lines (mindwtr-report--checklist-summary-lines before after)))
          (if (null lines)
              (insert (format "%s%s: %s → %s\n" indent field
                              (mindwtr-report--fmt before)
                              (mindwtr-report--fmt after)))
            (insert (format "%s%s:\n" indent field))
            (dolist (l lines)
              (insert (format "%s  %s\n" indent l)))))
      (insert (format "%s%s: %s → %s\n" indent field
                      (mindwtr-report--fmt before)
                      (mindwtr-report--fmt after))))))

(defvar mindwtr-report-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "r" #'mindwtr-report-restore-conflict)
    m)
  "Keymap for `mindwtr-report-mode'.
Inherits `org-mode-map' through the derived-mode chain (so TAB / `org-cycle'
folding of the timestamped sync log stays live); `r' overrides org's binding
on that key for the restore action.")

(define-derived-mode mindwtr-report-mode org-mode "Mindwtr-Report"
  "Major mode for the *Mindwtr Sync Report* buffer.
Derives from `org-mode' so the append-only sync log folds natively.  The
buffer is read-only; the sync engine writes under `inhibit-read-only'."
  (setq buffer-read-only t)
  (setq-local org-inhibit-startup t))

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

(defun mindwtr-report--change-label (change)
  "Human-readable label for an incoming CHANGE symbol."
  (pcase change
    ('created "created")
    ('updated "updated")
    ('deleted "deleted")
    (_ (format "%s" change))))

(defun mindwtr-report--reportable-p (stats conflicts skew-warning parse-warnings incoming-changes)
  "Non-nil when this sync carries anything worth a new log entry (R6).
A sync with no proposed changes, no incoming remote changes, no conflict,
no skew, and no parse warning appends no heading."
  (or (> (+ (or (plist-get stats :created) 0)
            (or (plist-get stats :updated) 0)
            (or (plist-get stats :deleted) 0))
         0)
      conflicts skew-warning parse-warnings incoming-changes))

(defun mindwtr-report--insert-entry (stats conflicts skew-warning backup-file
                                           parse-warnings incoming-changes sync-time
                                           &optional local-changes)
  "Insert one timestamped sync entry at point (end of buffer).
`inhibit-read-only' must be bound.  Conflict blocks are tagged with the
`mindwtr-conflict' text property so the restore action can find them; the
caller strips that property from prior entries before this runs, leaving
restore live only on this newest entry (R8)."
  (insert (format "* %s\n" (or sync-time (format-time-string "%Y-%m-%d %H:%M:%S"))))
  ;; These count what this device PROPOSED (local vs shadow); the conflicts
  ;; below report what the server actually overrode.
  (insert (format "  Proposed — Created: %d   Updated: %d   Deleted: %d\n"
                  (or (plist-get stats :created) 0)
                  (or (plist-get stats :updated) 0)
                  (or (plist-get stats :deleted) 0)))
  (dolist (lc local-changes)
    (insert (format "    ↑ %s (%s) — %s\n"
                    (or (plist-get lc :title) "(untitled)")
                    (plist-get lc :kind)
                    (mindwtr-report--change-label (plist-get lc :change))))
    (when (and (eq (plist-get lc :change) 'updated)
               (plist-get lc :before) (plist-get lc :after))
      (dolist (d (mindwtr-report--field-diff (plist-get lc :before) (plist-get lc :after)))
        (mindwtr-report--insert-field-diff d "        "))))
  (when incoming-changes
    (insert "  Incoming from remote:\n")
    (dolist (ic incoming-changes)
      (insert (format "    ↓ %s (%s) — %s\n"
                      (or (plist-get ic :title) "(untitled)")
                      (plist-get ic :kind)
                      (mindwtr-report--change-label (plist-get ic :change))))
      (when (and (eq (plist-get ic :change) 'updated)
                 (plist-get ic :before) (plist-get ic :after))
        (dolist (d (mindwtr-report--field-diff (plist-get ic :before) (plist-get ic :after)))
          (mindwtr-report--insert-field-diff d "        ")))))
  (when skew-warning
    (insert (format "  ⚠ Clock skew: %s\n" skew-warning)))
  (when parse-warnings
    (let ((dupes (seq-filter (lambda (w) (plist-get w :duplicate)) parse-warnings))
          (kw (seq-remove (lambda (w) (plist-get w :duplicate)) parse-warnings)))
      (when kw
        (insert (format "  ⚠ %d heading(s) with an invalid status keyword (status left unchanged):\n"
                        (length kw)))
        (dolist (w kw)
          (insert (format "    • %s %S — %s is not a valid %s status\n"
                          (or (plist-get w :id) "(new)")
                          (plist-get w :title)
                          (plist-get w :keyword)
                          (plist-get w :kind)))))
      (when dupes
        (insert (format "  ⚠ %d id(s) present in more than one file; the archive-file copy was dropped (edit not applied):\n"
                        (length dupes)))
        (dolist (w dupes)
          (insert (format "    • %s\n" (plist-get w :id)))))))
  (when backup-file
    (insert (format "  Pre-sync backup: %s\n" backup-file)))
  (if (null conflicts)
      (insert "  No conflicts. All local edits accepted.\n")
    (insert (format "  %d local edit(s) overridden by newer remote edits.\n"
                    (length conflicts)))
    (insert "  Press `r' on a conflict to restore your edit.\n")
    (dolist (c conflicts)
      (let ((start (point))
            (mine (plist-get c :mine))
            (theirs (plist-get c :theirs)))
        (insert (format "  • %s%s\n"
                        (plist-get c :id)
                        (if (plist-get c :kind)
                            (format " (%s)" (plist-get c :kind)) "")))
        ;; Attribute the winning server version (#28).  `sync-repair' is the
        ;; server's integrity pass (e.g. it empties a task's areaId when the
        ;; referenced area was deleted on another device) -- worth telling
        ;; apart from a genuine concurrent edit by another device.
        (let ((by (plist-get theirs :revBy)))
          (when by
            (insert (if (equal by "sync-repair")
                        "      server edit by: sync-repair (server integrity repair, e.g. a referenced area or project was deleted)\n"
                      (format "      server edit by: %s\n" by)))))
        (let ((diff (mindwtr-report--field-diff mine theirs)))
          (if (null diff)
              (insert "      (no field-level difference)\n")
            (dolist (d diff)
              (insert (format "      %s\n          yours : %s\n          server: %s\n"
                              (substring (symbol-name (nth 0 d)) 1)
                              (mindwtr-report--fmt (nth 1 d))
                              (mindwtr-report--fmt (nth 2 d)))))))
        ;; Tag the whole block so `r' anywhere within it restores.
        (put-text-property start (point) 'mindwtr-conflict c))))
  (insert "\n"))

(defun mindwtr-report-show (result &optional target-buffer backup-file sync-time)
  "Append a sync entry for RESULT, a sync cycle's result plist; return the buffer.
RESULT carries :stats (the create/update/delete counts), :conflicts (local
edits the server overrode), :skew (the server's clock-skew warning),
:warnings (parse warnings: plists (:id :title :keyword :kind) for headings
whose TODO keyword was not valid for their entity kind), :incoming (remote
changes the merge pulled in, plists (:id :kind :title :change), R1) and
:local-changes (what this device proposed).  Any key may be absent.

The report is an append-only org log: each reportable sync adds a top-level
heading (R5) rather than erasing prior content, and the log persists for the
buffer's lifetime -- killing the buffer starts a fresh log on the next sync
\(R7).  A sync with nothing to report appends no heading (R6).

TARGET-BUFFER is the org buffer a restore action writes back into.
BACKUP-FILE, when given, is the pre-sync buffer snapshot, surfaced so a lost
edit can be recovered from disk.  SYNC-TIME overrides the heading timestamp
\(defaults to the current time).

Only conflicts, skew, and parse warnings pop the window; incoming changes
append quietly, preserving the user's point and scroll.  On an actionable pop,
point lands on the newest entry (R9).  The whole render is wrapped so a
rendering hiccup in this post-PUT path cannot throw a spurious sync failure
\(KTD6)."
  (let ((stats (plist-get result :stats))
        (conflicts (plist-get result :conflicts))
        (skew-warning (plist-get result :skew))
        (parse-warnings (plist-get result :warnings))
        (incoming-changes (plist-get result :incoming))
        (local-changes (plist-get result :local-changes)))
    (mindwtr-report--show stats conflicts skew-warning backup-file target-buffer
                          parse-warnings incoming-changes sync-time local-changes)))

(defun mindwtr-report--show (stats conflicts skew-warning backup-file
                                   target-buffer parse-warnings incoming-changes
                                   sync-time local-changes)
  "Render one entry; see `mindwtr-report-show' for the arguments."
  (let ((buf (get-buffer-create "*Mindwtr Sync Report*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'mindwtr-report-mode)
        (let ((org-inhibit-startup t))
          (mindwtr-report-mode)))
      (setq mindwtr-report--target-buffer target-buffer
            mindwtr-report--backup-file backup-file)
      (condition-case err
          (when (mindwtr-report--reportable-p stats conflicts skew-warning
                                              parse-warnings incoming-changes)
            (let ((inhibit-read-only t))
              ;; A freshly created (or killed-then-recreated) buffer is empty;
              ;; seed the static title header once (R7).
              (when (= (buffer-size) 0)
                (insert "Mindwtr Sync Report\n===================\n\n"))
              ;; Restore stays live only on the newest entry: strip the
              ;; affordance from all prior content before appending (R8).
              (remove-text-properties (point-min) (point-max)
                                      '(mindwtr-conflict nil))
              (goto-char (point-max))
              (setq mindwtr-report--newest-entry (point))
              (mindwtr-report--insert-entry stats conflicts skew-warning
                                            backup-file parse-warnings
                                            incoming-changes sync-time
                                            local-changes)))
        (error
         (message "mindwtr: sync report render failed: %s"
                  (error-message-string err)))))
    ;; Only steal a window when there is something to act on; a clean
    ;; auto-sync (or a quiet incoming-only pull) should not pop the report.
    ;; The buffer is updated regardless, so it is there when the user looks.
    (when (or conflicts skew-warning parse-warnings)
      (let ((w (display-buffer buf))
            (entry (buffer-local-value 'mindwtr-report--newest-entry buf)))
        (when entry
          (with-current-buffer buf (goto-char entry))
          (when w (set-window-point w entry)))))
    buf))

(provide 'mindwtr-report)
;;; mindwtr-report.el ends here
