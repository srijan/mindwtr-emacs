;;; mindwtr-render-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-render)

(ert-deftest mindwtr-render-task-heading ()
  (let* ((task '(:id "t1" :mw-kind task :title "Buy milk" :status "next"
                 :priority "high" :contexts ("@errands") :tags ("#focused")
                 :energyLevel "medium" :description "notes"
                 :mw-extra-props nil))
         (shadow '(:createdAt "2026-01-01T10:00:00Z"
                   :updatedAt "2026-05-30T15:30:00Z"))
         (text (mindwtr-render-heading task 4 shadow)))
    ;; Org syntax requires the TODO keyword before the priority cookie:
    ;; `STARS KEYWORD [#PRIORITY] TITLE'.  This is the only order org can
    ;; parse back, so render must emit it this way.
    (should (string-match-p "^\\*\\*\\*\\* NEXT \\[#B\\] Buy milk" text))
    (should (string-match-p ":@errands:focused:" text))
    (should (string-match-p ":MW_TYPE: task" text))
    (should (string-match-p ":MW_ID: t1" text))
    (should (string-match-p ":MW_ENERGY: medium" text))
    (should (string-match-p ":MW_CREATED: \\[2026-01-01" text))
    (should (string-match-p "^notes$" text))))

(ert-deftest mindwtr-render-date-only-scheduled ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :startTime "2026-06-20" :mw-extra-props nil) 2 nil)))
    (should (string-match-p "SCHEDULED: <2026-06-20 Sat>" text))))

(ert-deftest mindwtr-render-closed-from-completedAt ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "done"
                 :completedAt "2026-05-31T17:39:53.268Z" :mw-extra-props nil) 2 nil)))
    (should (string-match-p "CLOSED: \\[2026-05-31" text))))

(ert-deftest mindwtr-render-area-no-keyword ()
  (let ((text (mindwtr-render-heading
               '(:id "a1" :mw-kind area :name "Work" :mw-extra-props nil) 1 nil)))
    (should (string-match-p "^\\* Work" text))
    (should (string-match-p ":MW_TYPE: area" text))))

(ert-deftest mindwtr-render-recurrence-is-readable ()
  "Recurrence renders as the rrule/rule string, not a Lisp sexp."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :recurrence (:rule "monthly" :strategy "strict" :rrule "FREQ=MONTHLY"))
               1 nil)))
    (should (string-match-p ":MW_RECURRENCE: FREQ=MONTHLY" text))
    (should-not (string-match-p ":rule" text))
    (should-not (string-match-p ":strategy" text))))

(ert-deftest mindwtr-render-recurrence-rule-fallback ()
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :recurrence (:rule "weekly"))
               1 nil)))
    (should (string-match-p ":MW_RECURRENCE: weekly" text))))

(ert-deftest mindwtr-render-emits-area-name-from-map ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (puthash "a1" "Personal" mindwtr-render-area-names)
    (let ((text (mindwtr-render-heading
                 '(:id "p1" :mw-kind project :title "Proj" :status "active" :areaId "a1")
                 2 nil)))
      (should (string-match-p ":CATEGORY: Personal" text))
      (should-not (string-match-p ":MW_AREA:" text))
      (should-not (string-match-p ":MW_AREA_ID:" text)))))

(ert-deftest mindwtr-render-no-area-when-absent ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (let ((text (mindwtr-render-heading
                 '(:id "t1" :mw-kind task :title "x" :status "next") 2 nil)))
      (should-not (string-match-p ":CATEGORY:" text))
      (should-not (string-match-p ":MW_AREA:" text)))))

(ert-deftest mindwtr-render-no-category-when-area-unresolvable ()
  "An :areaId absent from the names map renders no category line, no crash."
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (let ((text (mindwtr-render-heading
                 '(:id "p1" :mw-kind project :title "Proj" :status "active" :areaId "missing")
                 2 nil)))
      (should-not (string-match-p ":CATEGORY:" text))
      (should-not (string-match-p ":MW_AREA:" text)))))

(ert-deftest mindwtr-render-appdata-builds-lists ()
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0))
               :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1" :order 0))
               :sections nil
               :tasks ((:id "t1" :title "loose next" :status "next" :order 0)
                       (:id "t2" :title "in project" :status "next" :projectId "p1" :order 0)
                       (:id "t3" :title "old captured" :status "inbox")
                       (:id "t4" :title "gone" :status "archived")
                       (:id "t5" :title "deleted" :status "next" :deletedAt "2026-01-01T00:00:00Z"))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    ;; v3 containers exist in order
    (should (string-match-p "^\\* Inbox$" text))
    (should (string-match-p "^\\* Single Actions$" text))
    (should (string-match-p "^\\* Projects$" text))
    (should (string-match-p "^\\* Someday$" text))
    (should (string-match-p "^\\* Reference$" text))
    (should (string-match-p "^\\* Areas of Focus$" text))
    ;; standalone next under Single Actions; project task NOT a standalone
    (should (string-match-p "loose next" text))
    (should (string-match-p "old captured" text))
    (should (string-match-p "Proj" text))
    (should (string-match-p "in project" text))
    (should (string-match-p ":CATEGORY: Personal" text))
    ;; archived + tombstoned tasks NOT rendered
    (should-not (string-match-p "gone" text))
    (should-not (string-match-p "deleted" text))
    (should (string-match-p "^\\*\\* Personal$" text))))

(ert-deftest mindwtr-render-appdata-v3-splits-someday-and-waiting ()
  "Waiting projects sit under * Projects with active ones; someday tasks and
projects live under the nested * Someday container."
  (let* ((ad '(:areas nil
               :projects ((:id "pa" :title "ActiveProj" :status "active" :order 0)
                          (:id "pw" :title "WaitingProj" :status "waiting" :order 1)
                          (:id "ps" :title "SomedayProj" :status "someday" :order 2))
               :sections nil
               :tasks ((:id "ts" :title "someday single" :status "someday")
                       (:id "tp" :title "someday proj task" :status "next" :projectId "ps"))
               :settings nil))
         (text (mindwtr-render-appdata ad))
         ;; positions of the structural anchors
         (single (string-match "^\\* Single Actions$" text))
         (projects (string-match "^\\* Projects$" text))
         (someday (string-match "^\\* Someday$" text))
         (sd-single (string-match "^\\*\\* Single Actions$" text))
         (sd-projects (string-match "^\\*\\* Projects$" text))
         (reference (string-match "^\\* Reference$" text)))
    ;; nested Someday children exist as level-2 containers
    (should sd-single)
    (should sd-projects)
    ;; active and waiting projects are under top-level * Projects (before * Someday)
    (should (< projects (string-match "ActiveProj" text) someday))
    (should (< projects (string-match "WaitingProj" text) someday))
    ;; someday project + its task are under the nested ** Projects (after * Someday)
    (should (< someday sd-projects (string-match "SomedayProj" text) reference))
    (should (< (string-match "SomedayProj" text)
               (string-match "someday proj task" text)))
    ;; someday standalone task under nested ** Single Actions
    (should (< sd-single (string-match "someday single" text) sd-projects))
    ;; the nested children sit inside the Someday subtree
    (should (< someday sd-single))))

(ert-deftest mindwtr-render-appdata-leads-with-todo-keyword-line ()
  "The rendered buffer opens with an in-buffer `#+TODO:' line so the Mindwtr
