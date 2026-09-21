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
(AE: projects belong to the Projects view).

The delegated task is filed under an ACTIVE project on purpose.  Parking it
under the waiting project would make this fixture lie: the match string would
still find it, but the built view drops it (see
`mindwtr-agenda-engage-hides-a-waiting-project-delegation')."
  (let* ((blocks (nth 2 (mindwtr-agenda--engage-spec)))
         (wait-match (nth 1 (nth 3 blocks))))
    (mindwtr-agenda-test--with-appdata
        '(:areas nil
          :projects ((:id "p1" :title "Blocked proj" :status "waiting" :order 1)
                     (:id "p2" :title "Live proj" :status "active" :order 2))
          :sections nil
          :tasks ((:id "t1" :title "Awaiting reply" :status "waiting" :projectId "p2"))
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

(ert-deftest mindwtr-agenda-engage-calendar-shows-owning-project ()
  "Behavioral: a task scheduled today under a project leads its calendar-block
line with the project name, in place of org's filename category -- which would
otherwise render as \"mindwtr:\" or the bare \"???\" placeholder."
  (let* ((text (mindwtr-agenda-test--engage-text
                `(:areas nil
                  :projects ((:id "p1" :title "Atlas" :status "active"))
                  :sections nil
                  :tasks ((:id "t1" :title "Order supplies" :status "next"
                           :projectId "p1"
                           :startTime ,(mindwtr-agenda-test--iso-days 0)))
                  :settings nil)))
         ;; Isolate the calendar block ("Today" .. "Today's Focus") so the
         ;; project prefix is asserted there, not in Next Actions.
         (today (mindwtr-agenda-test--block-slice text "Today" "Today's Focus")))
    (should (string-match-p "Atlas +.*NEXT Order supplies" today))
    (should-not (string-match-p "\\?\\?\\?" today))
    (should-not (string-match-p "mindwtr:" today))))

(ert-deftest mindwtr-agenda-resolve-prefix-blank-off-heading ()
  "Unit: on an auxiliary agenda line (time grid, `now' marker) the `%(...)'
escape evaluates with point in the agenda buffer, not an Org heading.  The
resolver must not error there -- it returns a blank, width-padded column so grid
lines stay aligned under the project/area heading column."
  (with-temp-buffer
    (fundamental-mode)
    (let ((prefix (mindwtr-agenda--resolve-prefix)))
      (should (string-match-p "\\`[ ]+\\'" prefix))
      (should (= (length prefix) mindwtr-agenda-prefix-width)))))

(defun mindwtr-agenda-test--block-slice (text start-header end-header)
  "Return the slice of agenda TEXT under START-HEADER, up to END-HEADER.
Isolates a single Engage block so a test can assert what that block lists --
bare presence in the whole buffer is too weak, since the calendar block can
surface the same task by its date."
  (let* ((beg (string-match (regexp-quote start-header) text))
         (end (and beg (string-match (regexp-quote end-header) text (1+ beg)))))
    (substring text beg end)))

