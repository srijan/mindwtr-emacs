;;; mindwtr-archive.el --- The synced archive-file surface -*- lexical-binding: t; -*-
;;; Commentary:
;; Owns the archive file's location and buffer.  The archive file
;; (`mindwtr_archive.org' by default) is a SECOND synced render surface: the
;; sync engine parses it as local state and reconcile rebuilds it canonically
;; each full cycle, exactly like the main file.  This module is the seam every
;; other piece keys on -- when `mindwtr-archive-path' returns nil the surface
;; is INACTIVE and the engine runs its legacy single-file path unchanged.
;;
;; Resolution anchors on `mindwtr-file' first, then the current buffer's file
;; (KTD8): hooks and timers run with arbitrary buffers current -- including the
;; archive buffer itself -- so the derivation must not depend on which buffer
;; happens to be current when `mindwtr-file' is configured.
;;
;; The module deliberately never `require's `mindwtr.el': that would close a
;; cycle (`mindwtr.el' -> `mindwtr-sync.el' -> `mindwtr-archive.el').
;; `mindwtr-mode' is reached through `fboundp'/`declare-function' instead, so
;; the archive buffer still opens in the right major mode once `mindwtr.el'
;; has loaded, without this lower layer depending on it.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)

(defvar mindwtr-file)
;; Declared in `mindwtr-sync' (the layer that requires this one), so the quiet
;; save below can stand down the after-save debounce without a require cycle.
(defvar mindwtr--inhibit-save-sync)
(declare-function mindwtr-mode "mindwtr")

(defcustom mindwtr-archive-file nil
  "Where the synced archive file lives.
nil   -- derive `mindwtr_archive.org' beside the anchor file (`mindwtr-file'
         if set, else the current buffer's file).
string -- an explicit path, used verbatim.
function -- called with no arguments; its return value is the path.

A nil value with no anchor file (a temp buffer with `mindwtr-file' unset)
leaves the archive surface INACTIVE -- the legacy single-file behavior that
existing temp-buffer flows and tests rely on."
  :type '(choice (const :tag "Derive beside the anchor file" nil)
                 (file :tag "Explicit path")
                 (function :tag "Function returning a path"))
  :group 'mindwtr)

(defun mindwtr-archive-path ()
  "Return the archive file's path, or nil when the surface is inactive.
A custom string is returned verbatim and a custom function is called for the
path (both make the surface active regardless of any anchor file).  With the
default nil custom, the path is `mindwtr_archive.org' beside the anchor file --
`mindwtr-file' when set, else the current buffer's visited file -- and nil when
neither exists.  Anchoring on `mindwtr-file' first (KTD8) keeps the derivation
stable no matter which buffer is current."
  (cond
   ((functionp mindwtr-archive-file) (funcall mindwtr-archive-file))
   ((and (stringp mindwtr-archive-file) (not (string-empty-p mindwtr-archive-file)))
    mindwtr-archive-file)
   (t
    (let ((anchor (or (and (boundp 'mindwtr-file) mindwtr-file) buffer-file-name)))
      (when anchor
        (expand-file-name "mindwtr_archive.org"
                          (file-name-directory (expand-file-name anchor))))))))

(defun mindwtr-archive-buffer (&optional no-create)
  "Return the buffer visiting the archive file, or nil when surface is inactive.
By default the file is visited (`find-file-noselect'), creating a buffer for a
not-yet-existing file; with NO-CREATE non-nil only an already-visiting buffer
is returned (nil when none).  A returned buffer is put into `mindwtr-mode' when
that mode is available (guarded with `fboundp' to avoid requiring `mindwtr.el'),
so it carries the Mindwtr TODO keywords and status keybindings (R10)."
  (let ((path (mindwtr-archive-path)))
    (when path
      (let ((buf (if no-create
                     (find-buffer-visiting path)
                   (find-file-noselect path))))
        (when (and buf (fboundp 'mindwtr-mode))
          (with-current-buffer buf
            (unless (derived-mode-p 'mindwtr-mode) (mindwtr-mode))))
        buf))))

;;; Immediate refile -----------------------------------------------------------

(defun mindwtr-archive--target-or-error ()
  "Return (KIND . ID) for the refilable heading at point, or signal `user-error'.
Signals -- WITHOUT mutating the buffer -- when the archive surface is inactive,
point is not on a task or project heading, or the heading lacks an MW_ID."
  (unless (mindwtr-archive-path)
    (user-error "mindwtr-archive: the archive surface is inactive (no archive file)"))
  (save-excursion
    (unless (ignore-errors (org-back-to-heading t) t)
      (user-error "mindwtr-archive: point is not on a heading"))
    (let ((kind (let ((ty (mindwtr-parse--prop "MW_TYPE"))) (and ty (intern ty))))
          (id (mindwtr-parse--prop "MW_ID")))
      (unless (memq kind '(task project))
        (user-error "mindwtr-archive: point is not on a task or project heading"))
      (unless id
        (user-error "mindwtr-archive: heading has no MW_ID"))
      (cons kind id))))

(defun mindwtr-archive--ensure-container ()
  "Return the position of the archive buffer's `* Archive' container.
Creates it (plus a leading keyword line so org honours ARCH etc.) at the end of
the buffer when absent.  Point is left undefined; callers reposition."
  (goto-char (point-min))
  (if (re-search-forward "^[ \t]*:MW_LIST:[ \t]*archive[ \t]*$" nil t)
      (progn (org-back-to-heading t) (point))
    (goto-char (point-min))
    (unless (re-search-forward "^#\\+TODO:" nil t)
      (goto-char (point-min))
      (insert (mindwtr-model-todo-keyword-line) "\n"))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (let ((pos (point)))
      (insert (mindwtr-render--container "archive" 1))
      pos)))

(defun mindwtr-archive--save-quietly (buffer)
  "Save BUFFER to disk best-effort, without arming the auto-sync or signaling.
Binds `mindwtr--inhibit-save-sync' so the engine-style save stands down the
after-save debounce; a write failure is caught and reported, never thrown (the
refile is UX only -- R7)."
  (with-current-buffer buffer
    (when (and (buffer-file-name) (buffer-modified-p))
      (let ((mindwtr--inhibit-save-sync t))
        (condition-case err
            (save-buffer)
          (error (message "mindwtr-archive: save failed: %s"
                          (error-message-string err))))))))

(defun mindwtr-archive-refile-at-point ()
  "Move the task/project subtree at point into the archive file immediately.
Validates the target (`mindwtr-archive--target-or-error'); for a task, stamps
its containment (MW_PROJECT_ID/MW_SECTION_ID, section first) from the ancestry
it is about to lose (KTD7) so it round-trips across the file split; then cuts
the subtree, re-roots it to level 2 under the archive file's `* Archive'
container (created if absent), and saves both buffers quietly.

UX only (R7): correctness never depends on this -- a failure or an inactive
surface leaves the heading in place with its keyword, and the next sync performs
the identical move via ordinary parse/render.  Returns t on success."
  (let* ((target (mindwtr-archive--target-or-error))
         (kind (car target))
         (abuf (mindwtr-archive-buffer))
         (src (current-buffer)))
    (org-back-to-heading t)
    (when (eq kind 'task)
      (let ((sid (mindwtr-parse--ancestor-id 'section))
            (pid (mindwtr-parse--ancestor-id 'project)))
        (cond (sid (org-set-property "MW_SECTION_ID" sid))
              (pid (org-set-property "MW_PROJECT_ID" pid)))))
    (org-cut-subtree)
    (with-current-buffer abuf
      (let ((c (mindwtr-archive--ensure-container)))
        (goto-char c)
        (org-end-of-subtree t t)
        (org-paste-subtree 2)))
    (mindwtr-archive--save-quietly src)
    (mindwtr-archive--save-quietly abuf)
    t))

;;;###autoload
(defun mindwtr-archive-item-at-point ()
  "Archive the task or project at point: set ARCH and refile it immediately.
Signals a `user-error' WITHOUT mutating the buffer when point is not on a
task/project heading with an MW_ID, or the archive surface is inactive -- so an
invalid target never half-archives.  On success the subtree moves under the
archive file's `* Archive' container and both buffers are saved (R6)."
  (interactive)
  (mindwtr-archive--target-or-error)
  (save-excursion (org-back-to-heading t) (org-todo "ARCH"))
  (mindwtr-archive-refile-at-point))

(provide 'mindwtr-archive)
;;; mindwtr-archive.el ends here
