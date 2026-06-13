;;; mindwtr-commands-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'mindwtr-commands)
(require 'mindwtr-render)

(defmacro mindwtr-commands-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     ,@body))

(ert-deftest mindwtr-commands-kind-at-point-reads-mw-type ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next"))
        :settings nil)
    (re-search-forward "Loose")
    (should (eq (mindwtr-commands--kind-at-point) 'task))
    ;; "Proj" alone also matches the "* Projects" container heading; target
    ;; the project entity heading unambiguously via its TODO keyword.
    (re-search-forward "ACTIVE Proj")
    (should (eq (mindwtr-commands--kind-at-point) 'project))
    (goto-char (point-min))
    (re-search-forward "^\\* Inbox$")
    (should (eq (mindwtr-commands--kind-at-point) 'container))))

(ert-deftest mindwtr-commands-set-status-applies-chosen-keyword ()
  "set-status applies the keyword returned by the (stubbed) reader."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next")) :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'mindwtr-commands--read-keyword)
               (lambda (&rest _) "WAIT")))
      (mindwtr-set-status))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "Loose")
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "WAIT")))))

(defun mindwtr-commands-test--parent-list-of (title)
  "Return the MW_LIST role of the container the heading named TITLE sits under."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (regexp-quote title))
    (mindwtr-commands--parent-list-role)))

(ert-deftest mindwtr-commands-relocates-standalone-task-by-status ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Move me" :status "next")) :settings nil)
    ;; starts under single-actions
    (should (string= (mindwtr-commands-test--parent-list-of "Move me") "single-actions"))
    ;; next -> someday relocates to someday-single-actions
    (goto-char (point-min)) (re-search-forward "Move me") (org-back-to-heading t)
    (org-todo "SOMEDAY")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Move me")
                     "someday-single-actions"))
    ;; someday -> reference relocates to reference
    (goto-char (point-min)) (re-search-forward "Move me") (org-back-to-heading t)
    (org-todo "REF")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Move me") "reference"))))

(ert-deftest mindwtr-commands-relocates-project-subtree-with-children ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Child task" :status "next" :projectId "p1"))
        :settings nil)
    (should (string= (mindwtr-commands-test--parent-list-of "MyProj") "projects"))
    (goto-char (point-min)) (re-search-forward "MyProj") (org-back-to-heading t)
    (org-todo "SOMEDAY")
    (mindwtr-commands--relocate 'project)
    ;; project moved under someday-projects, child carried along (still its task)
    (should (string= (mindwtr-commands-test--parent-list-of "MyProj") "someday-projects"))
    (should (string= (mindwtr-commands-test--parent-list-of "Child task") "someday-projects"))
    ;; re-parse confirms the child still belongs to the project
    (let* ((ad (mindwtr-parse-buffer))
           (child (car (plist-get ad :tasks))))
      (should (string= (plist-get child :projectId) "p1")))))

(ert-deftest mindwtr-commands-project-task-does-not-relocate ()
  "A status change on a task inside a project leaves it nested under the project."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Inside" :status "next" :projectId "p1"))
        :settings nil)
    (goto-char (point-min)) (re-search-forward "Inside") (org-back-to-heading t)
    (org-todo "WAIT")
    (mindwtr-commands--relocate 'task)
    (let* ((ad (mindwtr-parse-buffer))
           (child (car (plist-get ad :tasks))))
      (should (string= (plist-get child :projectId) "p1")))))

(ert-deftest mindwtr-commands-archived-task-stays-in-place ()
  "Archiving a standalone task does not move it (archived has no bucket)."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Bye" :status "next")) :settings nil)
    (goto-char (point-min)) (re-search-forward "Bye") (org-back-to-heading t)
    (org-todo "ARCH")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Bye") "single-actions"))))

(ert-deftest mindwtr-commands-cycle-task-skips-active ()
  "Forward-cycling a task walks only task keywords (never ACTIVE) and relocates."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Cyc" :status "inbox")) :settings nil)
    (goto-char (point-min)) (re-search-forward "Cyc") (org-back-to-heading t)
    ;; inbox -> next (first forward step from INBOX)
    (mindwtr-cycle-status-forward)
    (save-excursion (goto-char (point-min)) (re-search-forward "Cyc") (org-back-to-heading t)
      (should (string= (org-get-todo-state) "NEXT")))
    (should (string= (mindwtr-commands-test--parent-list-of "Cyc") "single-actions"))))

