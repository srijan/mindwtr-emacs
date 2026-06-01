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
