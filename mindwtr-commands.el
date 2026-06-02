;;; mindwtr-commands.el --- Interactive type-aware status commands -*- lexical-binding: t; -*-
;;; Commentary:
;; Mode-scoped commands bound in `mindwtr-mode-map': a type-aware replacement
;; for `org-todo' that offers only the valid keywords for the entity at point,
;; type-aware status cycling, and eager relocation of a standalone task or a
;; project to the container matching its new status.  Re-parenting into/out of
;; a project stays on native `org-refile'.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)

(defun mindwtr-commands--kind-at-point ()
  "Return the MW_TYPE symbol of the heading at point, or nil."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((type (mindwtr-parse--prop "MW_TYPE")))
        (and type (intern type))))))

(defun mindwtr-commands--read-keyword (kind choices)
  "Prompt for one of CHOICES (list of (KEYWORD . CHAR)) for KIND.
Return the chosen keyword string, or nil on quit."
  (let* ((prompt (concat (format "%s status: " kind)
                         (mapconcat (lambda (c) (format "[%c]%s" (cdr c) (car c)))
                                    choices "  ")))
         (ch (read-char-choice prompt (mapcar #'cdr choices))))
    (car (rassq ch choices))))

;;;###autoload
(defun mindwtr-set-status ()
  "Set the TODO status of the entity at point, offering only type-valid keywords.
Shadows `org-todo' in `mindwtr-mode'.  After setting, relocate a standalone
task or a project to the container matching its new status."
  (interactive)
  (let ((kind (mindwtr-commands--kind-at-point)))
    (if (not (memq kind '(task project)))
        (call-interactively #'org-todo)
      (let ((kw (mindwtr-commands--read-keyword
                 kind (mindwtr-model-status-choices kind))))
        (when kw
          (save-excursion (org-back-to-heading t) (org-todo kw))
          (mindwtr-commands--relocate kind))))))

;; TEMPORARY no-op stub; replaced with the real implementation in Task 8.
(defun mindwtr-commands--relocate (_kind) nil)

(provide 'mindwtr-commands)
;;; mindwtr-commands.el ends here