(ert-deftest mindwtr-commands-cycle-project-only-project-keywords ()
  "Cycling a project never lands on a task-only keyword."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "PCyc" :status "active")) :sections nil
        :tasks nil :settings nil)
    (let ((valid '("ACTIVE" "SOMEDAY" "WAIT" "ARCH")))
      (dotimes (_ 6)
        (goto-char (point-min)) (re-search-forward "PCyc") (org-back-to-heading t)
        (mindwtr-cycle-status-forward)
        (goto-char (point-min)) (re-search-forward "PCyc") (org-back-to-heading t)
        (should (member (org-get-todo-state) valid))))))

(defun mindwtr-commands-test--task-by-id (id)
  "Parse the buffer and return the task entity with :id ID."
  (seq-find (lambda (tk) (string= (plist-get tk :id) id))
            (plist-get (mindwtr-parse-buffer) :tasks)))

(ert-deftest mindwtr-commands-set-area-on-standalone-task ()
  "On a standalone task, choosing an area writes MW_AREA and parse resolves :areaId."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0)
                (:id "a2" :name "Work" :order 1))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next")) :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Work")))
      (mindwtr-set-area))
    (save-excursion
      (goto-char (point-min)) (re-search-forward "Loose") (org-back-to-heading t)
      (should (string= (org-entry-get nil "MW_AREA") "Work")))
    (should (string= (plist-get (mindwtr-commands-test--task-by-id "t1") :areaId) "a2"))))

(ert-deftest mindwtr-commands-set-area-on-project ()
  "On a project heading, the command sets the area likewise."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil :tasks nil :settings nil)
    (re-search-forward "ACTIVE Proj")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Personal")))
      (mindwtr-set-area))
    (save-excursion
      (goto-char (point-min)) (re-search-forward "ACTIVE Proj") (org-back-to-heading t)
      (should (string= (org-entry-get nil "MW_AREA") "Personal")))))

(ert-deftest mindwtr-commands-set-area-refuses-task-under-project ()
  "On a task under a project, the command refuses: no MW_AREA written, and parse
yields :projectId with NO :areaId (guards the dual-container over-stamp)."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Child" :status "next" :projectId "p1"))
        :settings nil)
    (re-search-forward "Child")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt for a task under a project"))))
      (mindwtr-set-area))
    (save-excursion
      (goto-char (point-min)) (re-search-forward "Child") (org-back-to-heading t)
      (should-not (org-entry-get nil "MW_AREA")))
    (let ((task (mindwtr-commands-test--task-by-id "t1")))
      (should (string= (plist-get task :projectId) "p1"))
      (should-not (plist-get task :areaId)))))

(ert-deftest mindwtr-commands-set-area-noop-off-entity ()
  "Off a non-task/project heading (a container), the command no-ops -- it does
not prompt and writes no MW_AREA."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects nil :sections nil :tasks nil :settings nil)
    (goto-char (point-min))
    (re-search-forward "^\\* Inbox$")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt off an entity"))))
      (mindwtr-set-area))
    (org-back-to-heading t)
    (should-not (org-entry-get nil "MW_AREA"))))

(ert-deftest mindwtr-commands-set-area-offers-exactly-area-names ()
  "Completion offers exactly the buffer's existing area names."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0)
                (:id "a2" :name "Work" :order 1))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next")) :settings nil)
    (re-search-forward "Loose")
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt coll &rest _) (setq offered coll) "Personal")))
        (mindwtr-set-area))
      (should (equal (sort (copy-sequence offered) #'string<) '("Personal" "Work"))))))

(ert-deftest mindwtr-commands-set-area-replaces-existing-no-duplicate ()
  "Changing an already-set area replaces the MW_AREA value (no duplicate property)."
  (mindwtr-commands-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0)
                (:id "a2" :name "Work" :order 1))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next" :areaId "a1")) :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Work")))
      (mindwtr-set-area))
    (goto-char (point-min)) (re-search-forward "Loose") (org-back-to-heading t)
    (should (string= (org-entry-get nil "MW_AREA") "Work"))
    (let ((end (save-excursion (outline-next-heading) (point))) (count 0))
      (save-excursion
        (while (re-search-forward "^:MW_AREA:" end t) (setq count (1+ count))))
      (should (= count 1)))))

