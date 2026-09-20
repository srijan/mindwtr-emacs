;;; mindwtr-clarify-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'mindwtr-clarify)
(require 'mindwtr-render)

(defun mindwtr-clarify-test--teardown ()
  "Kill a leftover WIP buffer and reset session state between tests."
  (let ((buf (get-buffer mindwtr-clarify--wip-buffer-name)))
    (when buf (kill-buffer buf)))
  (setq mindwtr-clarify--pending nil
        mindwtr-clarify--source nil
        mindwtr-clarify--window-config nil))

(defmacro mindwtr-clarify-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY.
BODY runs with the source buffer current AND bound to `src' -- the clarify
session switches the current buffer to the WIP, so assertions on the source
go through (with-current-buffer src ...)."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     (let ((src (current-buffer)))
       (ignore src)
       (unwind-protect
           (progn ,@body)
         (mindwtr-clarify-test--teardown)))))

(defun mindwtr-clarify-test--wip ()
  "Return the live WIP buffer, or nil."
  (get-buffer mindwtr-clarify--wip-buffer-name))

(defun mindwtr-clarify-test--press (key)
  "Choose KEY at the decide menu of the live WIP buffer.
Stubs only the menu read (and `sit-for'); outcome prompts must be stubbed
by the caller, so an unexpected prompt fails loudly in batch."
  (let ((buf (mindwtr-clarify-test--wip)))
    (should buf)
    (with-current-buffer buf
      (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) key))
                ((symbol-function 'sit-for) (lambda (&rest _) t)))
        (mindwtr-clarify-decide)))))

(defun mindwtr-clarify-test--parent-list-of (title)
  "Return the MW_LIST role of the container the heading named TITLE sits under.
Case-sensitive search: with folding, a title like \"One\" would first match
inside \"DONE(d)\" on the #+TODO: header line."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (re-search-forward (regexp-quote title)))
    (mindwtr-commands--parent-list-role)))

(defun mindwtr-clarify-test--keyword-of (title)
  "Return the TODO keyword of the heading named TITLE."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (re-search-forward (regexp-quote title)))
    (org-back-to-heading t)
    (org-get-todo-state)))

(defconst mindwtr-clarify-test--date (encode-time 0 0 0 20 6 2026)
  "The fixed date the `org-read-date' stub returns (2026-06-20).")

(defun mindwtr-clarify-test--read-date-stub (&rest _)
  "Stand-in for `org-read-date' under `org-schedule'/`org-deadline'.
Both call it with TO-TIME, so an encoded time is the right return shape."
  (setq org-time-was-given nil)
  mindwtr-clarify-test--date)

;;; Structure helpers (unchanged surface)

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

(ert-deftest mindwtr-clarify-empty-inbox-opens-no-wip ()
  "An empty inbox ends the pass without opening a WIP buffer."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil :tasks nil :settings nil)
    (mindwtr-clarify)
    (should (null (mindwtr-clarify-test--wip)))))

;;; WIP buffer

