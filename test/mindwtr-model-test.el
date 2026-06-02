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
  ;; settings is intentionally excluded (verbatim passthrough)
  (should-not (assq 'settings mindwtr-model-known-fields))
  ;; representative keys transcribed from Mindwtr core types.ts
  (let ((task (cdr (assq 'task mindwtr-model-known-fields)))
        (proj (cdr (assq 'project mindwtr-model-known-fields)))
        (sec  (cdr (assq 'section mindwtr-model-known-fields)))
        (area (cdr (assq 'area mindwtr-model-known-fields))))
    (dolist (k '(:id :title :status :checklist :attachments :recurrence
                 :completedAt :purgedAt :deletedAt :rev :revBy))
      (should (memq k task)))
    (dolist (k '(:sequentialScope :supportNotes :attachments :dueDate :reviewAt
                 :isSequential :isFocused :areaTitle))
      (should (memq k proj)))
    (dolist (k '(:description :isCollapsed :deletedAtBeforeProjectArchive
                 :projectArchivedAt))
      (should (memq k sec)))
    (should (memq :icon area)))
  ;; every content field that applies to tasks is a known task key
  (dolist (k mindwtr-model-content-fields)
    (unless (eq k :name)                ; :name is an area field, not a task field
      (should (memq k (cdr (assq 'task mindwtr-model-known-fields)))))))

(ert-deftest mindwtr-model-list-roles-and-titles ()
  (should (equal mindwtr-model-list-roles
                 '("inbox" "next-actions" "waiting" "someday" "reference" "projects" "areas")))
  (should (string= (mindwtr-model-list-title "next-actions") "Next Actions"))
  (should (string= (mindwtr-model-list-title "areas") "Areas of Focus")))

(ert-deftest mindwtr-model-status->list-maps-standalone-statuses ()
  (should (string= (mindwtr-model-status->list "inbox") "inbox"))
  (should (string= (mindwtr-model-status->list "next") "next-actions"))
  (should (string= (mindwtr-model-status->list "done") "next-actions"))
  (should (string= (mindwtr-model-status->list "waiting") "waiting"))
  (should (string= (mindwtr-model-status->list "someday") "someday"))
  (should (string= (mindwtr-model-status->list "reference") "reference"))
  ;; archived has no list -> not rendered
  (should (null (mindwtr-model-status->list "archived"))))