(ert-deftest mindwtr-agenda-engage-next-actions-defers-future-ticklers ()
  "Behavioral: a NEXT task SCHEDULED in the future is a tickler (Clarify's defer
outcome) -- not actionable until its start date -- so it must not appear in Next
Actions.  A task starting today, an overdue tickler, and a task with no start
date all stay listed: only strictly-future ones are deferred."
  (let* ((text (mindwtr-agenda-test--engage-text
                `(:areas nil :projects nil :sections nil
                  :tasks ((:id "t1" :title "Deferred" :status "next"
                           :startTime ,(mindwtr-agenda-test--iso-days 7))
                          (:id "t2" :title "StartsToday" :status "next"
                           :startTime ,(mindwtr-agenda-test--iso-days 0))
                          (:id "t3" :title "Overdue" :status "next"
                           :startTime ,(mindwtr-agenda-test--iso-days -3))
                          (:id "t4" :title "Anytime" :status "next"))
                  :settings nil)))
         (next (mindwtr-agenda-test--block-slice text "Next Actions" "Waiting For")))
    (should-not (string-match-p "Deferred" next))
    (should (string-match-p "Anytime" next))
    (should (string-match-p "StartsToday" next))
    (should (string-match-p "Overdue" next))))

(defun mindwtr-agenda-test--engage-category-of (appdata title)
  "Run `mindwtr-engage' on APPDATA; return the `org-category' text property of
the agenda line whose heading matches TITLE (as a string), or nil.
This is the exact key `org-agenda-filter-by-category' (`<') compares, so it is
the faithful proxy for what the native category filter would keep.
`org-element-use-cache' is bound nil per the Org 9.6 cold-scan note on
`mindwtr-agenda-test--engage-text'."
  (let ((file (make-temp-file "mw-agenda" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert (mindwtr-render-appdata appdata)))
          (let ((mindwtr-file file)
                (org-element-use-cache nil)
                (org-agenda-window-setup 'current-window)
                (org-agenda-sticky nil))
            (mindwtr-engage))
          (with-current-buffer org-agenda-buffer-name
            (goto-char (point-min))
            (when (re-search-forward (regexp-quote title) nil t)
              (let ((cat (get-text-property (match-beginning 0) 'org-category)))
                (and cat (format "%s" cat))))))
      (when (get-buffer org-agenda-buffer-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer org-agenda-buffer-name)))
      (delete-file file))))

(ert-deftest mindwtr-agenda-engage-categories-inherit-for-native-filter ()
  "R6/AE1: org's native category filter (`<') narrows the Engage agenda by area.
A project's drawer `:CATEGORY:' inherits to its child NEXT task (which carries no
local category), while a standalone task carries its own -- so the two lines hold
distinct `org-category' text properties, the exact key
`org-agenda-filter-by-category' compares.  Asserting the inherited value proves
`<' on the area would keep the project-child line visible."
  (let ((appdata '(:areas ((:id "a1" :name "Work") (:id "a2" :name "Home"))
                   :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
                   :sections nil
                   :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1")
                           (:id "t2" :title "Chore" :status "next" :areaId "a2"))
                   :settings nil)))
    ;; Child task inherits the project's area category (the inherited-filter case).
    (should (equal (mindwtr-agenda-test--engage-category-of appdata "Sub") "Work"))
    ;; Standalone task carries its own -- distinct, so `<' separates the two.
    (should (equal (mindwtr-agenda-test--engage-category-of appdata "Chore") "Home"))))

;;; U4 -- Projects view --------------------------------------------------------

(defun mindwtr-agenda-test--projects-match ()
  "Return the match string of the Projects view's active block."
  (nth 1 (nth 0 (nth 2 (mindwtr-agenda--projects-spec)))))

(defun mindwtr-agenda-test--projects-text (appdata)
  "Render APPDATA to a temp Mindwtr file, run `mindwtr-projects', return the
agenda buffer text.  `org-element-use-cache' is bound nil for the same Org 9.6
cold-scan reason documented on `mindwtr-agenda-test--engage-text'."
  (let ((file (make-temp-file "mw-agenda" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file (insert (mindwtr-render-appdata appdata)))
          (let ((mindwtr-file file)
                (org-element-use-cache nil)
                (org-agenda-window-setup 'current-window)
                (org-agenda-sticky nil))
            (mindwtr-projects))
          (with-current-buffer org-agenda-buffer-name
            (buffer-substring-no-properties (point-min) (point-max))))
      (when (get-buffer org-agenda-buffer-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer org-agenda-buffer-name)))
      (delete-file file))))

(ert-deftest mindwtr-agenda-projects-waiting-block-renders-without-category ()
  "Behavioral: a waiting project surfaces under the Waiting Projects header,
and -- like the active block -- without org's filename category prefix."
  (let ((text (mindwtr-agenda-test--projects-text
               '(:areas nil
                 :projects ((:id "p1" :title "Active proj" :status "active")
                            (:id "p2" :title "Blocked proj" :status "waiting"))
                 :sections nil :tasks nil :settings nil))))
    (should (string-match-p "Waiting Projects" text))
    (should (string-match-p "WAIT Blocked proj" text))
    ;; The default filename category would render as "<base>: ... WAIT Blocked
    ;; proj"; the project-prefix suppresses it, leaving only blank padding.
    (should-not (string-match-p "[[:alnum:]]+: +WAIT Blocked proj" text))))

(ert-deftest mindwtr-agenda-projects-spec-has-active-and-waiting-blocks ()
  "The Projects spec is two blocks: active projects first (with stuck
flagging), then waiting projects under their own header (R7)."
  (let* ((spec (mindwtr-agenda--projects-spec))
         (blocks (nth 2 spec)))
    (should (= (length blocks) 2))
    (should (eq (nth 0 (nth 0 blocks)) 'tags-todo))
    (should (equal (nth 1 (nth 0 blocks)) "MW_TYPE=\"project\"+TODO=\"ACTIVE\""))
    (should (equal (mindwtr-agenda-test--block-header (nth 0 blocks)) "Projects"))
    (should (eq (nth 0 (nth 1 blocks)) 'tags-todo))
    (should (equal (nth 1 (nth 1 blocks)) "MW_TYPE=\"project\"+TODO=\"WAIT\""))
    (should (equal (mindwtr-agenda-test--block-header (nth 1 blocks))
                   "Waiting Projects"))))

(ert-deftest mindwtr-agenda-projects-waiting-block-matches-waiting-only ()
  "The Waiting Projects block matches waiting projects and not active ones;
the active block, conversely, does not match the waiting project."
  (let* ((blocks (nth 2 (mindwtr-agenda--projects-spec)))
         (active-match (nth 1 (nth 0 blocks)))
         (waiting-match (nth 1 (nth 1 blocks))))
    (mindwtr-agenda-test--with-appdata
        '(:areas nil
          :projects ((:id "p1" :title "Active proj" :status "active")
                     (:id "p2" :title "Waiting proj" :status "waiting"))
          :sections nil :tasks nil :settings nil)
      (let ((waiting (org-map-entries (lambda () (org-get-heading t t t t)) waiting-match))
            (active (org-map-entries (lambda () (org-get-heading t t t t)) active-match)))
        (should (member "Waiting proj" waiting))
        (should-not (member "Active proj" waiting))
        (should (member "Active proj" active))
        (should-not (member "Waiting proj" active))))))

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
  "A project task with no category of its own inherits its project's :CATEGORY:."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Work"))
        :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
        :sections nil
        :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Sub")
    (should (equal (mindwtr-agenda--resolve-area) "Work"))))

(ert-deftest mindwtr-agenda-resolve-area-on-standalone-category ()
  "On a standalone task with its own :CATEGORY:, the resolver returns it."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Work"))
        :projects nil :sections nil
        :tasks ((:id "t1" :title "Solo" :status "next" :areaId "a1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Solo")
    (should (equal (mindwtr-agenda--resolve-area) "Work"))))

(ert-deftest mindwtr-agenda-resolve-area-nil-not-filename-category ()
  "A heading with no CATEGORY anywhere in its ancestry resolves to nil -- NOT
org's filename/buffer category fallback (KTD5) -- so the prefix falls through
to the empty marker instead of leaking the dead `???' / `mindwtr:' slot."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Bare" :status "next"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Bare")
    (should-not (mindwtr-agenda--resolve-area))))

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

(ert-deftest mindwtr-agenda-resolve-prefix-shows-inherited-area-for-nested-task ()
  "A task nested under a project still shows the owning project title (project
wins over the inherited area in the fallback chain), even though its area is
inherited from the project's :CATEGORY:."
  (mindwtr-agenda-test--with-appdata
      '(:areas ((:id "a1" :name "Work"))
        :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
        :sections nil
        :tasks ((:id "t1" :title "Sub" :status "next" :projectId "p1"))
        :settings nil)
    (mindwtr-agenda-test--at-task "Sub")
    ;; resolver reports the inherited area...
    (should (equal (mindwtr-agenda--resolve-area) "Work"))
    ;; ...but the prefix shows the project, which leads the chain.
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

;;; U6 -- sequential projects: blocked steps ------------------------------------

(defmacro mindwtr-agenda-test--with-org (text &rest body)
  "Put TEXT in an org buffer with the Mindwtr TODO keywords registered, run BODY.
The appdata fixture renders only canonical layouts; these cases are about what
a HAND-EDITED buffer does, so they are written as raw org."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-model-todo-keyword-line) "\n" ,text)
       (org-mode))
     (goto-char (point-min))
     ,@body))

