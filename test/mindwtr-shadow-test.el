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
