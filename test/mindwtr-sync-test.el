;;; mindwtr-sync-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-sync)

(ert-deftest mindwtr-sync-build-candidate-create ()
  "A task absent from the shadow becomes a create: rev 1, gets id+createdAt."
  (let* ((local '(:tasks ((:id nil :mw-kind task :title "new" :status "next"))
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (stringp (plist-get task :id)))
    (should (= (plist-get task :rev) 1))
    (should (string= (plist-get task :createdAt) "2026-06-01T00:00:00Z"))
    (should (string= (plist-get task :revBy) "dev-1"))))

(ert-deftest mindwtr-sync-build-candidate-unchanged-echoes-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :revBy "phone" :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 7))
    (should (string= (plist-get task :revBy) "phone"))
    (should (string= (plist-get task :updatedAt) "U"))))

(ert-deftest mindwtr-sync-build-candidate-update-bumps-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "CHANGED" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 8))
    (should (string= (plist-get task :updatedAt) "NOW"))
    (should (string= (plist-get task :revBy) "dev-1"))
    (should (string= (plist-get task :createdAt) "C"))))

(ert-deftest mindwtr-sync-build-candidate-delete-tombstones ()
  "A task in the shadow but absent from local becomes a tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :createdAt "C"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :deletedAt) "NOW"))
    (should (= (plist-get task :rev) 4))))

(ert-deftest mindwtr-sync-unchanged-preserves-full-fidelity ()
  "An unchanged entity echoes the shadow: checklist item ids and sub-minute
timestamps survive, even though the lossy org parse dropped them."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 4
                                       :createdAt "C" :updatedAt "U"
                                       :startTime "2026-02-09T14:30:45.500Z"
                                       :isFocusedToday :false
                                       :checklist ((:id "c1" :title "a" :isCompleted t)
                                                   (:id "c2" :title "b" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         ;; what parse would yield from the rendered org: no item ids, minute ts
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :startTime "2026-02-09T14:30:00Z"
                                      :checklist ((:title "a" :isCompleted t)
                                                  (:title "b" :isCompleted :false))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 4))                      ; not bumped
    (should (string= (plist-get task :startTime) "2026-02-09T14:30:45.500Z"))
    (should (string= (plist-get (nth 0 (plist-get task :checklist)) :id) "c1"))
    (should (eq (plist-get task :isFocusedToday) :false))))   ; unmapped field kept

(ert-deftest mindwtr-sync-update-preserves-untouched-fields ()
  "Editing one field (title) must not strip checklist ids or coarsen the
timestamp of fields the user did not change."
  (let* ((shadow '(:tasks ((:id "t1" :title "old" :status "next" :rev 4
                            :createdAt "C"
                            :startTime "2026-02-09T14:30:45.500Z"
                            :checklist ((:id "c1" :title "a" :isCompleted t)))
                           )
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "new" :status "next"
                                      :startTime "2026-02-09T14:30:00Z"
                                      :checklist ((:title "a" :isCompleted t))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :title) "new"))          ; the real change
    (should (= (plist-get task :rev) 5))                      ; bumped
    (should (string= (plist-get task :startTime) "2026-02-09T14:30:45.500Z"))
    (should (string= (plist-get (car (plist-get task :checklist)) :id) "c1"))))

(ert-deftest mindwtr-sync-update-adopts-genuine-checklist-change ()
  "When the checklist content actually changes, the new value is taken."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                       :checklist ((:id "c1" :title "a" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :checklist ((:title "a" :isCompleted t))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (item (car (plist-get (car (plist-get cand :tasks)) :checklist))))
    (should (eq (plist-get item :isCompleted) t))             ; flipped
    (should (null (plist-get item :id)))))                    ; org can't carry it

(ert-deftest mindwtr-sync-update-clears-emptied-field ()
  "Clearing a field in org (e.g. deleting the description) clears it on write."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 1
                            :description "had notes"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :description ""))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-member task :description)))))

(ert-deftest mindwtr-sync-candidate-carries-settings-verbatim ()
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :settings (:theme "dark" :gtd (:x 1))))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW")))
    (should (equal (plist-get cand :settings) '(:theme "dark" :gtd (:x 1))))))

(ert-deftest mindwtr-sync-candidate-strips-device-local-fields ()
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                      :createdAt "C" :localStatus "dirty"))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-member task :localStatus)))))

(require 'mindwtr-api)
(require 'mindwtr-reconcile)

(ert-deftest mindwtr-sync-once-end-to-end ()
  "A local edit is PUT, merged result is reconciled, shadow updated."
  (let* ((dir (make-temp-file "mw-e2e" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2"))
                           :body put-body))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get result :ok))
            (should (string-match-p "do it" put-body))
            (let ((task (car (plist-get (mindwtr-shadow-load) :tasks))))
              (should (string= (plist-get task :title) "do it")))))
      (delete-directory dir t))))