(defun mindwtr-agenda-test--blocked-at (title)
  "Move to the task heading named TITLE and return its blocked-step result."
  (goto-char (point-min))
  (re-search-forward (concat "^\\*+ [A-Z]+ " (regexp-quote title) "$"))
  (mindwtr-agenda--blocked-step-p))

(defconst mindwtr-agenda-test--seq-appdata
  '(:areas nil
    :projects ((:id "p1" :title "Seq" :status "active" :order 1
                :isSequential t)
               (:id "p2" :title "Par" :status "active" :order 2))
    :sections nil
    :tasks ((:id "t1" :title "Step one" :status "next" :projectId "p1" :order 1)
            (:id "t2" :title "Step two" :status "next" :projectId "p1" :order 2)
            (:id "u1" :title "Free one" :status "next" :projectId "p2" :order 1)
            (:id "u2" :title "Free two" :status "next" :projectId "p2" :order 2))
    :settings nil)
  "Two projects with two NEXT steps each; only the first is sequential.")

(ert-deftest mindwtr-agenda-sequential-first-step-holds-the-slot ()
  "Step 1 of a sequential project is actionable; step 2 is blocked."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--seq-appdata
    (should-not (mindwtr-agenda-test--blocked-at "Step one"))
    (should (mindwtr-agenda-test--blocked-at "Step two"))))

(ert-deftest mindwtr-agenda-non-sequential-project-blocks-nothing ()
  "A project without MW_SEQUENTIAL keeps every step actionable."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--seq-appdata
    (should-not (mindwtr-agenda-test--blocked-at "Free one"))
    (should-not (mindwtr-agenda-test--blocked-at "Free two"))))

(ert-deftest mindwtr-agenda-standalone-task-blocks-nothing ()
  "A task with no owning project is never a blocked step."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "s1" :title "Loose end" :status "next"))
        :settings nil)
    (should-not (mindwtr-agenda-test--blocked-at "Loose end"))))

(ert-deftest mindwtr-agenda-sequential-done-step-passes-the-slot-on ()
  "A DONE step is complete, so the slot moves to the next incomplete one."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
        :sections nil
        :tasks ((:id "t1" :title "Step one" :status "done" :projectId "p1" :order 1)
                (:id "t2" :title "Step two" :status "next" :projectId "p1" :order 2)
                (:id "t3" :title "Step three" :status "next" :projectId "p1" :order 3))
        :settings nil)
    (should-not (mindwtr-agenda-test--blocked-at "Step two"))
    (should (mindwtr-agenda-test--blocked-at "Step three"))))

(ert-deftest mindwtr-agenda-sequential-waiting-step-still-holds-the-slot ()
  "WAIT is incomplete, so it holds the slot and blocks the steps behind it."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
        :sections nil
        :tasks ((:id "t1" :title "Step one" :status "waiting" :projectId "p1" :order 1)
                (:id "t2" :title "Step two" :status "next" :projectId "p1" :order 2))
        :settings nil)
    (should (mindwtr-agenda-test--blocked-at "Step two"))))

