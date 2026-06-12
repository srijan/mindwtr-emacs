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

(defun mindwtr-report-test--count-headings ()
  "Return the number of top-level `* ' sync headings in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward "^\\* " nil t) (setq n (1+ n)))
      n)))

(ert-deftest mindwtr-report-renders-incoming-line ()
  "Covers AE1.  An incoming change renders one per-entity line under the
incoming-from-remote section."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 0 :deleted 0)
              nil nil nil nil nil
              '((:id "t1" :kind task :title "Renamed on phone" :change updated)))))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "Incoming from remote:" nil t))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward "↓ Renamed on phone (task) — updated" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-incoming-updated-renders-field-diff ()
  "An incoming `updated' entry with differing :before/:after emits one indented
field-diff line per changed content field."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 0 :deleted 0)
              nil nil nil nil nil
              '((:id "t1" :kind task :title "Task A" :change updated
                 :before (:id "t1" :title "Task A" :status "next")
                 :after  (:id "t1" :title "Task A" :status "done"))))))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "↓ Task A (task) — updated" nil t))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward "status: next → done" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-incoming-updated-identical-content-no-diff-lines ()
  "An incoming `updated' entry whose :before/:after content fields are identical
(only non-content fields differ) emits no field-diff lines."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 0 :deleted 0)
              nil nil nil nil nil
              '((:id "t1" :kind task :title "Task A" :change updated
                 :before (:id "t1" :title "Task A" :status "next" :rev 1)
                 :after  (:id "t1" :title "Task A" :status "next" :rev 2))))))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "↓ Task A (task) — updated" nil t))
          (should-not (save-excursion
                        (goto-char (point-min))
                        (search-forward "rev:" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-local-changes-renders-proposed-list ()
  "When local-changes is non-nil the report lists each proposed entity with ↑
arrows after the Proposed count line; updated entries show a field diff."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show
              '(:created 1 :updated 1 :deleted 1)
              nil nil nil nil nil nil nil
              '((:id "t1" :kind task :title "New one" :change created)
                (:id "t2" :kind task :title "Edited" :change updated
                 :before (:id "t2" :title "Edited" :status "next")
                 :after  (:id "t2" :title "Edited" :status "done"))
                (:id "t3" :kind task :title "Gone" :change deleted)))))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "↑ New one (task) — created" nil t))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward "↑ Edited (task) — updated" nil t)))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward "status: next → done" nil t)))
          (should (save-excursion (goto-char (point-min))
                                  (search-forward "↑ Gone (task) — deleted" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-nil-local-changes-no-extra-output ()
  "When local-changes is nil the report omits the proposed-list section."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show
              '(:created 0 :updated 1 :deleted 0)
              nil nil nil nil nil nil nil nil)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should-not (search-forward "↑" nil t)))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-appends-rather-than-replaces ()
  "Covers AE5 / R5.  Two reportable syncs produce two timestamped top-level
headings in one buffer, not a replaced single entry."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let (buf)
    (unwind-protect
        (progn
          (mindwtr-report-show '(:created 1 :updated 0 :deleted 0) nil nil
                               nil nil nil nil "sync-one")
          (setq buf (mindwtr-report-show '(:created 0 :updated 1 :deleted 0) nil nil
                                         nil nil nil nil "sync-two"))
          (with-current-buffer buf
            (should (= (mindwtr-report-test--count-headings) 2))
            (goto-char (point-min))
            (should (search-forward "* sync-one" nil t))
            (should (search-forward "* sync-two" nil t))))
      (when buf (kill-buffer buf)))))

