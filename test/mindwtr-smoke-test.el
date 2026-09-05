;;; mindwtr-smoke-test.el --- Tests for the live smoke suite -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-smoke)
(require 'mindwtr-test-helpers)

(ert-deftest mindwtr-smoke-summary-exit-code ()
  "Summary returns non-zero exactly when a fail was recorded."
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-warn "b")
  (should (= 0 (mindwtr-smoke-summary)))
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-fail "c")
  (should (= 1 (mindwtr-smoke-summary)))
  ;; warn alone never fails the run
  (mindwtr-smoke-reset)
  (mindwtr-smoke-warn "only a warning")
  (should (= 0 (mindwtr-smoke-summary))))

(ert-deftest mindwtr-smoke-plist-keys-and-same-p ()
  (should (equal (sort (mindwtr-smoke-plist-keys '(:a 1 :b 2)) #'string<)
                 '(:a :b)))
  (should (mindwtr-smoke-plist-same-p '(:a 1 :b 2) '(:b 2 :a 1)))
  (should-not (mindwtr-smoke-plist-same-p '(:a 1) '(:a 2)))
  (should-not (mindwtr-smoke-plist-same-p '(:a 1 :b 2) '(:a 1))))

(ert-deftest mindwtr-smoke-find-and-index ()
  (let ((ad '(:tasks ((:id "t1" :title "x") (:id "t2" :deletedAt "Z"))
              :projects ((:id "p1")) :sections nil :areas nil)))
    (should (string= (plist-get (mindwtr-smoke-find-by-id ad "t1") :title) "x"))
    (should (mindwtr-smoke-find-by-id ad "p1"))
    (should-not (mindwtr-smoke-find-by-id ad "nope"))
    ;; live index excludes tombstones
    (let ((idx (mindwtr-smoke-index-by-id ad t)))
      (should (gethash "t1" idx))
      (should-not (gethash "t2" idx)))))

(ert-deftest mindwtr-smoke-blast-radius-detects-only-changes ()
  (let ((prior '(:tasks ((:id "t1" :title "a" :rev 1)
                         (:id "t2" :title "b" :rev 1))
                 :projects nil :sections nil :areas nil)))
    ;; no change
    (should (null (mindwtr-smoke-blast-radius prior prior)))
    ;; update t1
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "A" :rev 2)
                              (:id "t2" :title "b" :rev 1))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t1")))
    ;; create t3
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "a" :rev 1)
                              (:id "t2" :title "b" :rev 1)
                              (:id "t3" :title "c" :rev 1))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t3")))
    ;; tombstone t2 (live -> deleted)
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "a" :rev 1)
                              (:id "t2" :title "b" :rev 2 :deletedAt "Z"))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t2")))))

(ert-deftest mindwtr-smoke-canonical-field-diff-reports-changed-fields ()
  "The canonical diff names a content field that differs and skips equal ones."
  (let ((lines (mindwtr-smoke-canonical-field-diff
                '(:title "old" :status "next")
                '(:title "new" :status "next"))))
    (should (seq-some (lambda (s) (string-match-p ":title" s)) lines))
    (should-not (seq-some (lambda (s) (string-match-p ":status" s)) lines))))

(ert-deftest mindwtr-smoke-key-diff-reports-differing-keys ()
  (let ((lines (mindwtr-smoke-key-diff '(:a 1 :b 2) '(:a 1 :b 9 :c 3))))
    (should (seq-some (lambda (s) (string-match-p ":b" s)) lines))
    (should (seq-some (lambda (s) (string-match-p ":c" s)) lines))
    (should-not (seq-some (lambda (s) (string-match-p ":a" s)) lines))))

(ert-deftest mindwtr-smoke-schema-coverage-flags-unknown-and-unexercised ()
  "Unknown wire keys land in :unknown; known-but-absent keys in :unexercised."
  (let* ((ad '(:tasks ((:id "t1" :title "x" :status "next" :aiSummary "hi"))
               :projects nil :sections nil :areas nil))
         (cov (mindwtr-smoke-schema-coverage ad))
         (task (cdr (assq 'task cov))))
    (should (memq :aiSummary (plist-get task :unknown)))
    ;; a known task field not present on any task is unexercised, not unknown
    (should (memq :location (plist-get task :unexercised)))
    (should-not (memq :location (plist-get task :unknown)))
    ;; types with no entities report empty unknown
    (should (null (plist-get (cdr (assq 'area cov)) :unknown)))))

(ert-deftest mindwtr-smoke-phase-schema-coverage-warns-not-fails ()
  "An unknown key produces a WARN, never a FAIL."
  (mindwtr-smoke-reset)
  (mindwtr-smoke-phase-schema-coverage
   '(:tasks ((:id "t1" :title "x" :status "next" :aiSummary "hi"))
     :projects nil :sections nil :areas nil))
  (should (> (plist-get mindwtr-smoke--counts :warn) 0))
  (should (= 0 (plist-get mindwtr-smoke--counts :fail))))

(defconst mindwtr-smoke-test--initial
  '(:tasks ((:id "t-keep" :title "keep me" :status "next" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"
             :contexts ("@computer") :tags nil :areaId "a-work")
            (:id "t-child" :title "child task" :status "next" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"
             :projectId "p-1" :contexts nil :tags nil))
    :projects ((:id "p-1" :title "Some Project" :status "active" :areaId "a-work"
                :rev 1 :createdAt "2026-01-01T00:00:00Z"
                :updatedAt "2026-01-01T00:00:00Z"))
    :sections nil
    :areas ((:id "a-work" :name "Work" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"))
    :settings nil)
  "A minimal but valid server snapshot for offline phase tests.
Exercises the new GTD-list layout: a standalone task carrying an area
\(round-tripped via `:CATEGORY:'), an active project in that area, and a
task nested under the project (`:projectId' round-tripped via nesting).")

(ert-deftest mindwtr-smoke-readonly-phases-pass-on-clean-data ()
  (let* ((mindwtr-api-base-url "https://mock/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (mindwtr-test-server-http (mindwtr-test-server mindwtr-smoke-test--initial))))
    (mindwtr-smoke-reset)
    (should (mindwtr-smoke-phase-connectivity))
    (let ((ad (mindwtr-smoke-phase-snapshot)))
      (should ad)
      (mindwtr-smoke-phase-roundtrip ad))
    ;; clean data: no failures across connectivity + snapshot + round-trip
    (should (= 0 (plist-get mindwtr-smoke--counts :fail)))))

(ert-deftest mindwtr-smoke-write-lifecycle-end-to-end ()
  "The lifecycle creates, mutates, transitions, and deletes a task with no
failures, leaving every pre-existing entity untouched."
  (let* ((mindwtr-api-base-url "https://mock/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (mindwtr-test-server-http (mindwtr-test-server mindwtr-smoke-test--initial))))
    (mindwtr-smoke-reset)
    (mindwtr-smoke-phase-write-lifecycle)
    (should (= 0 (plist-get mindwtr-smoke--counts :fail)))
    (let* ((final (plist-get (mindwtr-api-get-data) :appdata))
           (smoke (seq-find
                   (lambda (tk) (string-prefix-p
                                 "[mw-smoke]" (or (plist-get tk :title) "")))
                   (plist-get final :tasks)))
           (keep (mindwtr-smoke-find-by-id final "t-keep")))
      ;; the smoke task is gone or tombstoned
      (should (or (null smoke) (plist-get smoke :deletedAt)))
      ;; the pre-existing task survived unchanged
      (should keep)
      (should (string= (plist-get keep :title) "keep me"))
      (should-not (plist-get keep :deletedAt)))))
