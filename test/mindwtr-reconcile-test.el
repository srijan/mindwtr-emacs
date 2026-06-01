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
