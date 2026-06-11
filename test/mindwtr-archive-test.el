;;; mindwtr-archive-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-archive)
(require 'mindwtr)

;;; mindwtr-archive-path ------------------------------------------------------

(ert-deftest mindwtr-archive-path-derives-beside-buffer-file ()
  "No custom, `mindwtr-file' nil: derive beside the current buffer's file."
  (let ((mindwtr-archive-file nil)
        (mindwtr-file nil)
        (f (expand-file-name "tasks.org" "/tmp/mw/")))
    (with-temp-buffer
      (setq buffer-file-name f)
      (should (string= (mindwtr-archive-path)
                       (expand-file-name "mindwtr_archive.org" "/tmp/mw/"))))))

(ert-deftest mindwtr-archive-path-custom-string-verbatim ()
  "A custom string path is returned verbatim, regardless of any anchor."
  (let ((mindwtr-archive-file "/somewhere/else/arch.org")
        (mindwtr-file nil))
    (with-temp-buffer
      (should (string= (mindwtr-archive-path) "/somewhere/else/arch.org")))))

(ert-deftest mindwtr-archive-path-custom-function-called ()
  "A custom function is called for the path."
  (let ((mindwtr-archive-file (lambda () "/fn/derived.org"))
        (mindwtr-file nil))
    (with-temp-buffer
      (should (string= (mindwtr-archive-path) "/fn/derived.org")))))

(ert-deftest mindwtr-archive-path-inactive-temp-buffer ()
  "Temp buffer (no file), no custom, `mindwtr-file' nil: surface inactive (nil)."
  (let ((mindwtr-archive-file nil)
        (mindwtr-file nil))
    (with-temp-buffer
      (should (null buffer-file-name))
      (should (null (mindwtr-archive-path))))))

(ert-deftest mindwtr-archive-path-anchors-on-mindwtr-file-first ()
  "With `mindwtr-file' set, derivation anchors beside it -- NOT beside the
current buffer's unrelated file (KTD8: hooks/timers run from arbitrary buffers)."
  (let ((mindwtr-archive-file nil)
        (mindwtr-file (expand-file-name "tasks.org" "/tmp/mw/")))
    (with-temp-buffer
      (setq buffer-file-name (expand-file-name "unrelated.org" "/tmp/other/"))
      (should (string= (mindwtr-archive-path)
                       (expand-file-name "mindwtr_archive.org" "/tmp/mw/"))))))

;;; mindwtr-archive-buffer ----------------------------------------------------

(ert-deftest mindwtr-archive-buffer-nil-when-inactive ()
  "No path resolvable -> no buffer."
  (let ((mindwtr-archive-file nil)
        (mindwtr-file nil))
    (with-temp-buffer
      (should (null (mindwtr-archive-buffer))))))

(ert-deftest mindwtr-archive-buffer-visits-and-enables-mode ()
  "Visiting the archive file creates a buffer in `mindwtr-mode'."
  (let* ((dir (make-temp-file "mw-arch" t))
         (mindwtr-archive-file (expand-file-name "mindwtr_archive.org" dir))
         (mindwtr-file nil))
    (unwind-protect
        (let ((buf (mindwtr-archive-buffer)))
          (should (bufferp buf))
          (with-current-buffer buf
            (should (derived-mode-p 'mindwtr-mode)))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))
      (delete-directory dir t))))

(ert-deftest mindwtr-archive-buffer-no-create-returns-nil-when-unvisited ()
  "NO-CREATE returns an existing buffer only; nil when none visits the path."
  (let* ((dir (make-temp-file "mw-arch" t))
         (mindwtr-archive-file (expand-file-name "mindwtr_archive.org" dir))
         (mindwtr-file nil))
    (unwind-protect
        (should (null (mindwtr-archive-buffer t)))
      (delete-directory dir t))))

(provide 'mindwtr-archive-test)
;;; mindwtr-archive-test.el ends here
