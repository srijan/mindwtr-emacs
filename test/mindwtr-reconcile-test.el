;;; mindwtr-reconcile-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-reconcile)

(defun mindwtr-reconcile-test--show-children ()
  "Reveal the immediate child headings at point (cross-version test helper).
Mirrors the `mindwtr-reconcile--hide-subtree'/`--show-entry' wrappers so test
setup never inlines an `fboundp' fold branch of its own."
  (if (fboundp 'org-fold-show-children)
      (org-fold-show-children)
    (org-show-children)))

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

(ert-deftest mindwtr-reconcile-builds-list-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas ((:id "a1" :name "Personal" :order 0))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
                    :sections nil
                    :tasks ((:id "t1" :title "loose next" :status "next")
                            (:id "t2" :title "child" :status "next" :projectId "p1"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "* Single Actions" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "loose next" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Projects" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "child" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Areas of Focus" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook-into-new-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      ;; an existing buffer (any layout) with a LOGBOOK under task t1
      (insert "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "renamed" :status "next"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "KEEPME" nil t))))))

(ert-deftest mindwtr-reconcile-archived-not-rendered ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "keep me" :status "next")
                            (:id "t2" :title "archived one" :status "archived"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "keep me" nil t))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "archived one" nil t))))))

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

;;; View-state preservation across reconcile -- fold state (U1)

(ert-deftest mindwtr-reconcile-keeps-folded-heading-folded ()
  "R1: a folded entity heading stays folded after a reconcile that changes
an unrelated entity.  Detection asserts via `org-invisible-p' so the test
runs identically on Org 9.5 and 9.8."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT task one\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "body of one\n"
              "** NEXT task two\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\n")
      (org-mode))
    (mindwtr-reconcile--goto-id "t1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position))) ; sanity: folded before
    (let ((merged '(:tasks ((:id "t1" :title "task one" :status "next" :areaId "a1"
                             :description "body of one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z")
                            (:id "t2" :title "task two RENAMED" :status "next" :areaId "a1"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "task two RENAMED" nil t)) ; the unrelated change landed
      (mindwtr-reconcile--goto-id "t1")
      (should (org-invisible-p (line-end-position)))))) ; still folded after

(ert-deftest mindwtr-reconcile-keeps-unfolded-heading-unfolded ()
  "R1: an unfolded heading is still unfolded after reconcile (no over-folding)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT task one\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "body of one\n")
      (org-mode))
    ;; leave everything unfolded
    (let ((merged '(:tasks ((:id "t1" :title "task one" :status "next" :areaId "a1"
                             :description "body of one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-reconcile--goto-id "t1")
      (should-not (org-invisible-p (line-end-position))))))

(ert-deftest mindwtr-reconcile-fold-follows-status-relocation ()
  "R6: a folded task that changes bucket (loose next -> under a project) is
folded again in its new location, because fold state is keyed by MW_ID."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT relocate me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "some body\n")
      (org-mode))
    (mindwtr-reconcile--goto-id "t1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position)))
    (let ((merged '(:tasks ((:id "t1" :title "relocate me" :status "next" :projectId "p1"
                             :description "some body"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :rev 1 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-reconcile--goto-id "t1")
      ;; it now lives under the project subtree; still folded
      (should (org-invisible-p (line-end-position))))))

(ert-deftest mindwtr-reconcile-restore-view-no-window-no-error ()
  "R4: reconcile completes without error with no live window (batch path) even
after folding, and the buffer is correctly rebuilt -- proves the
`condition-case' guard and the no-window path do not break the sync."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-reconcile--goto-id "t1")
    (mindwtr-reconcile--hide-subtree)
    (let ((merged '(:tasks ((:id "t1" :title "renamed t" :status "next" :areaId "a1"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (goto-char (point-min))
      (should (search-forward "renamed t" nil t)))))

(ert-deftest mindwtr-reconcile-folded-ancestor-does-not-error ()
  "Edge: a child entity hidden under a folded ancestor -- reconcile does not
error, and the ancestor's own fold state is preserved (documents the known
ancestor-skip limitation: only the ancestor's record drives restoration)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "*** NEXT child\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "child body\n")
      (org-mode))
    ;; fold the ancestor (project); the child is hidden only because of it
    (mindwtr-reconcile--goto-id "p1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position)))
    (let ((merged '(:tasks ((:id "t1" :title "child" :status "next" :projectId "p1"
                             :description "child body"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :rev 1 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (mindwtr-reconcile--goto-id "p1")
      (should (org-invisible-p (line-end-position)))))) ; ancestor still folded

;;; View-state preservation -- global cycle state + scroll anchor (U2)

(ert-deftest mindwtr-reconcile-reapplies-global-overview ()
  "R2: the global S-TAB overview state is reapplied after the rebuild.
Establishes overview by setting BOTH `org-cycle-global-status' (what the
snapshot reads) AND calling `org-overview' (the actual fold backdrop) --
`org-overview' alone does not set the variable, so a test using only it
would prove nothing.  Asserts the backdrop via `org-invisible-p'."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT deep task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (setq-local org-cycle-global-status 'overview)
    (org-overview)
    (let ((merged '(:tasks ((:id "t1" :title "deep task" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      ;; a top-level container heading stays visible
      (goto-char (point-min))
      (should (re-search-forward "^\\* Single Actions" nil t))
      (should-not (org-invisible-p (line-beginning-position)))
      ;; the deep entity heading is collapsed under the reapplied backdrop
      (mindwtr-reconcile--goto-id "t1")
      (should (org-invisible-p (line-beginning-position))))))

(ert-deftest mindwtr-reconcile-reapplies-global-contents ()
  "R2: the global `contents' S-TAB state is reapplied -- after reconcile a deep
