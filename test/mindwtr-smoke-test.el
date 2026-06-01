;;; mindwtr-smoke-test.el --- Tests for the live smoke suite -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-smoke)

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
