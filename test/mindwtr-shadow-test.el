;;; mindwtr-shadow-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-shadow)

;; Fixed clock: 2026-06-04 12:00:00 local.  Cutoff at retention 3 = 2026-06-01 12:00.
(defun mindwtr-shadow-test--now () (encode-time 0 0 12 4 6 2026))

(defmacro mindwtr-shadow-test--with-dir (&rest body)
  `(let* ((dir (make-temp-file "mw-shadow" t))
          (mindwtr-shadow-directory dir))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest mindwtr-shadow-save-load-roundtrip ()
  (mindwtr-shadow-test--with-dir
   (let ((ad '(:tasks ((:id "t1" :title "x" :status "next" :rev 3))
               :projects nil :sections nil :areas nil :settings (:theme "dark"))))
     (mindwtr-shadow-save ad)
     (let ((loaded (mindwtr-shadow-load)))
       (should (equal (plist-get (car (plist-get loaded :tasks)) :id) "t1"))
       (should (= (plist-get (car (plist-get loaded :tasks)) :rev) 3))))))

(ert-deftest mindwtr-shadow-load-empty-when-absent ()
  (mindwtr-shadow-test--with-dir
   (let ((ad (mindwtr-shadow-load)))
     (should (null (plist-get ad :tasks))))))

(ert-deftest mindwtr-shadow-etag-roundtrip ()
  (mindwtr-shadow-test--with-dir
   (mindwtr-shadow-set-etag "abc123")
   (should (string= (mindwtr-shadow-get-etag) "abc123"))))

(ert-deftest mindwtr-shadow-notes-migrated-latch ()
  "The notes-migration marker is absent until set, then latched on."
  (mindwtr-shadow-test--with-dir
   (should-not (mindwtr-shadow-latched-p 'notes))
   (mindwtr-shadow-latch 'notes)
   (should (mindwtr-shadow-latched-p 'notes))))

(ert-deftest mindwtr-shadow-fields-migrated-latch ()
  "The fields-migration marker is absent until set, then latched on, and is
independent of the notes-migration marker (the two latches do not interfere)."
  (mindwtr-shadow-test--with-dir
   (should-not (mindwtr-shadow-latched-p 'fields))
   (mindwtr-shadow-latch 'fields)
   (should (mindwtr-shadow-latched-p 'fields))
   ;; the notes latch is unaffected
   (should-not (mindwtr-shadow-latched-p 'notes))))

(ert-deftest mindwtr-shadow-device-id-stable ()
  (mindwtr-shadow-test--with-dir
   (let ((id (mindwtr-shadow-device-id)))
     (should (stringp id))
     (should (string= id (mindwtr-shadow-device-id))))))

(ert-deftest mindwtr-shadow-unknown-latch-signals ()
  (should-error (mindwtr-shadow-latched-p 'bogus)))

(ert-deftest mindwtr-shadow-memory-store-is-a-second-adapter ()
  "Everything above the store seam behaves identically on the in-memory store:
shadow round-trip with last-good copy, etag, latches, a stable device id --
and nothing touches `mindwtr-shadow-directory'."
  (let* ((mindwtr-shadow-directory "/nonexistent/mindwtr-test/")
         (store (mindwtr-shadow-memory-store))
         (mindwtr-shadow-store store))
    (mindwtr-shadow-save '(:tasks ((:id "t1" :rev 1)) :projects nil :sections nil :areas nil :settings nil))
    (mindwtr-shadow-save '(:tasks ((:id "t1" :rev 2)) :projects nil :sections nil :areas nil :settings nil))
    (should (= (plist-get (car (plist-get (mindwtr-shadow-load) :tasks)) :rev) 2))
    (should (string-match-p "\"rev\":1" (funcall (mindwtr-shadow-store-get store) "shadow.bak.json")))
    (mindwtr-shadow-set-etag "e1")
    (should (string= (mindwtr-shadow-get-etag) "e1"))
    (should-not (mindwtr-shadow-latched-p 'notes))
    (mindwtr-shadow-latch 'notes)
    (should (mindwtr-shadow-latched-p 'notes))
    (should (string= (mindwtr-shadow-device-id) (mindwtr-shadow-device-id)))
    (should-not (file-exists-p mindwtr-shadow-directory))))

(ert-deftest mindwtr-shadow-baseline-reads-everything-at-once ()
  (let ((mindwtr-shadow-store (mindwtr-shadow-memory-store)))
    (mindwtr-shadow-save '(:tasks ((:id "t1")) :projects nil :sections nil :areas nil :settings nil))
    (mindwtr-shadow-set-etag "e9")
    (mindwtr-shadow-latch 'fields)
    (let ((b (mindwtr-shadow-baseline)))
      (should (equal (plist-get (car (plist-get (mindwtr-shadow-baseline-appdata b) :tasks)) :id) "t1"))
      (should (string= (mindwtr-shadow-baseline-etag b) "e9"))
      (should (stringp (mindwtr-shadow-baseline-device-id b)))
      (should (equal (mindwtr-shadow-baseline-latches b) '(fields))))))

(ert-deftest mindwtr-shadow-baseline-on-empty-store ()
  (let ((mindwtr-shadow-store (mindwtr-shadow-memory-store)))
    (let ((b (mindwtr-shadow-baseline)))
      (should (null (plist-get (mindwtr-shadow-baseline-appdata b) :tasks)))
      (should (null (mindwtr-shadow-baseline-etag b)))
      (should (null (mindwtr-shadow-baseline-latches b))))))

(ert-deftest mindwtr-shadow-commit-writes-shadow-etag-and-latches ()
  (let ((mindwtr-shadow-store (mindwtr-shadow-memory-store))
        (ad '(:tasks ((:id "t1" :rev 4)) :projects nil :sections nil :areas nil :settings nil)))
    (should (equal (mindwtr-shadow-commit ad "e2" '(notes archive)) '(notes archive)))
    (should (= (plist-get (car (plist-get (mindwtr-shadow-load) :tasks)) :rev) 4))
    (should (string= (mindwtr-shadow-get-etag) "e2"))
    (should (equal (mindwtr-shadow-latched-names) '(notes archive)))))

(ert-deftest mindwtr-shadow-commit-without-latches-leaves-them-unset ()
  "The caller passes no latches when a save failed; protection stays on."
  (let ((mindwtr-shadow-store (mindwtr-shadow-memory-store)))
    (mindwtr-shadow-commit '(:tasks nil :projects nil :sections nil :areas nil :settings nil) "e1" nil)
    (should (null (mindwtr-shadow-latched-names)))))

(ert-deftest mindwtr-shadow-commit-survives-latch-write-failure ()
  "A failing latch write is messaged and skipped; the shadow, etag and the
other latches still commit (post-PUT must never throw)."
  (let* ((store (mindwtr-shadow-memory-store))
         (mindwtr-shadow-store store)
         (real-put (mindwtr-shadow-store-put store)))
    (setf (mindwtr-shadow-store-put store)
          (lambda (key content)
            (if (string= key "fields-migrated") (error "disk full")
              (funcall real-put key content))))
    (should (equal (mindwtr-shadow-commit
                    '(:tasks nil :projects nil :sections nil :areas nil :settings nil)
                    "e3" '(notes fields archive))
                   '(notes archive)))
    (should (string= (mindwtr-shadow-get-etag) "e3"))
    (should (equal (mindwtr-shadow-latched-names) '(notes archive)))))

(ert-deftest mindwtr-shadow-backup-and-prune-on-memory-store ()
  (let* ((store (mindwtr-shadow-memory-store))
         (mindwtr-shadow-store store)
         (mindwtr-backup-retention-days 3)
         (keys (mindwtr-shadow-store-keys store)))
    (with-temp-buffer
      (insert "* old\n")
      ;; 5 days before the fixed clock below -> pruned
      (mindwtr-shadow-backup "mindwtr" (encode-time 0 0 12 30 5 2026))
      (insert "* new\n")
      (should (string-match-p "\\`backups/mindwtr-archive-20260604T12"
                              (mindwtr-shadow-backup "mindwtr-archive" (mindwtr-shadow-test--now)))))
    (should (= (length (funcall keys "backups/")) 2))
    (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
    (should (equal (funcall keys "backups/") '("backups/mindwtr-archive-20260604T120000.org")))
    (should (string= (funcall (mindwtr-shadow-store-get store)
                              "backups/mindwtr-archive-20260604T120000.org")
                     "* old\n* new\n"))))

(ert-deftest mindwtr-shadow-prune-never-signals ()
  (let ((store (mindwtr-shadow-memory-store))
        (mindwtr-backup-retention-days 3))
    (setf (mindwtr-shadow-store-keys store) (lambda (_p) (error "boom")))
    (let ((mindwtr-shadow-store store))
      (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now)))))

(ert-deftest mindwtr-shadow-index-by-id ()
  (let ((ad '(:tasks ((:id "t1" :rev 1) (:id "t2" :rev 2))
              :projects nil :sections nil :areas nil)))
    (let ((idx (mindwtr-shadow-index ad :tasks)))
      (should (= (plist-get (gethash "t2" idx) :rev) 2)))))

(defun mindwtr-shadow-test--make-backup (name)
  "Create an empty backup file NAME under the backups dir."
  (let ((bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
    (make-directory bdir t)
    (write-region "" nil (expand-file-name name bdir))))

(defun mindwtr-shadow-test--backup-exists-p (name)
  (file-exists-p (expand-file-name (concat "backups/" name)
                                   mindwtr-shadow-directory)))

;; Fixed clock: 2026-06-04 12:00:00 local.  Cutoff at retention 3 = 2026-06-01 12:00.

(ert-deftest mindwtr-shadow-prune-deletes-old-backup ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260530T120000.org") ; 5 days old
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should-not (mindwtr-shadow-test--backup-exists-p "mindwtr-20260530T120000.org")))))

(ert-deftest mindwtr-shadow-prune-keeps-recent-backup ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260604T080000.org") ; same day
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20260604T080000.org")))))

(ert-deftest mindwtr-shadow-prune-disabled-keeps-everything ()
  (mindwtr-shadow-test--with-dir
   (mindwtr-shadow-test--make-backup "mindwtr-20200101T000000.org") ; ancient
   (let ((mindwtr-backup-retention-days nil))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20200101T000000.org")))
   (let ((mindwtr-backup-retention-days 0))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20200101T000000.org")))))

(ert-deftest mindwtr-shadow-prune-leaves-foreign-files ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "notes.txt")              ; not ours
     (mindwtr-shadow-test--make-backup "mindwtr-garbage.org")    ; ours-shaped, unparseable
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "notes.txt"))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-garbage.org")))))

(ert-deftest mindwtr-shadow-prune-missing-dir-is-noop ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     ;; no backups/ dir created at all
     (should-not (file-directory-p
                  (expand-file-name "backups/" mindwtr-shadow-directory)))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now)) ; must not error
     ;; reaching here without error is the assertion
     )))

(ert-deftest mindwtr-shadow-prune-keeps-backup-at-cutoff ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260601T120000.org") ; exactly at cutoff
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20260601T120000.org")))))

(ert-deftest mindwtr-shadow-prune-mixed-directory ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260530T120000.org") ; old → go
     (mindwtr-shadow-test--make-backup "mindwtr-20260604T080000.org") ; new → stay
     (mindwtr-shadow-test--make-backup "keep-me.org")                 ; foreign → stay
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should-not (mindwtr-shadow-test--backup-exists-p "mindwtr-20260530T120000.org"))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20260604T080000.org"))
     (should (mindwtr-shadow-test--backup-exists-p "keep-me.org")))))
