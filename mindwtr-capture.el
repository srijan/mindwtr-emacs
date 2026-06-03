;;; mindwtr-capture.el --- org-capture entry point -*- lexical-binding: t; -*-
;;; Commentary:
;; A capture template that drops a new task into the `* Inbox' bucket, stamped
;; with :MW_TYPE: task and a freshly minted :MW_ID:.  The stamping is belt-and-
;; suspenders: the parser also infers `task' for a heading under the Inbox
;; container (`mindwtr-parse--infer-kind'), and the sync engine mints an MW_ID
;; for any new heading lacking one -- so a capture that omits either still
;; round-trips.  This template just makes the heading first-class from birth.
;;; Code:

(require 'mindwtr-util)
(require 'mindwtr-model)

(defun mindwtr-capture-template ()
  "Return an `org-capture' template string for a new Mindwtr inbox task.
A level-1 INBOX heading stamped with :MW_TYPE: task and a freshly minted
lowercase v4 :MW_ID:, with `%?' marking the title cursor.  Intended as a
template-function entry in `org-capture-templates':

  (add-to-list \\='org-capture-templates
    \\=`(\"m\" \"Mindwtr inbox\" entry
       (file+headline mindwtr-file \"Inbox\")
       (function mindwtr-capture-template)))

org-capture normalizes the heading level to the `* Inbox' target."
  (format "* %s %%?\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: %s\n:END:\n"
          (mindwtr-model-status->keyword 'task "inbox")
          (mindwtr-util-uuid)))

(defun mindwtr-capture-template-with-link ()
  "Like `mindwtr-capture-template' but appends the org-capture annotation (%a)."
  (concat (mindwtr-capture-template) "%a\n%i\n"))

(provide 'mindwtr-capture)
;;; mindwtr-capture.el ends here
