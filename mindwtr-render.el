;;; mindwtr-render.el --- appdata -> canonical org text -*- lexical-binding: t; -*-
;;; Commentary:
;; Deterministic rendering of entities to org.  The inverse of mindwtr-parse.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-render--drawer-order
  '(:energyLevel :timeEstimate :recurrence :assignedTo :focusToday
    :reviewAt :location :taskMode :sequential :focused :mw-area-override :attach)
  "Canonical order of content properties in the drawer.
Note `:mw-area-override' (not `:areaId'): `areaId' is derived from the
ancestor Area heading and rendering it back as `MW_AREA_ID' would turn a
derived containment into a spurious override on every reconcile.  Only an
explicit override (parse sets `:mw-area-override' when `MW_AREA_ID' was
written in the drawer) is emitted.")

(defconst mindwtr-render--prop-names
  '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
    (:recurrence . "MW_RECURRENCE") (:assignedTo . "MW_ASSIGNED_TO")
    (:focusToday . "MW_FOCUS_TODAY") (:reviewAt . "MW_REVIEW_AT")
    (:location . "MW_LOCATION") (:taskMode . "MW_TASK_MODE")
    (:sequential . "MW_SEQUENTIAL") (:focused . "MW_FOCUSED")
    (:mw-area-override . "MW_AREA_ID") (:attach . "MW_ATTACH")))

(defun mindwtr-render--tags (task)
  "Render org tag string `:a:b:' for TASK contexts+tags, or empty."
  (let ((all (append (plist-get task :contexts)
                     (mapcar (lambda (s) (string-remove-prefix "#" s))
                             (plist-get task :tags)))))
    (if all (concat " :" (mapconcat #'identity all ":") ":") "")))

(defun mindwtr-render--checklist (task)
  "Render TASK checklist items as org checkboxes."
  (mapconcat (lambda (it)
               (format "- [%s] %s"
                       (if (eq (plist-get it :done) t) "X" " ")
                       (plist-get it :title)))
             (plist-get task :checklist) "\n"))

(defun mindwtr-render--active-ts (iso)
  "Render ISO as an org active timestamp `<...>' (for planning lines)."
  (replace-regexp-in-string
   "\\`\\[\\|\\]\\'" (lambda (m) (if (string= m "[") "<" ">"))
   (mindwtr-util-iso->org iso)))

(defun mindwtr-render-heading (entity level shadow)
  "Render ENTITY at outline LEVEL (1-based), using SHADOW for mirror fields.
Returns a string ending with a newline."
  (let* ((kind (plist-get entity :mw-kind))
         (stars (make-string level ?*))
         (todo (when (memq kind '(task project))
                 (let ((st (plist-get entity :status)))
                   (when st (concat (mindwtr-model-status->keyword kind st) " ")))))
         (cookie (when (eq kind 'task)
                   (let ((c (mindwtr-model-priority->cookie
                             (plist-get entity :priority))))
                     (when c (format "[#%c] " c)))))
         (title (or (plist-get entity :title) (plist-get entity :name)))
         (tags (if (eq kind 'task) (mindwtr-render--tags entity) ""))
         ;; Org heading syntax is `STARS KEYWORD [#PRIORITY] TITLE TAGS'.
         ;; The TODO keyword MUST precede the priority cookie or org will
         ;; not recognize it on re-parse (it would absorb the keyword into
         ;; the title).  Emit todo before cookie so render is parse-inverse.
         (lines (list (concat stars " " (or todo "") (or cookie "") title tags))))
    ;; planning line (tasks)
    (when (eq kind 'task)
      (let (parts)
        (when (plist-get entity :startTime)
          (push (format "SCHEDULED: %s"
                        (mindwtr-render--active-ts (plist-get entity :startTime)))
                parts))
        (when (plist-get entity :dueDate)
          (push (format "DEADLINE: %s"
                        (mindwtr-render--active-ts (plist-get entity :dueDate)))
                parts))
        ;; CLOSED uses an INACTIVE timestamp (org convention); render the
        ;; completedAt directly without flipping to `<...>'.
        (when (plist-get entity :completedAt)
          (push (format "CLOSED: %s"
                        (mindwtr-util-iso->org (plist-get entity :completedAt)))
                parts))
        (when parts (push (mapconcat #'identity (nreverse parts) " ") lines))))
    ;; properties drawer
    (push ":PROPERTIES:" lines)
    (push (format ":MW_TYPE: %s" kind) lines)
    (push (format ":MW_ID: %s" (plist-get entity :id)) lines)
    (dolist (k mindwtr-render--drawer-order)
      (let ((v (plist-get entity k)))
        (when v
          (push (format ":%s: %s" (cdr (assq k mindwtr-render--prop-names))
                        (if (eq v t) "t" v))
                lines))))
    ;; display-mirror fields from shadow
    (when shadow
      (when (plist-get shadow :createdAt)
        (push (format ":MW_CREATED: %s"
                      (mindwtr-util-iso->org (plist-get shadow :createdAt))) lines))
      (when (plist-get shadow :updatedAt)
        (push (format ":MW_UPDATED: %s"
                      (mindwtr-util-iso->org (plist-get shadow :updatedAt))) lines)))
    ;; preserved unknown properties
    (let ((extra (plist-get entity :mw-extra-props)) (i 0))
      (while (< i (length extra))
        (push (format ":%s: %s" (nth i extra) (nth (1+ i) extra)) lines)
        (setq i (+ i 2))))
    (push ":END:" lines)
    ;; body: description then checklist (tasks)
    (when (eq kind 'task)
      (let ((desc (plist-get entity :description))
            (cl (mindwtr-render--checklist entity)))
        (when (and desc (> (length desc) 0)) (push desc lines))
        (when (> (length cl) 0) (push cl lines))))
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))

(provide 'mindwtr-render)
;;; mindwtr-render.el ends here