keywords are registered regardless of the user's global `org-todo-keywords'."
  (let ((text (mindwtr-render-appdata
               '(:areas nil :projects nil :sections nil :tasks nil :settings nil))))
    (should (string-prefix-p (concat (mindwtr-model-todo-keyword-line) "\n") text))))

(ert-deftest mindwtr-render-appdata-orders-and-groups ()
  "Standalone tasks sort by :order; projects group by area :order then :order."
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0)
                       (:id "a2" :name "Work" :order 1))
               :projects ((:id "p2" :title "WorkProj" :status "active" :areaId "a2" :order 0)
                          (:id "p1" :title "PersA" :status "active" :areaId "a1" :order 1)
                          (:id "p0" :title "PersB" :status "active" :areaId "a1" :order 0)
                          (:id "p9" :title "Floating" :status "active" :order 0))
               :sections nil
               :tasks ((:id "t1" :title "second" :status "next" :order 1)
                       (:id "t2" :title "first" :status "next" :order 0))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    ;; tasks ordered
    (should (< (string-match "first" text) (string-match "second" text)))
    ;; projects: Personal area (order 0) group before Work; within Personal, order 0 (PersB) before order 1 (PersA); area-less Floating last
    (should (< (string-match "PersB" text) (string-match "PersA" text)))
    (should (< (string-match "PersA" text) (string-match "WorkProj" text)))
    (should (< (string-match "WorkProj" text) (string-match "Floating" text)))))

