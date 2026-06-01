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

(ert-deftest mindwtr-signature-ignores-unmapped-server-fields ()
  "Allow-list: server fields we do not map to org never affect the signature.
Regression for live drift where `:isFocusedToday :false' (and the rest of
the unmodeled field tail) diverged from a parsed entity that omits them."
  (let ((server '(:id "1" :title "x" :status "next"
                  :isFocusedToday :false :isSequential t :supportNotes "s"
                  :tagIds ("g1") :areaTitle "Personal" :reviewAt "2026-01-01"
                  :orderNum 3 :pushCount 0 :showFutureRecurrence :false))
        (parsed '(:id "1" :title "x" :status "next")))
    (should (string= (mindwtr-signature server) (mindwtr-signature parsed)))))

(ert-deftest mindwtr-signature-coarsens-sub-minute-datetimes ()
  "Datetimes differing only below the minute sign identically.
Org timestamps are minute-precision, so seconds must not drive change
detection."
  (let ((a '(:id "1" :title "x" :status "next" :startTime "2026-02-09T14:30:45Z"))
        (b '(:id "1" :title "x" :status "next" :startTime "2026-02-09T14:30:00Z")))
    (should (string= (mindwtr-signature a) (mindwtr-signature b))))
  ;; but a different minute is still a change
  (let ((a '(:id "1" :title "x" :status "next" :startTime "2026-02-09T14:30:00Z"))
        (b '(:id "1" :title "x" :status "next" :startTime "2026-02-09T14:31:00Z")))
    (should-not (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-checklist-ignores-item-id ()
  "Checklist items signing must ignore the server-assigned :id."
  (let ((a '(:id "1" :title "x" :status "next"
             :checklist ((:id "c1" :title "a" :isCompleted t))))
        (b '(:id "1" :title "x" :status "next"
             :checklist ((:title "a" :isCompleted t)))))
    (should (string= (mindwtr-signature a) (mindwtr-signature b))))
  ;; but a flipped completion is a real change
  (let ((a '(:id "1" :title "x" :status "next"
             :checklist ((:title "a" :isCompleted t))))
        (b '(:id "1" :title "x" :status "next"
             :checklist ((:title "a" :isCompleted :false)))))
    (should-not (string= (mindwtr-signature a) (mindwtr-signature b)))))
