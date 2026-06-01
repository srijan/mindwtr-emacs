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

(ert-deftest mindwtr-render-recurrence-is-readable ()
  "Recurrence renders as the rrule/rule string, not a Lisp sexp."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :recurrence (:rule "monthly" :strategy "strict" :rrule "FREQ=MONTHLY"))
               1 nil)))
    (should (string-match-p ":MW_RECURRENCE: FREQ=MONTHLY" text))
    (should-not (string-match-p ":rule" text))
    (should-not (string-match-p ":strategy" text))))

(ert-deftest mindwtr-render-recurrence-rule-fallback ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :recurrence (:rule "weekly"))
               1 nil)))
    (should (string-match-p ":MW_RECURRENCE: weekly" text))))

(ert-deftest mindwtr-render-emits-area-name-from-map ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (puthash "a1" "Personal" mindwtr-render-area-names)
    (let ((text (mindwtr-render-heading
                 '(:id "p1" :mw-kind project :title "Proj" :status "active" :areaId "a1")
                 2 nil)))
      (should (string-match-p ":MW_AREA: Personal" text))
      (should-not (string-match-p ":MW_AREA_ID:" text)))))

(ert-deftest mindwtr-render-no-area-when-absent ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (let ((text (mindwtr-render-heading
                 '(:id "t1" :mw-kind task :title "x" :status "next") 2 nil)))
      (should-not (string-match-p ":MW_AREA:" text)))))

(ert-deftest mindwtr-render-appdata-builds-lists ()
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0))
               :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1" :order 0))
               :sections nil
               :tasks ((:id "t1" :title "loose next" :status "next" :order 0)
                       (:id "t2" :title "in project" :status "next" :projectId "p1" :order 0)
                       (:id "t3" :title "old captured" :status "inbox")
                       (:id "t4" :title "gone" :status "archived")
                       (:id "t5" :title "deleted" :status "next" :deletedAt "2026-01-01T00:00:00Z"))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    ;; containers exist in order
    (should (string-match-p "^\\* Inbox$" text))
    (should (string-match-p "^\\* Next Actions$" text))
    (should (string-match-p "^\\* Projects$" text))
    (should (string-match-p "^\\* Areas of Focus$" text))
    ;; standalone next under Next Actions; project task NOT a standalone
    (should (string-match-p "loose next" text))
    ;; inbox task under Inbox
    (should (string-match-p "old captured" text))
    ;; project + nested task
    (should (string-match-p "Proj" text))
    (should (string-match-p "in project" text))
    ;; project carries area name
    (should (string-match-p ":MW_AREA: Personal" text))
    ;; archived + tombstoned tasks NOT rendered
    (should-not (string-match-p "gone" text))
    (should-not (string-match-p "deleted" text))
    ;; area entity under Areas of Focus
    (should (string-match-p "^\\*\\* Personal$" text))))

(ert-deftest mindwtr-render-appdata-orders-and-groups ()
  "Standalone tasks sort by :order; projects group by area :order then :order."
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0)
                       (:id "a2" :name "Work" :order 1))
               :projects ((:id "p2" :title "WorkProj" :status "active" :areaId "a2" :order 0)
                          (:id "p1" :title "PersA" :status "active" :areaId "a1" :order 1)
                          (:id "p0" :title "PersB" :status "active" :areaId "a1" :order 0)
                          (:id "p9" :title "Floating" :status "active" :order 0))
               :sections nil
               :tasks ((:id "t1" :title "second" :status "next" :order 1)
                       (:id "t2" :title "first" :status "next" :order 0))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    ;; tasks ordered
    (should (< (string-match "first" text) (string-match "second" text)))
    ;; projects: Personal area (order 0) group before Work; within Personal, order 0 (PersB) before order 1 (PersA); area-less Floating last
    (should (< (string-match "PersB" text) (string-match "PersA" text)))
    (should (< (string-match "PersA" text) (string-match "WorkProj" text)))
    (should (< (string-match "WorkProj" text) (string-match "Floating" text)))))
