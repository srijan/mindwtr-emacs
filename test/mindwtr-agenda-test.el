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
    (should (equal (nth 1 (nth 3 blocks)) "TODO=\"WAIT\"+MW_TYPE=\"task\""))
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
agenda buffer's text.

`org-element-use-cache' is bound nil here: Org 9.6.x (Emacs 29's bundled Org,
what CI runs) has an element-cache regression where a COLD agenda scan -- org
opening a fresh file buffer and scanning it before the cache is consistent --
intermittently misses deadlines.  It is fixed in Org 9.7+ and does not affect
interactive use, where the Mindwtr file is already open in a warm buffer (a
warm-buffer scan surfaces the deadline correctly even on 9.6).  Disabling the
cache here isolates the test from that unrelated upstream bug so it verifies
the calendar's deadline-window logic, not org's cache implementation."
  (let ((file (make-temp-file "mw-agenda" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (mindwtr-render-appdata appdata)))
          (let ((mindwtr-file file)
                (org-element-use-cache nil)
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

(ert-deftest mindwtr-agenda-engage-waiting-excludes-projects ()
  "The Waiting For block lists waiting tasks only.  A project in the waiting
state shares the WAIT keyword but is not an action -- it must not appear here
(AE: projects belong to the Projects view)."
  (let* ((blocks (nth 2 (mindwtr-agenda--engage-spec)))
         (wait-match (nth 1 (nth 3 blocks))))
    (mindwtr-agenda-test--with-appdata
        '(:areas nil
          :projects ((:id "p1" :title "Blocked proj" :status "waiting"))
          :sections nil
          :tasks ((:id "t1" :title "Awaiting reply" :status "waiting" :projectId "p1"))
          :settings nil)
      (let ((hits (org-map-entries (lambda () (org-get-heading t t t t)) wait-match)))
        (should (member "Awaiting reply" hits))
        (should-not (member "Blocked proj" hits))))))

(ert-deftest mindwtr-agenda-engage-next-actions-show-owning-project ()
  "Behavioral: a NEXT action under a project shows the project name in its
agenda prefix, replacing the useless filename category (\"mindwtr:\")."
  (let ((text (mindwtr-agenda-test--engage-text
               '(:areas nil
                 :projects ((:id "p1" :title "Atlas" :status "active"))
                 :sections nil
                 :tasks ((:id "t1" :title "Ship it" :status "next" :projectId "p1"))
                 :settings nil))))
    (should (string-match-p "Atlas +NEXT Ship it" text))
    (should-not (string-match-p "mindwtr: +NEXT Ship it" text))))

;;; U4 -- Projects view --------------------------------------------------------

(defun mindwtr-agenda-test--projects-match ()
  "Return the match string of the Projects view's single block."
  (nth 1 (nth 0 (nth 2 (mindwtr-agenda--projects-spec)))))

(ert-deftest mindwtr-agenda-projects-spec-is-single-active-project-block ()
  "The Projects spec is one block matching active projects (R7)."
  (let* ((spec (mindwtr-agenda--projects-spec))
         (blocks (nth 2 spec)))
    (should (= (length blocks) 1))
    (should (eq (nth 0 (nth 0 blocks)) 'tags-todo))
    (should (equal (nth 1 (nth 0 blocks)) "MW_TYPE=\"project\"+TODO=\"ACTIVE\""))))

(ert-deftest mindwtr-agenda-project-prefix-flags-stuck-only ()
  "The prefix returns the STUCK marker at a stuck project and blanks at a
non-stuck one (R8)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Stalled" :status "active")
                   (:id "p2" :title "Moving" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Act" :status "next" :projectId "p2"))
        :settings nil)
    (goto-char (point-min))
    (re-search-forward "ACTIVE Stalled")
    (let ((pfx (mindwtr-agenda--project-prefix)))
      (should (string-match-p "STUCK" pfx)))
    (goto-char (point-min))
    (re-search-forward "ACTIVE Moving")
    (let ((pfx (mindwtr-agenda--project-prefix)))
      (should-not (string-match-p "STUCK" pfx))
      (should (string-match-p "\\`[ ]+\\'" pfx)))))

(ert-deftest mindwtr-agenda-project-prefix-is-plain-ascii ()
  "The stuck marker is plain ASCII -- no emoji or icons (R12)."
  (should (string-match-p "\\`[[:ascii:]]+\\'" mindwtr-agenda--stuck-flag))
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Stalled" :status "active"))
        :sections nil :tasks nil :settings nil)
    (re-search-forward "ACTIVE Stalled")
    (should (string-match-p "\\`[[:ascii:]]+\\'"
                            (mindwtr-agenda--project-prefix)))))

(ert-deftest mindwtr-agenda-projects-match-excludes-archived ()
  "An ARCH project is not matched by the Projects spec (AE4)."
  (let ((match (mindwtr-agenda-test--projects-match)))
    (with-temp-buffer
      (let ((org-todo-keywords mindwtr-model-todo-keywords)
            (org-inhibit-startup t))
        (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                "** ACTIVE Live\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
                "** ARCH Gone\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p2\n:END:\n")
        (org-mode))
      (let ((hits (org-map-entries (lambda () (org-get-heading t t t t)) match)))
        (should (member "Live" hits))
        (should-not (member "Gone" hits))))))

;;; U6 -- prefix resolver (owning project / area) ------------------------------

