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
                     '((:title "sub a" :isCompleted :false)
                       (:title "sub b" :isCompleted t)))))))

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

(ert-deftest mindwtr-parse-recovers-keywords-when-global-config-defines-next ()
  "Regression: a user whose personal `org-todo-keywords' defines NEXT but
not the rest of the Mindwtr sequence must still parse a SOMEDAY heading to
status \"someday\".  The old guard trusted the presence of NEXT alone, so it
skipped installing the keywords; SOMEDAY then went unrecognised, leaking
into the title and yielding a nil status that aborted the whole sync."
  (with-temp-buffer
    (let ((org-todo-keywords '((sequence "TODO" "NEXT" "WAIT" "|" "DONE")))
          (org-inhibit-startup t))
      (org-mode)
      ;; The false-positive trap: NEXT is registered, SOMEDAY is not.
      (should (member "NEXT" org-todo-keywords-1))
      (should-not (member "SOMEDAY" org-todo-keywords-1))
      (insert "* SOMEDAY Try out annotate in place :@computer:\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (let ((e (mindwtr-parse-heading)))
        (should (string= (plist-get e :status) "someday"))
        (should (string= (plist-get e :title) "Try out annotate in place"))))))

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

(ert-deftest mindwtr-parse-area-from-property ()
  "areaId comes from :MW_AREA: resolved against Areas-of-Focus headings,
not from an ancestor area heading; project/section come from ancestry."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:MW_AREA: Personal\n:END:\n"
              "*** NEXT child\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT loose\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:MW_AREA: Personal\n:END:\n"
              "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
              "** Personal\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (proj (car (plist-get ad :projects)))
           (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get ad :tasks)))
           (t2 (seq-find (lambda (e) (equal (plist-get e :id) "t2")) (plist-get ad :tasks))))
      ;; project's area from its MW_AREA property
      (should (string= (plist-get proj :areaId) "a1"))
      ;; nested task: projectId from ancestry, NO areaId (no MW_AREA)
      (should (string= (plist-get t1 :projectId) "p1"))
      (should-not (plist-get t1 :areaId))
      ;; loose task: areaId from MW_AREA, no project
      (should (string= (plist-get t2 :areaId) "a1"))
      (should-not (plist-get t2 :projectId))
      ;; containers are not entities
      (should (= (length (plist-get ad :areas)) 1)))))

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
:MW_AREA: Work
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
        ;; A task stores ONLY its nearest container (section here).  The
        ;; project and area are derived structurally on render, never
        ;; stamped onto the task -- mirroring the server's single
        ;; container-id-per-task model.
        (should (string= (plist-get task :sectionId) "s1"))
        (should (null (plist-get task :projectId)))
        (should (null (plist-get task :areaId)))
        ;; mw internal keys stripped from output entities:
        (should (null (plist-member task :mw-kind)))))))

(ert-deftest mindwtr-parse-task-in-project-has-no-derived-area ()
  "A task in a project carries :projectId only, never a derived :areaId.
Regression for the live-data drift where the parser stamped both, which
would corrupt containment on write (the server stores projectId alone)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Personal
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
** ACTIVE Some Project
:PROPERTIES:
:MW_TYPE: project
:MW_ID: p1
:END:
*** NEXT Do thing
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
")
      (org-mode)
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get task :projectId) "p1"))
        (should (null (plist-get task :areaId)))
        (should (null (plist-get task :sectionId)))))))

(ert-deftest mindwtr-parse-task-directly-in-area-keeps-area ()
  "A loose task keeps :areaId from its :MW_AREA: property."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Personal
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
** NEXT Loose task
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:MW_AREA: Personal
:END:
")
      (org-mode)
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get task :areaId) "a1"))
        (should (null (plist-get task :projectId)))))))

