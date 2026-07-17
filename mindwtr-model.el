;;; mindwtr-model.el --- Mindwtr data model & validation -*- lexical-binding: t; -*-
;;; Commentary:
;; Enums, status/priority maps, field registries, and appdata validation.
;;; Code:

(require 'mindwtr-util)

(defconst mindwtr-model-task-statuses
  '("inbox" "next" "waiting" "someday" "reference" "done" "archived"))

(defconst mindwtr-model-project-statuses
  '("active" "someday" "waiting" "archived"))

(defconst mindwtr-model-todo-keywords
  '((sequence "INBOX(i)" "NEXT(n)" "WAIT(w)" "SOMEDAY(s)" "REF(r)" "ACTIVE(a)"
              "|" "DONE(d)" "ARCH(x)"))
  "Canonical `org-todo-keywords' sequence for Mindwtr buffers.
The single source of truth: `mindwtr-mode' and the parser both bind this,
and `mindwtr-model-todo-keyword-line' renders it as the in-buffer header so
the keywords are registered regardless of the user's global config.")

(defconst mindwtr-model-todo-keyword-names
  '("INBOX" "NEXT" "WAIT" "SOMEDAY" "REF" "ACTIVE" "DONE" "ARCH")
  "Bare Mindwtr TODO keyword names (no fast-access keys, no `|').
Used to test whether a buffer already has the full sequence registered.")

(defun mindwtr-model-todo-keyword-line ()
  "Return the in-buffer `#+TODO:' line registering the Mindwtr keywords.
Emitted at the top of the rendered file so org honours these keywords for
the file alone, overriding whatever the user's global `org-todo-keywords'
defines."
  (concat "#+TODO: " (mapconcat #'identity (cdar mindwtr-model-todo-keywords) " ")))

(defconst mindwtr-model--task-status-keywords
  '(("inbox" . "INBOX") ("next" . "NEXT") ("waiting" . "WAIT")
    ("someday" . "SOMEDAY") ("reference" . "REF")
    ("done" . "DONE") ("archived" . "ARCH")))

(defconst mindwtr-model--project-status-keywords
  '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
    ("waiting" . "WAIT") ("archived" . "ARCH")))

(defconst mindwtr-model-list-roles
  '("inbox" "single-actions" "projects"
    "someday" "someday-single-actions" "someday-projects"
    "reference" "areas" "archive")
  "Every container role used as a `:MW_LIST:' discriminator.
`* Someday' is a container whose children are the `someday-single-actions'
and `someday-projects' containers; the rest are top-level.  `archive' is the
container role of the synced archive file's single `* Archive' heading; it is
deliberately absent from `mindwtr-parse--infer-kind' (KTD9) -- a direct child
of `* Archive' could be a task or a project, so an untyped heading there
quarantines rather than being guessed.")

(defconst mindwtr-model--list-titles
  '(("inbox" . "Inbox") ("single-actions" . "Single Actions")
    ("projects" . "Projects") ("someday" . "Someday")
    ("someday-single-actions" . "Single Actions")
    ("someday-projects" . "Projects")
    ("reference" . "Reference") ("areas" . "Areas of Focus")
    ("archive" . "Archive")))

(defun mindwtr-model-list-title (role)
  "Default heading text for a container ROLE."
  (or (cdr (assoc role mindwtr-model--list-titles))
      (error "Unknown list role: %s" role)))

(defconst mindwtr-model--status->list
  '(("inbox" . "inbox") ("next" . "single-actions") ("waiting" . "single-actions")
    ("done" . "single-actions") ("someday" . "someday-single-actions")
    ("reference" . "reference"))
  "STANDALONE task status -> container role.  `archived' is absent on purpose:
archived tasks are not rendered.")

(defun mindwtr-model-status->list (status)
  "Return the list role a standalone task with STATUS renders under, or nil
when it must not be rendered (e.g. `archived')."
  (cdr (assoc status mindwtr-model--status->list)))

(defconst mindwtr-model--project-status->list
  '(("active" . "projects") ("waiting" . "projects")
    ("someday" . "someday-projects"))
  "Project status -> container role.  `archived' is absent (not rendered).")

(defun mindwtr-model-project-status->list (status)
  "Return the list role a project with STATUS renders under, or nil
when it must not be rendered (e.g. `archived')."
  (cdr (assoc status mindwtr-model--project-status->list)))

(defconst mindwtr-model-done-keywords '("DONE" "ARCH")
  "TODO keywords that count as org `done' states.")

(defun mindwtr-model--status-alist (kind)
  (pcase kind
    ('task mindwtr-model--task-status-keywords)
    ('project mindwtr-model--project-status-keywords)
    (_ (error "Unknown entity kind: %s" kind))))

(defun mindwtr-model-status->keyword (kind status)
  "Map STATUS string to its org TODO keyword for entity KIND."
  (or (cdr (assoc status (mindwtr-model--status-alist kind)))
      (error "Invalid %s status: %s" kind status)))

(defun mindwtr-model-keyword->status (kind keyword)
  "Map org TODO KEYWORD back to a STATUS string for entity KIND."
  (or (car (rassoc keyword (mindwtr-model--status-alist kind)))
      (error "Invalid %s keyword: %s" kind keyword)))

(defun mindwtr-model-keyword->status-safe (kind keyword)
  "Like `mindwtr-model-keyword->status' but return nil for a type-invalid KEYWORD.
Used by the parser backstop so an org-recognized keyword that is wrong for
KIND (e.g. NEXT on a project) does not abort the sync."
  (car (rassoc keyword (mindwtr-model--status-alist kind))))

(defconst mindwtr-model--keyword-fast-keys
  (let (alist)
    (dolist (kw (cdar mindwtr-model-todo-keywords))
      (when (string-match "\\`\\([A-Z]+\\)(\\(.\\))\\'" kw)
        (push (cons (match-string 1 kw) (string-to-char (match-string 2 kw))) alist)))
    (nreverse alist))
  "Alist KEYWORD -> fast-access char, parsed from `mindwtr-model-todo-keywords'.
The `|' separator entry has no `(key)' and is skipped.")

(defun mindwtr-model-status-choices (kind)
  "Return ((KEYWORD . CHAR) ...) of valid TODO keywords for entity KIND.
Ordered by the kind's status alist (active states first, then done states);
each keyword is paired with its fast-access char from the shared sequence."
  (mapcar (lambda (pair)
            (let ((kw (cdr pair)))
              (cons kw (cdr (assoc kw mindwtr-model--keyword-fast-keys)))))
          (mindwtr-model--status-alist kind)))

(defconst mindwtr-model--priority-cookies
  '(("urgent" . ?A) ("high" . ?B) ("medium" . ?C) ("low" . ?D)))

(defun mindwtr-model-priority->cookie (priority)
  "Map PRIORITY string to its org priority character, or nil."
  (when priority
    (or (cdr (assoc priority mindwtr-model--priority-cookies))
        (error "Invalid priority: %s" priority))))

(defun mindwtr-model-cookie->priority (cookie)
  "Map org priority character COOKIE to a PRIORITY string, or nil."
  (when cookie (car (rassoc cookie mindwtr-model--priority-cookies))))

(defconst mindwtr-model-shadow-only-fields
  '(:rev :revBy :deletedAt :color :icon :textDirection
    :order :orderNum :boardOrder :focusOrder
    :pushCount :showFutureRecurrence :completedOccurrences
    :purgedAt)
  "Fields stored only in the shadow, never written to org.")

(defconst mindwtr-model-display-mirror-fields '(:createdAt :updatedAt)
  "Fields rendered read-only into org; authoritative in the shadow.")

(defconst mindwtr-model-content-fields
  '(:name :title :status :priority :contexts :tags :description :supportNotes
    :checklist :startTime :dueDate :completedAt
    :areaId :projectId :sectionId
    :energyLevel :timeEstimate :assignedTo :location :taskMode
    :isFocusedToday :isSequential :isFocused :reviewAt)
  "Editable fields that round-trip through org and define the content signature.
This is an allow-list: any server field not named here (e.g.
`:tagIds', `:areaTitle', `:sequentialScope', `:recurrence', `:attachments')
is excluded from change detection by construction, so it can neither drift a
signature nor be lost -- it is preserved verbatim in the shadow and merged
back on write.  `:supportNotes' (project notes) and `:description'
\(task/section notes) both round-trip as inline body prose and so are
allow-listed.  The reserved drawer fields `:isFocusedToday' (task),
`:isSequential'/`:isFocused' (project), and `:reviewAt' (task+project) are
allow-listed too: they render to the MW_FOCUS_TODAY/MW_SEQUENTIAL/MW_FOCUSED/
MW_REVIEW_AT drawer properties and round-trip (the booleans normalize so
`:false'/nil/absent sign identically; `:reviewAt' coarsens to minute
precision).  This list is kind-agnostic -- it is iterated for every
entity regardless of kind -- so a field only affects an entity's signature
when that entity actually carries the key (e.g. `:supportNotes' is inert on
areas, which never carry it).  Excludes
`:id' (identity, matched separately), shadow-only fields, display
mirrors, and internal parse keys.  Containment IDs ARE included: refiling
a heading equals re-parenting in Mindwtr, so a changed parent must change
the signature.")

(defconst mindwtr-model-device-local-fields
  '(:lastSyncStats :lastSyncHistory :localStatus
    :pendingRemoteWriteAt :pendingRemoteWriteRetryAt :pendingRemoteWriteAttempts)
  "Fields that must be stripped before sending to the server.")

(defconst mindwtr-model--notes-fields
  '((task . :description) (section . :description) (project . :supportNotes))
  "Alist of entity-kind -> the body-prose (notes) field that renders inline.
`area' has no notes field and is omitted.  Render, parse, and reconcile all
read this through `mindwtr-model-notes-field' so the kind->field mapping
lives in one place -- adding a new note-bearing kind is a single edit here
rather than three divergent per-kind checks across render/parse/reconcile.")

(defun mindwtr-model-notes-field (kind)
  "Return the inline body-prose (notes) field keyword for entity KIND, or nil.
task/section -> `:description'; project -> `:supportNotes'; area -> nil."
  (cdr (assq kind mindwtr-model--notes-fields)))

(defconst mindwtr-model--protected-boolean-fields
  '((task . (:isFocusedToday)) (project . (:isSequential :isFocused)))
  "Alist of entity-kind -> the newly-signed boolean fields whose empty value
must be protected from clobbering server data on the first post-upgrade sync.
These are exactly the booleans that never rendered before the render-key fix,
so an old on-disk buffer parses them as empty (a false-empty, not a clear).
`:reviewAt' is absent on purpose: it always rendered, so an empty local value
is a genuine clear, not a false-empty (see the migration-latch reasoning).")

(defun mindwtr-model-protected-boolean-fields (kind)
  "Return the list of migration-protected boolean fields for entity KIND.
Empty for kinds that carry none (section, area)."
  (cdr (assq kind mindwtr-model--protected-boolean-fields)))

(defun mindwtr-model-entity-title (entity)
  "Return ENTITY's human-readable label, or nil when it carries neither key.
task/project/section carry `:title'; area carries `:name'.  One place for the
kind-agnostic title lookup so callers (the sync report, incoming-changes) do
not each re-spell the `(or :title :name)' idiom."
  (or (plist-get entity :title) (plist-get entity :name)))

(defconst mindwtr-model-known-fields
  '((task    . (:id :title :status :priority :energyLevel :timeEstimate
                :timeSpentMinutes :assignedTo :taskMode
                :startTime :relativeStartOffset :dueDate :recurrence
                :showFutureRecurrence :pushCount :tags :contexts :checklist
                :description :textDirection :attachments :location
                :suppressMindwtrReminders :repeatReminderMinutes
                :projectId :sectionId :areaId :isFocusedToday :reviewAt
                :completedAt :statusBeforeProjectArchive
                :completedAtBeforeProjectArchive
                :isFocusedTodayBeforeProjectArchive :projectArchivedAt
                :order :orderNum :boardOrder :focusOrder
                :rev :revBy :createdAt :updatedAt
                :deletedAt :purgedAt))
    (project . (:id :title :status :color :order :tagIds :isSequential
                :sequentialScope :isFocused :supportNotes :attachments
                :dueDate :reviewAt :areaId :areaTitle :rev :revBy
                :createdAt :updatedAt :deletedAt :purgedAt))
    (section . (:id :projectId :title :description :order :isCollapsed
                :rev :revBy :createdAt :updatedAt :deletedAt
                :deletedAtBeforeProjectArchive :projectArchivedAt))
    (area    . (:id :name :color :icon :order :rev :revBy
                :createdAt :updatedAt :deletedAt)))
  "Every server key we recognize, per synced entity type.
Transcribed from the Mindwtr core `types.ts' interfaces (Task, Project,
Section, Area).  The smoke suite flags wire keys absent here as UNKNOWN
\(server drift); doubles as living documentation of the synced schema.
Extend it deliberately when a new server field is intentionally adopted.
Settings is excluded on purpose -- it is a large, deeply-nested blob
passed through verbatim and never rendered to org.

Recognizing a key here is NOT the same as surfacing it: a field appears in
org only if it is also in `mindwtr-model-content-fields' (round-trips) or the
render drawer.  The following are recognized-only -- preserved verbatim in the
shadow and merged back on write, never rendered or edited:
`:timeSpentMinutes', `:relativeStartOffset', `:suppressMindwtrReminders',
`:repeatReminderMinutes' (each participates in the SERVER's content signature,
per `sync-signatures.ts', but the client does not diff them -- they can only
drift server-side, and a verbatim echo preserves them), and the order-only
`:boardOrder'/`:focusOrder' (manual Board-column / Today's-Focus ordering the
apps clear on status change; the server excludes them from its signature).
`:purgedAt' is a Trash tombstone marker on both task and project.")

(defun mindwtr-model-default-settings ()
  "Return a fresh, minimal non-null `settings' object for a new namespace.
A freshly provisioned server namespace has no `settings', so the client must
create initial ones: the Cloud server's settings merge dereferences the
incoming `settings.syncPreferences' without a null guard and 500s when the
client sends an absent/null settings blob.  A single non-empty key keeps the
object from collapsing back to JSON null through the encoder (empty objects
do); `syncPreferences' is the field the server's merge reads first."
  (list :syncPreferences (list :initialized t)))

(defun mindwtr-model-ensure-settings (appdata)
  "Return APPDATA with a guaranteed non-null `settings'.
Substitutes `mindwtr-model-default-settings' when APPDATA carries no settings
(a freshly provisioned namespace), so the server's settings merge is never
handed a null blob -- it dereferences `settings.syncPreferences' without a
null guard and 500s otherwise.  Present settings are returned unchanged; the
substitution copies APPDATA rather than mutating the caller's structure."
  (if (plist-get appdata :settings) appdata
    (plist-put (copy-sequence appdata) :settings (mindwtr-model-default-settings))))

(defun mindwtr-model-shadow-only-field-p (field)
  "Non-nil if FIELD (a keyword) is shadow-only."
  (and (memq field mindwtr-model-shadow-only-fields) t))

(defun mindwtr-model-validate-appdata (appdata)
  "Signal an error if APPDATA is structurally invalid; else return t."
  (dolist (key '(:tasks :projects :sections :areas))
    (unless (listp (plist-get appdata key))
      (error "appdata %s must be a list" key)))
  (dolist (task (plist-get appdata :tasks))
    (unless (and (plist-get task :id) (stringp (plist-get task :id)))
      (error "task missing string id: %S" task))
    (let ((st (plist-get task :status)))
      (unless (or (plist-get task :deletedAt)
                  (member st mindwtr-model-task-statuses))
        (error "task %s has invalid status %S" (plist-get task :id) st))))
  (dolist (proj (plist-get appdata :projects))
    (unless (plist-get proj :id) (error "project missing id: %S" proj))
    (let ((st (plist-get proj :status)))
      (when (and st (not (plist-get proj :deletedAt)) (not (member st mindwtr-model-project-statuses)))
        (error "project %s has invalid status %S" (plist-get proj :id) st))))
  (dolist (sec (plist-get appdata :sections))
    (unless (plist-get sec :id) (error "section missing id: %S" sec))
    (unless (plist-get sec :projectId)
      (error "section %s missing projectId" (plist-get sec :id))))
  (dolist (area (plist-get appdata :areas))
    (unless (plist-get area :id) (error "area missing id: %S" area)))
  t)

(provide 'mindwtr-model)
;;; mindwtr-model.el ends here