(ert-deftest mindwtr-agenda-sequential-parked-step-does-not-hold-the-slot ()
  "SOMEDAY/REF/INBOX steps are not committed actions, so they never freeze the
steps behind them -- only NEXT and WAIT are in the sequence."
  (dolist (parked '("someday" "reference" "inbox"))
    (mindwtr-agenda-test--with-appdata
        `(:areas nil
          :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
          :sections nil
          :tasks ((:id "t1" :title "Parked step" :status ,parked
                   :projectId "p1" :order 1)
                  (:id "t2" :title "Real step" :status "next"
                   :projectId "p1" :order 2))
          :settings nil)
      (should-not (mindwtr-agenda-test--blocked-at "Real step")))))

(ert-deftest mindwtr-agenda-sequential-no-section-tasks-sort-after-sections ()
  "Upstream's walk is sections first, then No Section -- not document-naive
\"tasks before sections\".  The section's step holds the slot even though the
section-less task carries a lower `:order'."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
        :sections ((:id "s1" :title "Phase one" :projectId "p1" :order 5))
        :tasks ((:id "t1" :title "Sectioned step" :status "next"
                 :projectId "p1" :sectionId "s1" :order 9)
                (:id "t2" :title "Loose step" :status "next"
                 :projectId "p1" :order 1))
        :settings nil)
    (should-not (mindwtr-agenda-test--blocked-at "Sectioned step"))
    (should (mindwtr-agenda-test--blocked-at "Loose step"))))

(ert-deftest mindwtr-agenda-sequential-due-step-takes-the-slot ()
  "A later step that is due today takes the project's slot from step 1."
  (let ((today (format-time-string "%Y-%m-%d")))
    (mindwtr-agenda-test--with-appdata
        `(:areas nil
          :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
          :sections nil
          :tasks ((:id "t1" :title "Step one" :status "next"
                   :projectId "p1" :order 1)
                  (:id "t2" :title "Step two" :status "next"
                   :projectId "p1" :order 2 :dueDate ,today))
          :settings nil)
      (should (mindwtr-agenda-test--blocked-at "Step one"))
      (should-not (mindwtr-agenda-test--blocked-at "Step two")))))

(ert-deftest mindwtr-agenda-sequential-review-due-step-takes-the-slot ()
  "MW_REVIEW_AT in the past also pulls the slot to a later step."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
        :sections nil
        :tasks ((:id "t1" :title "Step one" :status "next"
                 :projectId "p1" :order 1)
                (:id "t2" :title "Step two" :status "next"
                 :projectId "p1" :order 2 :reviewAt "2020-01-01T00:00:00.000Z"))
        :settings nil)
    (should (mindwtr-agenda-test--blocked-at "Step one"))
    (should-not (mindwtr-agenda-test--blocked-at "Step two"))))

(ert-deftest mindwtr-agenda-sequential-future-due-step-leaves-the-slot ()
  "A later step due in the future does not take the slot."
  (let ((later (format-time-string "%Y-%m-%d" (time-add nil (* 30 86400)))))
    (mindwtr-agenda-test--with-appdata
        `(:areas nil
          :projects ((:id "p1" :title "Seq" :status "active" :isSequential t))
          :sections nil
          :tasks ((:id "t1" :title "Step one" :status "next"
                   :projectId "p1" :order 1)
                  (:id "t2" :title "Step two" :status "next"
                   :projectId "p1" :order 2 :dueDate ,later))
          :settings nil)
      (should-not (mindwtr-agenda-test--blocked-at "Step one"))
      (should (mindwtr-agenda-test--blocked-at "Step two")))))

(ert-deftest mindwtr-agenda-sequential-untyped-step-still-holds-the-slot ()
  "A hand-typed action under a project has no `:MW_TYPE:' until the next sync
stamps one.  It must still count as a step -- and with it the project's only
step, nothing may be blocked."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Hand typed action
** NEXT Typed action
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
"
    ;; A second, competing step: without it the assertion would also pass
    ;; through the empty-slot fail-open branch and prove nothing.
    (should-not (mindwtr-agenda-test--blocked-at "Hand typed action"))
    (should (mindwtr-agenda-test--blocked-at "Typed action"))))

(ert-deftest mindwtr-agenda-sequential-finished-step-cannot-hold-the-slot ()
  "DONE/ARCH/REF are outside the eligibility pool upstream filters on, so a
finished step carrying a stale MW_REVIEW_AT or MW_FOCUS_TODAY must not take the
slot -- doing so froze the project permanently."
  (dolist (kw '("DONE" "ARCH" "REF"))
    (mindwtr-agenda-test--with-org (format "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** %s Finished
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:MW_REVIEW_AT: 2020-01-01T00:00:00.000Z
:MW_FOCUS_TODAY: t
:END:
** NEXT Real work
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
" kw)
      (should-not (mindwtr-agenda-test--blocked-at "Real work")))))

(ert-deftest mindwtr-agenda-sequential-all-day-deadline-is-end-of-day ()
  "An all-day deadline is less urgent than a timed one on the same day, not
more: org parses it as midnight, upstream reads it as 23:59:59."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT All day
DEADLINE: <2020-01-01 Wed>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT At nine
DEADLINE: <2020-01-01 Wed 09:00>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (should (mindwtr-agenda-test--blocked-at "All day"))
    (should-not (mindwtr-agenda-test--blocked-at "At nine"))))

(ert-deftest mindwtr-agenda-sequential-nested-project-owns-its-own-sequence ()
  "A project demoted under a sequential one keeps its own chain: its steps must
not take the outer project's slot, and the outer project's own step keeps it."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Outer
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** ACTIVE Inner
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p2
:END:
*** NEXT Inner work
DEADLINE: <2020-01-01 Wed>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Outer work
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (should-not (mindwtr-agenda-test--blocked-at "Outer work"))))

