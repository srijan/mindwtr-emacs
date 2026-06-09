;;; mindwtr-shadow-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-shadow)

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
   (should-not (mindwtr-shadow-notes-migrated-p))
   (mindwtr-shadow-set-notes-migrated)
   (should (mindwtr-shadow-notes-migrated-p))))

(ert-deftest mindwtr-shadow-fields-migrated-latch ()
  "The fields-migration marker is absent until set, then latched on, and is
independent of the notes-migration marker (the two latches do not interfere)."
  (mindwtr-shadow-test--with-dir
   (should-not (mindwtr-shadow-fields-migrated-p))
   (mindwtr-shadow-set-fields-migrated)
   (should (mindwtr-shadow-fields-migrated-p))
   ;; the notes latch is unaffected
   (should-not (mindwtr-shadow-notes-migrated-p))))

(ert-deftest mindwtr-shadow-device-id-stable ()
  (mindwtr-shadow-test--with-dir
   (let ((id (mindwtr-shadow-device-id)))
     (should (stringp id))
     (should (string= id (mindwtr-shadow-device-id))))))

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
(defun mindwtr-shadow-test--now () (encode-time 0 0 12 4 6 2026))

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
