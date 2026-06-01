;;; mindwtr-render-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-render)

(ert-deftest mindwtr-render-task-heading ()
  (let* ((task '(:id "t1" :mw-kind task :title "Buy milk" :status "next"
                 :priority "high" :contexts ("@errands") :tags ("#focused")
                 :energyLevel "medium" :description "notes"
                 :mw-extra-props nil))
         (shadow '(:createdAt "2026-01-01T10:00:00Z"
                   :updatedAt "2026-05-30T15:30:00Z"))
         (text (mindwtr-render-heading task 4 shadow)))
    ;; Org syntax requires the TODO keyword before the priority cookie:
    ;; `STARS KEYWORD [#PRIORITY] TITLE'.  This is the only order org can
    ;; parse back, so render must emit it this way.
    (should (string-match-p "^\\*\\*\\*\\* NEXT \\[#B\\] Buy milk" text))
    (should (string-match-p ":@errands:focused:" text))
    (should (string-match-p ":MW_TYPE: task" text))
    (should (string-match-p ":MW_ID: t1" text))
    (should (string-match-p ":MW_ENERGY: medium" text))
    (should (string-match-p ":MW_CREATED: \\[2026-01-01" text))
    (should (string-match-p "^notes$" text))))

(ert-deftest mindwtr-render-date-only-scheduled ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :startTime "2026-06-20" :mw-extra-props nil) 2 nil)))
    (should (string-match-p "SCHEDULED: <2026-06-20 Sat>" text))))

(ert-deftest mindwtr-render-closed-from-completedAt ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "done"
                 :completedAt "2026-05-31T17:39:53.268Z" :mw-extra-props nil) 2 nil)))
    (should (string-match-p "CLOSED: \\[2026-05-31" text))))

(ert-deftest mindwtr-render-area-no-keyword ()
  (let ((text (mindwtr-render-heading
               '(:id "a1" :mw-kind area :name "Work" :mw-extra-props nil) 1 nil)))
    (should (string-match-p "^\\* Work" text))
    (should (string-match-p ":MW_TYPE: area" text))))