(ert-deftest mindwtr-agenda-sequential-impossible-review-date-is-ignored ()
  "`iso8601-parse' normalizes Feb 30 into March rather than signalling, so a
hand-typo must be rejected explicitly or it becomes a real overdue review."
  (dolist (bad '("2026-02-30T00:00:00.000Z" "2026-13-01T00:00:00.000Z"))
    (mindwtr-agenda-test--with-org (format "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Step one
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:MW_REVIEW_AT: %s
:END:
" bad)
      (should-not (mindwtr-agenda-test--blocked-at "Step one")))))

(ert-deftest mindwtr-agenda-sequential-keyword-titled-section-is-not-a-step ()
  "A section titled \"WAIT Vendor\" renders as `*** WAIT Vendor', which Org reads
as a WAIT heading.  The keyword alone cannot decide what is a step: the section
must not take the slot from the task inside it."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** WAIT Vendor
:PROPERTIES:
:MW_TYPE:  section
:MW_ID:    s1
:END:
*** NEXT Real step
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
"
    (should-not (mindwtr-agenda-test--blocked-at "Real step"))))

(defmacro mindwtr-agenda-test--in-timezone (tz &rest body)
  "Run BODY with the process timezone actually set to TZ, restoring it after.
`process-environment' must NOT be let-bound for this: Emacs reads TZ through
`setenv', so a binding leaves the already-initialized zone in place and a
timezone test silently exercises whatever zone the test runner started in."
  (declare (indent 1))
  `(let ((saved (getenv "TZ")))
     (unwind-protect (progn (setenv "TZ" ,tz) ,@body)
       (setenv "TZ" saved))))

(ert-deftest mindwtr-agenda-all-day-deadline-ranks-at-end-of-day-across-dst ()
  "End of day must resolve in local time.  Carrying midnight's own UTC offset
lands 00:59:59 the NEXT day on a spring-forward date."
  (mindwtr-agenda-test--in-timezone "America/Los_Angeles"
    (mindwtr-agenda-test--with-org "\
* NEXT Spring forward
DEADLINE: <2026-03-08 Sun>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
"
      (goto-char (point-min))
      (re-search-forward "^\\*+ NEXT Spring forward$")
      (should (equal "2026-03-08 23:59:59"
                     (format-time-string
                      "%Y-%m-%d %H:%M:%S"
                      (mindwtr-agenda--deadline-rank-time
                       (org-get-deadline-time (point)))))))))

(ert-deftest mindwtr-agenda-midnight-dst-jump-keeps-the-deadline-due-today ()
  "Where a day has no 23:59 at all (America/Nuuk jumps at local midnight) the
end-of-day instant lands on the NEXT day.  Due-today is therefore decided on
the RAW date, or the deadline reads as future for the whole of its own day."
  (mindwtr-agenda-test--in-timezone "America/Nuuk"
    (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Undated
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Due that day
DEADLINE: <2026-03-28 Sat>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
      (goto-char (point-min))
      (re-search-forward "^\\*+ NEXT Due that day$")
      ;; TODAY is the deadline's own day: scored on that date it must rank 1
      ;; (due), not 2 (undated), or the undated step keeps the slot.
      (let ((today (time-to-days (org-get-deadline-time (point)))))
        (should (= 1 (car (mindwtr-agenda--slot-score (float-time) today))))))))

(ert-deftest mindwtr-agenda-review-rejects-an-impossible-clock-time ()
  "Validating only the calendar date let hour 25 through, and `encode-time'
normalized it into a real -- overdue -- review that took the slot.  Each later
review round found the next leak of the same shape, which is why the shape is
now an allow-list (`mindwtr-agenda--iso-re') rather than a field-by-field test:
an out-of-range offset minute, a fraction on the end-of-day form, a fractional
hour that `iso8601-parse' silently reads as the whole hour."
  (dolist (bad '("2020-03-01T25:00:00Z" "2020-03-01T24:01:00Z" "2020-03-01T23:61:00Z"
                 "2020-03-01T00:00:00+01:99" "2020-03-01T00:00:00+19:00"
                 "2020-03-01T24:00:00.5Z" "2020-03-01T09.5Z"
                 "2020-W54-1" "2020-W05-1" "2020-060"))
    (mindwtr-agenda-test--with-org (format "\
* SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:MW_REVIEW_AT: %s
:END:
" bad)
      (goto-char (point-min))
      (re-search-forward "^\\*+ SOMEDAY Parked$")
      (should-not (mindwtr-agenda--review-time)))))

(ert-deftest mindwtr-agenda-review-accepts-what-the-server-writes ()
  "The allow-list must not have narrowed past the forms actually in play: the
server's own `YYYY-MM-DDTHH:MM:SS.mmmZ', a bare date, and the offset and
minute-precision forms a human plausibly hand-types."
  (dolist (good '("2020-03-01T09:15:00.000Z" "2020-03-01" "2020-03-01T09:15Z"
                  "2020-03-01T22:00:00-05:00" "2020-03-01T09:15:00+05:30"
                  "2020-03-01T24:00:00Z"))
    (mindwtr-agenda-test--with-org (format "\
* SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:MW_REVIEW_AT: %s
:END:
" good)
      (goto-char (point-min))
      (re-search-forward "^\\*+ SOMEDAY Parked$")
      (should (mindwtr-agenda--review-time)))))

(ert-deftest mindwtr-agenda-review-accepts-reduced-precision ()
  "A month- or year-only review date is valid ISO 8601 and resolves to the
first instant of that period; rejecting it silently dropped the review."
  (dolist (case '(("2026-02" . "2026-02-01") ("2026" . "2026-01-01")))
    (mindwtr-agenda-test--with-org (format "\
* SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:MW_REVIEW_AT: %s
:END:
" (car case))
      (goto-char (point-min))
      (re-search-forward "^\\*+ SOMEDAY Parked$")
      (should (equal (cdr case)
                     (format-time-string "%Y-%m-%d" (mindwtr-agenda--review-time)))))))

(ert-deftest mindwtr-agenda-review-accepts-end-of-day-iso-form ()
  "`T24:00:00' is a valid ISO 8601 end-of-day and normalizes to 00:00 the next
day.  Validating the whole timestamp rejected it; only the DATE is checked."
  (mindwtr-agenda-test--with-org "\
* SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:MW_REVIEW_AT: 2020-03-01T24:00:00Z
:END:
"
    (goto-char (point-min))
    (re-search-forward "^\\*+ SOMEDAY Parked$")
    (should (equal "2020-03-02"
                   (format-time-string "%Y-%m-%d" (mindwtr-agenda--review-time) t)))))

(ert-deftest mindwtr-agenda-sequential-blocking-survives-a-narrowed-buffer ()
  "An agenda restriction narrows the source buffer before the skip function
runs.  The project ancestor must still be found, or every step inside a
restriction reads as standalone and a restricted view shows what a full one
hides."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT First
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** Phase
:PROPERTIES:
:MW_TYPE:  section
:MW_ID:    s1
:END:
*** NEXT Second
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (goto-char (point-min))
    (re-search-forward "^\\*+ Phase$")
    (org-narrow-to-subtree)
    (goto-char (point-min))
    (re-search-forward "^\\*+ NEXT Second$")
    (should (mindwtr-agenda--blocked-step-p))))

(ert-deftest mindwtr-agenda-sequential-empty-slot-fails-open ()
  "A sequential project the walk finds no candidate in blocks nothing.
Failing closed hid every action of the project with no way to clear it."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
"
    (goto-char (point-min))
    (re-search-forward "^\\*+ SOMEDAY Parked$")
    (should-not (mindwtr-agenda--blocked-step-p))))

(ert-deftest mindwtr-agenda-skip-does-not-swallow-a-nested-slot-holder ()
  "Skipping a blocked step must not skip past a step nested under it -- that
step is its own candidate and here it is the one holding the slot."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Parent step
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
*** NEXT Child step
DEADLINE: <2020-01-01 Wed>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (let ((child (progn (goto-char (point-min))
                        (re-search-forward "^\\*+ NEXT Child step$")
                        (line-beginning-position))))
      (goto-char (point-min))
      (re-search-forward "^\\*+ NEXT Parent step$")
      (should (mindwtr-agenda--blocked-step-p))
      (should (<= (mindwtr-agenda--skip-blocked-step) child)))))

(ert-deftest mindwtr-agenda-sequential-waiting-deadline-does-not-take-the-slot ()
  "A WAIT step's deadline earns nothing: it is not actionable, so letting it
outrank an earlier NEXT step would hide real work.  It holds by order alone."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Step one
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** WAIT Step two
DEADLINE: <2020-01-01 Wed>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (should-not (mindwtr-agenda-test--blocked-at "Step one"))
    (should (mindwtr-agenda-test--blocked-at "Step two"))))

