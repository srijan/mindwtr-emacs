;;; mindwtr-parse.el --- org buffer -> appdata content -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Parse org headings into Mindwtr entity content plists.  Sync metadata
;; and shadow-only fields are NOT produced here; they are merged from the
;; shadow later.  Each parsed entity carries internal keys:
;;   :mw-kind  -> one of area|person|project|section|task
;;   :mw-extra-props -> plist of unknown PROPERTIES keys to preserve
;;; Code:

(require 'org)
(require 'org-element)
(require 'mindwtr-model)
(require 'mindwtr-util)
(require 'mindwtr-clock)
(require 'mindwtr-heading)

(defconst mindwtr-parse--known-props
  '("MW_TYPE" "MW_ID" "MW_ENERGY" "MW_TIME_ESTIMATE" "MW_RECURRENCE"
    "MW_ASSIGNED_TO" "MW_FOCUS_TODAY" "MW_REVIEW_AT" "MW_LOCATION"
    "MW_TASK_MODE" "MW_SEQUENTIAL" "MW_FOCUSED" "CATEGORY" "MW_AREA_ID" "MW_AREA"
    "MW_ATTACH" "MW_CREATED" "MW_UPDATED" "MW_TAGS" "MW_CONTEXTS"
    "MW_PROJECT_ID" "MW_SECTION_ID" "MW_REFERENCE_LINK" "MW_CLOCK_SYNCED")
  "PROPERTIES keys the parser interprets; all others are preserved verbatim.
CATEGORY holds the per-item area name (org's native vehicle); MW_AREA is the
legacy vehicle kept here for the transitional read-fallback so a stale
`:MW_AREA:' is consumed (and dropped on rebuild) rather than preserved into
`:mw-extra-props' and re-rendered forever.  MW_AREA_ID is a defensive unread
reservation.
MW_PROJECT_ID/MW_SECTION_ID carry an archived task's containment explicitly
across the file split (KTD4): in the archive file a task whose project is still
live cannot nest under it, so the render emits the parent id as a drawer prop
and the task branch of `mindwtr-parse-buffer' honors it over outline ancestry.
They are listed here so they never leak into `:mw-extra-props'.")

(defun mindwtr-parse-ensure-keywords ()
  "Make sure the Mindwtr TODO keywords are recognized in this buffer.
Org only registers keywords from `org-todo-keywords' during mode
initialization, so when parsing a buffer that was put into plain
`org-mode' (e.g. tests, or a file opened under a personal org config) we
rebind the keywords and re-init org once.

We must check that the *whole* sequence is present, not just one keyword:
a personal GTD config commonly defines NEXT but not SOMEDAY/REF/etc., and
trusting NEXT alone left those unrecognized -- their headings then parsed
to a nil status, leaking the keyword into the title and aborting the sync."
  (unless (seq-every-p (lambda (k) (member k org-todo-keywords-1))
                       mindwtr-model-todo-keyword-names)
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (org-mode))))

(defun mindwtr-parse--split-tags (tags)
  "Split org TAGS list into (contexts . hashtags) per the @-convention."
  (let (contexts hashtags)
    (dolist (tg tags)
      (if (string-prefix-p "@" tg)
          (push tg contexts)
        (push (concat "#" tg) hashtags)))
    (cons (nreverse contexts) (nreverse hashtags))))

(defun mindwtr-parse--planning-iso (regexp)
  "Return ISO timestamp for a planning line matching REGEXP in this entry."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (mindwtr-heading-entry-end)))
      (when (re-search-forward regexp end t)
        (mindwtr-util-org->iso (match-string 1))))))

(defun mindwtr-parse--org->mw-links (text)
  "Convert org links in TEXT to markdown, leaving everything else verbatim.
The links-only half of `mindwtr-parse--org->mw-text', used directly for
heading titles (#29): a single-line title must not get the bullet
normalization meant for body prose (a title legitimately starting with
`+ '/`* ' is just text)."
  (when text
    (replace-regexp-in-string
     "\\[\\[\\([^]]*\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]"
     (lambda (m)
       (let ((url (match-string 1 m))
             (label (match-string 2 m)))
         (format "[%s](%s)"
                 (if (and label (not (string-empty-p label))) label url)
                 url)))
     text t t)))

(defun mindwtr-parse--org->mw-text (text)
  "Convert org body syntax in TEXT to mindwtr (markdown) syntax.

Bullets: a line whose first non-blank content is a `-', `+', or run of `*'
followed by a space is normalized to a markdown `- ' bullet.  This is the
inverse-side of `mindwtr-render--mw->org-text''s bullet normalization, so a
hand-typed `+'/`*' bullet in the buffer converges to `- ' in one cycle
instead of churning the signature.

Links: `[[url][label]]' becomes `[label](url)' and a label-less `[[url]]'
becomes `[url](url)'.  An empty label (`[[url][]]') falls back to the url,
yielding `[url](url)'.  Only links are converted; other inline org markup
\(bold, italic, ...) is left verbatim, mirroring the render side.  A literal
`]' inside an org link url or label is not supported: org link syntax cannot
unambiguously represent a bare `]' inside its path, so such a link is matched
only up to the first `]' (an inherent org limitation).

