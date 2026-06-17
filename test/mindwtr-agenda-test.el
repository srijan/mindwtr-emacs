;;; mindwtr-agenda-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'org-agenda)
(require 'mindwtr-model)
(require 'mindwtr-render)
(require 'mindwtr-agenda)

;; `mindwtr-file' is owned (defcustom'd) by mindwtr.el, which these tests do not
;; load (it pulls the full sync stack + the `plz' dependency).  Declare it special
;; with a value here so tests can dynamically `let'-bind it.
(defvar mindwtr-file nil)

;; A self-contained appdata renderer.  This mirrors
;; `mindwtr-commands-test--with-appdata' but is defined locally on purpose:
;; `make test' loads every `test/*-test.el' in alphabetical order, so this file
;; loads BEFORE mindwtr-commands-test.el -- its macro would not yet be defined
;; at this file's load time.
(defmacro mindwtr-agenda-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     ,@body))

;;; U1 -- file scoping helper ---------------------------------------------------

(ert-deftest mindwtr-agenda-files-returns-only-the-mindwtr-file ()
  "Scope is exactly the Mindwtr file; the archive path is never included (AE4)."
  (let ((mindwtr-file "/tmp/mindwtr-test.org"))
    (should (equal (mindwtr-agenda--files) '("/tmp/mindwtr-test.org")))))

(ert-deftest mindwtr-agenda-files-errors-when-file-unset ()
  "An unset `mindwtr-file' is a clear error, not a silent empty scope."
  (let ((mindwtr-file nil))
    (should-error (mindwtr-agenda--files))))

;;; U2 -- stuck-project predicate ----------------------------------------------

(defun mindwtr-agenda-test--stuck-at (title)
  "Move to the project heading named TITLE and return its stuck-p result."
  (goto-char (point-min))
  (re-search-forward (concat "ACTIVE " (regexp-quote title)))
  (mindwtr-agenda--project-stuck-p))

(ert-deftest mindwtr-agenda-project-with-next-child-is-not-stuck ()
  "An active project with a NEXT child is not stuck (AE2)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "HasNext" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Do it" :status "next" :projectId "p1"))
        :settings nil)
    (should-not (mindwtr-agenda-test--stuck-at "HasNext"))))

(ert-deftest mindwtr-agenda-project-without-next-child-is-stuck ()
  "An active project with zero NEXT children is stuck (AE2)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "NoNext" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Later" :status "waiting" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "NoNext"))))

(ert-deftest mindwtr-agenda-project-with-only-done-children-is-stuck ()
  "DONE children do not clear stuck."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "AllDone" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Finished" :status "done" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "AllDone"))))

(ert-deftest mindwtr-agenda-project-with-only-waiting-child-is-stuck ()
  "A WAIT child but no NEXT is still stuck."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "OnlyWait" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Blocked" :status "waiting" :projectId "p1"))
        :settings nil)
    (should (mindwtr-agenda-test--stuck-at "OnlyWait"))))

(ert-deftest mindwtr-agenda-project-with-nested-next-is-not-stuck ()
  "A NEXT task under a section within the project clears stuck (whole-subtree
scan, not just direct children)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Nested" :status "active"))
        :sections ((:id "s1" :title "Phase 1" :projectId "p1"))
        :tasks ((:id "t1" :title "Deep action" :status "next"
                 :projectId "p1" :sectionId "s1"))
        :settings nil)
    (should-not (mindwtr-agenda-test--stuck-at "Nested"))))

;;; U3 -- Engage view ----------------------------------------------------------

(defun mindwtr-agenda-test--block-header (block)
  "Return BLOCK's `org-agenda-overriding-header' value."
  (cadr (assq 'org-agenda-overriding-header
              (car (last block)))))

(ert-deftest mindwtr-agenda-engage-spec-block-order ()
  "The Engage spec is five blocks in order: calendar, focus, next, waiting,
inbox -- with the Inbox last (R1, R6)."
  (let* ((spec (mindwtr-agenda--engage-spec))
         (blocks (nth 2 spec)))
    (should (= (length blocks) 5))
    (should (eq (nth 0 (nth 0 blocks)) 'agenda))
    (should (eq (nth 0 (nth 1 blocks)) 'tags-todo))
    (should (equal (nth 1 (nth 1 blocks)) "MW_FOCUS_TODAY=\"t\""))
    (should (equal (nth 1 (nth 2 blocks)) "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""))
    (should (equal (nth 1 (nth 3 blocks)) "TODO=\"WAIT\""))
    ;; Inbox is the last block (R6).
    (should (eq (nth 0 (nth 4 blocks)) 'tags-todo))
    (should (equal (nth 1 (nth 4 blocks)) "TODO=\"INBOX\""))))

(ert-deftest mindwtr-agenda-engage-headers-are-plain-ascii ()
  "Every block header is plain ASCII text -- no emoji or icon characters (R12)."
  (dolist (block (nth 2 (mindwtr-agenda--engage-spec)))
    (let ((header (mindwtr-agenda-test--block-header block)))
      (should (stringp header))
      (should (string-match-p "\\`[[:ascii:]]+\\'" header)))))

(ert-deftest mindwtr-agenda-engage-calendar-keeps-org-deadline-default ()
  "The calendar block does not override `org-deadline-warning-days' -- the
look-ahead window follows the user's org default (R2)."
  (let* ((blocks (nth 2 (mindwtr-agenda--engage-spec)))
         (settings (car (last (nth 0 blocks)))))
    (should-not (assq 'org-deadline-warning-days settings))))

(ert-deftest mindwtr-agenda-engage-focus-dedups-against-next ()
  "Behavioral (AE1): run the focus and next-actions match strings the spec
actually uses against a rendered buffer with a focused NEXT and an unfocused
NEXT.  The focused task appears under focus and NOT under next; the unfocused
one appears under next.  This catches a wrong-but-plausible match string a
structure-only assertion would miss."
  (let* ((blocks (nth 2 (mindwtr-agenda--engage-spec)))
         (focus-match (nth 1 (nth 1 blocks)))
         (next-match (nth 1 (nth 2 blocks))))
    (mindwtr-agenda-test--with-appdata
        '(:areas nil :projects nil :sections nil
          :tasks ((:id "t1" :title "Focused" :status "next" :isFocusedToday t)
                  (:id "t2" :title "Plain" :status "next"))
          :settings nil)
      (let ((focus (org-map-entries (lambda () (org-get-heading t t t t)) focus-match))
            (next (org-map-entries (lambda () (org-get-heading t t t t)) next-match)))
        (should (member "Focused" focus))
        (should-not (member "Plain" focus))
        (should (member "Plain" next))
        (should-not (member "Focused" next))))))

(defun mindwtr-agenda-test--iso-days (n)
  "Return a date-only ISO string N days from today."
  (format-time-string "%Y-%m-%d" (time-add nil (days-to-time n))))

(defun mindwtr-agenda-test--engage-text (appdata)
  "Render APPDATA to a temp Mindwtr file, run `mindwtr-engage', return the
agenda buffer's text."
  (let ((file (make-temp-file "mw-agenda" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (mindwtr-model-todo-keyword-line) "\n"
                    (mindwtr-render-appdata appdata)))
          (let ((mindwtr-file file)
                (org-agenda-files (list file))
                (org-agenda-window-setup 'current-window)
                (org-agenda-sticky nil))
            (mindwtr-engage))
          (with-current-buffer org-agenda-buffer-name
            (buffer-substring-no-properties (point-min) (point-max))))
      (when (get-buffer org-agenda-buffer-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer org-agenda-buffer-name)))
      (delete-file file))))

(ert-deftest mindwtr-agenda-engage-calendar-honors-deadline-window ()
  "Behavioral (AE3): a deadline inside org's default warning window surfaces on
today's calendar block; one beyond it does not."
  (let ((text (mindwtr-agenda-test--engage-text
               `(:areas nil :projects nil :sections nil
                 :tasks ((:id "t1" :title "DueSoon" :status "next"
                          :dueDate ,(mindwtr-agenda-test--iso-days 7))
                         (:id "t2" :title "DueFar" :status "next"
                          :dueDate ,(mindwtr-agenda-test--iso-days 60)))
                 :settings nil))))
    ;; The calendar block renders an upcoming deadline as "In N d.: NEXT Title".
    ;; That marker only appears in the calendar block (Next Actions lists both
    ;; tasks bare), so matching it -- not bare presence -- proves the calendar
    ;; surfaced the near deadline and skipped the far one.
    (should (string-match-p "In +[0-9]+ d\\.: +NEXT DueSoon" text))
    (should-not (string-match-p "In +[0-9]+ d\\.: +NEXT DueFar" text))))

;;; mindwtr-agenda-test.el ends here
