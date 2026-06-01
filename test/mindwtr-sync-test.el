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