entity heading is visible while its body stays folded."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n")
      (org-mode))
    (setq-local org-cycle-global-status 'contents)
    (org-content)
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "body"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-reconcile--goto-id "t1")
      (should-not (org-invisible-p (line-beginning-position))) ; heading visible
      (should (org-invisible-p (line-end-position))))))        ; body folded

(ert-deftest mindwtr-reconcile-reopens-entity-on-top-of-backdrop ()
  "R2 + R1 composition: with global overview set but one entity left open,
after reconcile that entity's own body is shown while a sibling the user had
folded stays collapsed -- the per-entity pass overrides the backdrop."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t1\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody one\n"
              "** NEXT t2\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\nbody two\n")
      (org-mode))
    (setq-local org-cycle-global-status 'overview)
    (org-overview)
    ;; reveal Work's immediate children (t1/t2 headings show, bodies folded)
    (mindwtr-reconcile--goto-id "a1")
    (mindwtr-reconcile-test--show-children)
    ;; user expands t1's body only; t2 stays folded
    (mindwtr-reconcile--goto-id "t1")
    (mindwtr-reconcile--show-entry)
    (let ((merged '(:tasks ((:id "t1" :title "t1" :status "next" :areaId "a1"
                             :description "body one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z")
                            (:id "t2" :title "t2" :status "next" :areaId "a1"
                             :description "body two"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-reconcile--goto-id "t1")
      (should-not (org-invisible-p (line-end-position))) ; reopened
      (mindwtr-reconcile--goto-id "t2")
      (should (org-invisible-p (line-end-position)))))) ; still folded

(ert-deftest mindwtr-reconcile-no-window-skips-scroll-anchor ()
  "R3: with no live window the scroll anchor (:top-id) is nil and reconcile
restores without attempting (or erroring on) a window scroll."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (should (null (plist-get (mindwtr-reconcile--snapshot-view) :top-id)))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (goto-char (point-min))
      (should (search-forward "* Single Actions" nil t)))))