Text with no convertible syntax is returned unchanged."
  (when text
    (mindwtr-parse--org->mw-links
     (replace-regexp-in-string
      "^\\([ \t]*\\)\\(?:\\*+\\|\\+\\) " "\\1- " text))))

(defun mindwtr-parse--body (&optional parse-checklist)
  "Return (PROSE . CHECKLIST) for the entry at point.
PROSE is the body minus planning lines, drawers, and -- when PARSE-CHECKLIST
is non-nil -- checklist items.  When PARSE-CHECKLIST is nil, `- [ ]' lines
stay in PROSE: kinds without a `:checklist' field (project, section) must not
have a checkbox line amputated into a dropped checklist on the next sync (R9).

Two hardening rules keep prose that merely LOOKS structural (#26):
- A `:word:' line opens a drawer only when a matching `:END:' follows in
  this entry; an unterminated one is prose (org itself requires the `:END:'),
  so a bare `:warning:' no longer swallows the rest of the note.
- Planning keywords (SCHEDULED/DEADLINE/CLOSED) are stripped only from the
  leading planning run directly under the heading -- the only place org puts
  them -- so a note line like `DEADLINE: ship Friday' stays prose."
  (save-excursion
    (org-back-to-heading t)
    (let* ((el (org-element-at-point))
           (cbeg (org-element-property :contents-begin el))
           (end (mindwtr-heading-entry-end))
           (lines (when cbeg
                    (vconcat
                     (split-string (buffer-substring-no-properties cbeg end)
                                   "\n"))))
           (n (if lines (length lines) 0))
           (i 0)
           prose checklist (in-planning t))
      (while (< i n)
        (let ((ln (aref lines i)))
          (cond
           ((and in-planning
                 (string-match-p "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):" ln)))
           ((and (string-match-p "^[ \t]*:[A-Za-z0-9_]+:[ \t]*$" ln)
                 (not (string-match-p "^[ \t]*:END:[ \t]*$" ln))
                 ;; Drawer only when terminated: scan ahead for its :END:.
                 (let ((j (1+ i)) close)
                   (while (and (< j n) (not close))
                     (when (string-match-p "^[ \t]*:END:[ \t]*$" (aref lines j))
                       (setq close j))
                     (setq j (1+ j)))
                   (when close (setq i close) t)))
            (setq in-planning nil))
           ((and parse-checklist
                 (string-match "^[ \t]*- \\[\\([ X]\\)\\] \\(.*\\)$" ln))
            (setq in-planning nil)
            (push (list :title (match-string 2 ln)
                        :isCompleted (if (string= (match-string 1 ln) "X") t :false))
                  checklist))
           (t (setq in-planning nil)
              (push ln prose))))
        (setq i (1+ i)))
      (cons (mindwtr-parse--org->mw-text
             (string-trim (mapconcat #'identity (nreverse prose) "\n")))
            (nreverse checklist)))))

(defun mindwtr-parse-extra-props ()
  "Return a plist (string key -> value) of unknown PROPERTIES at point."
  (let (extra)
    (pcase-dolist (`(,k . ,v) (mindwtr-heading-properties))
      (unless (member k mindwtr-parse--known-props)
        (setq extra (plist-put extra k v))))
    extra))

