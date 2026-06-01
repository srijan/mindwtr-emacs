;;; mindwtr-util-test.el --- Tests for mindwtr-util -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-util)

(ert-deftest mindwtr-util-loads ()
  "The util library provides its feature."
  (should (featurep 'mindwtr-util)))

(ert-deftest mindwtr-util-uuid-format ()
  (let ((id (mindwtr-util-uuid)))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
             id))
    (should-not (string= id (mindwtr-util-uuid)))))

(ert-deftest mindwtr-util-iso-to-org-and-back ()
  (let ((iso "2026-01-01T10:00:00.000Z"))
    (let* ((org (mindwtr-util-iso->org iso))
           (back (mindwtr-util-org->iso org)))
      (should (string-prefix-p "[" org))
      (should (string-suffix-p "]" org))
      (should (string= (mindwtr-util-iso-normalize back)
                       (mindwtr-util-iso-normalize iso))))))

(ert-deftest mindwtr-util-iso-normalize-truncates-millis ()
  (should (string= (mindwtr-util-iso-normalize "2026-01-01T10:00:00.500Z")
                   "2026-01-01T10:00:00Z")))

(ert-deftest mindwtr-util-json-roundtrip-plist ()
  (let* ((obj '(:id "x" :n 3 :flag t :off :false :tags ("a" "b")))
         (s (mindwtr-util-json-encode obj))
         (back (mindwtr-util-json-decode s)))
    (should (string= (plist-get back :id) "x"))
    (should (= (plist-get back :n) 3))
    (should (eq (plist-get back :flag) t))
    (should (eq (plist-get back :off) :false))
    (should (equal (plist-get back :tags) '("a" "b")))))

(ert-deftest mindwtr-util-atomic-write-and-read ()
  (let ((f (make-temp-file "mw-atomic")))
    (unwind-protect
        (progn
          (mindwtr-util-atomic-write f "hello")
          (should (string= (mindwtr-util-read-file f) "hello")))
      (delete-file f))))
