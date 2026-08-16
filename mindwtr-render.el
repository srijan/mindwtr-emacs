;;; mindwtr-render.el --- appdata -> canonical org text -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Deterministic rendering of entities to org.  The inverse of mindwtr-parse.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-model)
(require 'mindwtr-util)

(defvar mindwtr-render-area-names nil
  "Hash table id->name for resolving the area `:CATEGORY:' during rendering.
Dynamically bound by `mindwtr-render-appdata' / reconcile.")

(defconst mindwtr-render--drawer-order
  '(:energyLevel :timeEstimate :recurrence :assignedTo :isFocusedToday
    :reviewAt :location :taskMode :isSequential :isFocused :referenceLink :attach
    :mw-clock-synced)
  "Canonical order of content properties in the drawer.
`:referenceLink' is person-only; it is iterated for every kind but inert on
entities that do not carry it.  `:mw-clock-synced' is the task-only,
device-local clock-time baseline (MW_CLOCK_SYNCED); it is rendered from the
entity value (overlaid onto the merged response in the sync reconcile pass)
but stripped before the wire and excluded from the content signature.")

(defconst mindwtr-render--prop-names
  '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
    (:recurrence . "MW_RECURRENCE") (:assignedTo . "MW_ASSIGNED_TO")
    (:isFocusedToday . "MW_FOCUS_TODAY") (:reviewAt . "MW_REVIEW_AT")
    (:location . "MW_LOCATION") (:taskMode . "MW_TASK_MODE")
    (:isSequential . "MW_SEQUENTIAL") (:isFocused . "MW_FOCUSED")
    (:referenceLink . "MW_REFERENCE_LINK")
    (:attach . "MW_ATTACH")
    (:mw-clock-synced . "MW_CLOCK_SYNCED")))

(defconst mindwtr-render--boolean-fields '(:isFocusedToday :isSequential :isFocused)
  "Drawer fields whose value is a server boolean.
The server's false is the symbol `:false' (non-nil, truthy in elisp), so the
generic non-nil render arm would wrongly emit `:false'; these fields get an
explicit branch that emits the property only for a genuine `t' and omits it
otherwise, making \"absent\" the unique fixed point for not-set/false.")

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

(defun mindwtr-render--mw->org-text (text)
  "Convert mindwtr (markdown) body syntax in TEXT to org syntax.

Bullets: a line whose first non-blank content is a run of `*' or a `+'
followed by a space becomes an org `- ' bullet.  This is the
heading-injection guard -- a body line beginning with `*'+space is an org
HEADING, which would split the note into a phantom sibling/child entity on
the next parse -- and it normalizes markdown's `*'/`+' bullet markers to the
single marker org can carry in a body (`-'; `*' at column 0 is a heading).
Inline emphasis (`**bold**', `*italic*', `_x_') is deliberately left verbatim:
it does not collide with org block structure (an org heading needs a space
after the stars), and a naive regex conversion would corrupt ordinary prose
\(`snake_case', `2 * 3').

Links: `[label](url)' becomes `[[url][label]]'; when the label equals the url
\(the form a label-less org link round-trips through) -- or the label is
empty -- it collapses back to the canonical `[[url]]' so the org buffer stays
byte-stable across a sync.  The url group tolerates one level of balanced
parens so URLs like `https://x/Foo_(bar)' survive intact.

Text with no convertible syntax is returned unchanged."
  (when text
    (let ((s (replace-regexp-in-string
              "^\\([ \t]*\\)\\(?:\\*+\\|\\+\\) " "\\1- " text)))
      (replace-regexp-in-string
       "\\[\\([^]]*\\)\\](\\(\\(?:[^()]\\|([^()]*)\\)*\\))"
       (lambda (m)
         (let ((label (match-string 1 m))
               (url (match-string 2 m)))
           (if (or (string= label url) (string-empty-p label))
               (format "[[%s]]" url)
             (format "[[%s][%s]]" url label))))
       s t t))))

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
          (when name (push (format ":CATEGORY: %s" name) lines)))))
    (dolist (k mindwtr-render--drawer-order)
      (let ((v (plist-get entity k)))
        (cond
         ;; Booleans: emit `:PROP: t' only for a genuine `t'; `:false'/nil omit
         ;; the property so absent is the unique not-set/false fixed point.
         ((memq k mindwtr-render--boolean-fields)
          (when (eq v t)
            (push (format ":%s: t" (cdr (assq k mindwtr-render--prop-names)))
                  lines)))
         ;; Clock-time baseline (minutes): emit only when > 0, so absent and 0
         ;; are a single fixed point (0 is non-nil in elisp, so the generic arm
         ;; below would otherwise emit `:MW_CLOCK_SYNCED: 0').
         ((eq k :mw-clock-synced)
          (when (and (integerp v) (> v 0))
            (push (format ":%s: %d" (cdr (assq k mindwtr-render--prop-names)) v)
                  lines)))
         (v
          (push (format ":%s: %s" (cdr (assq k mindwtr-render--prop-names))
                        (cond ((eq k :recurrence) (mindwtr-render--recurrence v))
                              ((eq v t) "t")
                              (t v)))
                lines)))))
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
    (let ((extra (plist-get entity :mw-extra-props)))
      (while extra
        (push (format ":%s: %s" (car extra) (cadr extra)) lines)
        (setq extra (cddr extra))))
    (push ":END:" lines)
    ;; body: notes prose then checklist.  The notes field is per-kind
    ;; (`mindwtr-model-notes-field': task/section -> :description, project ->
    ;; :supportNotes, area -> none); checklist stays task-only.  This is the
    ;; sole prose serializer, so reconcile's preserved-body must NOT also carry
    ;; the note for any kind whose field renders here, or it double-grafts.
    (let* ((field (mindwtr-model-notes-field kind))
           (notes (and field (plist-get entity field))))
      (when (and notes (> (length notes) 0))
        (push (mindwtr-render--mw->org-text notes) lines)))
    (when (eq kind 'task)
      (let ((cl (mindwtr-render--checklist entity)))
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

(defun mindwtr-render--people-sorted (people)
  "Stable-sort PEOPLE by :name for a byte-stable render (KTD5).
Person has no `:order' field, so `mindwtr-render--sorted' would leave people
in server order (non-deterministic across pulls); sort by name instead.  Copies
the list because `sort' is destructive on the caller's structure."
  (sort (copy-sequence people)
        (lambda (a b)
          (string< (or (plist-get a :name) "") (or (plist-get b :name) "")))))

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

(defun mindwtr-render--standalone-for (role tasks)
  "Standalone (no projectId/sectionId) TASKS whose status maps to container ROLE."
  (cl-remove-if-not
   (lambda (e)
     (and (not (plist-get e :projectId))
          (not (plist-get e :sectionId))
          (equal (mindwtr-model-status->list (plist-get e :status)) role)))
   tasks))

(defun mindwtr-render--group-children (sections tasks)
  "Group SECTIONS and TASKS by their parent id for O(1) subtree lookup.
Returns (SECS-BY-PROJ TASKS-BY-SEC PTASKS-BY-PROJ): sections keyed by
`:projectId', sectioned tasks keyed by `:sectionId', and section-less project
tasks keyed by `:projectId'.  Each bucket preserves the incoming relative
order, so `mindwtr-render--sorted''s stable tie-break is unchanged from the
per-parent `cl-remove-if-not' filters this replaces (which were O(parents x
children) per render)."
  (let ((secs-by-proj (make-hash-table :test 'equal))
        (tasks-by-sec (make-hash-table :test 'equal))
        (ptasks-by-proj (make-hash-table :test 'equal)))
    (dolist (s sections)
      (let ((pid (plist-get s :projectId)))
        (when pid (push s (gethash pid secs-by-proj)))))
    (dolist (tk tasks)
      (let ((sid (plist-get tk :sectionId))
            (pid (plist-get tk :projectId)))
        (cond (sid (push tk (gethash sid tasks-by-sec)))
              (pid (push tk (gethash pid ptasks-by-proj))))))
    (dolist (h (list secs-by-proj tasks-by-sec ptasks-by-proj))
      (maphash (lambda (k v) (puthash k (nreverse v) h)) h))
    (list secs-by-proj tasks-by-sec ptasks-by-proj)))

(defun mindwtr-render--task-bucket (role level tasks org-only)
  "Render container ROLE at LEVEL, then standalone TASKS (pre-filtered) at LEVEL+1."
  (let ((parts (list (mindwtr-render--container role level))))
    (dolist (e (mindwtr-render--sorted tasks))
      (push (mindwtr-render--entity e 'task (1+ level) org-only) parts))
    (mapconcat #'identity (nreverse parts) "")))

(defun mindwtr-render--project-subtree (proj level children org-only)
  "Render PROJ at LEVEL, its sections at LEVEL+1 (their tasks LEVEL+2), and its
section-less tasks at LEVEL+1.  CHILDREN is the grouped lookup from
`mindwtr-render--group-children'."
  (pcase-let ((`(,secs-by-proj ,tasks-by-sec ,ptasks-by-proj) children)
              (pid (plist-get proj :id)))
    (let ((parts (list (mindwtr-render--entity proj 'project level org-only))))
      (dolist (sec (mindwtr-render--sorted (gethash pid secs-by-proj)))
        (push (mindwtr-render--entity sec 'section (1+ level) org-only) parts)
        (dolist (tk (mindwtr-render--sorted
                     (gethash (plist-get sec :id) tasks-by-sec)))
          (push (mindwtr-render--entity tk 'task (+ level 2) org-only) parts)))
      (dolist (tk (mindwtr-render--sorted (gethash pid ptasks-by-proj)))
        (push (mindwtr-render--entity tk 'task (1+ level) org-only) parts))
      (mapconcat #'identity (nreverse parts) ""))))

(defun mindwtr-render--projects-bucket (role level projects children area-order org-only)
  "Render container ROLE at LEVEL, then PROJECTS whose project-status maps to ROLE,
grouped by area, each as a subtree at LEVEL+1.  CHILDREN is the grouped lookup
from `mindwtr-render--group-children'."
  (let ((parts (list (mindwtr-render--container role level)))
        (matched (cl-remove-if-not
                  (lambda (p)
                    (equal (mindwtr-model-project-status->list (plist-get p :status)) role))
                  projects)))
    (dolist (proj (mindwtr-render--sorted-projects matched area-order))
      (push (mindwtr-render--project-subtree proj (1+ level) children org-only)
            parts))
    (mapconcat #'identity (nreverse parts) "")))

(defun mindwtr-render-appdata (appdata &optional org-only)
  "Render APPDATA to the canonical v3 GTD-list org layout, returning a string.
ORG-ONLY, when given, is a hash id -> (:body STR :extra PLIST) of org-only
content to preserve across a reconcile.  Tombstoned and archived entities
are not rendered."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         (areas (mindwtr-render--live (plist-get appdata :areas)))
         (projects (mindwtr-render--live (plist-get appdata :projects) t))
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks) t))
         (children (mindwtr-render--group-children sections tasks))
         ;; Lead with the in-buffer keyword line so org registers the Mindwtr
         ;; TODO sequence for this file regardless of the user's global config.
         (parts (list (concat (mindwtr-model-todo-keyword-line) "\n"))))
    ;; Inbox
    (push (mindwtr-render--task-bucket
           "inbox" 1
           (mindwtr-render--standalone-for "inbox" tasks) org-only)
          parts)
    ;; Single Actions (next | waiting | done)
    (push (mindwtr-render--task-bucket
           "single-actions" 1
           (mindwtr-render--standalone-for "single-actions" tasks) org-only)
          parts)
    ;; Projects (active | waiting), grouped by area
    (push (mindwtr-render--projects-bucket
           "projects" 1 projects children area-order org-only)
          parts)
    ;; Someday parent with two nested children
    (push (mindwtr-render--container "someday" 1) parts)
    (push (mindwtr-render--task-bucket
           "someday-single-actions" 2
           (mindwtr-render--standalone-for "someday-single-actions" tasks)
           org-only)
          parts)
    (push (mindwtr-render--projects-bucket
           "someday-projects" 2 projects children area-order org-only)
          parts)
    ;; Reference
    (push (mindwtr-render--task-bucket
           "reference" 1
           (mindwtr-render--standalone-for "reference" tasks) org-only)
          parts)
    ;; Areas of Focus reference section
    (push (mindwtr-render--container "areas" 1) parts)
    (dolist (a (mindwtr-render--sorted areas))
      (push (mindwtr-render--entity a 'area 2 org-only) parts))
    ;; People reference section (modeled on Areas; sorted by name, KTD5)
    (push (mindwtr-render--container "people" 1) parts)
    (dolist (p (mindwtr-render--people-sorted
                (mindwtr-render--live (plist-get appdata :people))))
      (push (mindwtr-render--entity p 'person 2 org-only) parts))
    (mapconcat #'identity (nreverse parts) "")))

;;; Archive surface render -----------------------------------------------------

(defun mindwtr-render--inject-containment (rendered task)
  "Inject TASK's MW_PROJECT_ID/MW_SECTION_ID into RENDERED's PROPERTIES drawer.
The props are placed immediately before the drawer's `:END:' (the first one in
RENDERED, which closes the sole PROPERTIES drawer -- any grafted LOGBOOK sits
after it), at a fixed point so the render round-trips byte-stably (KTD4, R4).
A no-op when TASK carries neither containment id."
  (let (props)
    (when (plist-get task :projectId)
      (push (format ":MW_PROJECT_ID: %s" (plist-get task :projectId)) props))
    (when (plist-get task :sectionId)
      (push (format ":MW_SECTION_ID: %s" (plist-get task :sectionId)) props))
    (if (null props) rendered
      (let ((i (string-match "\n:END:\n" rendered)))
        (if (not i) rendered
          (concat (substring rendered 0 i)
                  "\n" (mapconcat #'identity (nreverse props) "\n")
                  (substring rendered i)))))))

(defun mindwtr-render--archived-in-subtree-p (task arch-proj-ids arch-section-ids)
  "Non-nil if TASK renders inside an archived project's subtree, not flat.
A task whose nearest container (section first, else project) belongs to an
archived project rendered in this file is pulled into that subtree by
`mindwtr-render--project-subtree'; such a task must be excluded from the flat
archived-task list so it appears exactly once (R3).  ARCH-PROJ-IDS and
ARCH-SECTION-IDS are hash sets (id -> t) of the archived projects and of the
sections that belong to them."
  (let ((sid (plist-get task :sectionId))
        (pid (plist-get task :projectId)))
    (cond (sid (and (gethash sid arch-section-ids) t))
          (pid (and (gethash pid arch-proj-ids) t))
          (t nil))))

(defun mindwtr-render--id-set (entities)
  "Return a hash set (id -> t) of ENTITIES' `:id' values."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e entities) (puthash (plist-get e :id) t h))
    h))

(defun mindwtr-render-archive-appdata (appdata &optional org-only)
  "Render APPDATA's archived entities to the canonical archive-file layout.
The mirror of `mindwtr-render-appdata' for the second (archive) surface: a
single `* Archive' container holding (a) flat archived standalone/live-project
tasks at level 2 -- each carrying its containment as explicit
MW_PROJECT_ID/MW_SECTION_ID drawer props since its parent renders in the OTHER
file (KTD4) -- then (b) archived projects as full subtrees, whose own
done/next/archived children render inside them via ancestry (no props needed).
Tombstoned entities are dropped; live (non-archived) entities never appear here.
ORG-ONLY is the same id -> (:body :extra) preserved-content hash reconcile
passes the main render.  Ordering reuses the shared sort helpers for
determinism, and the render round-trips byte-stably (R4)."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         ;; Non-tombstoned, archived NOT dropped: the archive file is exactly
         ;; where archived entities live.
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks)))
         (children (mindwtr-render--group-children sections tasks))
         (arch-projects
          (cl-remove-if-not
           (lambda (p) (equal (plist-get p :status) "archived"))
           (mindwtr-render--live (plist-get appdata :projects))))
         (arch-proj-ids (mindwtr-render--id-set arch-projects))
         (arch-section-ids
          (mindwtr-render--id-set
           (cl-remove-if-not
            (lambda (s) (gethash (plist-get s :projectId) arch-proj-ids))
            sections)))
         (flat-tasks
          (cl-remove-if-not
           (lambda (tk)
             (and (equal (plist-get tk :status) "archived")
                  (not (mindwtr-render--archived-in-subtree-p
                        tk arch-proj-ids arch-section-ids))))
           tasks))
         (parts (list (concat (mindwtr-model-todo-keyword-line) "\n"))))
    (push (mindwtr-render--container "archive" 1) parts)
    ;; (a) flat archived tasks, containment props injected into the drawer
    (dolist (tk (mindwtr-render--sorted flat-tasks))
      (push (mindwtr-render--inject-containment
             (mindwtr-render--entity tk 'task 2 org-only) tk)
            parts))
    ;; (b) archived projects as full subtrees (children NOT dropped for archived)
    (dolist (proj (mindwtr-render--sorted-projects arch-projects area-order))
      (push (mindwtr-render--project-subtree proj 2 children org-only) parts))
    (mapconcat #'identity (nreverse parts) "")))

(provide 'mindwtr-render)
;;; mindwtr-render.el ends here
