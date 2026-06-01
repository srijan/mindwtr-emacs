;;; mindwtr-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr)

(ert-deftest mindwtr-mode-sets-todo-keywords ()
  (with-temp-buffer
    (mindwtr-mode)
    (should (member "NEXT" (mapcar #'car org-todo-kwd-alist)))
    (should (member "ACTIVE" (mapcar #'car org-todo-kwd-alist)))))

(ert-deftest mindwtr-token-prefers-explicit-var ()
  (let ((mindwtr-auth-token "explicit"))
    (should (string= (mindwtr--resolve-token) "explicit"))))

(ert-deftest mindwtr-sync-command-is-interactive ()
  (should (commandp 'mindwtr-sync)))
