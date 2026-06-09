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

(ert-deftest mindwtr-commands-promote-task-to-project ()
  "Promoting an inbox task converts it to an ACTIVE project under * Projects:
a FRESH MW_ID replaces the task's (so children infer as its tasks and the old
task id is tombstoned at sync), MW_TYPE project, keyword-less children
stamped NEXT, existing child keywords preserved."
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
    (mindwtr-promote-to-project)
    (should (string= (mindwtr-commands-test--parent-list-of "Plan party") "projects"))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Plan party"))
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "MW_TYPE") "project"))
      ;; fresh id, not the old task's
      (let ((id (org-entry-get nil "MW_ID")))
        (should id)
        (should-not (string= id "t1")))
      (should (string= (org-get-todo-state) "ACTIVE")))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Book venue"))
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "NEXT")))
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "Invite people"))
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "WAIT")))
    ;; The whole structure parses: one active project, its two child tasks
    ;; bound to it via the freshly minted project id.
    (let* ((ad (mindwtr-parse-buffer))
           (projects (plist-get ad :projects))
           (proj (car projects))
           (tasks (plist-get ad :tasks))
           (statuses (sort (mapcar (lambda (tk) (plist-get tk :status)) tasks)
                           #'string<)))
      (should (= (length projects) 1))
      (should (string= (plist-get proj :title) "Plan party"))
      (should (string= (plist-get proj :status) "active"))
      (should (equal statuses '("next" "waiting")))
      (dolist (tk tasks)
        (should (string= (plist-get tk :projectId) (plist-get proj :id)))))))

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

;;; mindwtr-commands-test.el ends here