(ert-deftest mindwtr-commands-promote-task-with-children-to-project ()
  "Promoting a sketched inbox item mirrors the app: a NEW project entity is
created (fresh id) and the task KEEPS its MW_ID, becoming a NEXT action
under it; keyword-less children stamped NEXT, existing keywords preserved;
no next-action retitle prompt when children exist."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Plan party\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "*** Book venue\n"
              "*** WAIT Invite people\n"
              "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Plan party"))
    (let ((prompts 0))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &optional init &rest _)
                   (setq prompts (1+ prompts))
                   (or init ""))))
        (mindwtr-promote-to-project))
      ;; only the project-title prompt; children suppress the retitle prompt
      (should (= prompts 1)))
    ;; the task kept its id and became a NEXT action inside the project
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "NEXT Plan party"))
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "MW_ID") "t1"))
      (should (string= (org-entry-get nil "MW_TYPE") "task")))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Book venue"))
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "NEXT")))
    ;; parse: one fresh-id active project; the original task (id kept) and
    ;; both children bound to it via :projectId
    (let* ((ad (mindwtr-parse-buffer))
           (projects (plist-get ad :projects))
           (proj (car projects))
           (tasks (plist-get ad :tasks))
           (orig (seq-find (lambda (tk) (equal (plist-get tk :id) "t1")) tasks)))
      (should (= (length projects) 1))
      (should (string= (plist-get proj :title) "Plan party"))
      (should (string= (plist-get proj :status) "active"))
      (should (plist-get proj :id))
      (should-not (string= (plist-get proj :id) "t1"))
      (should (= (length tasks) 3))
      (should orig)
      (should (string= (plist-get orig :status) "next"))
      (should (equal (sort (mapcar (lambda (tk) (plist-get tk :status)) tasks)
                     #'string<)
                     '("next" "next" "waiting")))
      (dolist (tk tasks)
        (should (string= (plist-get tk :projectId) (plist-get proj :id)))))))

(ert-deftest mindwtr-commands-promote-childless-task-prompts-next-action ()
  "A childless promote prompts for the next action (the app requires one)
and retitles the task with it; the project takes the typed title."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Throw a party" :status "inbox"))
        :settings nil)
    (re-search-forward "Throw a party")
    (let ((answers '("Party project" "Book venue")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (pop answers))))
        (mindwtr-promote-to-project)))
    (let* ((ad (mindwtr-parse-buffer))
           (proj (car (plist-get ad :projects)))
           (task (car (plist-get ad :tasks))))
      (should (string= (plist-get proj :title) "Party project"))
      (should (string= (plist-get task :title) "Book venue"))
      (should (string= (plist-get task :id) "t1"))
      (should (string= (plist-get task :status) "next"))
      (should (string= (plist-get task :projectId) (plist-get proj :id))))))

(ert-deftest mindwtr-commands-promote-reuses-same-titled-project ()
  "When a project with the typed title already exists (case-insensitive),
the task moves under it instead of creating a duplicate -- app behavior."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Do thing" :status "inbox"))
        :settings nil)
    (re-search-forward "Do thing")
    (let ((answers '("myproj" "Do thing")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (pop answers))))
        (mindwtr-promote-to-project)))
    (let* ((ad (mindwtr-parse-buffer))
           (projects (plist-get ad :projects))
           (task (car (plist-get ad :tasks))))
      (should (= (length projects) 1))
      (should (string= (plist-get (car projects) :id) "p1"))
      (should (string= (plist-get task :projectId) "p1"))
      (should (string= (plist-get task :status) "next")))))

(ert-deftest mindwtr-commands-promote-refuses-project ()
  "Promote refuses on a project heading."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil :tasks nil :settings nil)
    (re-search-forward "ACTIVE Proj")
    (should-error (mindwtr-promote-to-project) :type 'user-error)))

(ert-deftest mindwtr-commands-promote-refuses-task-in-project ()
  "Promote refuses on a task that already belongs to a project."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Child" :status "next" :projectId "p1"))
        :settings nil)
    (re-search-forward "Child")
    (should-error (mindwtr-promote-to-project) :type 'user-error)))

(ert-deftest mindwtr-commands-promote-without-projects-container-leaves-task-untouched ()
  "Promote errors out BEFORE mutating when there is no `* Projects'
container and no same-titled project: no NEXT stamp on the task, no
keyword stamping on its children."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Plan party\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "*** Book venue\n")
      (org-mode))
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Plan party"))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional init &rest _) (or init ""))))
      (should-error (mindwtr-promote-to-project) :type 'user-error))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Plan party"))
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "INBOX")))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Book venue"))
      (org-back-to-heading t)
      (should-not (org-get-todo-state)))))

