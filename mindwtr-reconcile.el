;;; mindwtr-reconcile.el --- Apply merged appdata into the org buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Updates the current buffer to reflect a merged AppData by id, editing
;; recognized fields in place and preserving org-only drawers (LOGBOOK,
;; unknown PROPERTIES) and the user's point.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-util)

(defun mindwtr-reconcile--id-markers ()
  "Return a hash MW_ID -> marker at heading start for every entity heading."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (let ((id (org-entry-get (point) "MW_ID")))
         (when id (puthash id (point-marker) h)))))
    h))

(defun mindwtr-reconcile--container-marker (markers entity)
  "Return marker of ENTITY's container heading, or nil for top-level."
  (let ((parent (or (plist-get entity :sectionId)
                    (plist-get entity :projectId)
                    (plist-get entity :areaId))))
    (and parent (gethash parent markers))))

(defun mindwtr-reconcile--update-heading (entity kind)
  "Rewrite recognized parts of the heading at point from ENTITY (kind KIND).
Preserves LOGBOOK and unknown properties."
  (let* ((title (or (plist-get entity :title) (plist-get entity :name)))
         (todo (when (memq kind '(task project))
                 (and (plist-get entity :status)
                      (mindwtr-model-status->keyword kind (plist-get entity :status))))))
    (org-edit-headline title)
    (when (memq kind '(task project)) (org-todo (or todo 'none)))
    (when (eq kind 'task)
      (let ((c (mindwtr-model-priority->cookie (plist-get entity :priority))))
        ;; `org-priority' in this Org errors with "No priority cookie found
        ;; in line" when asked to `remove' from a line that has none, so only
        ;; remove when a cookie is actually present.
        (cond (c (org-priority c))
              ((nth 3 (org-heading-components)) (org-priority 'remove))))
      (org-set-tags (append (plist-get entity :contexts)
                            (mapcar (lambda (s) (string-remove-prefix "#" s))
                                    (plist-get entity :tags))))))
  (dolist (p '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
               (:assignedTo . "MW_ASSIGNED_TO") (:location . "MW_LOCATION")
               (:taskMode . "MW_TASK_MODE")))
    (let ((v (plist-get entity (car p))))
      (if v (org-entry-put (point) (cdr p) (format "%s" v))
        (org-entry-delete (point) (cdr p)))))
  (when (plist-get entity :createdAt)
    (org-entry-put (point) "MW_CREATED" (mindwtr-util-iso->org (plist-get entity :createdAt))))
  (when (plist-get entity :updatedAt)
    (org-entry-put (point) "MW_UPDATED" (mindwtr-util-iso->org (plist-get entity :updatedAt)))))

(defun mindwtr-reconcile--insert-entity (entity kind markers)
  "Insert ENTITY (kind KIND) as a new heading under its container."
  (let* ((cmark (mindwtr-reconcile--container-marker markers entity))
         (level (if cmark
                    (1+ (save-excursion (goto-char cmark) (org-current-level)))
                  1)))
    (if cmark
        (progn (goto-char cmark)
               (org-end-of-subtree t t)
               (unless (bolp) (insert "\n")))
      (goto-char (point-max)) (unless (bolp) (insert "\n")))
    (let ((e (plist-put (copy-sequence entity) :mw-kind kind)))
      (insert (mindwtr-render-heading e level
                                      (list :createdAt (plist-get entity :createdAt)
                                            :updatedAt (plist-get entity :updatedAt)))))))

(defun mindwtr-reconcile-buffer (merged)
  "Reconcile the current buffer to reflect MERGED AppData."
  (mindwtr-parse-ensure-keywords)
  (save-excursion
    (let ((markers (mindwtr-reconcile--id-markers)))
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (e (plist-get merged key))
          (when (plist-get e :deletedAt)
            (let ((m (gethash (plist-get e :id) markers)))
              (when m (goto-char m) (org-back-to-heading t)
                    (org-cut-subtree) (remhash (plist-get e :id) markers))))))
      (dolist (key '(:areas :projects :sections :tasks))
        (let ((kind (intern (substring (symbol-name key) 1
                                       (1- (length (symbol-name key)))))))
          (dolist (e (plist-get merged key))
            (unless (plist-get e :deletedAt)
              (let ((m (gethash (plist-get e :id) markers)))
                (if m
                    (progn (goto-char m) (org-back-to-heading t)
                           (mindwtr-reconcile--update-heading e kind))
                  (mindwtr-reconcile--insert-entity e kind markers)
                  (setq markers (mindwtr-reconcile--id-markers)))))))))))

(provide 'mindwtr-reconcile)
;;; mindwtr-reconcile.el ends here