(ert-deftest mindwtr-render--mw->org-text-conversions ()
  "Markdown link syntax in a description converts to org links."
  ;; labelled link
  (should (string= (mindwtr-render--mw->org-text "see [the docs](https://example.com)")
                   "see [[https://example.com][the docs]]"))
  ;; label == url collapses to the canonical label-less org form
  (should (string= (mindwtr-render--mw->org-text "see [https://example.com](https://example.com)")
                   "see [[https://example.com]]"))
  ;; multiple links on one line
  (should (string= (mindwtr-render--mw->org-text "[x](a) and [y](b)")
                   "[[a][x]] and [[b][y]]"))
  ;; no links: passthrough (and nil-safe)
  (should (string= (mindwtr-render--mw->org-text "plain prose, no links") "plain prose, no links"))
  (should (null (mindwtr-render--mw->org-text nil))))

(ert-deftest mindwtr-render--mw->org-text-parens-in-url ()
  "A url containing balanced parens survives the conversion intact.
Regression: a naive `[^)]*' url group truncates at the first inner `)',
corrupting the link and breaking round-trip byte-stability."
  ;; single parens-bearing url with a label
  (should (string= (mindwtr-render--mw->org-text
                    "[Foo](https://en.wikipedia.org/wiki/Foo_(bar))")
                   "[[https://en.wikipedia.org/wiki/Foo_(bar)][Foo]]"))
  ;; still converts multiple links on one line, parens or not
  (should (string= (mindwtr-render--mw->org-text
                    "[a](http://x/y_(z)) and [b](http://q)")
                   "[[http://x/y_(z)][a]] and [[http://q][b]]"))
  ;; a label that legitimately contains `)' is not regressed
  (should (string= (mindwtr-render--mw->org-text "[a(b)c](http://x)")
                   "[[http://x][a(b)c]]"))
  ;; parens url whose label equals the url still collapses to label-less form
  (should (string= (mindwtr-render--mw->org-text
                    "[http://x/(y)](http://x/(y))")
                   "[[http://x/(y)]]")))

(ert-deftest mindwtr-render--mw->org-text-empty-label ()
  "An empty markdown label `[](url)' collapses to the canonical `[[url]]'.
