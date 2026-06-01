;;; mindwtr-render.el --- appdata -> canonical org text -*- lexical-binding: t; -*-
;;; Commentary:
;; Deterministic rendering of entities to org.  The inverse of mindwtr-parse.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defvar mindwtr-render-area-names nil
  "Hash table id->name for resolving `:MW_AREA:' during rendering.
Dynamically bound by `mindwtr-render-appdata' / reconcile.")

(defconst mindwtr-render--drawer-order
  '(:energyLevel :timeEstimate :recurrence :assignedTo :focusToday
    :reviewAt :location :taskMode :sequential :focused :attach)
  "Canonical order of content properties in the drawer.")

(defconst mindwtr-render--prop-names
  '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
    (:recurrence . "MW_RECURRENCE") (:assignedTo . "MW_ASSIGNED_TO")
    (:focusToday . "MW_FOCUS_TODAY") (:reviewAt . "MW_REVIEW_AT")
    (:location . "MW_LOCATION") (:taskMode . "MW_TASK_MODE")
    (:sequential . "MW_SEQUENTIAL") (:focused . "MW_FOCUSED")
    (:attach . "MW_ATTACH")))

(defconst mindwtr-render--org-tag-re "\\`[[:alnum:]_@#%]+\\'"
  "A context/tag matching this can be a native org tag.
Mirrors Org's own `org-tag-re' character class; anything outside it
\(spaces, `-', `/', `.', ...) makes Org silently drop the tag, so such
values fall back to the MW_CONTEXTS/MW_TAGS drawer to stay exact.")

(defun mindwtr-render--org-tag-tokens (task)
  "Return TASK's contexts (verbatim) + hashtags (minus `#') as org tag tokens."
  (append (plist-get task :contexts)
          (mapcar (lambda (s) (string-remove-prefix "#" s))
                  (plist-get task :tags))))

(defun mindwtr-render--tags-org-safe-p (task)
  "Non-nil if every context/tag of TASK can be a native org tag."
  (seq-every-p (lambda (s) (string-match-p mindwtr-render--org-tag-re s))
               (mindwtr-render--org-tag-tokens task)))

(defun mindwtr-render--tags (task)
  "Render org tag string `:a:b:' for TASK contexts+tags, or empty.
Returns empty when TASK has no tags, OR when any context/tag contains
characters org tags can't hold -- in that case the values move wholesale
to the MW_CONTEXTS/MW_TAGS drawer (see `mindwtr-render-heading')."
  (let ((all (mindwtr-render--org-tag-tokens task)))
    (if (and all (mindwtr-render--tags-org-safe-p task))
        (concat " :" (mapconcat #'identity all ":") ":")
      "")))

(defun mindwtr-render--checklist (task)
  "Render TASK checklist items as org checkboxes."
  (mapconcat (lambda (it)
               (format "- [%s] %s"
                       (if (eq (plist-get it :isCompleted) t) "X" " ")
                       (plist-get it :title)))
             (plist-get task :checklist) "\n"))

(defun mindwtr-render--active-ts (iso)
  "Render ISO as an org active timestamp `<...>' (for planning lines)."
  (replace-regexp-in-string
   "\\`\\[\\|\\]\\'" (lambda (m) (if (string= m "[") "<" ">"))
   (mindwtr-util-iso->org iso)))

(defun mindwtr-render--recurrence (rec)
  "Render a recurrence value REC as a readable drawer string.
REC is a plist (e.g. (:rule \"monthly\" :rrule \"FREQ=MONTHLY\")); prefer
the rrule, then the human rule, falling back to a printed form."
  (cond
   ((stringp rec) rec)
   ((and (consp rec) (keywordp (car rec)))
    (or (plist-get rec :rrule) (plist-get rec :rule) (format "%s" rec)))
   (t (format "%s" rec))))

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
    (let ((aid (plist-get entity :areaId)))
      (when (and aid mindwtr-render-area-names)
        (let ((name (gethash aid mindwtr-render-area-names)))
          (when name (push (format ":MW_AREA: %s" name) lines)))))
    (dolist (k mindwtr-render--drawer-order)
      (let ((v (plist-get entity k)))
        (when v
          (push (format ":%s: %s" (cdr (assq k mindwtr-render--prop-names))
                        (cond ((eq k :recurrence) (mindwtr-render--recurrence v))
                              ((eq v t) "t")
                              (t v)))
                lines))))
    ;; contexts/tags fallback: when any value can't be a native org tag,
    ;; move the whole list into a drawer property (JSON-encoded for
    ;; exactness, since the trigger includes spaces and other separators).
    (when (and (eq kind 'task) (not (mindwtr-render--tags-org-safe-p entity)))
      (when (plist-get entity :contexts)
        (push (format ":MW_CONTEXTS: %s"
                      (mindwtr-util-json-encode (plist-get entity :contexts)))
              lines))
      (when (plist-get entity :tags)
        (push (format ":MW_TAGS: %s"
                      (mindwtr-util-json-encode (plist-get entity :tags)))
              lines)))
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
