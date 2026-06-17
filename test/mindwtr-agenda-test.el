;;; mindwtr-agenda-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'org-agenda)
(require 'mindwtr-model)
(require 'mindwtr-render)
(require 'mindwtr-agenda)

;; `mindwtr-file' is owned (defcustom'd) by mindwtr.el, which these tests do not
;; load (it pulls the full sync stack + the `plz' dependency).  Declare it special
;; with a value here so tests can dynamically `let'-bind it.
(defvar mindwtr-file nil)

;; A self-contained appdata renderer.  This mirrors
;; `mindwtr-commands-test--with-appdata' but is defined locally on purpose:
;; `make test' loads every `test/*-test.el' in alphabetical order, so this file
;; loads BEFORE mindwtr-commands-test.el -- its macro would not yet be defined
;; at this file's load time.
(defmacro mindwtr-agenda-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     ,@body))

;;; U1 -- file scoping helper ---------------------------------------------------

(ert-deftest mindwtr-agenda-files-returns-only-the-mindwtr-file ()
  "Scope is exactly the Mindwtr file; the archive path is never included (AE4)."
  (let ((mindwtr-file "/tmp/mindwtr-test.org"))
    (should (equal (mindwtr-agenda--files) '("/tmp/mindwtr-test.org")))))

(ert-deftest mindwtr-agenda-files-errors-when-file-unset ()
  "An unset `mindwtr-file' is a clear error, not a silent empty scope."
  (let ((mindwtr-file nil))
    (should-error (mindwtr-agenda--files))))

;;; U2 -- stuck-project predicate ----------------------------------------------

(defun mindwtr-agenda-test--stuck-at (title)
  "Move to the project heading named TITLE and return its stuck-p result."
  (goto-char (point-min))
  (re-search-forward (concat "ACTIVE " (regexp-quote title)))
  (mindwtr-agenda--project-stuck-p))

(ert-deftest mindwtr-agenda-project-with-next-child-is-not-stuck ()
  "An active project with a NEXT child is not stuck (AE2)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "HasNext" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Do it" :status "next" :projectId "p1"))
        :settings nil)
    (should-not (mindwtr-agenda-test--stuck-at "HasNext"))))

(ert-deftest mindwtr-agenda-project-without-next-child-is-stuck ()
  "An active project with zero NEXT children is stuck (AE2)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "NoNext" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Later" :status "waiting" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "NoNext"))))

(ert-deftest mindwtr-agenda-project-with-only-done-children-is-stuck ()
  "DONE children do not clear stuck."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "AllDone" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Finished" :status "done" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "AllDone"))))

(ert-deftest mindwtr-agenda-project-with-only-waiting-child-is-stuck ()
  "A WAIT child but no NEXT is still stuck."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "OnlyWait" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Blocked" :status "waiting" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "OnlyWait"))))

(ert-deftest mindwtr-agenda-project-with-nested-next-is-not-stuck ()
  "A NEXT task under a section within the project clears stuck (whole-subtree
scan, not just direct children)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Nested" :status "active"))
        :sections ((:id "s1" :title "Phase 1" :projectId "p1"))
        :tasks ((:id "t1" :title "Deep action" :status "next"
                 :projectId "p1" :sectionId "s1"))
        :settings nil)
    (should-not (mindwtr-agenda-test--stuck-at "Nested"))))

;;; mindwtr-agenda-test.el ends here
