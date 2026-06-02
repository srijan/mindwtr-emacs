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

;;; mindwtr-commands-test.el ends here
