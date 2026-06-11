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

;;; U6: immediate refile + commands ------------------------------------------

(defmacro mindwtr-archive-test--with-active (archive-path &rest body)
  "Run BODY with the archive surface active at ARCHIVE-PATH (explicit).
Cleans up the archive buffer afterward."
  (declare (indent 1))
  `(let ((mindwtr-archive-file ,archive-path)
         (mindwtr-file nil))
     (unwind-protect (progn ,@body)
       (let ((b (find-buffer-visiting ,archive-path)))
         (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))))))

(ert-deftest mindwtr-archive-item-refiles-task-with-containment ()
  "Covers R6 + KTD7.  Archiving a done task under a live project moves it out of
the source (project remains), into the archive buffer at level 2 with ARCH and
:MW_PROJECT_ID: pointing at the project."
  (let* ((root (make-temp-file "mw-refile" t))
         (apath (expand-file-name "arch.org" root)))
    (unwind-protect
        (mindwtr-archive-test--with-active apath
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                      "** ACTIVE Keep me\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
                      "*** DONE Finish it\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (mindwtr-mode))
            (goto-char (point-min))
            (re-search-forward "Finish it")
            (mindwtr-archive-item-at-point)
            ;; gone from source; project kept
            (should-not (save-excursion (goto-char (point-min))
                                        (search-forward "Finish it" nil t)))
            (should (save-excursion (goto-char (point-min))
                                    (search-forward "Keep me" nil t))))
          (with-current-buffer (mindwtr-archive-buffer)
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* ARCH Finish it" nil t))
            (should (save-excursion (goto-char (point-min))
                                    (search-forward ":MW_PROJECT_ID: p1" nil t)))))
      (delete-directory root t))))

(ert-deftest mindwtr-archive-item-archives-whole-project-subtree ()
  "Archiving a project at point moves the whole subtree (project, section,
task) as one unit."
  (let* ((root (make-temp-file "mw-refile-p" t))
         (apath (expand-file-name "arch.org" root)))
    (unwind-protect
        (mindwtr-archive-test--with-active apath
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                      "** ACTIVE Big\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
                      "*** Phase\n:PROPERTIES:\n:MW_TYPE: section\n:MW_ID: s1\n:END:\n"
                      "**** DONE Step\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (mindwtr-mode))
            (goto-char (point-min))
            (re-search-forward "ACTIVE Big")
            (mindwtr-archive-item-at-point)
            (should-not (save-excursion (goto-char (point-min))
                                        (search-forward "Big" nil t))))
          (with-current-buffer (mindwtr-archive-buffer)
            (goto-char (point-min))
            (should (re-search-forward "^\\*\\* ARCH Big" nil t))
            (should (save-excursion (goto-char (point-min)) (search-forward "Phase" nil t)))
            (should (save-excursion (goto-char (point-min)) (search-forward "Step" nil t)))))
      (delete-directory root t))))

(ert-deftest mindwtr-archive-item-inactive-surface-errors-untouched ()
  "Command with no file and no configured archive path: user-error, buffer
untouched (no ARCH stamped)."
  (let ((mindwtr-archive-file nil) (mindwtr-file nil))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* NEXT Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
        (org-mode))
      (goto-char (point-min))
      (let ((before (buffer-string)))
        (should-error (mindwtr-archive-item-at-point) :type 'user-error)
        (should (string= before (buffer-string)))))))

(ert-deftest mindwtr-archive-item-no-id-errors ()
  "Command on a task heading lacking MW_ID: user-error, untouched."
  (let* ((root (make-temp-file "mw-noid" t))
         (apath (expand-file-name "arch.org" root)))
    (unwind-protect
        (mindwtr-archive-test--with-active apath
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* NEXT No id\n:PROPERTIES:\n:MW_TYPE: task\n:END:\n")
              (mindwtr-mode))
            (goto-char (point-min))
            (re-search-forward "No id")
            (let ((before (buffer-string)))
              (should-error (mindwtr-archive-item-at-point) :type 'user-error)
              (should (string= before (buffer-string))))))
      (delete-directory root t))))

(ert-deftest mindwtr-archive-item-on-container-errors ()
  "Command on a container heading: user-error (not a task/project)."
  (let* ((root (make-temp-file "mw-cont" t))
         (apath (expand-file-name "arch.org" root)))
    (unwind-protect
        (mindwtr-archive-test--with-active apath
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n")
              (mindwtr-mode))
            (goto-char (point-min))
            (re-search-forward "Projects")
            (should-error (mindwtr-archive-item-at-point) :type 'user-error)))
      (delete-directory root t))))

(provide 'mindwtr-archive-test)
;;; mindwtr-archive-test.el ends here
