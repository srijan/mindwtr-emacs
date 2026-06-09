;;; mindwtr-clarify.el --- Guided inbox triage (clarify workflow) -*- lexical-binding: t; -*-
;;; Commentary:
;; A guided pass over the `* Inbox' items -- the org-gtd clarify/organize
;; wizard, rebuilt on the existing type-aware commands instead of a new
;; state machine.  `mindwtr-clarify' visits each inbox item in turn and
;; runs a single-key action loop: set a type-valid status
;; (`mindwtr-set-status', which also relocates the item to its status
;; bucket), edit contexts/hashtags (org tags), set an area
;; (`mindwtr-set-area'), or refile under a project (native `org-refile',
;; offered only mindwtr project headings as targets).  An item is finished
;; when it leaves the inbox (status change or refile) or is skipped; the
;; loop then advances to the next item.
;;; Code:

(require 'org)
(require 'org-refile)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-commands)

(defun mindwtr-clarify--show-entry ()
  "Reveal the body of the heading at point (cross-version).
The `org-fold-*' namespace only exists in Org 9.6+; the project floor is
Emacs 28.1 / Org 9.5, where legacy `outline-*' is the equivalent."
  (if (fboundp 'org-fold-show-entry)
      (org-fold-show-entry)
    (outline-show-entry)))

(defun mindwtr-clarify--inbox-items ()
  "Return markers at each direct child heading of the inbox container, in order.
Signals a `user-error' when the buffer has no inbox container."
  (let ((inbox (mindwtr-commands--container-marker "inbox")))
    (unless inbox
      (user-error "mindwtr-clarify: no Inbox container in this buffer"))
    (unwind-protect
        (save-excursion
          (goto-char inbox)
          (let ((parent-level (org-current-level))
                (end (save-excursion (org-end-of-subtree t t) (point)))
                items)
            (while (and (outline-next-heading) (< (point) end))
              (when (= (org-current-level) (1+ parent-level))
                (push (point-marker) items)))
            (nreverse items)))
      (set-marker inbox nil))))

(defun mindwtr-clarify--in-inbox-p ()
  "Non-nil when the heading at point still sits under the inbox container."
  (equal (mindwtr-parse--ancestor-list-role) "inbox"))

(defun mindwtr-clarify--project-target-p ()
  "Non-nil when the heading at point is a mindwtr project heading.
The `org-refile-target-verify-function' that scopes refiling to projects."
  (equal (org-entry-get (point) "MW_TYPE") "project"))

(defun mindwtr-clarify--refile ()
  "Refile the item at point under a project, via native `org-refile'.
Binds `org-refile-targets' to the current buffer with project headings as
the only valid destinations -- the minimal refile-target wiring the clarify
flow needs, without touching the user's global refile config."
  (let ((org-refile-targets '((nil :maxlevel . 9)))
        (org-refile-target-verify-function #'mindwtr-clarify--project-target-p)
        (org-refile-use-cache nil))
    (org-refile)))

(defun mindwtr-clarify--item ()
  "Run the single-key action loop for the inbox item at point.
Returns normally when the item is dealt with (it left the inbox) or is
skipped; throws `mindwtr-clarify--quit' when the user quits the whole pass."
  (let (done)
    (while (not done)
      (org-back-to-heading t)
      (mindwtr-clarify--show-entry)
      (let ((ch (read-char-choice
                 (format "Clarify \"%s\":  [s]tatus  [c]ontexts/tags  [a]rea  [r]efile to project  [n]ext  [q]uit "
                         (org-get-heading t t t t))
                 '(?s ?c ?a ?r ?n ?q))))
        (pcase ch
          (?s (mindwtr-set-status)
              ;; A status change relocates the item to its bucket; if it left
              ;; the inbox it is clarified.  Choosing INBOX keeps the loop.
              (setq done (not (mindwtr-clarify--in-inbox-p))))
          (?c (org-set-tags-command))
          (?a (mindwtr-set-area))
          (?r (condition-case err
                  (progn (mindwtr-clarify--refile) (setq done t))
                ;; e.g. "No refile targets" when the buffer has no projects;
                ;; keep the loop alive instead of aborting the whole pass.
                (error (message "%s" (error-message-string err))
                       (sit-for 1))))
          (?n (setq done t))
          (?q (throw 'mindwtr-clarify--quit nil)))))))

;;;###autoload
(defun mindwtr-clarify ()
  "Triage the inbox: walk the `* Inbox' items one by one through a clarify loop.
For each item, single keys apply the existing type-aware commands:

  s  set a type-valid status (`mindwtr-set-status'); the item immediately
     relocates to the bucket matching the new status
  c  edit contexts/hashtags (org tags; `@'-prefixed tags are contexts)
  a  set an area (`mindwtr-set-area')
  r  refile under a project (native `org-refile', project targets only)
  n  skip to the next inbox item
  q  stop the pass

An item is finished when it leaves the inbox or is skipped."
  (interactive)
  (let ((items (mindwtr-clarify--inbox-items)))
    (if (null items)
        (message "mindwtr-clarify: inbox is empty")
      (unwind-protect
          (if (catch 'mindwtr-clarify--quit
                (dolist (m items)
                  (goto-char m)
                  ;; A marker can collapse onto the next sibling when its item
                  ;; was relocated; only clarify positions that still hold an
                  ;; inbox heading.
                  (when (and (org-at-heading-p)
                             (mindwtr-clarify--in-inbox-p))
                    (mindwtr-clarify--item)))
                t)
              (message "mindwtr-clarify: inbox clarified")
            (message "mindwtr-clarify: stopped"))
        (dolist (m items) (set-marker m nil))))))

(provide 'mindwtr-clarify)
;;; mindwtr-clarify.el ends here