(defun mindwtr-agenda-test--at-task (title)
  "Move point onto the NEXT task heading named TITLE."
  (goto-char (point-min))
  (re-search-forward (concat "NEXT " (regexp-quote title))))

(ert-deftest mindwtr-agenda-resolve-project-returns-parent-project-title ()
  "A task nested under a project resolves to that project's clean title."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Atlas Rollout" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Do it" :status "next" :projectId "p1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Do it")
    (should (equal (mindwtr-agenda--resolve-project) "Atlas Rollout"))))

(ert-deftest mindwtr-agenda-resolve-project-nil-for-standalone-action ()
  "A standalone single action has no owning project."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Lone task" :status "next"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Lone task")
    (should-not (mindwtr-agenda--resolve-project))))

(ert-deftest mindwtr-agenda-resolve-project-finds-project-through-section ()
  "A task under a section still resolves to the enclosing project (whole
ancestry walk, not just the direct parent)."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Deep Proj" :status "active"))
        :sections ((:id "s1" :title "Phase 1" :projectId "p1"))
        :tasks ((:id "t1" :title "Nested act" :status "next"
                 :projectId "p1" :sectionId "s1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Nested act")
    (should (equal (mindwtr-agenda--resolve-project) "Deep Proj"))))

(ert-deftest mindwtr-agenda-resolve-area-inherits-project-area ()
  "A project task with no area of its own inherits its project's MW_AREA."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Work"))
        :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
        :sections nil
        :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Sub")
    (should (equal (mindwtr-agenda--resolve-area) "Work"))))

(ert-deftest mindwtr-agenda-resolve-prefix-prefers-project-over-area ()
  "When a task has both an owning project and an area, the prefix shows the
project (R: project leads the fallback chain)."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Work"))
        :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
        :sections nil
        :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Sub")
    (should (string-match-p "\\`Proj *\\'" (mindwtr-agenda--resolve-prefix)))))

(ert-deftest mindwtr-agenda-resolve-prefix-uses-area-when-no-project ()
  "A standalone action with its own area shows the area (project slot empty)."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Home"))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Chore" :status "next" :areaId "a1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Chore")
    (should (string-match-p "\\`Home *\\'" (mindwtr-agenda--resolve-prefix)))))

(ert-deftest mindwtr-agenda-resolve-prefix-empty-marker-when-unfiled ()
  "An action with neither project nor area shows the empty marker."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Bare" :status "next"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Bare")
    (should (string-match-p (concat "\\`" (regexp-quote mindwtr-agenda--prefix-empty))
                            (mindwtr-agenda--resolve-prefix)))))

(ert-deftest mindwtr-agenda-resolve-prefix-truncates-to-width ()
  "A long owning-project title is truncated to `mindwtr-agenda-prefix-width'
with an ellipsis."
  (let ((mindwtr-agenda-prefix-width 10))
    (mindwtr-agenda-test--with-appdata
        '(:areas nil
          :projects ((:id "p1" :title "A very long project title" :status "active"))
          :sections nil
          :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1"))
          :settings nil)
      (mindwtr-agenda-test--at-task "Sub")
      (let ((pfx (mindwtr-agenda--resolve-prefix)))
        (should (= (string-width pfx) 10))
        (should (string-suffix-p mindwtr-agenda-prefix-ellipsis pfx))))))

;;; U5 -- setup / keybindings ---------------------------------------------------

(defmacro mindwtr-agenda-test--with-sandbox-global-map (&rest body)
  "Run BODY with a fresh global keymap, restoring the real one afterward."
  (declare (indent 0))
  `(let ((saved (current-global-map)))
     (unwind-protect
         (progn (use-global-map (make-sparse-keymap)) ,@body)
       (use-global-map saved))))

(ert-deftest mindwtr-agenda-setup-binds-default-prefix ()
  "After setup, C-c d e -> engage and C-c d p -> projects (R10, overridden)."
  (mindwtr-agenda-test--with-sandbox-global-map
    (let ((mindwtr-agenda-prefix-key "C-c d"))
      (mindwtr-agenda-setup))
    (should (eq (key-binding (kbd "C-c d e")) 'mindwtr-engage))
    (should (eq (key-binding (kbd "C-c d p")) 'mindwtr-projects))))

(ert-deftest mindwtr-agenda-setup-honors-custom-prefix ()
  "A custom `mindwtr-agenda-prefix-key' binds the commands under that prefix."
  (mindwtr-agenda-test--with-sandbox-global-map
    (let ((mindwtr-agenda-prefix-key "C-c m"))
      (mindwtr-agenda-setup))
    (should (eq (key-binding (kbd "C-c m e")) 'mindwtr-engage))
    (should (eq (key-binding (kbd "C-c m p")) 'mindwtr-projects))))

(ert-deftest mindwtr-agenda-setup-is-idempotent ()
  "Calling setup twice leaves a single consistent binding."
  (mindwtr-agenda-test--with-sandbox-global-map
    (let ((mindwtr-agenda-prefix-key "C-c d"))
      (mindwtr-agenda-setup)
      (mindwtr-agenda-setup))
    (should (eq (key-binding (kbd "C-c d e")) 'mindwtr-engage))
    (should (eq (key-binding (kbd "C-c d p")) 'mindwtr-projects))))

;;; mindwtr-agenda-test.el ends here