(ert-deftest mindwtr-agenda-sequential-most-urgent-due-step-takes-the-slot ()
  "Between two overdue steps the slot goes to the MORE overdue one, not the
earlier one in the buffer -- upstream scores by time, order only breaks ties."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Due yesterday
DEADLINE: <2020-06-02 Tue>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Due last week
DEADLINE: <2020-01-01 Wed>
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:END:
"
    (should (mindwtr-agenda-test--blocked-at "Due yesterday"))
    (should-not (mindwtr-agenda-test--blocked-at "Due last week"))))

(ert-deftest mindwtr-agenda-sequential-review-later-today-waits-for-its-instant ()
  "MW_REVIEW_AT is compared as an INSTANT, not a day: a review due at 23:59
must not pull the slot this morning."
  (let ((soon (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                  (time-add nil 3600) t))
        (past (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                  (time-add nil -3600) t)))
    (mindwtr-agenda-test--with-org (format "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Step one
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Review soon
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:MW_REVIEW_AT: %s
:END:
" soon)
      (should-not (mindwtr-agenda-test--blocked-at "Step one"))
      (should (mindwtr-agenda-test--blocked-at "Review soon")))
    (mindwtr-agenda-test--with-org (format "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Step one
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Review passed
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:MW_REVIEW_AT: %s
:END:
" past)
      (should (mindwtr-agenda-test--blocked-at "Step one"))
      (should-not (mindwtr-agenda-test--blocked-at "Review passed")))))

(ert-deftest mindwtr-agenda-sequential-focused-step-takes-the-slot ()
  "A step the user put in Today's Focus outranks everything (upstream rank 0),
so the steps behind it stay blocked."
  (mindwtr-agenda-test--with-org "\
* ACTIVE Seq
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:MW_SEQUENTIAL: t
:END:
** NEXT Step one
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
** NEXT Step two
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t2
:MW_FOCUS_TODAY: t
:END:
"
    (should (mindwtr-agenda-test--blocked-at "Step one"))
    (should-not (mindwtr-agenda-test--blocked-at "Step two"))))

(ert-deftest mindwtr-agenda-skip-function-returns-entry-end-or-nil ()
  "The skip function keeps the slot holder (nil) and skips past a blocked step."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--seq-appdata
    (goto-char (point-min))
    (re-search-forward "^\\*+ NEXT Step one$")
    (should-not (mindwtr-agenda--skip-blocked-step))
    (goto-char (point-min))
    (re-search-forward "^\\*+ NEXT Step two$")
    (let ((end (mindwtr-agenda--skip-blocked-step)))
      (should (integerp end))
      (should (> end (point))))))

;;; U7 -- parked projects: the project-status filter ---------------------------

(defun mindwtr-agenda-test--parked-at (title)
  "Move to the task heading named TITLE and return its parked-project result."
  (goto-char (point-min))
  (re-search-forward (concat "^\\*+ [A-Z]+ " (regexp-quote title) "$"))
  (mindwtr-agenda--parked-project-p))

(defconst mindwtr-agenda-test--parked-appdata
  '(:areas nil
    :projects ((:id "p1" :title "Parked" :status "someday" :order 1)
               (:id "p2" :title "Live" :status "active" :order 2)
               (:id "p3" :title "Pinned" :status "someday" :order 3 :isFocused t)
               (:id "p4" :title "Blocked" :status "waiting" :order 4))
    :sections nil
    :tasks ((:id "t1" :title "Later step" :status "next" :projectId "p1")
            (:id "t2" :title "Now step" :status "next" :projectId "p2")
            (:id "t3" :title "Pinned step" :status "next" :projectId "p3")
            (:id "t4" :title "Held step" :status "next" :projectId "p4"))
    :settings nil)
  "One NEXT step under each project status: someday, active, someday+focused,
waiting.")

(ert-deftest mindwtr-agenda-someday-project-parks-its-steps ()
  "A NEXT step inside a project filed under Someday is not available."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--parked-appdata
    (should (mindwtr-agenda-test--parked-at "Later step"))))