(ert-deftest mindwtr-clarify-opens-wip-with-item-copy ()
  "The session copies the first inbox item into the WIP buffer at level 1,
in `mindwtr-clarify-mode', pointing back at the source."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (should (derived-mode-p 'mindwtr-clarify-mode))
      (goto-char (point-min))
      (outline-next-heading)
      (should (looking-at-p "\\* INBOX One"))
      (should (eq mindwtr-clarify--source-buffer src))
      (should (string= mindwtr-clarify--source-id "t1")))))

(ert-deftest mindwtr-clarify-rejects-second-session ()
  "Starting a clarify while a WIP buffer is live is a user-error."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (should-error (with-current-buffer src (mindwtr-clarify))
                  :type 'user-error)))

;;; Outcomes

(ert-deftest mindwtr-clarify-next-action-relocates-and-advances ()
  "Deciding [n] files One as NEXT under single-actions and loads Two; the
skip then leaves Two in the inbox and ends the session."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "unexpected area prompt"))))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?n))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "single-actions"))
      (should (string= (mindwtr-clarify-test--keyword-of "One") "NEXT")))
    ;; The WIP now holds Two; skipping it ends the session.
    (with-current-buffer (mindwtr-clarify-test--wip)
      (goto-char (point-min))
      (outline-next-heading)
      (should (looking-at-p "\\* INBOX Two"))
      (mindwtr-clarify-skip))
    (should (null (mindwtr-clarify-test--wip)))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "Two") "inbox")))))

(ert-deftest mindwtr-clarify-quick-action-marks-done ()
  "[q] marks the item DONE with a CLOSED stamp and files it in single-actions."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (mindwtr-clarify-test--press ?q)
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "single-actions"))
      (should (string= (mindwtr-clarify-test--keyword-of "One") "DONE"))
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "DONE One"))
      (should (re-search-forward
               "CLOSED:" (save-excursion (org-end-of-subtree t t) (point)) t)))))

(ert-deftest mindwtr-clarify-delegate-sets-who-checkin-and-waits ()
  "[d] offers the People roster, accepts a new name, records it with a
check-in DEADLINE, and files the item WAIT."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :people ((:id "pe1" :name "Alice"))
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt cands &rest _) (setq offered cands) "Bob"))
                ((symbol-function 'org-read-date)
                 #'mindwtr-clarify-test--read-date-stub)
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) nil)))
        (mindwtr-clarify)
        (mindwtr-clarify-test--press ?d))
      (should (member "Alice" offered)))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "single-actions"))
      (should (string= (mindwtr-clarify-test--keyword-of "One") "WAIT"))
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "WAIT One"))
      (org-back-to-heading t)
      (should (string= (org-entry-get nil "MW_ASSIGNED_TO") "Bob"))
      (should-not (org-entry-get nil "MW_CONTEXTS"))
      (should (re-search-forward
               "DEADLINE: <2026-06-20"
               (save-excursion (org-end-of-subtree t t) (point)) t)))))

(ert-deftest mindwtr-clarify-delegate-skips-person-on-empty ()
  "RET at the assignee prompt files the item WAIT with no assignee."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) ""))
              ((symbol-function 'org-read-date)
               #'mindwtr-clarify-test--read-date-stub)
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil)))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?d))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--keyword-of "One") "WAIT"))
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "WAIT One"))
      (should-not (org-entry-get nil "MW_ASSIGNED_TO")))))

(ert-deftest mindwtr-clarify-tickler-schedules-next ()
  "[t] files the item NEXT with the chosen SCHEDULED date (this one outcome
covers calendar items too -- same NEXT + startTime shape in the model)."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'org-read-date)
               #'mindwtr-clarify-test--read-date-stub)
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil)))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?t))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "single-actions"))
      (should (string= (mindwtr-clarify-test--keyword-of "One") "NEXT"))
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "NEXT One"))
      (should (re-search-forward
               "SCHEDULED: <2026-06-20"
               (save-excursion (org-end-of-subtree t t) (point)) t)))))

(ert-deftest mindwtr-clarify-someday-reference-trash ()
  "[s] -> someday bucket, [r] -> reference bucket, [x] -> ARCH in place
(archived has no bucket on purpose; the next sync drops it)."
  (pcase-dolist (`(,key ,list ,kw)
                 '((?s "someday-single-actions" "SOMEDAY")
                   (?r "reference" "REF")
                   (?x "inbox" "ARCH")))
    (mindwtr-clarify-test--with-appdata
        '(:areas nil :projects nil :sections nil
          :tasks ((:id "t1" :title "One" :status "inbox"))
          :settings nil)
      (mindwtr-clarify)
      (mindwtr-clarify-test--press key)
      (with-current-buffer src
        (should (string= (mindwtr-clarify-test--parent-list-of "One") list))
        (should (string= (mindwtr-clarify-test--keyword-of "One") kw))))))

