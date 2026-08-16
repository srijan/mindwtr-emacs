;;; mindwtr-model-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-model)

(ert-deftest mindwtr-model-task-status-keyword-roundtrip ()
  (dolist (pair '(("inbox" . "INBOX") ("next" . "NEXT") ("waiting" . "WAIT")
                  ("someday" . "SOMEDAY") ("reference" . "REF")
                  ("done" . "DONE") ("archived" . "ARCH")))
    (should (string= (mindwtr-model-status->keyword 'task (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-keyword->status 'task (cdr pair)) (car pair)))))

(ert-deftest mindwtr-model-project-status-keyword-roundtrip ()
  (dolist (pair '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
                  ("waiting" . "WAIT") ("archived" . "ARCH")))
    (should (string= (mindwtr-model-status->keyword 'project (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-keyword->status 'project (cdr pair)) (car pair)))))

(ert-deftest mindwtr-model-priority-cookie-roundtrip ()
  (dolist (pair '(("urgent" . ?A) ("high" . ?B) ("medium" . ?C) ("low" . ?D)))
    (should (eq (mindwtr-model-priority->cookie (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-cookie->priority (cdr pair)) (car pair))))
  (should (null (mindwtr-model-priority->cookie nil))))

(ert-deftest mindwtr-model-shadow-only-field-p ()
  (should (mindwtr-model-shadow-only-field-p :rev))
  (should (mindwtr-model-shadow-only-field-p :color))
  (should (mindwtr-model-shadow-only-field-p :boardOrder))
  (should (mindwtr-model-shadow-only-field-p :focusOrder))
  (should-not (mindwtr-model-shadow-only-field-p :title)))

(ert-deftest mindwtr-model-validate-appdata-accepts-minimal ()
  (should (mindwtr-model-validate-appdata
           '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-appdata-rejects-task-without-id ()
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks ((:title "x" :status "next")) :projects nil
      :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-appdata-rejects-bad-status ()
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks ((:id "1" :title "x" :status "bogus")) :projects nil
      :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-accepts-task-tombstone-without-status ()
  "A tombstoned task (deletedAt set) need not carry a valid status."
  (should (mindwtr-model-validate-appdata
           '(:tasks ((:id "t1" :deletedAt "2026-06-01T00:00:00Z" :rev 4))
             :projects nil :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-accepts-project-tombstone-without-status ()
  (should (mindwtr-model-validate-appdata
           '(:tasks nil
             :projects ((:id "p1" :deletedAt "2026-06-01T00:00:00Z" :rev 2))
             :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-still-rejects-live-task-without-status ()
  "A live task (no deletedAt) with an invalid status is still rejected."
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks ((:id "t1" :title "x" :status "bogus")) :projects nil
      :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-todo-keyword-line-lists-full-sequence ()
  "The in-buffer `#+TODO:' line carries every Mindwtr keyword, in order,
with fast-access keys and the done-state separator."
  (should (string= (mindwtr-model-todo-keyword-line)
                   "#+TODO: INBOX(i) NEXT(n) WAIT(w) SOMEDAY(s) REF(r) ACTIVE(a) | DONE(d) ARCH(x)")))

(ert-deftest mindwtr-model-todo-keyword-names-are-bare ()
  "The bare-name list has no fast-access keys and omits the `|' separator."
  (should (equal mindwtr-model-todo-keyword-names
                 '("INBOX" "NEXT" "WAIT" "SOMEDAY" "REF" "ACTIVE" "DONE" "ARCH")))
  (should-not (member "|" mindwtr-model-todo-keyword-names)))

(ert-deftest mindwtr-model-known-fields-covers-entity-types ()
  "The registry has an entry per synced entity type with representative keys."
  (should (assq 'task mindwtr-model-known-fields))
  (should (assq 'project mindwtr-model-known-fields))
  (should (assq 'section mindwtr-model-known-fields))
  (should (assq 'area mindwtr-model-known-fields))
  (should (assq 'person mindwtr-model-known-fields))
  ;; settings is intentionally excluded (verbatim passthrough)
  (should-not (assq 'settings mindwtr-model-known-fields))
  ;; Person field set is exactly the core `Person' (KTD3): no color/icon/order.
  (should (equal (cdr (assq 'person mindwtr-model-known-fields))
                 '(:id :name :note :referenceLink :rev :revBy
                   :createdAt :updatedAt :deletedAt)))
  ;; representative keys transcribed from Mindwtr core types.ts
  (let ((task (cdr (assq 'task mindwtr-model-known-fields)))
        (proj (cdr (assq 'project mindwtr-model-known-fields)))
        (sec  (cdr (assq 'section mindwtr-model-known-fields)))
        (area (cdr (assq 'area mindwtr-model-known-fields))))
    (dolist (k '(:id :title :status :checklist :attachments :recurrence
                 :completedAt :purgedAt :deletedAt :rev :revBy
                 ;; recognized-only fields transcribed from later types.ts revs
                 :timeSpentMinutes :relativeStartOffset :suppressMindwtrReminders
                 :repeatReminderMinutes :boardOrder :focusOrder))
      (should (memq k task)))
    (dolist (k '(:sequentialScope :supportNotes :attachments :dueDate :reviewAt
                 :isSequential :isFocused :areaTitle :purgedAt
                 ;; recognized-only, added server-side in 1.2.0
                 :taskSortBy))
      (should (memq k proj)))
    (dolist (k '(:description :isCollapsed :deletedAtBeforeProjectArchive
                 :projectArchivedAt))
      (should (memq k sec)))
    (should (memq :icon area)))
  ;; every content field is a known key for at least one entity kind
  ;; (e.g. :name is an area field, :supportNotes a project field, :description
  ;; a task/section field -- none are task-only, so check the union).
  (let ((all-known (apply #'append (mapcar #'cdr mindwtr-model-known-fields))))
    (dolist (k mindwtr-model-content-fields)
      (should (memq k all-known)))))

(ert-deftest mindwtr-model-list-roles-and-titles ()
  (should (equal mindwtr-model-list-roles
                 '("inbox" "single-actions" "projects"
                   "someday" "someday-single-actions" "someday-projects"
                   "reference" "areas" "people" "archive")))
  (should (string= (mindwtr-model-list-title "single-actions") "Single Actions"))
  (should (string= (mindwtr-model-list-title "someday-single-actions") "Single Actions"))
  (should (string= (mindwtr-model-list-title "someday-projects") "Projects"))
  (should (string= (mindwtr-model-list-title "areas") "Areas of Focus"))
  (should (string= (mindwtr-model-list-title "people") "People"))
  (should (string= (mindwtr-model-list-title "archive") "Archive")))

(ert-deftest mindwtr-model-status->list-maps-standalone-statuses ()
  (should (string= (mindwtr-model-status->list "inbox") "inbox"))
  (should (string= (mindwtr-model-status->list "next") "single-actions"))
  (should (string= (mindwtr-model-status->list "waiting") "single-actions"))
  (should (string= (mindwtr-model-status->list "done") "single-actions"))
  (should (string= (mindwtr-model-status->list "someday") "someday-single-actions"))
  (should (string= (mindwtr-model-status->list "reference") "reference"))
  ;; archived has no list -> not rendered
  (should (null (mindwtr-model-status->list "archived"))))

(ert-deftest mindwtr-model-project-status->list-maps-project-statuses ()
  (should (string= (mindwtr-model-project-status->list "active") "projects"))
  (should (string= (mindwtr-model-project-status->list "waiting") "projects"))
  (should (string= (mindwtr-model-project-status->list "someday") "someday-projects"))
  (should (null (mindwtr-model-project-status->list "archived"))))

(ert-deftest mindwtr-model-keyword->status-safe-returns-nil-on-mismatch ()
  ;; valid combos resolve like the erroring form
  (should (string= (mindwtr-model-keyword->status-safe 'task "NEXT") "next"))
  (should (string= (mindwtr-model-keyword->status-safe 'project "ACTIVE") "active"))
  ;; type-invalid combos return nil instead of erroring
  (should (null (mindwtr-model-keyword->status-safe 'project "NEXT")))
  (should (null (mindwtr-model-keyword->status-safe 'task "ACTIVE"))))

(ert-deftest mindwtr-model-entity-title-resolves-title-or-name ()
  "task/project/section resolve via :title; area via :name; neither -> nil."
  (should (string= (mindwtr-model-entity-title '(:id "t1" :title "A task")) "A task"))
  (should (string= (mindwtr-model-entity-title '(:id "p1" :title "A project")) "A project"))
  (should (string= (mindwtr-model-entity-title '(:id "s1" :title "A section")) "A section"))
  (should (string= (mindwtr-model-entity-title '(:id "a1" :name "An area")) "An area"))
  (should (null (mindwtr-model-entity-title '(:id "x1")))))

(ert-deftest mindwtr-model-status-choices-are-type-scoped-with-fast-keys ()
  (let ((task (mindwtr-model-status-choices 'task))
        (proj (mindwtr-model-status-choices 'project)))
    ;; tasks expose i/n/w/s/r + d/x, never ACTIVE
    (should (equal task '(("INBOX" . ?i) ("NEXT" . ?n) ("WAIT" . ?w)
                          ("SOMEDAY" . ?s) ("REF" . ?r) ("DONE" . ?d) ("ARCH" . ?x))))
    ;; projects expose a/s/w + x, never INBOX/NEXT/REF/DONE
    (should (equal proj '(("ACTIVE" . ?a) ("SOMEDAY" . ?s) ("WAIT" . ?w) ("ARCH" . ?x))))
    (should-not (assoc "ACTIVE" task))
    (should-not (assoc "NEXT" proj))))

(ert-deftest mindwtr-model-notes-field-person-is-note ()
  "Person's inline body-prose field is `:note' (KTD4)."
  (should (eq (mindwtr-model-notes-field 'person) :note))
  ;; area still has none
  (should (null (mindwtr-model-notes-field 'area))))

(ert-deftest mindwtr-model-content-fields-include-person-fields ()
  "`:note' and `:referenceLink' are signed content fields (KTD4)."
  (should (memq :note mindwtr-model-content-fields))
  (should (memq :referenceLink mindwtr-model-content-fields)))

(ert-deftest mindwtr-model-validate-appdata-accepts-people ()
  "A people list with id-bearing persons validates."
  (should (mindwtr-model-validate-appdata
           '(:tasks nil :projects nil :sections nil :areas nil
             :people ((:id "pe1" :name "Alex" :note "notes" :rev 1))
             :settings nil))))

(ert-deftest mindwtr-model-validate-appdata-rejects-person-without-id ()
  "A person missing :id is rejected."
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks nil :projects nil :sections nil :areas nil
      :people ((:name "Alex")) :settings nil))))
