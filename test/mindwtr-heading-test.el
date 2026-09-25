;;; mindwtr-heading-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'mindwtr-heading)

(defmacro mindwtr-heading-test--with (text &rest body)
  "Insert TEXT in an org buffer, move to the first heading, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       (org-next-visible-heading 1)
       ,@body)))

(defconst mindwtr-heading-test--tree
  "* Projects
:PROPERTIES:
:MW_TYPE: container
:MW_LIST: projects
:END:
** ACTIVE Ship it
:PROPERTIES:
:MW_TYPE: project
:MW_ID: p1
:CATEGORY: Work
:END:
*** Phase one
:PROPERTIES:
:MW_TYPE: section
:MW_ID: s1
:END:
**** NEXT Write the thing
SCHEDULED: <2026-02-09 Mon>
DEADLINE: <2026-02-15 Sun>
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:MW_BLANK:
:END:
Some body text.
***** Untyped child
Just a note.
* Inbox
:PROPERTIES:
:MW_TYPE: container
:MW_LIST: inbox
:END:
** Loose
:PROPERTIES:
:MW_TYPE:
:MW_ID: t2
:END:
* Stray
No drawer here.
")

(defun mindwtr-heading-test--goto (id)
  "Move to the heading whose MW_ID is ID (test helper, plain search)."
  (goto-char (point-min))
  (re-search-forward (format ":MW_ID: %s$" id))
  (org-back-to-heading t))

;;; Property drawer

(ert-deftest mindwtr-heading-prop-reads-past-two-planning-lines ()
  "The literal scan finds a drawer under SCHEDULED + DEADLINE, where
`org-entry-get' has been observed to lose it."
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (should (equal (mindwtr-heading-prop "MW_ID") "t1"))
    (should (equal (mindwtr-heading-type) "task"))
    (should (eq (mindwtr-heading-kind) 'task))))

(ert-deftest mindwtr-heading-prop-from-inside-the-body ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (search-forward "Some body text")
    (should (equal (mindwtr-heading-id) "t1"))
    (should (= (mindwtr-heading-body-start)
               (save-excursion (mindwtr-heading-test--goto "t1")
                               (search-forward ":END:\n") (point))))))

(ert-deftest mindwtr-heading-prop-blank-vs-absent ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (should (equal (mindwtr-heading-prop "MW_BLANK") ""))
    (should-not (mindwtr-heading-prop-nonblank "MW_BLANK"))
    (should-not (mindwtr-heading-prop "NOPE"))
    (mindwtr-heading-test--goto "t2")
    (should (equal (mindwtr-heading-prop "MW_TYPE") ""))
    (should-not (mindwtr-heading-type))
    (should-not (mindwtr-heading-kind))))

(ert-deftest mindwtr-heading-prop-no-drawer ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (goto-char (point-max))
    (re-search-backward "^\\* Stray")
    (should-not (mindwtr-heading-properties))
    (should-not (mindwtr-heading-id))
    (should (= (mindwtr-heading-body-start)
               (save-excursion (forward-line 1) (point))))
    (should (= (mindwtr-heading-entry-end) (point-max)))))

(ert-deftest mindwtr-heading-category-never-falls-back-to-filename ()
  "CATEGORY is special-cased by `org-entry-get'; the literal read is not."
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "p1")
    (should (equal (mindwtr-heading-prop-nonblank "CATEGORY") "Work"))
    (mindwtr-heading-test--goto "t1")
    (should-not (mindwtr-heading-prop "CATEGORY"))
    (should (equal (mindwtr-heading-inherited-prop "CATEGORY") "Work"))
    (mindwtr-heading-test--goto "t2")
    (should-not (mindwtr-heading-inherited-prop "CATEGORY"))))

(ert-deftest mindwtr-heading-properties-memo-invalidates-on-edit ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "p1")
    (should (equal (mindwtr-heading-prop "CATEGORY") "Work"))
    (org-set-property "CATEGORY" "Home")
    (should (equal (mindwtr-heading-prop "CATEGORY") "Home"))))

(ert-deftest mindwtr-heading-properties-memo-is-per-heading ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "p1")
    (should (equal (mindwtr-heading-id) "p1"))
    (mindwtr-heading-test--goto "s1")
    (should (equal (mindwtr-heading-id) "s1"))
    (mindwtr-heading-test--goto "p1")
    (should (equal (mindwtr-heading-id) "p1"))))

(ert-deftest mindwtr-heading-properties-memo-survives-position-shift ()
  "A structural edit above a heading shifts positions; the tick bump must
invalidate position-keyed entries rather than misattribute them."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (should (equal (mindwtr-heading-id) "t1"))
    (goto-char (point-min))
    (search-forward ":MW_ID: t1")
    (replace-match ":MW_ID: t2")
    (goto-char (point-min))
    (should (equal (mindwtr-heading-id) "t2"))
    (goto-char (point-min))
    (insert "* Other\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: o1\n:END:\n")
    (goto-char (point-max))
    (should (equal (mindwtr-heading-id) "t2"))
    (goto-char (point-min))
    (should (equal (mindwtr-heading-id) "o1"))))

;;; Lookup

(ert-deftest mindwtr-heading-find-id-and-role ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (let ((here (point)))
      (should (= (mindwtr-heading-find-id "s1")
                 (save-excursion (mindwtr-heading-test--goto "s1") (point))))
      (should (= (mindwtr-heading-find-role "inbox")
                 (save-excursion (goto-char (point-min))
                                 (re-search-forward "^\\* Inbox") (line-beginning-position))))
      (should-not (mindwtr-heading-find-id "nope"))
      (should-not (mindwtr-heading-find-role "nope"))
      ;; side-effect free
      (should (= (point) here)))))