(ert-deftest mindwtr-reconcile-restore-view-tolerates-unresolved-anchor ()
  "R4: restoring a snapshot whose :top-id and folded ids no longer resolve
after the rebuild does not throw, and the global backdrop is still applied
\(proves restore ran to completion rather than being swallowed at the start)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((view (list :folds (let ((h (make-hash-table :test 'equal)))
                               (puthash "ghost" 'folded h) h)
                      :global 'overview
                      :top-id "ghost")))
      (should (null (mindwtr-reconcile--restore-view view))) ; no throw
      (goto-char (point-min))
      (should-not (org-invisible-p (line-beginning-position))) ; container visible
      (mindwtr-reconcile--goto-id "t1")
      (should (org-invisible-p (line-beginning-position)))))) ; backdrop applied

(ert-deftest mindwtr-reconcile-restore-view-preserves-modified-flag ()
  "R5: restore touches only visual state (fold overlays), so it must not flip
`buffer-modified-p' -- folding an entry happens, yet the buffer stays clean."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n")
      (org-mode))
    (set-buffer-modified-p nil)
    (let ((view (list :folds (let ((h (make-hash-table :test 'equal)))
                               (puthash "t1" 'folded h) h)
                      :global nil :top-id nil)))
      (mindwtr-reconcile--restore-view view)
      (mindwtr-reconcile--goto-id "t1")
      (should (org-invisible-p (line-end-position))) ; the fold was applied
      (should-not (buffer-modified-p)))))            ; but the flag is untouched

(ert-deftest mindwtr-reconcile-render-error-leaves-buffer-intact ()
  "If rendering the merged appdata errors, the buffer is NOT wiped.
Regression: erase-buffer ran before insert, so a bad server status
emptied the user's file."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT keep me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((before (buffer-string))
          ;; a task with an unknown status under a project makes
          ;; mindwtr-render-appdata signal (project-subtree renders its child
          ;; tasks unconditionally, so status->keyword aborts on "bogus")
          (merged '(:areas nil :projects ((:id "p1" :title "P" :status "active"))
                    :sections nil
                    :tasks ((:id "t1" :title "x" :status "bogus" :projectId "p1"))
                    :settings nil)))
      (should-error (mindwtr-reconcile-buffer merged))
      ;; buffer content is unchanged -- nothing was erased
      (should (string= (buffer-string) before)))))

;;; Quarantine guard -- untyped/un-inferable headings (U2) -------------------

(defun mindwtr-reconcile-test--count (s)
  "Count literal occurrences of S in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0)) (while (search-forward s nil t) (setq n (1+ n))) n)))

(defconst mindwtr-reconcile-test--empty
  '(:tasks nil :projects nil :sections nil :areas nil :settings nil)
  "Merged appdata with no entities (renders only the canonical containers).")

(ert-deftest mindwtr-reconcile-quarantines-untyped-orphan ()
  "A top-level heading with no MW_TYPE and no inferable context is preserved
under a * Sync Failures container instead of being erased (R2)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray thought\n:PROPERTIES:\n:ID: xyz\n:END:\nremember this body\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray thought" nil t)))
    (should (save-excursion (goto-char (point-min)) (search-forward "remember this body" nil t)))))

(ert-deftest mindwtr-reconcile-quarantine-carries-annotation ()
  "Each quarantined heading carries a reason note so it is actionable (R2)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:ID: xyz\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (save-excursion (goto-char (point-min))
                            (search-forward "couldn't determine type" nil t)))))

(ert-deftest mindwtr-reconcile-quarantine-is-idempotent ()
  "Two reconciles with the same persistent orphan yield ONE container and ONE
copy of the orphan -- no nesting, no duplication (R3)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray thought\n:PROPERTIES:\n:ID: xyz\n:END:\nbody\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (= 1 (mindwtr-reconcile-test--count "Stray thought")))))

(ert-deftest mindwtr-reconcile-does-not-quarantine-inferable-heading ()
  "An untyped heading under a recognized container is inferable, so it is NOT
quarantined; the merged data renders it in its bucket and no container appears."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Captured\n:PROPERTIES:\n:ID: x\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "Captured" :status "inbox" :rev 1
                :createdAt "2026-06-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil :areas nil :settings nil))
    (should (= 0 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Captured" nil t)))))

(ert-deftest mindwtr-reconcile-clean-buffer-has-no-quarantine ()
  "A buffer of only typed entities reconciles with no * Sync Failures heading (R4)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1" :contexts ("@x")
                :rev 5 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil
       :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
    (should (= 0 (mindwtr-reconcile-test--count "Sync Failures")))))

(ert-deftest mindwtr-reconcile-collect-orphans-reads-current-buffer ()
  "Orphan collection reads the live buffer (so it runs before erase -- R7)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:ID: x\n:END:\nbody text\n")
      (org-mode))
    (let ((orphans (mindwtr-reconcile--collect-orphans)))
      (should (= 1 (length orphans)))
      (should (string-match-p "Stray" (car orphans)))
      (should (string-match-p "body text" (car orphans))))))

(ert-deftest mindwtr-reconcile-collect-orphans-unwraps-existing-quarantine ()
  "An existing * Sync Failures container is unwrapped: its children are
re-collected and the wrapper itself is discarded (R3, no-nesting)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Sync Failures\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: sync-failures\n:END:\n"
              "** Stray child\n:PROPERTIES:\n:ID: x\n:END:\nbody\n")
      (org-mode))
    (let ((orphans (mindwtr-reconcile--collect-orphans)))
      (should (= 1 (length orphans)))
      (should (string-match-p "Stray child" (car orphans)))
      (should-not (string-match-p "Sync Failures" (car orphans))))))

(ert-deftest mindwtr-reconcile-quarantine-excludes-typed-descendants ()
  "A typed (real) entity nested under an untyped orphan is NOT swallowed into
the quarantine text -- it round-trips via the server and renders in its bucket
exactly once, with no duplicate MW_ID."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray note\n:PROPERTIES:\n:ID: xyz\n:END:\nnote body\n"
              "** NEXT Real task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "Real task" :status "next" :rev 1
                :createdAt "2026-06-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil :areas nil :settings nil))
    ;; the orphan parent is preserved under quarantine...
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray note" nil t)))
    ;; ...but the typed task is NOT duplicated: it appears once (its bucket only)
    (should (= 1 (mindwtr-reconcile-test--count ":MW_ID: t1")))
    (should (= 1 (mindwtr-reconcile-test--count "Real task")))))

(ert-deftest mindwtr-reconcile-quarantines-blank-mw-type-orphan ()
  "A stray heading whose :MW_TYPE: value is blank (neither a real kind nor
inferable) is quarantined, not silently erased."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:MW_TYPE:\n:END:\nbody\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray" nil t)))))
