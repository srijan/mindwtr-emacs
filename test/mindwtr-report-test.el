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