(ert-deftest mindwtr-clarify-trash-advances-to-next-item ()
  "Trashing advances to the real next item.  Regression: the write-back
rewrites the item's subtree up to the next heading, so a marker-based
queue collapsed onto the trashed item -- which, uniquely, stays in place
(ARCH has no bucket) -- and re-opened it instead of the next one."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (mindwtr-clarify-test--press ?x)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (goto-char (point-min))
      (outline-next-heading)
      (should (looking-at-p "\\* INBOX Two"))
      (should (string= mindwtr-clarify--source-id "t2")))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--keyword-of "One") "ARCH")))))

(ert-deftest mindwtr-clarify-wip-edits-written-back-on-decide ()
  "Rewording the item in the WIP buffer lands in the source on decide."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "One"))
      (insert " refined"))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil)))
      (mindwtr-clarify-test--press ?n))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One refined")
                       "single-actions"))
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get task :id) "t1"))
        (should (string= (plist-get task :title) "One refined"))))))

(ert-deftest mindwtr-clarify-skip-discards-wip-edits ()
  "Skipping leaves the source item untouched, edits and all."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (goto-char (point-min))
      (let ((case-fold-search nil)) (re-search-forward "One"))
      (insert " refined")
      (mindwtr-clarify-skip))
    (should (null (mindwtr-clarify-test--wip)))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "inbox"))
      (goto-char (point-min))
      (should-not (let ((case-fold-search nil))
                    (re-search-forward "refined" nil t))))))

(ert-deftest mindwtr-clarify-stop-ends-the-pass ()
  "Stopping in the first item's WIP leaves the rest of the inbox untouched."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (mindwtr-clarify)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (mindwtr-clarify-stop))
    (should (null (mindwtr-clarify-test--wip)))
    (should (null mindwtr-clarify--pending))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "inbox"))
      (should (string= (mindwtr-clarify-test--parent-list-of "Two") "inbox")))))

(ert-deftest mindwtr-clarify-project-outcome-promotes ()
  "[p] makes the item the first NEXT action of a new ACTIVE project (the
task keeps its id; the project is a fresh entity)."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Plan party" :status "inbox"))
        :settings nil)
    ;; RET through both prompts (project title and next action keep defaults)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional init &rest _) (or init ""))))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?p))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "Plan party") "projects"))
      (let* ((ad (mindwtr-parse-buffer))
             (proj (car (plist-get ad :projects)))
             (task (car (plist-get ad :tasks))))
        (should (string= (plist-get proj :title) "Plan party"))
        (should (string= (plist-get proj :status) "active"))
        (should (string= (plist-get task :id) "t1"))
        (should (string= (plist-get task :status) "next"))
        (should (string= (plist-get task :projectId) (plist-get proj :id)))))))

(ert-deftest mindwtr-clarify-project-outcome-asks-project-area ()
  "[p] asks for the NEW project's area (its tasks inherit it), not the task's."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Plan party" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional init &rest _) (or init "")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Personal")))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?p))
    (with-current-buffer src
      (let* ((ad (mindwtr-parse-buffer))
             (proj (car (plist-get ad :projects)))
             (task (car (plist-get ad :tasks))))
        (should (string= (plist-get proj :areaId) "a1"))
        (should (string= (plist-get task :projectId) (plist-get proj :id)))
        (should-not (plist-get task :areaId))))))

(ert-deftest mindwtr-clarify-project-outcome-skips-area-when-project-has-one ()
  "[p] onto an existing same-titled project that already has an area asks nothing."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects ((:id "p1" :title "Plan party" :status "active" :areaId "a1"))
        :sections nil
        :tasks ((:id "t1" :title "Plan party" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional init &rest _) (or init "")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "unexpected area prompt"))))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?p))
    (with-current-buffer src
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get task :projectId) "p1"))))))

(ert-deftest mindwtr-clarify-failed-outcome-keeps-wip-alive ()
  "An outcome that errors (promote with no `* Projects' container) keeps
the WIP buffer open for a re-decision instead of advancing."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Plan party\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((src (current-buffer)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'read-string)
                       (lambda (_prompt &optional init &rest _) (or init ""))))
              (mindwtr-clarify)
              (mindwtr-clarify-test--press ?p))
            (should (mindwtr-clarify-test--wip))
            (with-current-buffer src
              (should (string= (mindwtr-clarify-test--parent-list-of "Plan party")
                               "inbox"))))
        (mindwtr-clarify-test--teardown)))))

