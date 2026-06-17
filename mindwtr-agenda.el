;;; mindwtr-agenda.el --- Opt-in org-agenda views for the Mindwtr file -*- lexical-binding: t; -*-
;;; Commentary:
;; Two opt-in `org-agenda' views over the Mindwtr file:
;;   `mindwtr-engage'   -- today's calendar, Today's Focus, Next Actions,
;;                         Waiting For, and the Inbox (in that order).
;;   `mindwtr-projects' -- active projects, with stuck ones (no NEXT action)
;;                         flagged inline and floated to the top.
;;
;; Each command builds its agenda dynamically and scopes `org-agenda-files' to
;; the Mindwtr file alone (the archive file is excluded -- archived/done
;; entities are not actionable), so the views work whether or not the user has
;; added the Mindwtr file to their global agenda configuration.  Nothing is
;; written to the user's global `org-agenda-custom-commands'.
;;
;; `mindwtr-agenda-setup' binds both commands under a configurable prefix
;; (default "C-c d": `e' -> Engage, `p' -> Projects).  The commands are also
;; plain `M-x'-invocable.
;;
;; This module deliberately never `require's `mindwtr.el' (which requires this
;; one): `mindwtr-file' is reached through a forward `defvar', mirroring
;; `mindwtr-archive.el'.
;;; Code:

(require 'org)
(require 'org-agenda)
(require 'mindwtr-model)

(defvar mindwtr-file)

(defcustom mindwtr-agenda-prefix-key "C-c d"
  "Key prefix `mindwtr-agenda-setup' binds the Mindwtr agenda commands under.
Beneath this prefix, `e' is bound to `mindwtr-engage' and `p' to
`mindwtr-projects'.  A key description string as understood by `kbd'."
  :type 'string :group 'mindwtr)

(defun mindwtr-agenda--files ()
  "Return the agenda file list scoped to the Mindwtr task file.
Signals a clear error when `mindwtr-file' is unset (mirrors the guard in
`mindwtr--prepare').  Deliberately excludes the archive file: archived and
done entities are not actionable and must not appear in these views."
  (unless mindwtr-file (error "mindwtr-agenda: set `mindwtr-file'"))
  (list mindwtr-file))

(provide 'mindwtr-agenda)
;;; mindwtr-agenda.el ends here
