;;; mindwtr-capture-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-capture)
(require 'mindwtr-parse)

(defconst mindwtr-capture-test--uuid-re
  "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
  "Anchored lowercase RFC-4122 v4 UUID.")

(ert-deftest mindwtr-capture-template-mints-lowercase-v4-id ()
  "The template stamps a freshly minted lowercase v4 MW_ID."
  (let ((tmpl (mindwtr-capture-template)))
    (should (string-match ":MW_ID: \\(.+\\)$" tmpl))
    (should (string-match-p mindwtr-capture-test--uuid-re (match-string 1 tmpl)))))

(ert-deftest mindwtr-capture-template-parses-as-inbox-task ()
  "The template body, placed under the Inbox container and parsed, yields a
task with status inbox and the exact minted id (R6)."
  (let* ((tmpl (mindwtr-capture-template))
         (id (and (string-match ":MW_ID: \\(.+\\)$" tmpl) (match-string 1 tmpl)))
         ;; org-capture replaces %? with the cursor/title and normalizes the
         ;; heading level to the target; emulate both for an offline parse.
         (body (replace-regexp-in-string "%\\?" "Buy milk" tmpl))
         (body (replace-regexp-in-string "\\`\\* " "** " body)))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
                body)
        (org-mode))
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get task :title) "Buy milk"))
        (should (string= (plist-get task :status) "inbox"))
        (should (string= (plist-get task :id) id))))))
;;; mindwtr-capture-test.el ends here
