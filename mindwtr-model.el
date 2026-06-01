;;; mindwtr-model.el --- Mindwtr data model & validation -*- lexical-binding: t; -*-
;;; Commentary:
;; Enums, status/priority maps, field registries, and appdata validation.
;;; Code:

(require 'mindwtr-util)

(defconst mindwtr-model-task-statuses
  '("inbox" "next" "waiting" "someday" "reference" "done" "archived"))

(defconst mindwtr-model-project-statuses
  '("active" "someday" "waiting" "archived"))

(defconst mindwtr-model--task-status-keywords
  '(("inbox" . "INBOX") ("next" . "NEXT") ("waiting" . "WAIT")
    ("someday" . "SOMEDAY") ("reference" . "REF")
    ("done" . "DONE") ("archived" . "ARCH")))

(defconst mindwtr-model--project-status-keywords
  '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
    ("waiting" . "WAIT") ("archived" . "ARCH")))

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
    :order :orderNum :pushCount :showFutureRecurrence :completedOccurrences
    :purgedAt)
  "Fields stored only in the shadow, never written to org.")

(defconst mindwtr-model-display-mirror-fields '(:createdAt :updatedAt)
  "Fields rendered read-only into org; authoritative in the shadow.")

(defconst mindwtr-model-content-fields
  '(:name :title :status :priority :contexts :tags :description :checklist
    :startTime :dueDate :completedAt
    :areaId :projectId :sectionId
    :energyLevel :timeEstimate :assignedTo :location :taskMode)
  "Editable fields that round-trip through org and define the content signature.
This is an allow-list: any server field not named here (e.g.
`:isFocusedToday', `:isSequential', `:supportNotes', `:tagIds',
`:areaTitle', `:reviewAt') is excluded from change detection by
construction, so it can neither drift a signature nor be lost -- it is
preserved verbatim in the shadow and merged back on write.  Excludes
`:id' (identity, matched separately), shadow-only fields, display
mirrors, and internal parse keys.  Containment IDs ARE included: refiling
a heading equals re-parenting in Mindwtr, so a changed parent must change
the signature.")

(defconst mindwtr-model-device-local-fields
  '(:lastSyncStats :lastSyncHistory :localStatus
    :pendingRemoteWriteAt :pendingRemoteWriteRetryAt :pendingRemoteWriteAttempts)
  "Fields that must be stripped before sending to the server.")

(defconst mindwtr-model-known-fields
  '((task    . (:id :title :status :priority :energyLevel :timeEstimate
                :assignedTo :taskMode :startTime :dueDate :recurrence
                :showFutureRecurrence :pushCount :tags :contexts :checklist
                :description :textDirection :attachments :location
                :projectId :sectionId :areaId :isFocusedToday :reviewAt
                :completedAt :statusBeforeProjectArchive
                :completedAtBeforeProjectArchive
                :isFocusedTodayBeforeProjectArchive :projectArchivedAt
                :order :orderNum :rev :revBy :createdAt :updatedAt
                :deletedAt :purgedAt))
    (project . (:id :title :status :color :order :tagIds :isSequential
                :sequentialScope :isFocused :supportNotes :attachments
                :dueDate :reviewAt :areaId :areaTitle :rev :revBy
                :createdAt :updatedAt :deletedAt))
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
passed through verbatim and never rendered to org.")

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
