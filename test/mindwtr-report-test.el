;;; mindwtr-report-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-sync)
(require 'mindwtr-report)

(ert-deftest mindwtr-sync-detect-conflicts-finds-lost-edit ()
  "A locally-changed task whose merged result differs is a lost edit."
  (let* ((candidate '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8
                               :revBy "dev-1"))
                      :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "THEIRS" :status "next" :rev 9
                            :revBy "phone"))
                   :projects nil :sections nil :areas nil))
         (changed-ids '("t1"))
         (conflicts (mindwtr-sync-detect-conflicts candidate merged changed-ids)))
    (should (= (length conflicts) 1))
    (let ((c (car conflicts)))
      (should (string= (plist-get c :id) "t1"))
      (should (string= (plist-get (plist-get c :mine) :title) "MINE"))
      (should (string= (plist-get (plist-get c :theirs) :title) "THEIRS")))))

(ert-deftest mindwtr-sync-detect-conflicts-ignores-accepted-edit ()
  (let* ((candidate '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8))
                      :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8))
                   :projects nil :sections nil :areas nil)))
    (should (null (mindwtr-sync-detect-conflicts candidate merged '("t1"))))))

(ert-deftest mindwtr-report-renders-buffer ()
  (let ((buf (mindwtr-report-show
              '(:created 2 :updated 1 :deleted 0)
              '((:id "t1" :mine (:title "MINE") :theirs (:title "THEIRS")))
              nil)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "Created: 2" nil t))
          (should (search-forward "t1" nil t))
          (should (search-forward "MINE" nil t)))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-field-diff-lists-differing-content-fields ()
  "The diff names only content fields that differ, ignoring equal ones."
  (let ((d (mindwtr-report--field-diff
            '(:title "a" :priority "high" :status "next")
            '(:title "b" :priority "high" :status "next"))))
    (should (= (length d) 1))
    (should (eq (car (car d)) :title))))

(ert-deftest mindwtr-report-field-diff-includes-support-notes ()
  "Covers R11 / AE4.  Now that :supportNotes is an allow-listed content field, a
server-overridden project note appears in the override report's field diff."
  (let ((d (mindwtr-report--field-diff
            '(:title "Proj" :status "active" :supportNotes "my local note")
            '(:title "Proj" :status "active" :supportNotes "server note"))))
    (should (= (length d) 1))
    (should (eq (car (car d)) :supportNotes))
    (should (string= (nth 1 (car d)) "my local note"))
    (should (string= (nth 2 (car d)) "server note"))))

(ert-deftest mindwtr-report-field-diff-ignores-noncontent-and-empty ()
  "Equal-after-canonicalization values (e.g. tag order) and rev/updatedAt
\(non-content) do not appear in the diff."
  (let ((d (mindwtr-report--field-diff
            '(:title "a" :tags ("#b" "#a") :rev 8 :updatedAt "X")
            '(:title "a" :tags ("#a" "#b") :rev 9 :updatedAt "Y"))))
    (should (null d))))

(ert-deftest mindwtr-report-shows-field-diff-and-backup ()
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 1 :deleted 0)
              '((:id "t1" :kind task
                 :mine (:id "t1" :title "MINE" :priority "high")
                 :theirs (:id "t1" :title "THEIRS" :priority "low")))
              "clock off by 5m"
              "/tmp/mindwtr/backups/mindwtr-x.org")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "clock off by 5m" nil t))
          (should (search-forward "title" nil t))
          (should (save-excursion (search-forward "MINE" nil t)))
          (should (save-excursion (search-forward "THEIRS" nil t)))
          (should (save-excursion (goto-char (point-min)) (search-forward "priority" nil t)))
          (should (save-excursion (goto-char (point-min)) (search-forward "mindwtr-x.org" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-restore-reapplies-local-edit ()
  "Pressing restore on a conflict re-applies the local (mine) version into
the synced buffer so the next sync will push it."
  (require 'mindwtr-reconcile)
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT theirs version\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let* ((target (current-buffer))
           (mine '(:id "t1" :title "mine again" :status "next" :areaId "a1"
                   :rev 9 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
           (report (mindwtr-report-show
                    '(:created 0 :updated 0 :deleted 0)
                    (list (list :id "t1" :kind 'task :mine mine
                                :theirs '(:id "t1" :title "theirs version")))
                    nil nil target)))
      (unwind-protect
          (progn
            (with-current-buffer report
              (goto-char (point-min))
              (search-forward "t1")
              (mindwtr-report-restore-conflict))
            (with-current-buffer target
              (goto-char (point-min))
              (should (search-forward "mine again" nil t))
              (should-not (save-excursion (search-forward "theirs version" nil t)))))
        (kill-buffer report)))))

(ert-deftest mindwtr-report-shows-parse-warnings ()
  "Type-invalid keyword warnings are surfaced in the report buffer."
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 0 :deleted 0)
              nil nil nil nil
              '((:id "p1" :title "Build the deck" :keyword "NEXT" :kind project)))))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "invalid status keyword" nil t))
          (should (save-excursion (goto-char (point-min)) (search-forward "Build the deck" nil t)))
          (should (save-excursion (goto-char (point-min)) (search-forward "NEXT" nil t)))
          (should (save-excursion (goto-char (point-min)) (search-forward "p1" nil t))))
      (kill-buffer buf))))