(defvar mindwtr-parse--area-names nil
  "Hash name->id for resolving an area `:CATEGORY:' name.
Dynamically bound by `mindwtr-parse-buffer'.")

(defvar mindwtr-parse--warnings nil
  "Accumulator of data-quality warnings for the current `mindwtr-parse-buffer'.
Each element is a plist (:id ID :title TITLE :keyword KW :kind KIND) recording
a heading whose TODO keyword was not valid for its entity kind.  Reset at the
start of every `mindwtr-parse-buffer'; read afterwards via
`mindwtr-parse-warnings' so the sync report can surface them.")

(defun mindwtr-parse-warnings ()
  "Return warnings accumulated by the most recent `mindwtr-parse-buffer'.
A list of plists (:id :title :keyword :kind) in document order; empty when
the parse was clean."
  (reverse mindwtr-parse--warnings))

(defun mindwtr-parse--build-area-names ()
  "Scan the current buffer for area headings, returning a name->id hash.
Warns on a duplicate name (keeps the first id)."
  (let ((h (make-hash-table :test 'equal)))
    (mindwtr-heading-map
     (lambda ()
       (when (string= (or (mindwtr-heading-prop "MW_TYPE") "") "area")
         ;; Same link conversion as `mindwtr-parse-heading' titles, so the
         ;; name->id map keys match the server-side (markdown) names that
         ;; `:CATEGORY:' values carry.
         (let ((name (mindwtr-parse--org->mw-links (org-get-heading t t t t)))
               (id (mindwtr-heading-prop "MW_ID")))
           (when (and name id)
             (if (gethash name h)
                 (message "mindwtr: duplicate area name %S; keeping first" name)
               (puthash name id h)))))))
    h))

(defun mindwtr-parse--area-id (entity-area-name)
  "Resolve an area `:CATEGORY:' ENTITY-AREA-NAME to an area id, or nil."
  (and entity-area-name mindwtr-parse--area-names
       (gethash entity-area-name mindwtr-parse--area-names)))

(defun mindwtr-parse-heading (&optional kind)
  "Parse the org heading at point into a Mindwtr entity content plist.
KIND, when given, is the entity kind symbol to use (e.g. for a heading whose
type was inferred from context).  When omitted it is read from the
:MW_TYPE: property, falling back to `mindwtr-parse-infer-kind'."
  (save-excursion (mindwtr-parse-ensure-keywords))
  (org-back-to-heading t)
  (let* ((kind (or kind
                   (let ((mt (mindwtr-heading-prop "MW_TYPE")))
                     (and mt (intern mt)))
                   (mindwtr-parse-infer-kind)
                   (error "Heading has no MW_TYPE and type could not be inferred: %s"
                          (org-get-heading t t t t))))
         (id (mindwtr-heading-prop "MW_ID"))
         ;; Titles convert org links to markdown like body prose does (#29);
         ;; links-only, so a title starting with `+ ' is not bullet-mangled.
         (title (mindwtr-parse--org->mw-links (org-get-heading t t t t)))
         (todo (org-get-todo-state))
         (tags (org-get-tags nil t))
         (split (mindwtr-parse--split-tags tags))
         (e (list :id id :mw-kind kind
                  :mw-extra-props (mindwtr-parse-extra-props))))
    (pcase kind
      ((or 'area 'person) (setq e (plist-put e :name title)))
      ((or 'project 'section 'task) (setq e (plist-put e :title title))))
    (when (memq kind '(task project))
      (let ((status (and todo (mindwtr-model-keyword->status-safe kind todo))))
        (cond
         (status (setq e (plist-put e :status status)))
         (todo
          ;; An org-recognized keyword that is wrong for this kind (e.g. NEXT on
          ;; a project).  Omit the status rather than erroring -- the shadow
          ;; merge keeps the prior status (or a type default for a new entity),
          ;; so a stray keyword no longer aborts the whole sync.  Record it so
          ;; the sync report can surface it (see `mindwtr-parse-warnings').
          (push (list :id id :title title :keyword todo :kind kind)
                mindwtr-parse--warnings)))))
    (when (eq kind 'task)
      (let* ((body (mindwtr-parse--body t))
             (pr (nth 3 (org-heading-components))))
        (setq e (plist-put e :priority (mindwtr-model-cookie->priority pr)))
        ;; MW_CONTEXTS/MW_TAGS are the exact-fidelity fallback for values
        ;; org tags can't hold; when present they are authoritative and the
        ;; native `:tags:' line (suppressed by render in that case) is
        ;; ignored for the corresponding list.
        (let ((mw-contexts (mindwtr-heading-prop "MW_CONTEXTS"))
              (mw-tags (mindwtr-heading-prop "MW_TAGS")))
          (setq e (plist-put e :contexts
                             (if mw-contexts
                                 (mindwtr-util-json-decode mw-contexts)
                               (car split))))
          (setq e (plist-put e :tags
                             (if mw-tags
                                 (mindwtr-util-json-decode mw-tags)
                               (cdr split)))))
        (setq e (plist-put e :description (car body)))
        (when (cdr body) (setq e (plist-put e :checklist (cdr body))))
        (let ((s (mindwtr-parse--planning-iso "SCHEDULED: *\\(<[^>]+>\\)"))
              (d (mindwtr-parse--planning-iso "DEADLINE: *\\(<[^>]+>\\)"))
              (c (mindwtr-parse--planning-iso "CLOSED: *\\(\\[[^]]+\\]\\)")))
          (when s (setq e (plist-put e :startTime s)))
          (when d (setq e (plist-put e :dueDate d)))
          (when c (setq e (plist-put e :completedAt c))))
        (dolist (p '(("MW_ENERGY" . :energyLevel) ("MW_TIME_ESTIMATE" . :timeEstimate)
                     ("MW_ASSIGNED_TO" . :assignedTo) ("MW_LOCATION" . :location)
                     ("MW_TASK_MODE" . :taskMode)))
          (let ((v (mindwtr-heading-prop (car p))))
            (when v (setq e (plist-put e (cdr p) v)))))
        ;; Device-local clock-time roll-up input: the task's closed LOGBOOK sum
        ;; (minutes), carried to the sync reconcile pass; never rendered, signed,
        ;; or sent on the wire (KTD11/KTD13).
        (setq e (plist-put e :mw-logbook-minutes (mindwtr-clock--logbook-minutes)))))
    ;; Notes prose for the non-task note-bearing kinds, dispatched through the
    ;; registry (`mindwtr-model-notes-field': section -> :description, project
    ;; -> :supportNotes).  task is handled in its own block above; any future
    ;; note-bearing kind added to the registry is picked up here automatically,
    ;; with no second edit-point to keep in sync.  Parsed WITHOUT checklist
    ;; extraction so a `- [ ]' line stays literal prose (R9).  Set
    ;; unconditionally (like the task :description above) so an emptied note
    ;; clears the field on merge.
    (when (and (not (eq kind 'task)) (mindwtr-model-notes-field kind))
      (setq e (plist-put e (mindwtr-model-notes-field kind)
                         (car (mindwtr-parse--body nil)))))
    ;; Reserved drawer fields parsed kind-agnostically -- mirror the :areaId
    ;; resolution below, which also runs for every kind.  MW_SEQUENTIAL/
    ;; MW_FOCUSED are project-only and MW_REVIEW_AT is task+project, so parsing
    ;; them inside the task-only block above would leave the project-side fields
    ;; permanently unparsed.  Booleans: set the key to `t' only when the value
    ;; is exactly "t"; a blank or absent value omits the key (never read an
    ;; empty string as meaningful -- the same blank-guard discipline that fixed
    ;; the blank-MW_TYPE bug).  Parsing a field on a kind that never carries it
    ;; is harmless (the drawer simply lacks the key).
    (dolist (p '(("MW_FOCUS_TODAY" . :isFocusedToday)
                 ("MW_SEQUENTIAL" . :isSequential)
                 ("MW_FOCUSED" . :isFocused)))
      (let ((v (mindwtr-heading-prop (car p))))
        (when (and v (string= (string-trim v) "t"))
          (setq e (plist-put e (cdr p) t)))))
    (let ((rv (mindwtr-heading-prop "MW_REVIEW_AT")))
      (when (and rv (not (string-empty-p (string-trim rv))))
        (setq e (plist-put e :reviewAt rv))))
    ;; MW_REFERENCE_LINK is person-only, but parsed kind-agnostically (mirrors
    ;; MW_REVIEW_AT above): a kind that never carries it simply lacks the key.
    ;; A blank value omits the key (the blank-guard discipline).
    (let ((rl (mindwtr-heading-prop "MW_REFERENCE_LINK")))
      (when (and rl (not (string-empty-p (string-trim rl))))
        (setq e (plist-put e :referenceLink rl))))
    ;; MW_CLOCK_SYNCED is the device-local clock-time baseline (minutes we last
    ;; synced), read kind-agnostically like MW_REVIEW_AT above.  A blank value
    ;; omits the key (treated as 0 downstream).  It is stripped before the wire
    ;; (KTD13) and never signed, so it is device-local state kept in the drawer.
    (let ((cs (mindwtr-heading-prop "MW_CLOCK_SYNCED")))
      (when (and cs (not (string-empty-p (string-trim cs))))
        (setq e (plist-put e :mw-clock-synced (string-to-number cs)))))
    ;; Area: org-native `:CATEGORY:' is the vehicle; fall back to a legacy
    ;; `:MW_AREA:' when no `:CATEGORY:' is present so the first post-upgrade
    ;; parse of an old buffer reads the real area (never a false-empty that
    ;; reads as the user clearing the area).  Both reads are drawer-local
    ;; (KTD2/KTD3).
    (let ((aid (mindwtr-parse--area-id
                (or (mindwtr-heading-prop "CATEGORY")
                    (mindwtr-heading-prop "MW_AREA")))))
      (when aid (setq e (plist-put e :areaId aid))))
    e))

(defconst mindwtr-parse--internal-keys '(:mw-kind :mw-extra-props :mw-ancestors)
  "Keys used during parsing that must be stripped from output entities.")

(defun mindwtr-parse--strip-internal (e)
  "Return E without internal :mw-* keys (but keep :mw-extra-props in metadata)."
  (mindwtr-util-plist-omit e '(:mw-kind :mw-ancestors)))

(defun mindwtr-parse-infer-kind ()
  "Infer an entity kind for a heading lacking :MW_TYPE: from its outline context.
Returns `task', `project', `area', or `person', or nil when the position
implies no mindwtr entity (no recognized container ancestor -- e.g. a stray
top-level heading, or one parked under `* Sync Failures').  Keyed on the nearest
container's :MW_LIST: plus project/section ancestry:

  inbox / single-actions / someday-single-actions / reference -> task
  projects / someday-projects, under a project or section       -> task
  projects / someday-projects, direct child of the container    -> project
  areas                                                         -> area
  people                                                        -> person"
  (pcase (mindwtr-heading-container-role)
    ((or "inbox" "single-actions" "someday-single-actions" "reference") 'task)
    ((or "projects" "someday-projects")
     (if (or (mindwtr-heading-ancestor-id 'section)
             (mindwtr-heading-ancestor-id 'project))
         'task 'project))
    ("areas" 'area)
    ("people" 'person)
    (_ nil)))

(defun mindwtr-parse-buffer (&optional area-names)
  "Parse the current org buffer into a content appdata plist.
AREA-NAMES (name->id hash) overrides the buffer scan for area headings; the
sync passes the main file's map so the archive surface resolves `:CATEGORY:'."
  (setq mindwtr-parse--warnings nil)
  (mindwtr-parse-ensure-keywords)
  (let ((mindwtr-parse--area-names (or area-names (mindwtr-parse--build-area-names)))
        tasks projects sections areas people)
    (mindwtr-heading-map
     (lambda ()
       ;; A heading's kind comes from its :MW_TYPE: property; a `container'
       ;; is structural, not an entity.  When :MW_TYPE: is absent (org-capture,
       ;; raw edit, mobile), fall back to inferring the kind from outline
       ;; context so the heading still round-trips instead of being silently
       ;; dropped (and then erased by reconcile).
       (let* ((mt (mindwtr-heading-type))
              (kind (cond ((null mt) (mindwtr-parse-infer-kind))
                          ((string= mt "container") nil)
                          (t (intern mt)))))
         (when kind
           (let ((e (mindwtr-parse-heading kind)))
             (pcase kind
               ('area (push (mindwtr-parse--strip-internal e) areas))
               ('person (push (mindwtr-parse--strip-internal e) people))
               ('project (push (mindwtr-parse--strip-internal e) projects))
               ('section
                (let ((pid (mindwtr-heading-ancestor-id 'project)))
                  (when pid (setq e (plist-put e :projectId pid))))
                (push (mindwtr-parse--strip-internal e) sections))
               ('task
                ;; Containment: an explicit MW_SECTION_ID/MW_PROJECT_ID drawer
                ;; prop (the archive file's cross-split carrier, KTD4) wins over
                ;; outline ancestry per axis.  In the main file the props are
                ;; never emitted, so there it is the ancestry walk.  A
                ;; sectioned task carries its project too: upstream's canonical
                ;; form is the section plus its project
                ;; (`resolveTaskContainerHierarchy'), and the server's repair
                ;; restores a dropped projectId, so parsing the section alone
                ;; pushed `projectId -> (empty)' on every sync.
                (let ((sid (or (mindwtr-heading-prop "MW_SECTION_ID")
                               (mindwtr-heading-ancestor-id 'section)))
                      (pid (or (mindwtr-heading-prop "MW_PROJECT_ID")
                               (mindwtr-heading-ancestor-id 'project))))
                  (when sid (setq e (plist-put e :sectionId sid)))
                  (when pid (setq e (plist-put e :projectId pid))))
                (push (mindwtr-parse--strip-internal e) tasks))))))))
    (list :tasks (nreverse tasks) :projects (nreverse projects)
          :sections (nreverse sections) :areas (nreverse areas)
          :people (nreverse people))))

(provide 'mindwtr-parse)
;;; mindwtr-parse.el ends here
