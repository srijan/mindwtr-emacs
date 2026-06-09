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
After U6 the reserved drawer fields (`:isSequential', `:reviewAt', ...) ARE
allow-listed, so this asserts the still-unmapped tail does not drift -- and that
a boolean `:isFocusedToday :false' folds to absent so a server `:false' still
signs identically to a parsed entity that omits it."
  (let ((server '(:id "1" :title "x" :status "next"
                  :isFocusedToday :false
                  :tagIds ("g1") :areaTitle "Personal"
                  :sequentialScope "all" :showFutureRecurrence :false
                  :orderNum 3 :pushCount 0))
        (parsed '(:id "1" :title "x" :status "next")))
    (should (string= (mindwtr-signature server) (mindwtr-signature parsed)))))

(ert-deftest mindwtr-signature-includes-support-notes ()
  "Covers R4.  `:supportNotes' is an allow-listed content field: a project with
notes signs differently from one without, editing the note changes the
signature, and an unedited note does not."
  (let ((with-notes '(:id "p1" :title "x" :status "active" :supportNotes "hello"))
        (without     '(:id "p1" :title "x" :status "active"))
        (edited      '(:id "p1" :title "x" :status "active" :supportNotes "hello there")))
    (should-not (string= (mindwtr-signature with-notes) (mindwtr-signature without)))
    (should-not (string= (mindwtr-signature with-notes) (mindwtr-signature edited)))
    ;; empty-string note signs the same as no note (empty == absent)
    (should (string= (mindwtr-signature without)
                     (mindwtr-signature '(:id "p1" :title "x" :status "active"
                                          :supportNotes ""))))))

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

(ert-deftest mindwtr-signature-canonical-value-folds-booleans ()
  "Covers R4 (mechanism).  A boolean field's canonical value is `t' only for a
genuine `t'; `:false' and nil fold to nil so they later drop as absent."
  (should (eq (mindwtr-signature-canonical-value :isFocusedToday t) t))
  (should (null (mindwtr-signature-canonical-value :isFocusedToday :false)))
  (should (null (mindwtr-signature-canonical-value :isFocusedToday nil)))
  (should (eq (mindwtr-signature-canonical-value :isSequential t) t))
  (should (null (mindwtr-signature-canonical-value :isFocused :false))))

(ert-deftest mindwtr-signature-canonical-value-coarsens-review-at ()
  "Covers R5 (mechanism).  :reviewAt routes through minute coarsening so
sub-minute deltas collapse to one canonical form."
  (should (string= (mindwtr-signature-canonical-value :reviewAt "2026-06-09T14:30:45Z")
                   (mindwtr-signature-canonical-value :reviewAt "2026-06-09T14:30:00.123Z")))
  ;; a different minute stays distinct
  (should-not (string= (mindwtr-signature-canonical-value :reviewAt "2026-06-09T14:30:00Z")
                       (mindwtr-signature-canonical-value :reviewAt "2026-06-09T14:31:00Z"))))

(ert-deftest mindwtr-signature-review-at-nil-not-serialized-as-null ()
  "Covers R5.  A nil :reviewAt is dropped on the wire (not emitted as null/[]),
because the server 422s on a null ISO field.  :reviewAt is a scalar, so it must
not be in `mindwtr-util-json-array-fields'."
  (should-not (memq :reviewAt mindwtr-util-json-array-fields))
  (let ((json (mindwtr-util-json-encode '(:id "t1" :reviewAt nil :title "x"))))
    (should-not (string-match-p "reviewAt" json))))

(ert-deftest mindwtr-signature-boolean-false-absent-true-collapse ()
  "Covers R4 end-to-end (post-promotion).  Through the FULL signature: a boolean
`:false' and an absent key sign identically, and a genuine `t' signs distinctly
\(so a :false->t flip classifies as a change)."
  (let ((false-e '(:id "t1" :title "x" :status "next" :isFocusedToday :false))
        (absent-e '(:id "t1" :title "x" :status "next"))
        (true-e '(:id "t1" :title "x" :status "next" :isFocusedToday t)))
    (should (string= (mindwtr-signature false-e) (mindwtr-signature absent-e)))
    (should-not (string= (mindwtr-signature true-e) (mindwtr-signature false-e)))
    (should-not (string= (mindwtr-signature true-e) (mindwtr-signature absent-e)))))

(ert-deftest mindwtr-signature-review-at-collapse-and-coarsen ()
  "Covers R5 end-to-end (post-promotion).  Through the FULL signature: a nil/
absent :reviewAt signs as absent, and sub-minute deltas collapse to one form."
  (let ((with-rev '(:id "t1" :title "x" :status "next" :reviewAt "2026-06-09T14:30:45Z"))
        (with-rev2 '(:id "t1" :title "x" :status "next" :reviewAt "2026-06-09T14:30:00Z"))
        (without '(:id "t1" :title "x" :status "next"))
        (nil-rev '(:id "t1" :title "x" :status "next" :reviewAt nil)))
    (should (string= (mindwtr-signature with-rev) (mindwtr-signature with-rev2)))
    (should (string= (mindwtr-signature without) (mindwtr-signature nil-rev)))
    (should-not (string= (mindwtr-signature with-rev) (mindwtr-signature without)))))
