;;; mindwtr-clarify-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'mindwtr-clarify)
(require 'mindwtr-render)

(defmacro mindwtr-clarify-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     ,@body))

(defun mindwtr-clarify-test--feed (keys thunk)
  "Call THUNK with `read-char-choice' stubbed to return KEYS in order.
Every prompt in the flow (the clarify menu AND the status picker inside
`mindwtr-set-status') consumes from the same feed.  Errors when a prompt
fires after the feed is exhausted."
  (let ((feed (copy-sequence keys)))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _)
                 (or (pop feed)
                     (error "clarify test: key feed exhausted")))))
      (funcall thunk))))

(defun mindwtr-clarify-test--parent-list-of (title)
  "Return the MW_LIST role of the container the heading named TITLE sits under.
Case-sensitive search: with folding, a title like \"One\" would first match
inside \"DONE(d)\" on the #+TODO: header line."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (re-search-forward (regexp-quote title)))
    (mindwtr-commands--parent-list-role)))

(ert-deftest mindwtr-clarify-inbox-items-in-order ()
  "Markers cover exactly the inbox's direct children, in buffer order."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox")
                (:id "t3" :title "Elsewhere" :status "next"))
        :settings nil)
    (let ((items (mindwtr-clarify--inbox-items)))
      (unwind-protect
          (progn
            (should (= (length items) 2))
            (goto-char (nth 0 items))
            (should (looking-at-p "\\*\\* INBOX One"))
            (goto-char (nth 1 items))
            (should (looking-at-p "\\*\\* INBOX Two")))
        (dolist (m items) (set-marker m nil))))))

(ert-deftest mindwtr-clarify-errors-without-inbox-container ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Notes\n")
      (org-mode))
    (should-error (mindwtr-clarify--inbox-items) :type 'user-error)))

(ert-deftest mindwtr-clarify-empty-inbox-prompts-nothing ()
  "An empty inbox ends the pass without ever prompting."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil :tasks nil :settings nil)
    (mindwtr-clarify-test--feed '() (lambda () (mindwtr-clarify)))))

(ert-deftest mindwtr-clarify-status-relocates-and-advances ()
  "Setting a status that leaves the inbox finishes the item and moves on:
`s' `n' (NEXT) clarifies One into single-actions; `n' skips Two in place."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (mindwtr-clarify-test--feed '(?s ?n ?n) (lambda () (mindwtr-clarify)))
    (should (string= (mindwtr-clarify-test--parent-list-of "One") "single-actions"))
    (should (string= (mindwtr-clarify-test--parent-list-of "Two") "inbox"))))

(ert-deftest mindwtr-clarify-keeping-inbox-status-stays-in-loop ()
  "Choosing INBOX from the status picker keeps the item's loop alive (the
item did not leave the inbox), so a further key is needed to move on."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    ;; s -> i (INBOX, stays) -> n (skip)
    (mindwtr-clarify-test--feed '(?s ?i ?n) (lambda () (mindwtr-clarify)))
    (should (string= (mindwtr-clarify-test--parent-list-of "One") "inbox"))))

(ert-deftest mindwtr-clarify-contexts-and-area-stay-on-item ()
  "Tags and area edits act on the item and keep its loop running."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'org-set-tags-command)
               (lambda (&rest _) (org-set-tags '("@home"))))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Personal")))
      (mindwtr-clarify-test--feed '(?c ?a ?n) (lambda () (mindwtr-clarify))))
    (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
      (should (equal (plist-get task :contexts) '("@home")))
      (should (string= (plist-get task :areaId) "a1"))
      (should (string= (plist-get task :status) "inbox")))))

(ert-deftest mindwtr-clarify-refile-targets-only-projects ()
  "The refile wiring offers exactly the buffer's project headings."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects ((:id "p1" :title "MyProj" :status "active")
                   (:id "p2" :title "LaterProj" :status "someday"))
        :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (let* ((org-refile-targets '((nil :maxlevel . 9)))
           (org-refile-target-verify-function #'mindwtr-clarify--project-target-p)
           (org-refile-use-cache nil)
           (targets (mapcar #'car (org-refile-get-targets))))
      (should (= (length targets) 2))
      (should (cl-some (lambda (s) (string-match-p "MyProj" s)) targets))
      (should (cl-some (lambda (s) (string-match-p "LaterProj" s)) targets)))))

(ert-deftest mindwtr-clarify-refile-finishes-item ()
  "`r' hands off to `org-refile' (with the project wiring bound) and counts
the item as clarified."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (let (seen-verify)
      (cl-letf (((symbol-function 'org-refile)
                 (lambda (&rest _)
                   (setq seen-verify org-refile-target-verify-function))))
        (mindwtr-clarify-test--feed '(?r ?n) (lambda () (mindwtr-clarify))))
      (should (eq seen-verify #'mindwtr-clarify--project-target-p)))))

(ert-deftest mindwtr-clarify-quit-stops-the-pass ()
  "`q' on the first item leaves the rest of the inbox untouched and unprompted."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (mindwtr-clarify-test--feed '(?q) (lambda () (mindwtr-clarify)))
    (should (string= (mindwtr-clarify-test--parent-list-of "One") "inbox"))
    (should (string= (mindwtr-clarify-test--parent-list-of "Two") "inbox"))))

;;; mindwtr-clarify-test.el ends here
