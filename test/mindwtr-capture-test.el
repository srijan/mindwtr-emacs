;;; mindwtr-capture-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org-capture)
(require 'mindwtr-capture)
(require 'mindwtr-parse)
(require 'mindwtr-render)

(defvar mindwtr-file nil)

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

(ert-deftest mindwtr-capture-goto-inbox-finds-mw-list-container ()
  "The locator lands on the container whose :MW_LIST: is inbox, even when the
heading text is not literally \"Inbox\"."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stuff\n"
              "* In-Tray\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "* Reference\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: reference\n:END:\n")
      (org-mode))
    (mindwtr-capture--goto-inbox)
    (should (looking-at-p "\\* In-Tray$"))))

(ert-deftest mindwtr-capture-goto-inbox-falls-back-to-plain-headline ()
  "Without an :MW_LIST: container, a literal `* Inbox' headline is the target."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Notes\n* Inbox\n* Other\n")
      (org-mode))
    (mindwtr-capture--goto-inbox)
    (should (looking-at-p "\\* Inbox$"))))

(ert-deftest mindwtr-capture-goto-inbox-errors-without-inbox ()
  "No inbox container and no `* Inbox' headline is a user-error."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Notes\n")
      (org-mode))
    (should-error (mindwtr-capture--goto-inbox) :type 'user-error)))

(ert-deftest mindwtr-capture-errors-when-file-unset ()
  "The command fails fast with a helpful error when `mindwtr-file' is nil."
  (let ((mindwtr-file nil))
    (should-error (mindwtr-capture) :type 'user-error)))

(ert-deftest mindwtr-capture-command-captures-into-inbox ()
  "End-to-end: `mindwtr-capture' on a rendered file, type a title, finalize;
the new heading parses as an inbox task with a minted id."
  (let ((file (make-temp-file "mindwtr-capture-test" nil ".org"))
        (org-capture-templates nil))
    (unwind-protect
        (let ((mindwtr-file file))
          (with-temp-file file
            (insert (mindwtr-render-appdata
                     '(:areas nil :projects nil :sections nil
                       :tasks ((:id "t0" :title "Existing" :status "inbox"))
                       :settings nil))))
          (mindwtr-capture)
          (insert "Buy milk")
          (org-capture-finalize)
          (with-current-buffer (or (find-buffer-visiting file)
                                   (find-file-noselect file))
            (let* ((tasks (plist-get (mindwtr-parse-buffer) :tasks))
                   (new (seq-find (lambda (tk)
                                    (equal (plist-get tk :title) "Buy milk"))
                                  tasks)))
              (should (= (length tasks) 2))
              (should new)
              (should (string= (plist-get new :status) "inbox"))
              (should (string-match-p mindwtr-capture-test--uuid-re
                                      (plist-get new :id))))))
      (let ((buf (find-buffer-visiting file)))
        (when buf
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf)))
      (delete-file file))))

(ert-deftest mindwtr-capture-template-entry-shape ()
  "The template entry targets `mindwtr-file''s inbox via file+function and
uses the (with-link) template function."
  (let ((plain (mindwtr-capture-template-entry))
        (linked (mindwtr-capture-template-entry "M" "With link" t)))
    (should (equal (seq-take plain 4)
                   '("m" "Mindwtr inbox" entry
                     (file+function mindwtr-capture--file
                                    mindwtr-capture--goto-inbox))))
    (should (equal (nth 4 plain) (list 'function #'mindwtr-capture-template)))
    (should (equal (car linked) "M"))
    (should (equal (nth 4 linked)
                   (list 'function #'mindwtr-capture-template-with-link)))))
;;; mindwtr-capture-test.el ends here