Rendering `[[url][]]' would produce invalid org, so an empty label is
treated like label==url."
  (should (string= (mindwtr-render--mw->org-text "see [](https://example.com) now")
                   "see [[https://example.com]] now")))

(ert-deftest mindwtr-render-description-links-converted ()
  "A task's markdown description renders org links into the buffer body."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :description "Check [the site](https://example.com) later."
                 :mw-extra-props nil) 2 nil)))
    (should (string-match-p "Check \\[\\[https://example.com\\]\\[the site\\]\\] later\\." text))))

(ert-deftest mindwtr-render-project-notes-as-body ()
  "Covers R1.  A project's :supportNotes renders as inline body prose after the
PROPERTIES :END:, like a task description."
  (let ((text (mindwtr-render-heading
               '(:id "p1" :mw-kind project :title "Proj" :status "active"
                 :supportNotes "Project planning notes." :mw-extra-props nil)
               2 nil)))
    (should (string-match-p ":MW_TYPE: project" text))
    (should (string-match-p "^Project planning notes\\.$" text))
    ;; the note sits AFTER the drawer's :END:, not inside the drawer.
    (should (string-match-p ":END:\nProject planning notes\\." text))))

(ert-deftest mindwtr-render-section-notes-as-body ()
  "Covers R2.  A section's :description renders as inline body prose."
  (let ((text (mindwtr-render-heading
               '(:id "s1" :mw-kind section :title "Sec"
                 :description "Section notes here." :mw-extra-props nil)
               3 nil)))
    (should (string-match-p ":MW_TYPE: section" text))
    (should (string-match-p "^Section notes here\\.$" text))))

(ert-deftest mindwtr-render-project-notes-links-converted ()
  "Covers R7 (render half).  Markdown links in :supportNotes become org links."
  (let ((text (mindwtr-render-heading
               '(:id "p1" :mw-kind project :title "x" :status "active"
                 :supportNotes "See [docs](https://example.com) now."
                 :mw-extra-props nil) 2 nil)))
    (should (string-match-p "See \\[\\[https://example.com\\]\\[docs\\]\\] now\\." text))))

(ert-deftest mindwtr-render-area-notes-none ()
  "An area has no notes field, so it never emits a body even if a stray
:description/:supportNotes value is present on the plist."
  (let ((text (mindwtr-render-heading
               '(:id "a1" :mw-kind area :name "Work"
                 :description "should not render" :supportNotes "nor this"
                 :mw-extra-props nil) 1 nil)))
    (should-not (string-match-p "should not render" text))
    (should-not (string-match-p "nor this" text))))

(ert-deftest mindwtr-render-task-desc-then-checklist-unchanged ()
  "A task still renders :description followed by its checklist (no regression)."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :description "Task notes."
                 :checklist ((:title "one" :isCompleted :false)
                             (:title "two" :isCompleted t))
                 :mw-extra-props nil) 2 nil)))
    (should (string-match-p "Task notes\\.\n- \\[ \\] one\n- \\[X\\] two" text))))

(ert-deftest mindwtr-render-focus-today-true-renders ()
  "A task with :isFocusedToday t renders a :MW_FOCUS_TODAY: t drawer line."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :isFocusedToday t :mw-extra-props nil) 2 nil)))
    (should (string-match-p "^:MW_FOCUS_TODAY: t$" text))))

(ert-deftest mindwtr-render-focus-today-false-omits ()
  "A task with :isFocusedToday :false renders no MW_FOCUS_TODAY line."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :isFocusedToday :false :mw-extra-props nil) 2 nil)))
    (should-not (string-match-p "MW_FOCUS_TODAY" text))))

(ert-deftest mindwtr-render-focus-today-absent-omits ()
  "A task with no :isFocusedToday key renders no MW_FOCUS_TODAY line."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :mw-extra-props nil) 2 nil)))
    (should-not (string-match-p "MW_FOCUS_TODAY" text))))

(ert-deftest mindwtr-render-project-booleans-mixed ()
  "A project with :isSequential t and :isFocused :false renders only SEQUENTIAL."
  (let ((text (mindwtr-render-heading
               '(:id "p1" :mw-kind project :title "x" :status "active"
                 :isSequential t :isFocused :false :mw-extra-props nil) 2 nil)))
    (should (string-match-p "^:MW_SEQUENTIAL: t$" text))
    (should-not (string-match-p "MW_FOCUSED" text))))

;;; U3: archive surface render -----------------------------------------------

(require 'mindwtr-parse)

(defconst mindwtr-render-archive--appdata
  '(:tasks ((:id "t1" :title "Lone archived" :status "archived")
            (:id "t2" :title "Archived loose task" :status "archived"
             :projectId "plive")
            (:id "t3" :title "Done child" :status "done" :sectionId "s1")
            (:id "t4" :title "Archived child" :status "archived" :projectId "parch")
            (:id "tlive" :title "Still active" :status "next")
            (:id "ttomb" :title "Gone" :status "archived" :deletedAt "2026-06-01T00:00:00Z"))
    :projects ((:id "parch" :title "Archived Project" :status "archived")
               (:id "plive" :title "An Active Project" :status "active"))
    :sections ((:id "s1" :projectId "parch" :title "Phase 1"))
    :areas nil :settings nil)
  "Mixed appdata exercising every archive-render branch.")

(ert-deftest mindwtr-render-archive-layout ()
  "Container, flat archived tasks (owned one carrying MW_PROJECT_ID), the
archived project subtree with its done child; live + tombstoned absent."
  (let ((text (mindwtr-render-archive-appdata mindwtr-render-archive--appdata)))
    ;; container
    (should (string-match-p "^\\* Archive" text))
    (should (string-match-p ":MW_LIST: archive" text))
    ;; flat standalone archived task at level 2
    (should (string-match-p "^\\*\\* ARCH Lone archived" text))
    ;; flat archived task owned by a live project carries the containment prop
    (should (string-match-p "^\\*\\* ARCH Archived loose task" text))
    (should (string-match-p ":MW_PROJECT_ID: plive" text))
    ;; archived project renders as a subtree at level 2, section at 3, child at 4
    (should (string-match-p "^\\*\\* ARCH Archived Project" text))
    (should (string-match-p "^\\*\\*\\* Phase 1" text))
    (should (string-match-p "^\\*\\*\\*\\* DONE Done child" text))
    ;; archived section-less child of the archived project at level 3
    (should (string-match-p "^\\*\\*\\* ARCH Archived child" text))
    ;; live and tombstoned entities never appear
    (should-not (string-match-p "Still active" text))
    (should-not (string-match-p "Gone" text))
    ;; the live project itself is not rendered (only archived projects are)
    (should-not (string-match-p "An Active Project" text))))

(ert-deftest mindwtr-render-archive-child-appears-once ()
  "A done child of an archived project appears inside the subtree, never flat."
  (let* ((text (mindwtr-render-archive-appdata mindwtr-render-archive--appdata))
         (start 0) (n 0))
    (while (string-match "Done child" text start)
      (setq n (1+ n) start (match-end 0)))
    (should (= n 1))))

(ert-deftest mindwtr-render-archive-round-trips-byte-stable ()
  "Covers R4.  render -> parse -> render reproduces identical bytes."
  (let* ((text1 (mindwtr-render-archive-appdata mindwtr-render-archive--appdata))
         (reparsed (with-temp-buffer
                     (let ((org-inhibit-startup t)) (insert text1) (org-mode))
                     (mindwtr-parse-buffer)))
         (text2 (mindwtr-render-archive-appdata reparsed)))
    (should (string= text1 text2))))

(ert-deftest mindwtr-render-archive-empty-is-just-container ()
  "Appdata with no archived entities renders only the keyword line + container."
  (let ((text (mindwtr-render-archive-appdata
               '(:tasks ((:id "t1" :title "x" :status "next"))
                 :projects nil :sections nil :areas nil :settings nil))))
    (should (string-match-p "^\\* Archive" text))
    (should-not (string-match-p "^\\*\\*" text))))

(ert-deftest mindwtr-render-appdata-emits-people-container ()
  "Appdata with people emits a `MW_LIST: people' container with a heading per
