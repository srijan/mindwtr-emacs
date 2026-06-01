;;; mindwtr-parse-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'mindwtr-parse)

(defmacro mindwtr-parse-test--with (text &rest body)
  "Insert TEXT in an org buffer, move to first heading, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       (org-next-visible-heading 1)
       ,@body)))

(ert-deftest mindwtr-parse-task-basic ()
  (mindwtr-parse-test--with
      "* WORKAREA
:PROPERTIES:
:MW_TYPE: area
:MW_ID: area-1
:END:
** NEXT [#B] Buy milk :@errands:focused:
SCHEDULED: <2026-02-09 Mon>
DEADLINE: <2026-02-15 Sun>
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:MW_ENERGY: medium
:END:
Some notes.
- [ ] sub a
- [X] sub b
"
    (org-next-visible-heading 1) ; move to the task
    (let ((e (mindwtr-parse-heading)))
      (should (string= (plist-get e :id) "t1"))
      (should (eq (plist-get e :mw-kind) 'task))
      (should (string= (plist-get e :title) "Buy milk"))
      (should (string= (plist-get e :status) "next"))
      (should (string= (plist-get e :priority) "high"))
      (should (equal (plist-get e :contexts) '("@errands")))
      (should (equal (plist-get e :tags) '("#focused")))
      (should (string= (plist-get e :energyLevel) "medium"))
      (should (string-match-p "2026-02-09" (plist-get e :startTime)))
      (should (string-match-p "2026-02-15" (plist-get e :dueDate)))
      (should (string= (plist-get e :description) "Some notes."))
      (should (equal (plist-get e :checklist)
                     '((:title "sub a" :done :false)
                       (:title "sub b" :done t)))))))

(ert-deftest mindwtr-parse-area-has-no-keyword ()
  (mindwtr-parse-test--with
      "* My Area
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
"
    (let ((e (mindwtr-parse-heading)))
      (should (eq (plist-get e :mw-kind) 'area))
      (should (string= (plist-get e :name) "My Area"))
      (should (null (plist-get e :status))))))

(ert-deftest mindwtr-parse-preserves-unknown-properties ()
  (mindwtr-parse-test--with
      "* NEXT Task :@x:
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t9
:CUSTOM_KEY: keepme
:END:
"
    (let ((e (mindwtr-parse-heading)))
      ;; `:mw-extra-props' is a string-keyed plist; `plist-get' must be
      ;; told to compare keys with `equal' (its default `eq' never
      ;; matches distinct string objects).
      (should (string= (plist-get (plist-get e :mw-extra-props)
                                  "CUSTOM_KEY" #'equal)
                       "keepme")))))

(ert-deftest mindwtr-parse-buffer-containment ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
** ACTIVE Big Project
:PROPERTIES:
:MW_TYPE: project
:MW_ID: p1
:END:
*** Planning
:PROPERTIES:
:MW_TYPE: section
:MW_ID: s1
:END:
**** NEXT Do thing :@x:
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
")
      (org-mode)
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks)))
             (proj (car (plist-get ad :projects)))
             (sec  (car (plist-get ad :sections))))
        (should (= (length (plist-get ad :areas)) 1))
        (should (string= (plist-get proj :areaId) "a1"))
        (should (string= (plist-get sec :projectId) "p1"))
        (should (string= (plist-get task :projectId) "p1"))
        (should (string= (plist-get task :sectionId) "s1"))
        (should (string= (plist-get task :areaId) "a1"))
        ;; mw internal keys stripped from output entities:
        (should (null (plist-member task :mw-kind)))))))

(ert-deftest mindwtr-parse-buffer-skips-inbox-container ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox
:PROPERTIES:
:MW_TYPE: container
:END:
** INBOX capture this
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
")
      (org-mode)
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks))))
        (should (= (length (plist-get ad :tasks)) 1))
        (should (null (plist-get task :projectId)))
        (should (null (plist-get task :areaId)))))))
