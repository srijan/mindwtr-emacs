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

(defvar mindwtr-file)
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

(provide 'mindwtr-archive)
;;; mindwtr-archive.el ends here