person: name as heading text, MW_ID in the drawer."
  (let* ((ad '(:tasks nil :projects nil :sections nil :areas nil
               :people ((:id "pe1" :name "Alex Rivera")
                        (:id "pe2" :name "Sam Park"))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    (should (string-match-p "^\\* People$" text))
    (should (string-match-p "^:MW_LIST: people$" text))
    (should (string-match-p "^\\*\\* Alex Rivera$" text))
    (should (string-match-p "^\\*\\* Sam Park$" text))
    (should (string-match-p ":MW_ID: pe1" text))
    (should (string-match-p ":MW_TYPE: person" text))))

(ert-deftest mindwtr-render-person-note-and-reference-link ()
  "A person with :note renders body prose; :referenceLink renders the drawer prop."
  (let* ((ad '(:tasks nil :projects nil :sections nil :areas nil
               :people ((:id "pe1" :name "Sam Park"
                         :note "Met at the conference."
                         :referenceLink "https://example.com/sam"))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    (should (string-match-p "^:MW_REFERENCE_LINK: https://example.com/sam$" text))
    (should (string-match-p "^Met at the conference\\.$" text))))

(ert-deftest mindwtr-render-people-sorted-by-name ()
  "People render sorted by name regardless of input order (KTD5)."
  (let* ((ad '(:tasks nil :projects nil :sections nil :areas nil
               :people ((:id "pe1" :name "Zoe")
                        (:id "pe2" :name "Alex")
                        (:id "pe3" :name "Maria"))
               :settings nil))
         (text (mindwtr-render-appdata ad))
         (a (string-match "Alex" text))
         (m (string-match "Maria" text))
         (z (string-match "Zoe" text)))
    (should (and a m z))
    (should (< a m))
    (should (< m z))))

(ert-deftest mindwtr-render-people-tombstones-not-rendered ()
  "A tombstoned person is filtered by render--live."
  (let* ((ad '(:tasks nil :projects nil :sections nil :areas nil
               :people ((:id "pe1" :name "Live Person")
                        (:id "pe2" :name "Dead Person"
                         :deletedAt "2026-01-01T00:00:00Z"))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    (should (string-match-p "Live Person" text))
    (should-not (string-match-p "Dead Person" text))))

(ert-deftest mindwtr-render-clock-synced-emits-when-positive ()
  "A positive :mw-clock-synced renders MW_CLOCK_SYNCED (U2)."
  (let ((text (mindwtr-render-heading
               '(:id "t1" :mw-kind task :title "x" :status "next"
                 :mw-clock-synced 60 :mw-extra-props nil) 2 nil)))
    (should (string-match-p "^:MW_CLOCK_SYNCED: 60$" text))))

(ert-deftest mindwtr-render-clock-synced-omitted-when-zero-or-nil ()
  "0 or nil :mw-clock-synced omits the property (absent = 0 fixed point) (U2)."
  (dolist (v '(0 nil))
    (let ((text (mindwtr-render-heading
                 (list :id "t1" :mw-kind 'task :title "x" :status "next"
                       :mw-clock-synced v :mw-extra-props nil) 2 nil)))
      (should-not (string-match-p "MW_CLOCK_SYNCED" text)))))
