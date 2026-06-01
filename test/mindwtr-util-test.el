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

(ert-deftest mindwtr-util-json-prep-omits-nil-scalars-keeps-empty-arrays ()
  "A nil scalar field is dropped entirely; a nil array field becomes [].
This is the deletedAt/[] bug: the server rejects `[]' where it wants a
scalar timestamp, so nil scalars must be absent, not empty arrays."
  (let* ((obj '(:id "t" :deletedAt nil :dueDate nil :purgedAt nil
                :tags nil :contexts ("@x") :checklist nil))
         (s (mindwtr-util-json-encode obj))
         (back (mindwtr-util-json-decode s)))
    ;; scalar nils omitted entirely (no key on the wire)
    (should-not (string-match-p "deletedAt" s))
    (should-not (string-match-p "dueDate" s))
    (should-not (string-match-p "purgedAt" s))
    (should-not (plist-member back :deletedAt))
    ;; array fields present as [] even when nil
    (should (string-match-p "\"tags\":\\[\\]" s))
    (should (string-match-p "\"checklist\":\\[\\]" s))
    ;; non-nil values untouched
    (should (equal (plist-get back :contexts) '("@x")))
    (should (string= (plist-get back :id) "t"))))

(ert-deftest mindwtr-util-json-encode-returns-text-not-raw-bytes ()
  "Encoding yields multibyte text, not the unibyte UTF-8 bytes `json-serialize'
returns.  Regression: raw bytes inserted into the shadow buffer became
eight-bit chars (\\342\\200\\242) the saver could not encode."
  (let ((s (mindwtr-util-json-encode '(:title "a • b “q” —"))))
    (should (multibyte-string-p s))
    (should (string-match-p "•" s))
    ;; round-trips back through the decoder
    (should (string= (plist-get (mindwtr-util-json-decode s) :title)
                     "a • b “q” —"))))

(ert-deftest mindwtr-util-atomic-write-roundtrips-non-ascii ()
  "Non-ASCII content writes and reads back intact as UTF-8 (no save prompt,
no byte corruption)."
  (let ((f (make-temp-file "mw-uni")))
    (unwind-protect
        (progn
          (mindwtr-util-atomic-write
           f (mindwtr-util-json-encode '(:title "café • “q” —")))
          (let ((back (mindwtr-util-json-decode (mindwtr-util-read-file f))))
            (should (string= (plist-get back :title) "café • “q” —"))))
      (delete-file f))))

(ert-deftest mindwtr-util-json-ascii-is-pure-ascii ()
  "Non-ASCII content is escaped to \\uXXXX yet decodes back unchanged."
  (let* ((obj '(:title "café • “quote”" :emoji "\U0001F600"))
         (s (mindwtr-util-json-ascii obj)))
    (should-not (string-match-p "[^[:ascii:]]" s))   ; pure ASCII on the wire
    (should (string-match-p "\\\\u00e9" s))           ; é escaped
    (should (string-match-p "\\\\u2022" s))           ; • escaped
    (should (string-match-p "\\\\ud83d\\\\ude00" s))  ; emoji as surrogate pair
    (let ((back (mindwtr-util-json-decode s)))
      (should (string= (plist-get back :title) "café • “quote”"))
      (should (string= (plist-get back :emoji) "\U0001F600")))))

(ert-deftest mindwtr-util-date-only-iso->org->iso ()
  "A date-only value round-trips as date-only without a time or day shift."
  (let* ((org (mindwtr-util-iso->org "2026-06-20")))
    (should (string= org "[2026-06-20 Sat]"))
    (should (string= (mindwtr-util-org->iso org) "2026-06-20"))))

(ert-deftest mindwtr-util-date-only-predicate ()
  (should (mindwtr-util-iso-date-only-p "2026-06-20"))
  (should-not (mindwtr-util-iso-date-only-p "2026-06-20T00:00:00Z")))

(ert-deftest mindwtr-util-datetime-still-roundtrips-to-the-minute ()
  (let* ((iso "2026-05-31T17:39:53.268Z")
         (back (mindwtr-util-org->iso (mindwtr-util-iso->org iso))))
    ;; org keeps minute precision; compare to the minute-truncated UTC form
    (should (string= back "2026-05-31T17:39:00Z"))))

(ert-deftest mindwtr-util-atomic-write-and-read ()
  (let ((f (make-temp-file "mw-atomic")))
    (unwind-protect
        (progn
          (mindwtr-util-atomic-write f "hello")
          (should (string= (mindwtr-util-read-file f) "hello")))
      (delete-file f))))

(ert-deftest mindwtr-util-json-array-fields-covers-source-arrays ()
  "Nested array-valued keys from the source serialize as [] when nil,
while scalar nils are still omitted."
  ;; recurrence.byDay is an array; nil -> [] (not omitted, not null)
  (let ((s (mindwtr-util-json-encode '(:recurrence (:rule "weekly" :byDay nil)))))
    (should (string-match-p "\"byDay\":\\[\\]" s)))
  ;; settings array fields -> []
  (let ((s (mindwtr-util-json-encode '(:externalCalendars nil :savedSearches nil
                                       :lastSyncHistory nil))))
    (should (string-match-p "\"externalCalendars\":\\[\\]" s))
    (should (string-match-p "\"savedSearches\":\\[\\]" s))
    (should (string-match-p "\"lastSyncHistory\":\\[\\]" s)))
  ;; a scalar nil is still omitted
  (should-not (string-match-p "reviewAt"
                              (mindwtr-util-json-encode '(:reviewAt nil :id "x")))))
