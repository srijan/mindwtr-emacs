;;; mindwtr-report.el --- Sync report buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Renders sync stats, conflicts (lost local edits) with diffs, and clock
;; skew warnings into *Mindwtr Sync Report*.
;;; Code:

(defun mindwtr-report-show (stats conflicts skew-warning)
  "Display STATS, CONFLICTS, and SKEW-WARNING; return the report buffer."
  (let ((buf (get-buffer-create "*Mindwtr Sync Report*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Mindwtr Sync Report\n===================\n\n")
        (insert (format "Created: %d   Updated: %d   Deleted: %d\n\n"
                        (or (plist-get stats :created) 0)
                        (or (plist-get stats :updated) 0)
                        (or (plist-get stats :deleted) 0)))
        (when skew-warning
          (insert (format "⚠ Clock skew: %s\n\n" skew-warning)))
        (if (null conflicts)
            (insert "No conflicts. All local edits accepted.\n")
          (insert (format "%d local edit(s) overridden by newer remote edits:\n\n"
                          (length conflicts)))
          (dolist (c conflicts)
            (insert (format "• %s\n" (plist-get c :id)))
            (insert (format "    yours : %s\n"
                            (plist-get (plist-get c :mine) :title)))
            (insert (format "    server: %s\n\n"
                            (plist-get (plist-get c :theirs) :title)))))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer buf)
    buf))

(provide 'mindwtr-report)
;;; mindwtr-report.el ends here