(ert-deftest mindwtr-commands-set-context-sets-tags-preserves-hashtags ()
  "Chosen contexts (with `@' added when missing) replace the @-tags; hashtag
tags stay; parse yields the new :contexts and the untouched :tags."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next"
                 :contexts ("@office") :tags ("#shop")))
        :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("@home" "work"))))
      (mindwtr-set-context))
    (let ((task (mindwtr-commands-test--task-by-id "t1")))
      (should (equal (plist-get task :contexts) '("@home" "@work")))
      (should (equal (plist-get task :tags) '("#shop"))))))

(ert-deftest mindwtr-commands-set-context-offers-buffer-contexts-prefills-current ()
  "Completion candidates cover the buffer's @contexts (not hashtags); the
initial input prefills the task's current contexts."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next" :contexts ("@office"))
                (:id "t2" :title "Other" :status "next"
                 :contexts ("@home") :tags ("#shop")))
        :settings nil)
    (re-search-forward "Loose")
    (let (offered initial)
      (cl-letf (((symbol-function 'completing-read-multiple)
                 (lambda (_prompt coll _pred _req init &rest _)
                   (setq offered coll initial init)
                   '("@office"))))
        (mindwtr-set-context))
      (should (member "@home" offered))
      (should (member "@office" offered))
      (should-not (member "shop" offered))
      (should (equal initial "@office")))))

(ert-deftest mindwtr-commands-set-context-empty-input-clears ()
  "An empty selection clears the contexts but keeps hashtag tags."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next"
                 :contexts ("@office") :tags ("#shop")))
        :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '())))
      (mindwtr-set-context))
    (let ((task (mindwtr-commands-test--task-by-id "t1")))
      (should-not (plist-get task :contexts))
      (should (equal (plist-get task :tags) '("#shop"))))))

(ert-deftest mindwtr-commands-set-context-noop-off-task ()
  "On a project heading the command no-ops without prompting."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil :tasks nil :settings nil)
    (re-search-forward "ACTIVE Proj")
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (error "should not prompt off a task"))))
      (mindwtr-set-context))))

(ert-deftest mindwtr-commands-set-context-rejects-org-unsafe-input ()
  "A typed context org tags cannot hold is a user-error, not a silent drop."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next")) :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("@home office"))))
      (should-error (mindwtr-set-context) :type 'user-error))))

(ert-deftest mindwtr-commands-set-context-refuses-unsafe-mw-contexts ()
  "A task whose MW_CONTEXTS holds org-unsafe values is refused untouched."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Exotic\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
              ":MW_CONTEXTS: [\"@home office\"]\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Exotic"))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) (error "should not prompt on unsafe MW_CONTEXTS"))))
      (mindwtr-set-context))
    (org-back-to-heading t)
    (should (org-entry-get nil "MW_CONTEXTS"))))

(ert-deftest mindwtr-commands-set-context-lifts-safe-mw-contexts ()
  "A representable MW_CONTEXTS prefills the prompt, lands on the native tag
line, and the drawer key is removed (the edit is authoritative)."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Deep\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
              ":MW_CONTEXTS: [\"@deep\"]\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Deep"))
    (let (initial)
      (cl-letf (((symbol-function 'completing-read-multiple)
                 (lambda (_prompt _coll _pred _req init &rest _)
                   (setq initial init)
                   '("@deep" "@work"))))
        (mindwtr-set-context))
      (should (equal initial "@deep")))
    (org-back-to-heading t)
    (should-not (org-entry-get nil "MW_CONTEXTS"))
    (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
      (should (equal (plist-get task :contexts) '("@deep" "@work"))))))

(defun mindwtr-commands-test--id-count (id)
  "Number of headings carrying MW_ID ID in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0) (re (format "^[ \t]*:MW_ID:[ \t]*%s[ \t]*$" (regexp-quote id))))
      (while (re-search-forward re nil t) (cl-incf n))
      n)))

(ert-deftest mindwtr-commands-relocate-does-not-duplicate-on-consecutive-kills ()
  "Relocating several tasks in a row must not duplicate earlier ones.
Regression: `org-cut-subtree' appends to the kill-ring head when `last-command'
is `kill-region' (as the interactive command loop leaves it after a prior
relocation), and `org-paste-subtree' with no explicit tree pastes that growing
blob -- so each move re-inserts every previously-moved task (the staircase seen
in heavy clarify sessions)."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Alpha" :status "next")
                (:id "t2" :title "Bravo" :status "next")
                (:id "t3" :title "Charlie" :status "next"))
        :settings nil)
    (dolist (id '("t1" "t2" "t3"))
      ;; Simulate the command loop leaving `kill-region' as `last-command'
      ;; after the previous relocation's cut.
      (setq last-command 'kill-region)
      (goto-char (point-min))
      (re-search-forward (format ":MW_ID: %s$" id))
      (org-back-to-heading t)
      (org-todo "SOMEDAY")
      (mindwtr-commands--relocate 'task))
    (should (= (mindwtr-commands-test--id-count "t1") 1))
    (should (= (mindwtr-commands-test--id-count "t2") 1))
    (should (= (mindwtr-commands-test--id-count "t3") 1))))

;;; mindwtr-commands-test.el ends here