(ert-deftest mindwtr-clarify-add-to-project-refiles ()
  "[a] hands off to `org-refile' with the project-only wiring bound."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (let (seen-verify)
      (cl-letf (((symbol-function 'org-refile)
                 (lambda (&rest _)
                   (setq seen-verify org-refile-target-verify-function)))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) nil)))
        (mindwtr-clarify)
        (mindwtr-clarify-test--press ?a))
      (should (eq seen-verify #'mindwtr-clarify--project-target-p))
      (should (null (mindwtr-clarify-test--wip))))))

(ert-deftest mindwtr-clarify-add-to-project-sets-next ()
  "[a] makes the item NEXT before handing off to the refile -- a task under a
project rests at NEXT, not the INBOX state it carried in the inbox (issue #35).
The refile is stubbed to a no-op so the keyword stays observable in place."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'org-refile) (lambda (&rest _) nil))
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil)))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?a))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--keyword-of "One") "NEXT")))))

(ert-deftest mindwtr-clarify-add-to-project-stamps-child-keywords ()
  "[a] stamps NEXT on keyword-less child sub-headings that ride along, just
like `mindwtr-promote-to-project' does -- so the local buffer shows them as
project tasks immediately, not only after the next sync's `ensure-status'."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Plan party\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "*** Buy cake\n"
              "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE MyProj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((src (current-buffer)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'org-refile) (lambda (&rest _) nil))
                      ((symbol-function 'completing-read-multiple)
                       (lambda (&rest _) nil)))
              (mindwtr-clarify)
              (mindwtr-clarify-test--press ?a))
            (should (string= (mindwtr-clarify-test--keyword-of "Plan party") "NEXT"))
            (should (string= (mindwtr-clarify-test--keyword-of "Buy cake") "NEXT")))
        (mindwtr-clarify-test--teardown)))))

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

;;; Post-decision prompts

(ert-deftest mindwtr-clarify-post-prompts-set-contexts-and-area ()
  "An actionable decision is followed by the contexts prompt and -- when
the buffer has areas and the item none -- the area prompt."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox"))
        :settings nil)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("@home")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Personal")))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?n))
    (with-current-buffer src
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (equal (plist-get task :contexts) '("@home")))
        (should (string= (plist-get task :areaId) "a1"))
        (should (string= (plist-get task :status) "next"))))))

(ert-deftest mindwtr-clarify-post-prompts-skips-area-when-already-set ()
  "When the item already carries an area (org-native :CATEGORY:), the area
prompt does not fire again -- the guard reads :CATEGORY:, not the legacy
:MW_AREA:, so a clarified item with an area is left as-is."
  (mindwtr-clarify-test--with-appdata
      '(:areas ((:id "a1" :name "Personal" :order 0))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox" :areaId "a1"))
        :settings nil)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "unexpected area prompt"))))
      (mindwtr-clarify)
      (mindwtr-clarify-test--press ?n))
    (with-current-buffer src
      (let ((task (car (plist-get (mindwtr-parse-buffer) :tasks))))
        ;; the pre-set area survives untouched (no re-prompt clobbered it)
        (should (string= (plist-get task :areaId) "a1"))))))

;;; Hand-written items

(ert-deftest mindwtr-clarify-drawerless-item-gets-id-and-clarifies ()
  "A hand-written inbox heading without a drawer is stamped an MW_ID when
its WIP opens, so the write-back has a stable handle; [n] then files it."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** Some idea\n"
              "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (let ((src (current-buffer)))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'completing-read-multiple)
                       (lambda (&rest _) nil)))
              (mindwtr-clarify)
              (with-current-buffer (mindwtr-clarify-test--wip)
                (should mindwtr-clarify--source-id))
              (mindwtr-clarify-test--press ?n))
            (with-current-buffer src
              (should (string= (mindwtr-clarify-test--parent-list-of "Some idea")
                               "single-actions"))
              (goto-char (point-min))
              (let ((case-fold-search nil)) (re-search-forward "Some idea"))
              (org-back-to-heading t)
              (should (org-entry-get nil "MW_ID"))))
        (mindwtr-clarify-test--teardown)))))

