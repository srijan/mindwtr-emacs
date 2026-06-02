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

;;; mindwtr-commands-test.el ends here