(ert-deftest mindwtr-report-restore-live-only-on-newest-entry ()
  "Covers AE5 / R8.  After a second append carrying a conflict, the first
entry's conflict block no longer carries `mindwtr-conflict'; the newest does."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let (buf)
    (unwind-protect
        (progn
          (mindwtr-report-show
           '(:created 0 :updated 0 :deleted 0)
           '((:id "old1" :kind task :mine (:title "A") :theirs (:title "B")))
           nil nil nil nil nil "sync-one")
          (setq buf (mindwtr-report-show
                     '(:created 0 :updated 0 :deleted 0)
                     '((:id "new2" :kind task :mine (:title "C") :theirs (:title "D")))
                     nil nil nil nil nil "sync-two"))
          (with-current-buffer buf
            ;; The older entry's conflict block has been de-tagged.
            (goto-char (point-min))
            (should (search-forward "old1" nil t))
            (should (null (get-text-property (point) 'mindwtr-conflict)))
            ;; Pressing `r' there hits the not-on-a-conflict guard.
            (should-error (mindwtr-report-restore-conflict) :type 'user-error)
            ;; The newest entry's conflict block is still actionable.
            (goto-char (point-min))
            (should (search-forward "new2" nil t))
            (should (get-text-property (point) 'mindwtr-conflict))))
      (when buf (kill-buffer buf)))))

(ert-deftest mindwtr-report-no-heading-when-nothing-reportable ()
  "Covers R6.  A sync with no proposed/incoming/conflict/skew/warning content
appends no heading."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((buf (mindwtr-report-show '(:created 0 :updated 0 :deleted 0)
                                  nil nil nil nil nil nil "quiet")))
    (unwind-protect
        (with-current-buffer buf
          (should (= (mindwtr-report-test--count-headings) 0))
          (should (= (buffer-size) 0)))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-fresh-log-after-buffer-killed ()
  "Covers R7.  Killing the report buffer starts a fresh log (one entry, fresh
title header) on the next sync rather than resurrecting prior history."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let ((first (mindwtr-report-show '(:created 1 :updated 0 :deleted 0) nil nil
                                    nil nil nil nil "sync-one")))
    (kill-buffer first))
  (let ((buf (mindwtr-report-show '(:created 0 :updated 1 :deleted 0) nil nil
                                  nil nil nil nil "sync-two")))
    (unwind-protect
        (with-current-buffer buf
          (should (= (mindwtr-report-test--count-headings) 1))
          (goto-char (point-min))
          (should (search-forward "* sync-two" nil t))
          (should-not (save-excursion (goto-char (point-min))
                                      (search-forward "* sync-one" nil t))))
      (kill-buffer buf))))

(ert-deftest mindwtr-report-incoming-appends-quietly-conflict-pops ()
  "An incoming-only sync does not pop a window; a sync with a conflict does."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let (popped buf)
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (b &rest _) (setq popped t) (get-buffer-window b))))
      (unwind-protect
          (progn
            ;; Incoming-only: quiet.
            (setq popped nil)
            (setq buf (mindwtr-report-show
                       '(:created 0 :updated 0 :deleted 0) nil nil nil nil nil
                       '((:id "t1" :kind task :title "x" :change updated))
                       "sync-one"))
            (should-not popped)
            ;; Conflict: pops.
            (setq popped nil)
            (mindwtr-report-show
             '(:created 0 :updated 0 :deleted 0)
             '((:id "t1" :kind task :mine (:title "A") :theirs (:title "B")))
             nil nil nil nil nil "sync-two")
            (should popped))
        (when buf (kill-buffer buf))))))

(ert-deftest mindwtr-report-actionable-pop-points-at-newest-entry ()
  "Covers R9.  On an actionable pop, point lands on the newest sync entry."
  (when (get-buffer "*Mindwtr Sync Report*")
    (kill-buffer "*Mindwtr Sync Report*"))
  (let (buf)
    (unwind-protect
        (progn
          (mindwtr-report-show '(:created 1 :updated 0 :deleted 0) nil nil
                               nil nil nil nil "sync-one")
          (setq buf (mindwtr-report-show
                     '(:created 0 :updated 0 :deleted 0)
                     '((:id "t1" :kind task :mine (:title "A") :theirs (:title "B")))
                     nil nil nil nil nil "sync-two"))
          (with-current-buffer buf
            (should (looking-at-p "\\* sync-two"))))
      (when buf (kill-buffer buf)))))

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