(ert-deftest mindwtr-heading-find-id-is-anchored ()
  "An id that is a prefix of another must not match it."
  (mindwtr-heading-test--with "* A
:PROPERTIES:
:MW_ID: t10
:END:
* B
:PROPERTIES:
:MW_ID: t1
:END:
"
    (should (= (mindwtr-heading-find-id "t1")
               (save-excursion (goto-char (point-min))
                               (re-search-forward "^\\* B") (line-beginning-position))))))

(ert-deftest mindwtr-heading-find-key-and-goto-key ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (should (= (mindwtr-heading-find-key "inbox") (mindwtr-heading-find-role "inbox")))
    (should (= (mindwtr-heading-find-key "t1") (mindwtr-heading-find-id "t1")))
    (should-not (mindwtr-heading-find-key nil))
    (let ((here (point)))
      (should-not (mindwtr-heading-goto-key "nope"))
      (should (= (point) here)))
    (should (mindwtr-heading-goto-key "s1"))
    (should (equal (mindwtr-heading-id) "s1"))))

;;; Ancestry

(ert-deftest mindwtr-heading-ancestor-id-skips-self ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (should (equal (mindwtr-heading-ancestor-id 'section) "s1"))
    (should (equal (mindwtr-heading-ancestor-id 'project) "p1"))
    (should-not (mindwtr-heading-ancestor-id 'task))
    (mindwtr-heading-test--goto "p1")
    (should-not (mindwtr-heading-ancestor-id 'project))))

(ert-deftest mindwtr-heading-ancestor-pos-include-self ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "p1")
    (let ((p1 (point)))
      (should-not (mindwtr-heading-ancestor-pos 'project))
      (should (= (mindwtr-heading-ancestor-pos 'project t) p1))
      (mindwtr-heading-test--goto "t1")
      (should (= (mindwtr-heading-ancestor-pos 'project) p1))
      (should (= (mindwtr-heading-ancestor-pos 'project t) p1)))))

(ert-deftest mindwtr-heading-container-role ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (should (equal (mindwtr-heading-container-role) "projects"))
    (mindwtr-heading-test--goto "t2")
    (should (equal (mindwtr-heading-container-role) "inbox"))
    (goto-char (point-max))
    (re-search-backward "^\\* Stray")
    (should-not (mindwtr-heading-container-role))))

(ert-deftest mindwtr-heading-container-role-first-container-wins ()
  "A blank MW_LIST on the nearest container is \"no container\", not a
fall-through to an outer container."
  (mindwtr-heading-test--with "* Outer
:PROPERTIES:
:MW_TYPE: container
:MW_LIST: projects
:END:
** Inner
:PROPERTIES:
:MW_TYPE: container
:END:
*** Leaf
:PROPERTIES:
:MW_ID: x
:END:
"
    (mindwtr-heading-test--goto "x")
    (should-not (mindwtr-heading-container-role))))

(ert-deftest mindwtr-heading-nearest-id-pos ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (mindwtr-heading-test--goto "t1")
    (let ((t1 (point)))
      (should (equal (mindwtr-heading-nearest-id-pos) (cons "t1" t1)))
      (re-search-forward "^\\*\\*\\*\\*\\* Untyped child")
      (should (equal (mindwtr-heading-nearest-id-pos) (cons "t1" t1))))
    (goto-char (point-min))
    (should-not (mindwtr-heading-nearest-id-pos))
    (should (equal (mindwtr-heading-list-role) "projects"))))

;;; Iteration

(ert-deftest mindwtr-heading-map-hides-file-name ()
  "The scan runs with `buffer-file-name' nil so Org's agenda-file check
never prompts; the file name is back afterwards.  (The companion
`org-element-use-cache' binding is not asserted here: on Org 9.7+
`org-scan-tags' re-enables the cache internally for the duration of the
scan, so its value inside the callback is not observable.)"
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (setq buffer-file-name "/nonexistent/dir/x.org")
    (let (seen)
      (mindwtr-heading-map
       (lambda ()
         (should-not buffer-file-name)
         (push (mindwtr-heading-id) seen)))
      (should (equal (nreverse seen) '(nil "p1" "s1" "t1" nil nil "t2" nil))))
    (should (equal buffer-file-name "/nonexistent/dir/x.org"))
    (setq buffer-file-name nil)))

(ert-deftest mindwtr-heading-map-binds-scan-off-element-cache ()
  "`org-map-entries' is entered with `org-element-use-cache' nil, keeping the
auto-sync scan off the long-lived cache that has wedged Emacs (see
docs/solutions/runtime-errors/org-element-cache-wedges-auto-sync-scan.md).
Observed at the hand-off because Org 9.7+ re-binds it inside the scan, which
is why `mindwtr-heading-map-hides-file-name' cannot see it."
  (let ((org-element-use-cache t)
        (buffer-file-name "/nonexistent/dir/x.org")
        seen)
    (cl-letf (((symbol-function 'org-map-entries)
               (lambda (&rest _)
                 (setq seen (list org-element-use-cache buffer-file-name)))))
      (mindwtr-heading-map #'ignore))
    (should (equal seen '(nil nil)))
    (should (eq org-element-use-cache t))))

(ert-deftest mindwtr-heading-map-passes-args ()
  (mindwtr-heading-test--with mindwtr-heading-test--tree
    (should (equal (mindwtr-heading-map (lambda () (mindwtr-heading-id))
                                        "MW_TYPE=\"project\"")
                   '("p1")))))

(provide 'mindwtr-heading-test)
;;; mindwtr-heading-test.el ends here