(ert-deftest mindwtr-agenda-active-project-steps-stay-available ()
  "A step of an ACTIVE project is never parked by the project rule."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--parked-appdata
    (should-not (mindwtr-agenda-test--parked-at "Now step"))))

(ert-deftest mindwtr-agenda-focused-parked-project-keeps-its-steps ()
  "MW_FOCUSED (the server's `project.isFocused' pin) un-parks a someday project."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--parked-appdata
    (should-not (mindwtr-agenda-test--parked-at "Pinned step"))))

(ert-deftest mindwtr-agenda-waiting-project-parks-its-steps ()
  "A waiting project is parked too -- only ACTIVE (or focused) is available."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--parked-appdata
    (should (mindwtr-agenda-test--parked-at "Held step"))))

(ert-deftest mindwtr-agenda-standalone-task-is-never-parked ()
  "A task with no owning project has no project status to be parked by."
  (mindwtr-agenda-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "s1" :title "Loose end" :status "next"))
        :settings nil)
    (should-not (mindwtr-agenda-test--parked-at "Loose end"))))

(ert-deftest mindwtr-agenda-nearest-project-decides-parking ()
  "An ACTIVE project demoted under a parked one keeps its own steps available,
matching upstream's single `task.projectId' lookup."
  (mindwtr-agenda-test--with-org
      "* SOMEDAY Parked
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p1
:END:
** ACTIVE Live
:PROPERTIES:
:MW_TYPE:  project
:MW_ID:    p2
:END:
*** NEXT Inner step
:PROPERTIES:
:MW_TYPE:  task
:MW_ID:    t1
:END:
"
    (should-not (mindwtr-agenda-test--parked-at "Inner step"))))

(ert-deftest mindwtr-agenda-untyped-project-heading-fails-open ()
  "A hand-typed project with no MW_TYPE drawer yet must not hide its tasks."
  (mindwtr-agenda-test--with-org
      "* SOMEDAY Parked
** NEXT Typed by hand
"
    (should-not (mindwtr-agenda-test--parked-at "Typed by hand"))))

