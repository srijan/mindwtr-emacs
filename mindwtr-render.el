;;; mindwtr-render.el --- appdata -> canonical org text -*- lexical-binding: t; -*-
;;; Commentary:
;; Deterministic rendering of entities to org.  The inverse of mindwtr-parse.
;;; Code:

(require 'cl-lib)
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

(defun mindwtr-render--area-name-map (appdata)
  "Return a hash id->name for APPDATA's areas."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (a (plist-get appdata :areas))
      (when (plist-get a :id)
        (puthash (plist-get a :id) (or (plist-get a :name) "") h)))
    h))

(defun mindwtr-render--area-order-map (appdata)
  "Return a hash areaId->:order for APPDATA's areas."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (a (plist-get appdata :areas))
      (puthash (plist-get a :id) (or (plist-get a :order) most-positive-fixnum) h))
    h))

(defun mindwtr-render--container (role level)
  "Render the list container heading for ROLE at outline LEVEL."
  (format "%s %s\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: %s\n:END:\n"
          (make-string level ?*) (mindwtr-model-list-title role) role))

(defun mindwtr-render--order-key (e)
  "Sort key for entity E: its :order, then :orderNum, then a last-sorting sentinel."
  (or (plist-get e :order) (plist-get e :orderNum) most-positive-fixnum))

(defun mindwtr-render--sorted (entities)
  "Stable-sort ENTITIES by order key, order-less entries sorting last.
Entities without an :order/:orderNum keep their incoming relative position
and sort after all ordered entries."
  (let ((i 0) keyed)
    (dolist (e entities)
      (push (list (mindwtr-render--order-key e) i e) keyed)
      (setq i (1+ i)))
    (mapcar (lambda (x) (nth 2 x))
            (sort (nreverse keyed)
                  (lambda (a b)
                    (if (= (nth 0 a) (nth 0 b)) (< (nth 1 a) (nth 1 b))
                      (< (nth 0 a) (nth 0 b))))))))

(defun mindwtr-render--sorted-projects (projects area-order)
  "Stable-sort PROJECTS grouped by area then project order, area-less last.
AREA-ORDER is a hash areaId->order; projects without an areaId sort after
all area-grouped projects, then by project :order within each group."
  (let ((i 0) keyed)
    (dolist (p projects)
      (let ((ao (if (plist-get p :areaId)
                    (gethash (plist-get p :areaId) area-order most-positive-fixnum)
                  most-positive-fixnum)))
        (push (list ao (mindwtr-render--order-key p) i p) keyed))
      (setq i (1+ i)))
    (mapcar (lambda (x) (nth 3 x))
            (sort (nreverse keyed)
                  (lambda (a b)
                    (cond ((/= (nth 0 a) (nth 0 b)) (< (nth 0 a) (nth 0 b)))
                          ((/= (nth 1 a) (nth 1 b)) (< (nth 1 a) (nth 1 b)))
                          (t (< (nth 2 a) (nth 2 b)))))))))

(defun mindwtr-render--graft-org-only (rendered id org-only)
  "Inject preserved org-only body for ID into RENDERED after PROPERTIES :END:."
  (let ((p (and org-only (gethash id org-only))))
    (if (not (and p (plist-get p :body))) rendered
      (let ((i (string-match "\n:END:\n" rendered)))
        (if (not i) rendered
          (let ((cut (+ i (length "\n:END:\n"))))
            (concat (substring rendered 0 cut) (plist-get p :body)
                    (substring rendered cut))))))))

(defun mindwtr-render--entity (e kind level org-only)
  "Render entity E of KIND at outline LEVEL, grafting preserved ORG-ONLY content.
ORG-ONLY is a hash id -> (:body STR :extra PLIST), or nil; extra-props and
the org-only body for E's id are injected into the rendered heading."
  (let* ((id (plist-get e :id))
         (p (and org-only (gethash id org-only)))
         (e2 (plist-put (plist-put (copy-sequence e) :mw-kind kind)
                        :mw-extra-props (and p (plist-get p :extra)))))
    (mindwtr-render--graft-org-only (mindwtr-render-heading e2 level e2) id org-only)))

(defun mindwtr-render--live (entities &optional drop-archived)
  "Return ENTITIES without tombstones (and without archived if DROP-ARCHIVED)."
  (cl-remove-if (lambda (e)
                  (or (plist-get e :deletedAt)
                      (and drop-archived (equal (plist-get e :status) "archived"))))
                entities))

(defun mindwtr-render-appdata (appdata &optional org-only)
  "Render APPDATA to the canonical GTD-list org layout, returning a string.
ORG-ONLY, when given, is a hash id -> (:body STR :extra PLIST) of org-only
content to preserve across a reconcile.  Tombstoned and archived entities
are not rendered."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         (areas (mindwtr-render--live (plist-get appdata :areas)))
         (projects (mindwtr-render--live (plist-get appdata :projects) t))
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks) t))
         ;; Lead with the in-buffer keyword line so org registers the Mindwtr
         ;; TODO sequence for this file regardless of the user's global config.
         (out (concat (mindwtr-model-todo-keyword-line) "\n")))
    ;; Standalone task lists (no project, no section), placed by status.
    (dolist (role '("inbox" "next-actions" "waiting" "someday" "reference"))
      (setq out (concat out (mindwtr-render--container role 1)))
      (dolist (e (mindwtr-render--sorted
                  (cl-remove-if-not
                   (lambda (e)
                     (and (not (plist-get e :projectId))
                          (not (plist-get e :sectionId))
                          (equal (mindwtr-model-status->list (plist-get e :status)) role)))
                   tasks)))
        (setq out (concat out (mindwtr-render--entity e 'task 2 org-only)))))
    ;; Projects, grouped by area then order; each with sections+tasks nested.
    (setq out (concat out (mindwtr-render--container "projects" 1)))
    (dolist (proj (mindwtr-render--sorted-projects projects area-order))
      (setq out (concat out (mindwtr-render--entity proj 'project 2 org-only)))
      (dolist (sec (mindwtr-render--sorted
                    (cl-remove-if-not
                     (lambda (s) (equal (plist-get s :projectId) (plist-get proj :id)))
                     sections)))
        (setq out (concat out (mindwtr-render--entity sec 'section 3 org-only)))
        (dolist (tk (mindwtr-render--sorted
                     (cl-remove-if-not
                      (lambda (tk) (equal (plist-get tk :sectionId) (plist-get sec :id)))
                      tasks)))
          (setq out (concat out (mindwtr-render--entity tk 'task 4 org-only)))))
      (dolist (tk (mindwtr-render--sorted
                   (cl-remove-if-not
                    (lambda (tk) (and (equal (plist-get tk :projectId) (plist-get proj :id))
                                      (not (plist-get tk :sectionId))))
                    tasks)))
        (setq out (concat out (mindwtr-render--entity tk 'task 3 org-only)))))
    ;; Areas of Focus reference section.
    (setq out (concat out (mindwtr-render--container "areas" 1)))
    (dolist (a (mindwtr-render--sorted areas))
      (setq out (concat out (mindwtr-render--entity a 'area 2 org-only))))
    out))

(provide 'mindwtr-render)
;;; mindwtr-render.el ends here
