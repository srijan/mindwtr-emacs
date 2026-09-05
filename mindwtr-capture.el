;;; mindwtr-capture.el --- org-capture entry point -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; The inbox-capture front door: `mindwtr-capture' drops a new task into the
;; `* Inbox' bucket of `mindwtr-file' with no `org-capture-templates' setup,
;; and `mindwtr-capture-template-entry' builds a registrable template entry
;; for users who prefer the standard `C-c c' dispatcher (the with-link
;; variant also suits an `org-protocol' template).  New headings are stamped
;; with :MW_TYPE: task and a freshly minted :MW_ID:.  The stamping is belt-
;; and-suspenders: the parser also infers `task' for a heading under the
;; Inbox container (`mindwtr-parse--infer-kind'), and the sync engine mints
;; an MW_ID for any new heading lacking one -- so a capture that omits
;; either still round-trips.  This module just makes the heading first-class
;; from birth.
;;; Code:

(require 'org)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-heading)

(defvar mindwtr-file)
(defvar org-capture-templates)
(declare-function org-capture "org-capture" (&optional goto keys))

;;;###autoload
(defun mindwtr-capture-template ()
  "Return an `org-capture' template string for a new Mindwtr inbox task.
A level-1 INBOX heading stamped with :MW_TYPE: task and a freshly minted
lowercase v4 :MW_ID:, with `%?' marking the title cursor.  Used by
`mindwtr-capture-template-entry' as a template-function entry; org-capture
normalizes the heading level to the `* Inbox' target."
  (format "* %s %%?\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: %s\n:END:\n"
          (mindwtr-model-status->keyword 'task "inbox")
          (mindwtr-util-uuid)))

(defun mindwtr-capture-template-with-link ()
  "Like `mindwtr-capture-template' but appends the org-capture annotation (%a)."
  (concat (mindwtr-capture-template) "%a\n%i\n"))

(defun mindwtr-capture--file ()
  "Return `mindwtr-file', erroring helpfully when it is unset.
Doubles as the file element of the capture target, so the variable is read
at capture time, not template-definition time."
  (or (and (boundp 'mindwtr-file) mindwtr-file)
      (user-error "mindwtr-capture: set `mindwtr-file' first")))

(defun mindwtr-capture--goto-inbox ()
  "Move point to the Inbox container heading in the current buffer.
The find-location function of the `file+function' capture target.  Prefers
the container whose :MW_LIST: is `inbox' (robust to a renamed heading);
falls back to a literal top-level `* Inbox' headline for a hand-written
file; errors when neither exists."
  (goto-char (point-min))
  (let ((pos (mindwtr-heading-find-role "inbox")))
    (cond
     (pos (goto-char pos))
     ((re-search-forward "^\\* Inbox[ \t]*$" nil t)
      (beginning-of-line))
     (t (user-error "mindwtr-capture: no `* Inbox' container in %s (run `mindwtr-bootstrap'?)"
                    (buffer-name))))))

(defun mindwtr-capture-template-entry (&optional key description with-link)
  "Return an `org-capture-templates' entry capturing into the Mindwtr inbox.
KEY (default \"m\") and DESCRIPTION (default \"Mindwtr inbox\") name the
template; non-nil WITH-LINK uses the annotation-appending variant (the
right one for `org-protocol' captures).  Register it permanently with

  (add-to-list \\='org-capture-templates (mindwtr-capture-template-entry))

or skip registration entirely and use `mindwtr-capture'."
  (list (or key "m") (or description "Mindwtr inbox") 'entry
        '(file+function mindwtr-capture--file mindwtr-capture--goto-inbox)
        (list 'function (if with-link
                            #'mindwtr-capture-template-with-link
                          #'mindwtr-capture-template))))

;;;###autoload
(defun mindwtr-capture (&optional with-link)
  "Capture a new task straight into the Mindwtr inbox.
A self-contained front door over `org-capture' -- no
`org-capture-templates' setup needed.  With prefix argument WITH-LINK,
append the org-capture annotation (a link back to where you were) to the
entry.  Finish with `C-c C-c' as usual; the heading lands under `* Inbox'
in `mindwtr-file', stamped with :MW_TYPE: task and a fresh :MW_ID:."
  (interactive "P")
  (require 'org-capture)
  (mindwtr-capture--file)               ; fail fast, before any capture UI
  (let ((org-capture-templates
         (list (mindwtr-capture-template-entry "m" nil with-link))))
    (org-capture nil "m")))

(provide 'mindwtr-capture)
;;; mindwtr-capture.el ends here
