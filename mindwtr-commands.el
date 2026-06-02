;;; mindwtr-commands.el --- Interactive type-aware status commands -*- lexical-binding: t; -*-
;;; Commentary:
;; Mode-scoped commands bound in `mindwtr-mode-map': a type-aware replacement
;; for `org-todo' that offers only the valid keywords for the entity at point,
;; type-aware status cycling, and eager relocation of a standalone task or a
;; project to the container matching its new status.  Re-parenting into/out of
;; a project stays on native `org-refile'.
;;; Code:

(require 'cl-lib)
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

(defun mindwtr-commands--status-at-point (kind)
  "Status string for the KIND entity at point, derived from its TODO keyword."
  (let ((kw (save-excursion (org-back-to-heading t) (org-get-todo-state))))
    (and kw (mindwtr-model-keyword->status-safe kind kw))))

(defun mindwtr-commands--in-project-p ()
  "Non-nil if the heading at point has a project or section ancestor."
  (or (mindwtr-parse--ancestor-id 'section)
      (mindwtr-parse--ancestor-id 'project)))

(defun mindwtr-commands--target-role (kind)
  "Container role the KIND entity at point should live under, or nil for no move.
Only standalone tasks and projects relocate; archived statuses have no role."
  (pcase kind
    ('task
     (unless (mindwtr-commands--in-project-p)
       (mindwtr-model-status->list (mindwtr-commands--status-at-point 'task))))
    ('project
     (mindwtr-model-project-status->list (mindwtr-commands--status-at-point 'project)))
    (_ nil)))

(defun mindwtr-commands--parent-list-role ()
  "Return the MW_LIST role of the nearest container ancestor of point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let (role)
      (while (and (not role) (org-up-heading-safe))
        (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") "container")
          (setq role (mindwtr-parse--prop "MW_LIST"))))
      role)))

(defun mindwtr-commands--container-marker (role)
  "Return a marker at the container heading whose MW_LIST is ROLE, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((re (format "^[ \t]*:MW_LIST:[ \t]*%s[ \t]*$" (regexp-quote role))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)
        (point-marker)))))

(defun mindwtr-commands--relocate (kind)
  "Move the KIND entity at point under the container matching its current status.
No-op when the target role is nil (archived / project task / section) or the
entity already sits directly under the target container."
  (let ((role (mindwtr-commands--target-role kind)))
    (when (and role (not (equal (mindwtr-commands--parent-list-role) role)))
      (let ((target (mindwtr-commands--container-marker role)))
        (when target
          (unwind-protect
              ;; No `save-excursion': leave point on the moved heading so the
              ;; cursor follows the entity the user just re-statused.
              (progn
                (org-back-to-heading t)
                (let ((level (1+ (save-excursion (goto-char target) (org-current-level)))))
                  (org-cut-subtree)
                  (goto-char target)
                  ;; To the start of the heading after this container's subtree
                  ;; (or end of buffer) -- a clean line boundary -- then paste as
                  ;; the container's last child at the computed level.
                  (org-end-of-subtree t t)
                  (org-paste-subtree level)))
            (set-marker target nil)))))))

(defun mindwtr-commands--cycle (dir)
  "Cycle the entity at point by DIR (+1/-1) through its type-valid keywords,
then relocate.  Falls back to plain org shift-cycling off Mindwtr headings."
  (let ((kind (mindwtr-commands--kind-at-point)))
    (if (not (memq kind '(task project)))
        (call-interactively (if (> dir 0) #'org-shiftright #'org-shiftleft))
      (let* ((kws (mapcar #'car (mindwtr-model-status-choices kind)))
             (cur (save-excursion (org-back-to-heading t) (org-get-todo-state)))
             (idx (and cur (cl-position cur kws :test #'string=)))
             (next (cond ((null idx) (if (> dir 0) 0 (1- (length kws))))
                         (t (mod (+ idx dir) (length kws))))))
        (save-excursion (org-back-to-heading t) (org-todo (nth next kws)))
        (mindwtr-commands--relocate kind)))))

;;;###autoload
(defun mindwtr-cycle-status-forward ()
  "Cycle the entity at point to its next type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle 1))

;;;###autoload
(defun mindwtr-cycle-status-backward ()
  "Cycle the entity at point to its previous type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle -1))

(provide 'mindwtr-commands)
;;; mindwtr-commands.el ends here