(ert-deftest mindwtr-agenda-skip-parked-project-returns-entry-end-or-nil ()
  "The parked-project skip keeps an active project's step (nil) and skips past
a parked one."
  (mindwtr-agenda-test--with-appdata mindwtr-agenda-test--parked-appdata
    (goto-char (point-min))
    (re-search-forward "^\\*+ NEXT Now step$")
    (should-not (mindwtr-agenda--skip-parked-project))
    (goto-char (point-min))
    (re-search-forward "^\\*+ NEXT Later step$")
    (let ((end (mindwtr-agenda--skip-parked-project)))
      (should (integerp end))
      (should (> end (point))))))
(ert-deftest mindwtr-agenda-engage-spec-parks-projects-view-wide ()
  "The parked-project skip is a view-wide setting, so it reaches the calendar,
Focus, Waiting and Inbox blocks -- not just Next Actions."
  (let ((gprops (nth 3 (mindwtr-agenda--engage-spec))))
    ;; The GLOBAL hook, not `org-agenda-skip-function': `org-agenda-skip' ORs
    ;; the two, so a block that installs its own skip function (Next Actions
    ;; does) still gets this rule.  Binding the non-global one instead would be
    ;; silently cancelled there.
    (should (equal (cadr (assq 'org-agenda-skip-function-global gprops))
                   ''mindwtr-agenda--skip-parked-project))))

(ert-deftest mindwtr-agenda-engage-hides-a-waiting-project-delegation ()
  "Behavioral, and a deliberate divergence from the naive reading: a delegated
step inside a WAITING project is absent from Waiting For.  Upstream parks
waiting projects exactly like someday ones -- `isTaskInActiveProject' is
active-or-pinned -- and the desktop Waiting list, the mobile task list and the
weekly review's waiting step all drop it too.  The project itself stays
reachable through `mindwtr-projects'."
  (let ((text (mindwtr-agenda-test--engage-text
               '(:areas nil
                 :projects ((:id "p1" :title "Blocked proj" :status "waiting" :order 1)
                            (:id "p2" :title "Live proj" :status "active" :order 2))
                 :sections nil
                 :tasks ((:id "t1" :title "ChaseParked" :status "waiting" :projectId "p1")
                         (:id "t2" :title "ChaseLive" :status "waiting" :projectId "p2"))
                 :settings nil))))
    (should (string-match-p "ChaseLive" text))
    (should-not (string-match-p "ChaseParked" text))))

(ert-deftest mindwtr-agenda-engage-calendar-drops-a-parked-project-date ()
  "Behavioral: the parked-project rule reaches the CALENDAR block too, not just
the tags-todo ones -- a view-wide skip function covers every block.  Upstream
applies the same rule before bucketing a task into a day (`isCalendarFeedTask',
\"the same visibility rule the Calendar view applies\")."
  (let ((text (mindwtr-agenda-test--engage-text
               `(:areas nil
                 :projects ((:id "p1" :title "Parked" :status "someday" :order 1)
                            (:id "p2" :title "Live" :status "active" :order 2))
                 :sections nil
                 :tasks ((:id "t1" :title "ParkedDated" :status "next" :projectId "p1"
                          :dueDate ,(mindwtr-agenda-test--iso-days 0))
                         (:id "t2" :title "LiveDated" :status "next" :projectId "p2"
                          :dueDate ,(mindwtr-agenda-test--iso-days 0)))
                 :settings nil))))
    ;; "Deadline:" only ever appears in the calendar block, so matching it --
    ;; not bare presence -- proves the calendar itself dropped the parked one.
    (should (string-match-p "Deadline: +NEXT LiveDated" text))
    (should-not (string-match-p "Deadline: +NEXT ParkedDated" text))))

(ert-deftest mindwtr-agenda-engage-next-actions-keeps-both-skip-rules ()
  "Behavioral: the Next Actions block installs its own
`org-agenda-skip-function', which REPLACES a view-wide one of the same name --
so the parked rule rides `org-agenda-skip-function-global', which
`org-agenda-skip' ORs with it.  This asserts both rules still fire in that
block at once: the sequential project's second step is blocked, and the parked
project's step is gone.  Binding the non-global hook view-wide would silently
lose the sequential filter here."
  (let ((text (mindwtr-agenda-test--engage-text
               '(:areas nil
                 :projects ((:id "p1" :title "Seq" :status "active" :order 1
                             :isSequential t)
                            (:id "p2" :title "Parked" :status "someday" :order 2))
                 :sections nil
                 :tasks ((:id "t1" :title "SeqStepOne" :status "next" :projectId "p1" :order 1)
                         (:id "t2" :title "SeqStepTwo" :status "next" :projectId "p1" :order 2)
                         (:id "t3" :title "ParkedStep" :status "next" :projectId "p2"))
                 :settings nil))))
    (should (string-match-p "SeqStepOne" text))
    (should-not (string-match-p "SeqStepTwo" text))
    (should-not (string-match-p "ParkedStep" text))))

(ert-deftest mindwtr-agenda-engage-hides-parked-project-next-actions ()
  "Behavioral: a NEXT step of a someday project is absent from the whole Engage
view, while the active project's step and the pinned project's step remain."
  (let ((text (mindwtr-agenda-test--engage-text
               mindwtr-agenda-test--parked-appdata)))
    (should (string-match-p "Now step" text))
    (should (string-match-p "Pinned step" text))
    (should-not (string-match-p "Later step" text))
    (should-not (string-match-p "Held step" text))))

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