(ert-deftest mindwtr-parse-type-invalid-keyword-omits-status-not-errors ()
  "A project carrying a task-only keyword (NEXT) must not error or leak the
keyword into the title; it parses with no :status and warns."
  (mindwtr-parse-test--with
      (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** NEXT Build the deck\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
    ;; jump to the project heading (second heading)
    (org-next-visible-heading 1)
    (let ((e (mindwtr-parse-heading)))
      (should (string= (plist-get e :title) "Build the deck"))
      (should (null (plist-get e :status))))))

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

(ert-deftest mindwtr-parse-buffer-accumulates-invalid-keyword-warnings ()
  "A type-invalid keyword is recorded in `mindwtr-parse-warnings'."
  (mindwtr-parse-test--with
      (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** NEXT Build the deck\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
    (mindwtr-parse-buffer)
    (let ((ws (mindwtr-parse-warnings)))
      (should (= (length ws) 1))
      (let ((w (car ws)))
        (should (string= (plist-get w :id) "p1"))
        (should (string= (plist-get w :title) "Build the deck"))
        (should (string= (plist-get w :keyword) "NEXT"))
        (should (eq (plist-get w :kind) 'project))))))

(ert-deftest mindwtr-parse-buffer-clean-has-no-warnings ()
  "A valid buffer accumulates no warnings (and a fresh parse resets them)."
  (mindwtr-parse-test--with
      (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Build the deck\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
    (mindwtr-parse-buffer)
    (should (null (mindwtr-parse-warnings)))))

;;; MW_TYPE inference from outline context (U1) ------------------------------

(ert-deftest mindwtr-parse-infers-task-under-inbox ()
  "A heading lacking MW_TYPE under the Inbox container is parsed as a task.
Captures the org-capture-inbox case: an INBOX heading with only an org :ID:."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Test new issue from emacs\n"
              ":PROPERTIES:\n:ID:       56E8C571-D8CA-47CB-B699-07A195EA4193\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (task (car (plist-get ad :tasks))))
      ;; Placement in :tasks is the kind signal -- `mindwtr-parse-buffer'
      ;; strips the internal :mw-kind from its output.
      (should (= (length (plist-get ad :tasks)) 1))
      (should (string= (plist-get task :title) "Test new issue from emacs"))
      (should (string= (plist-get task :status) "inbox"))
      ;; No MW_ID yet -- the sync engine mints one (R5).
      (should (null (plist-get task :id))))))

(ert-deftest mindwtr-parse-infers-project-directly-under-projects ()
  "A heading lacking MW_TYPE directly under the Projects container is a project."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Launch the thing\n:PROPERTIES:\n:ID: abc\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (proj (car (plist-get ad :projects))))
      (should (= (length (plist-get ad :projects)) 1))
      (should (string= (plist-get proj :title) "Launch the thing"))
      (should (string= (plist-get proj :status) "active"))
      (should (null (plist-get ad :tasks))))))

(ert-deftest mindwtr-parse-infers-task-under-typed-project ()
  "A heading lacking MW_TYPE under a typed project is a task, not a project."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Big Project\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "*** NEXT Do the thing\n:PROPERTIES:\n:ID: def\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (task (car (plist-get ad :tasks))))
      (should (= (length (plist-get ad :tasks)) 1))
      (should (string= (plist-get task :projectId) "p1"))
      (should (string= (plist-get task :status) "next")))))

(ert-deftest mindwtr-parse-infers-task-under-section ()
  "A heading lacking MW_TYPE under a section is a task with that sectionId."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Big Project\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "*** Planning\n:PROPERTIES:\n:MW_TYPE: section\n:MW_ID: s1\n:END:\n"
              "**** NEXT Sketch it\n:PROPERTIES:\n:ID: ghi\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (task (car (plist-get ad :tasks))))
      (should (= (length (plist-get ad :tasks)) 1))
      (should (string= (plist-get task :sectionId) "s1"))
      (should (null (plist-get task :projectId))))))

(ert-deftest mindwtr-parse-infers-area-under-areas ()
  "A heading lacking MW_TYPE under Areas of Focus is an area."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
              "** Health\n:PROPERTIES:\n:ID: jkl\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (area (car (plist-get ad :areas))))
      (should (= (length (plist-get ad :areas)) 1))
      (should (string= (plist-get area :name) "Health")))))

(ert-deftest mindwtr-parse-inferred-heading-keeps-org-id-as-extra-prop ()
  "An adopted heading's org :ID: is preserved as an unknown property, not as
the entity id (R5: MW_ID stays the sync identity)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Captured\n:PROPERTIES:\n:ID: 56E8C571\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (task (car (plist-get ad :tasks))))
      (should (null (plist-get task :id)))
      (should (string= (plist-get (plist-get task :mw-extra-props) "ID" #'equal)
                       "56E8C571")))))

(ert-deftest mindwtr-parse-infer-kind-nil-without-container-context ()
  "A heading with no recognized container ancestor cannot be inferred -- it is
left unparsed so the quarantine guard (U2) can preserve it."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Some random note\n:PROPERTIES:\n:ID: xyz\n:END:\nbody text\n")
      (org-mode)
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (should (null (mindwtr-parse--infer-kind))))
    (should (null (plist-get (mindwtr-parse-buffer) :tasks)))))

(ert-deftest mindwtr-parse-blank-mw-type-treated-as-absent ()
  "A heading with a blank :MW_TYPE: value (a raw edit that left it empty) is
treated as untyped -- inferred from context, not interned to the empty symbol
and silently dropped."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Half-typed\n:PROPERTIES:\n:MW_TYPE:\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (task (car (plist-get ad :tasks))))
      (should (= (length (plist-get ad :tasks)) 1))
      (should (string= (plist-get task :title) "Half-typed"))
      (should (string= (plist-get task :status) "inbox"))
      (should (string= (plist-get task :id) "t1")))))

(ert-deftest mindwtr-parse-infer-kind-covers-every-entity-role ()
  "Drift guard: every container role that holds ENTITIES must infer a kind, so
adding a render-layer role without teaching `mindwtr-parse--infer-kind' fails
loudly here instead of silently quarantining everything under the new bucket.
Exceptions: `someday' (a parent whose children are themselves containers) infers
nil, and the reconcile quarantine role `sync-failures' (not a model list-role)
must stay un-inferable so its children keep round-tripping through quarantine."
  (let ((parent-only '("someday")))
    (dolist (role (append mindwtr-model-list-roles '("sync-failures")))
      (with-temp-buffer
        (let ((org-inhibit-startup t))
          (insert (format "* C\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: %s\n:END:\n"
                          role)
                  "** H\n:PROPERTIES:\n:ID: x\n:END:\n")
          (org-mode)
          (goto-char (point-min))
          (org-next-visible-heading 1)   ; container
          (org-next-visible-heading 1)   ; child H
          (if (or (member role parent-only) (string= role "sync-failures"))
              (should (null (mindwtr-parse--infer-kind)))
            (should (mindwtr-parse--infer-kind))))))))

(ert-deftest mindwtr-parse-explicit-mw-type-not-overridden-by-inference ()
  "Inference is a pure fallback: an explicit MW_TYPE always wins, even when the
context would imply a different kind."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      ;; A section explicitly typed, sitting under Inbox (which would infer task).
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** Weird\n:PROPERTIES:\n:MW_TYPE: section\n:MW_ID: s9\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (sec (car (plist-get ad :sections))))
      ;; Placement in :sections (not :tasks) proves the explicit MW_TYPE won.
      (should (= (length (plist-get ad :sections)) 1))
      (should (string= (plist-get sec :title) "Weird"))
      (should (null (plist-get ad :tasks))))))
