;;; mindwtr-reconcile-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-reconcile)

(ert-deftest mindwtr-reconcile-updates-existing-title ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT old title :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "new title" :status "next"
                             :areaId "a1" :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work" :rev 1)) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "new title" nil t))
      (should-not (save-excursion (search-forward "old title" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "done" :areaId "a1"
                             :rev 6 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "KEEPME" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "DONE" nil t))))))

(ert-deftest mindwtr-reconcile-removes-tombstoned ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT gone :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "gone" :status "next" :areaId "a1"
                             :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should-not (search-forward "gone" nil t)))))

(ert-deftest mindwtr-reconcile-inserts-remote-new ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t2" :title "fresh" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-06-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "fresh" nil t)))))

(ert-deftest mindwtr-reconcile-update-reflects-new-deadline ()
  "A server-changed dueDate must appear on an EXISTING heading.
Regression: the partial in-place update left the old planning line in
place, so the next sync re-parsed the stale date and PUT it back,
silently reverting the remote edit."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\nDEADLINE: <2026-01-01 Thu>\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :contexts ("@x") :dueDate "2099-12-31"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "2099-12-31" nil t))
      ;; the old DEADLINE active timestamp must be gone (MW_CREATED keeps an
      ;; inactive [2026-01-01...], so match the active "<2026-01-01" form).
      (should-not (save-excursion (search-forward "<2026-01-01" nil t))))))

(ert-deftest mindwtr-reconcile-update-removes-dropped-schedule ()
  "When the server clears startTime, the SCHEDULED line is removed."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\nSCHEDULED: <2026-02-09 Mon>\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should-not (search-forward "SCHEDULED" nil t)))))

(ert-deftest mindwtr-reconcile-update-reflects-new-description ()
  "A server-changed description replaces the old prose on an existing heading."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "old body prose\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "fresh body prose"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "fresh body prose" nil t))
      (should-not (save-excursion (search-forward "old body prose" nil t))))))

(ert-deftest mindwtr-reconcile-update-reflects-new-checklist ()
  "A server-changed checklist replaces the old checkbox items."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "- [ ] one\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :checklist ((:title "one" :isCompleted t)
                                         (:title "two" :isCompleted :false))
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "- [X] one" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "- [ ] two" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-logbook-through-body-change ()
  "A full-content update keeps org-only drawers (LOGBOOK) while rewriting prose."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n"
              "stale prose\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "brand new prose"
                             :rev 7 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "KEEPME" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "brand new prose" nil t)))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "stale prose" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-unknown-properties ()
  "An unknown PROPERTIES key survives a full-content update."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
              ":CUSTOM_KEY: keepme\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "renamed" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "keepme" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-project-prose ()
  "Renaming a project (non-task) keeps its free-prose body.
The renderer emits no body for non-task kinds, so the whole body is
org-only content and must survive a full-content rebuild."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "Important planning notes.\nSecond line.\n")
      (org-mode))
    (let ((merged '(:tasks nil
                    :projects ((:id "p1" :title "Renamed Proj" :status "active"
                                :areaId "a1" :rev 4 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "Renamed Proj" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "Important planning notes." nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "Second line." nil t)))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "ACTIVE Proj\n" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-bare-clock ()
  "A bare CLOCK line (org-clock-into-drawer disabled) survives a task rebuild."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "new prose"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "CLOCK: [2026-01-01 Thu 10:00]" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "new prose" nil t))))))

(ert-deftest mindwtr-reconcile-no-duplicate-when-logbook-precedes-properties ()
  "A heading whose LOGBOOK drawer sits ABOVE its PROPERTIES drawer is still
matched by id (no spurious duplicate insert)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:LOGBOOK:\n- note KEEPME\n:END:\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "renamed" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      ;; exactly one task heading for t1 -- no duplicate appended
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^\\*\\* .* renamed$" nil t) (setq n (1+ n)))
        (should (= n 1))))))

(ert-deftest mindwtr-reconcile-restore-roundtrips-field-edit ()
  "Restoring a simple field edit reproduces it exactly -> `restored'."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT theirs\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((mine '(:id "t1" :title "mine" :status "next" :areaId "a1"
                  :rev 9 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z")))
      (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'restored))
      (goto-char (point-min))
      (should (search-forward "mine" nil t)))))

(ert-deftest mindwtr-reconcile-restore-refile-is-partial ()
  "Restoring a refile (containment) edit cannot move the heading in place,
so it must report `partial' (honest) rather than falsely claim success."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE PA\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: pA\n:END:\n"
              "** ACTIVE PB\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: pB\n:END:\n"
              "*** NEXT thing\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    ;; the task currently sits under pB; the lost edit moved it to pA
    (let ((mine '(:id "t1" :title "thing" :status "next" :projectId "pA"
                  :rev 9 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z")))
      (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'partial)))))

(ert-deftest mindwtr-reconcile-restore-missing-heading-returns-nil ()
  "Restoring an entity that is no longer in the buffer (remote delete) is nil."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (should (null (mindwtr-reconcile-restore-entity
                   '(:id "gone" :title "x" :status "next") 'task)))))

(ert-deftest mindwtr-reconcile-low-priority-does-not-crash ()
  "Updating a task to :priority \"low\" writes [#D] without erroring."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :priority "low"
                             :areaId "a1" :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "[#D]" nil t)))))