;;; Single-item entry point

(ert-deftest mindwtr-clarify-this-item-only-touches-item-at-point ()
  "`mindwtr-clarify-this-item' triages exactly the item at point: Two is
clarified to single-actions, One is neither loaded nor moved."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "One" :status "inbox")
                (:id "t2" :title "Two" :status "inbox"))
        :settings nil)
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Two"))
    (mindwtr-clarify-this-item)
    (with-current-buffer (mindwtr-clarify-test--wip)
      (goto-char (point-min))
      (outline-next-heading)
      (should (looking-at-p "\\* INBOX Two")))
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (&rest _) nil)))
      (mindwtr-clarify-test--press ?n))
    (should (null (mindwtr-clarify-test--wip)))
    (with-current-buffer src
      (should (string= (mindwtr-clarify-test--parent-list-of "Two") "single-actions"))
      (should (string= (mindwtr-clarify-test--parent-list-of "One") "inbox")))))

(ert-deftest mindwtr-clarify-this-item-climbs-to-inbox-item ()
  "From a heading nested inside an inbox item, this-item acts on the item."
  (with-temp-buffer
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Plan party\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "*** Book venue\n")
      (org-mode))
    (goto-char (point-min))
    (unwind-protect
        (progn
          (let ((case-fold-search nil)) (re-search-forward "Book venue"))
          (mindwtr-clarify-this-item)
          (with-current-buffer (mindwtr-clarify-test--wip)
            (goto-char (point-min))
            (outline-next-heading)
            (should (looking-at-p "\\* INBOX Plan party"))
            (should (string= mindwtr-clarify--source-id "t1"))))
      (mindwtr-clarify-test--teardown))))

(ert-deftest mindwtr-clarify-this-item-errors-off-inbox ()
  "Off an inbox item (a single-actions task), this-item is a user-error."
  (mindwtr-clarify-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next"))
        :settings nil)
    (goto-char (point-min))
    (let ((case-fold-search nil)) (re-search-forward "Loose"))
    (should-error (mindwtr-clarify-this-item) :type 'user-error)))

(ert-deftest mindwtr-clarify-trash-refiles-to-archive-when-active ()
  "Covers R5.  With the archive surface active, clarify trash refiles the item
into the archive file (it leaves the source buffer) and the session advances to
the next inbox item -- the id-based queue skips the vanished heading."
  (let* ((root (make-temp-file "mw-clar-arch" t))
         (apath (expand-file-name "arch.org" root))
         (mindwtr-archive-file apath)
         (mindwtr-file nil))
    (unwind-protect
        (mindwtr-clarify-test--with-appdata
            '(:areas nil :projects nil :sections nil
              :tasks ((:id "t1" :title "One" :status "inbox")
                      (:id "t2" :title "Two" :status "inbox"))
              :settings nil)
          (mindwtr-clarify)
          (mindwtr-clarify-test--press ?x)
          ;; the session advanced to the next inbox item
          (with-current-buffer (mindwtr-clarify-test--wip)
            (should (string= mindwtr-clarify--source-id "t2")))
          ;; the trashed item left the source buffer ... (case-sensitive: the
          ;; #+TODO keyword line contains "DONE", which case-folds to match "One")
          (with-current-buffer src
            (goto-char (point-min))
            (let ((case-fold-search nil))
              (should-not (search-forward "One" nil t))))
          ;; ... and landed under * Archive with ARCH
          (with-current-buffer (mindwtr-archive-buffer)
            (goto-char (point-min))
            (should (re-search-forward "ARCH One" nil t))))
      (let ((b (find-buffer-visiting apath)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (delete-directory root t))))

;;; mindwtr-clarify-test.el ends here
