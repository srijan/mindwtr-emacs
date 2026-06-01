;;; mindwtr-signature-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-signature)

(ert-deftest mindwtr-signature-ignores-shadow-and-mirror-fields ()
  (let ((a '(:id "1" :title "x" :status "next" :rev 5 :updatedAt "A" :color "#fff"))
        (b '(:id "1" :title "x" :status "next" :rev 9 :updatedAt "B" :color "#000")))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-detects-editable-change ()
  (let ((a '(:id "1" :title "x" :status "next"))
        (b '(:id "1" :title "x" :status "done")))
    (should-not (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-order-insensitive-for-plist ()
  (let ((a '(:id "1" :title "x" :status "next"))
        (b '(:status "next" :title "x" :id "1")))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-order-insensitive-for-list-fields ()
  ;; tags/contexts are sets — order must not matter.
  (let ((a '(:id "1" :title "x" :status "next" :tags ("a" "b")))
        (b '(:id "1" :title "x" :status "next" :tags ("b" "a"))))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))
