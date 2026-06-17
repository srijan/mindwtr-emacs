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

;;; mindwtr-agenda-test.el ends here
