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

(defun mindwtr-agenda--project-stuck-p ()
  "Non-nil when the project heading at point is stuck.
A project is stuck when it is active (TODO keyword ACTIVE) and has no
descendant carrying the NEXT keyword.  Only NEXT clears stuck: WAIT, SOMEDAY,
and DONE children do not.  The scan covers the whole subtree, so a NEXT task
nested under a section still counts.  Returns nil off an active project
heading.  Used both as the Projects view's inline stuck flag and its sort key,
so the definition lives in one place."
  (save-excursion
    (org-back-to-heading t)
    (and (equal (org-get-todo-state) "ACTIVE")
         (let ((end (save-excursion (org-end-of-subtree t t) (point)))
               (found nil))
           (save-excursion
             (while (and (not found)
                         (outline-next-heading)
                         (< (point) end))
               (when (equal (org-get-todo-state) "NEXT")
                 (setq found t))))
           (not found)))))

;;; Engage view ----------------------------------------------------------------

(defun mindwtr-agenda--engage-spec ()
  "Return the composite `org-agenda-custom-commands' entry for the Engage view.
Blocks, in order (R1): today's calendar, Today's Focus, Next Actions, Waiting
For, and the Inbox last.

The Next Actions block excludes focused tasks with the property INEQUALITY
`MW_FOCUS_TODAY<>\"t\"', not tag negation `-MW_FOCUS_TODAY': MW_FOCUS_TODAY is
a drawer property (it renders as `:MW_FOCUS_TODAY: t'), so `-MW_FOCUS_TODAY'
would negate a non-existent tag and fail to dedup.  The inequality form also
correctly matches the common case where the property is absent (every
non-focused task), so those still appear under Next Actions.

The calendar block is a single day (`org-agenda-span' 1) and deliberately does
NOT override `org-deadline-warning-days': upcoming deadlines surface through the
user's own org default (R2)."
  `("e" "Mindwtr Engage"
    ((agenda ""
             ((org-agenda-span 1)
              (org-agenda-overriding-header "Today")))
     (tags-todo "MW_FOCUS_TODAY=\"t\""
                ((org-agenda-overriding-header "Today's Focus")))
     (tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""
                ((org-agenda-overriding-header "Next Actions")))
     (tags-todo "TODO=\"WAIT\""
                ((org-agenda-overriding-header "Waiting For")))
     (tags-todo "TODO=\"INBOX\""
                ((org-agenda-overriding-header "Inbox"))))))

;;;###autoload
(defun mindwtr-engage ()
  "Open the Mindwtr Engage agenda: today, focus, next actions, waiting, inbox.
Scopes `org-agenda-files' to the Mindwtr file and builds the view dynamically,
so it works with no global agenda configuration."
  (interactive)
  (let ((org-agenda-files (mindwtr-agenda--files))
        (org-agenda-custom-commands (list (mindwtr-agenda--engage-spec))))
    (org-agenda nil "e")))

(provide 'mindwtr-agenda)
;;; mindwtr-agenda.el ends here
