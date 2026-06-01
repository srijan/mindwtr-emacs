# GTD-List Org Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the area-heading containment tree with a fixed GTD-list org layout (Inbox/Next Actions/Waiting/Someday/Reference/Projects + Areas of Focus), where a task's list comes from its status, projects keep nested tasks, and area is an `:MW_AREA:` property.

**Architecture:** A new pure renderer `mindwtr-render-appdata` produces the whole canonical buffer from `AppData`; reconcile becomes a full-buffer rebuild that preserves per-id org-only content (LOGBOOK/CLOCK, unknown PROPERTIES) and restores point by id. Parsing resolves `areaId` from `:MW_AREA:` (via an in-file name→id map) instead of ancestry; `projectId`/`sectionId` still come from ancestry. Archived entities are shadow-only.

**Tech Stack:** Emacs Lisp (28.1+), `ert`, `cl-lib`, `org`. Tests via `make test` / `make compile`. Spec: `docs/superpowers/specs/2026-06-01-mindwtr-gtd-list-layout-design.md`.

**Conventions for every task:** before running tests, `find . -name '*.elc' -delete`. Run the full suite with
`emacs -Q --batch -L . -L smoke -L test -l ert $(for f in test/*-test.el; do echo "-l $f"; done) -f ert-run-tests-batch-and-exit`
and the compile gate with `make compile` (must exit 0). Commit messages end with
`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work directly on `main`.

---

## File Structure

| File | Responsibility in this change |
|---|---|
| `mindwtr-model.el` | New: list-role registry, role→title, status→list map. Pure data. |
| `mindwtr-render.el` | New: `mindwtr-render-appdata` (full canonical renderer), `:MW_AREA:` emission via an id→name map, readable recurrence. |
| `mindwtr-parse.el` | `areaId` from `:MW_AREA:` (+ in-file name→id map); keep project/section ancestry; recognize `MW_AREA`. |
| `mindwtr-reconcile.el` | `mindwtr-reconcile-buffer` becomes a full rebuild preserving per-id org-only content + point. `restore-entity`/`--rebuild-entry` kept for the conflict-restore action. |
| `mindwtr-sync.el` | Deletion detection skips `status = archived` shadow entities. |
| `test/*` | Update parse/render/roundtrip/reconcile fixtures to the new layout; add coverage for lists, areas, archived, ordering. |

---

## Task 1: Model — list roles, titles, status→list map

**Files:**
- Modify: `mindwtr-model.el` (after `mindwtr-model--project-status-keywords`, ~line 21)
- Test: `test/mindwtr-model-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-model-test.el`:

```elisp
(ert-deftest mindwtr-model-list-roles-and-titles ()
  (should (equal mindwtr-model-list-roles
                 '("inbox" "next-actions" "waiting" "someday" "reference" "projects" "areas")))
  (should (string= (mindwtr-model-list-title "next-actions") "Next Actions"))
  (should (string= (mindwtr-model-list-title "areas") "Areas of Focus")))

(ert-deftest mindwtr-model-status->list-maps-standalone-statuses ()
  (should (string= (mindwtr-model-status->list "inbox") "inbox"))
  (should (string= (mindwtr-model-status->list "next") "next-actions"))
  (should (string= (mindwtr-model-status->list "done") "next-actions"))
  (should (string= (mindwtr-model-status->list "waiting") "waiting"))
  (should (string= (mindwtr-model-status->list "someday") "someday"))
  (should (string= (mindwtr-model-status->list "reference") "reference"))
  ;; archived has no list -> not rendered
  (should (null (mindwtr-model-status->list "archived"))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-model-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-model-list-roles` / `mindwtr-model-status->list` void.

- [ ] **Step 3: Implement**

Add to `mindwtr-model.el` after line 21:

```elisp
(defconst mindwtr-model-list-roles
  '("inbox" "next-actions" "waiting" "someday" "reference" "projects" "areas")
  "Ordered top-level container roles, used as `:MW_LIST:' discriminators.")

(defconst mindwtr-model--list-titles
  '(("inbox" . "Inbox") ("next-actions" . "Next Actions") ("waiting" . "Waiting")
    ("someday" . "Someday") ("reference" . "Reference") ("projects" . "Projects")
    ("areas" . "Areas of Focus")))

(defun mindwtr-model-list-title (role)
  "Default heading text for a container ROLE."
  (or (cdr (assoc role mindwtr-model--list-titles))
      (error "Unknown list role: %s" role)))

(defconst mindwtr-model--status->list
  '(("inbox" . "inbox") ("next" . "next-actions") ("done" . "next-actions")
    ("waiting" . "waiting") ("someday" . "someday") ("reference" . "reference"))
  "Status -> list role for a STANDALONE task.  `archived' is absent on
purpose: archived tasks are not rendered.")

(defun mindwtr-model-status->list (status)
  "Return the list role a standalone task with STATUS renders under, or nil
when it must not be rendered (e.g. `archived')."
  (cdr (assoc status mindwtr-model--status->list)))
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-model.el test/mindwtr-model-test.el
git commit -m "feat(model): list roles, titles, and status->list map"
```

---

## Task 2: Render — readable recurrence

**Files:**
- Modify: `mindwtr-render.el` (the drawer-emission loop, ~lines 109-114)
- Test: `test/mindwtr-render-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-render-test.el`:

```elisp
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-render-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — current code renders `(:rule monthly :strategy strict ...)`.

- [ ] **Step 3: Implement**

Add this helper to `mindwtr-render.el` (before `mindwtr-render-heading`):

```elisp
(defun mindwtr-render--recurrence (rec)
  "Render a recurrence value REC as a readable drawer string.
REC is a plist (e.g. (:rule \"monthly\" :rrule \"FREQ=MONTHLY\")); prefer
the rrule, then the human rule, falling back to a printed form."
  (cond
   ((stringp rec) rec)
   ((and (consp rec) (keywordp (car rec)))
    (or (plist-get rec :rrule) (plist-get rec :rule) (format "%s" rec)))
   (t (format "%s" rec))))
```

Change the drawer-emission loop (currently lines 109-114) to special-case recurrence:

```elisp
    (dolist (k mindwtr-render--drawer-order)
      (let ((v (plist-get entity k)))
        (when v
          (push (format ":%s: %s" (cdr (assq k mindwtr-render--prop-names))
                        (cond ((eq k :recurrence) (mindwtr-render--recurrence v))
                              ((eq v t) "t")
                              (t v)))
                lines))))
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-render.el test/mindwtr-render-test.el
git commit -m "feat(render): readable recurrence string instead of Lisp sexp"
```

---

## Task 3: Render — `:MW_AREA:` emission via id→name map

**Files:**
- Modify: `mindwtr-render.el` (`mindwtr-render--drawer-order`, `mindwtr-render--prop-names`, `mindwtr-render-heading`)
- Test: `test/mindwtr-render-test.el`

This drops the old `:MW_AREA_ID:`/`:mw-area-override` drawer entry and instead emits `:MW_AREA: <name>` for any entity that has an `:areaId`, resolving the name from the dynamically-bound `mindwtr-render-area-names` (id→name hash).

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-render-test.el`:

```elisp
(ert-deftest mindwtr-render-emits-area-name-from-map ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (puthash "a1" "Personal" mindwtr-render-area-names)
    (let ((text (mindwtr-render-heading
                 '(:id "p1" :mw-kind project :title "Proj" :status "active" :areaId "a1")
                 2 nil)))
      (should (string-match-p ":MW_AREA: Personal" text))
      (should-not (string-match-p ":MW_AREA_ID:" text)))))

(ert-deftest mindwtr-render-no-area-when-absent ()
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (let ((text (mindwtr-render-heading
                 '(:id "t1" :mw-kind task :title "x" :status "next") 2 nil)))
      (should-not (string-match-p ":MW_AREA:" text)))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-render-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-render-area-names` void / no `:MW_AREA:` emitted.

- [ ] **Step 3: Implement**

In `mindwtr-render.el`:

a. Add the dynamic var near the top (after the `require`s):

```elisp
(defvar mindwtr-render-area-names nil
  "Hash table id->name for resolving `:MW_AREA:' during rendering.
Dynamically bound by `mindwtr-render-appdata' / reconcile.")
```

b. Remove `:mw-area-override` from `mindwtr-render--drawer-order` (it becomes):

```elisp
(defconst mindwtr-render--drawer-order
  '(:energyLevel :timeEstimate :recurrence :assignedTo :focusToday
    :reviewAt :location :taskMode :sequential :focused :attach)
  "Canonical order of content properties in the drawer.")
```

c. Remove the `(:mw-area-override . "MW_AREA_ID")` pair from `mindwtr-render--prop-names`.

d. In `mindwtr-render-heading`, immediately after the `(push (format ":MW_ID: ...))` line, insert area emission:

```elisp
    (push (format ":MW_ID: %s" (plist-get entity :id)) lines)
    (let ((aid (plist-get entity :areaId)))
      (when (and aid mindwtr-render-area-names)
        (let ((name (gethash aid mindwtr-render-area-names)))
          (when name (push (format ":MW_AREA: %s" name) lines)))))
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

NOTE: `test/mindwtr-roundtrip-test.el` will be updated in Task 6; if any roundtrip test referencing `MW_AREA_ID` fails now, leave it — Task 6 rewrites those fixtures.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-render.el test/mindwtr-render-test.el
git commit -m "feat(render): emit :MW_AREA: name from id->name map; drop MW_AREA_ID"
```

---

## Task 4: Render — `mindwtr-render-appdata` (canonical full renderer)

**Files:**
- Modify: `mindwtr-render.el` (add `cl-lib` require; add the functions below; `provide` stays last)
- Test: `test/mindwtr-render-test.el`

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-render-test.el`:

```elisp
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
    ;; containers exist in order
    (should (string-match-p "^\\* Inbox$" text))
    (should (string-match-p "^\\* Next Actions$" text))
    (should (string-match-p "^\\* Projects$" text))
    (should (string-match-p "^\\* Areas of Focus$" text))
    ;; standalone next under Next Actions; project task NOT a standalone
    (should (string-match-p "loose next" text))
    ;; inbox task under Inbox
    (should (string-match-p "old captured" text))
    ;; project + nested task
    (should (string-match-p "Proj" text))
    (should (string-match-p "in project" text))
    ;; project carries area name
    (should (string-match-p ":MW_AREA: Personal" text))
    ;; archived + tombstoned tasks NOT rendered
    (should-not (string-match-p "gone" text))
    (should-not (string-match-p "deleted" text))
    ;; area entity under Areas of Focus
    (should (string-match-p "^\\*\\* Personal$" text))))

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-render-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-render-appdata` void.

- [ ] **Step 3: Implement**

At the top of `mindwtr-render.el` add `(require 'cl-lib)`. Add these functions before `(provide 'mindwtr-render)`:

```elisp
(defun mindwtr-render--area-name-map (appdata)
  "Return a hash id->name for APPDATA's areas."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (a (plist-get appdata :areas))
      (when (plist-get a :id)
        (puthash (plist-get a :id) (or (plist-get a :name) "") h)))
    h))

(defun mindwtr-render--area-order-map (appdata)
  "Return a hash areaId->:order for APPDATA's areas."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (a (plist-get appdata :areas))
      (puthash (plist-get a :id) (or (plist-get a :order) most-positive-fixnum) h))
    h))

(defun mindwtr-render--container (role level)
  "Render the list container heading for ROLE at outline LEVEL."
  (format "%s %s\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: %s\n:END:\n"
          (make-string level ?*) (mindwtr-model-list-title role) role))

(defun mindwtr-render--order-key (e)
  (or (plist-get e :order) (plist-get e :orderNum) most-positive-fixnum))

(defun mindwtr-render--sorted (entities)
  "Stable sort ENTITIES by :order/:orderNum; entities without an order keep
their incoming relative position and sort last."
  (let ((i 0) keyed)
    (dolist (e entities)
      (push (list (mindwtr-render--order-key e) i e) keyed)
      (setq i (1+ i)))
    (mapcar (lambda (x) (nth 2 x))
            (sort (nreverse keyed)
                  (lambda (a b)
                    (if (= (nth 0 a) (nth 0 b)) (< (nth 1 a) (nth 1 b))
                      (< (nth 0 a) (nth 0 b))))))))

(defun mindwtr-render--sorted-projects (projects area-order)
  "Sort PROJECTS grouped by area (AREA-ORDER hash areaId->order, area-less
last), then by project :order, stably."
  (let ((i 0) keyed)
    (dolist (p projects)
      (let ((ao (if (plist-get p :areaId)
                    (gethash (plist-get p :areaId) area-order most-positive-fixnum)
                  most-positive-fixnum)))
        (push (list ao (mindwtr-render--order-key p) i p) keyed))
      (setq i (1+ i)))
    (mapcar (lambda (x) (nth 3 x))
            (sort (nreverse keyed)
                  (lambda (a b)
                    (cond ((/= (nth 0 a) (nth 0 b)) (< (nth 0 a) (nth 0 b)))
                          ((/= (nth 1 a) (nth 1 b)) (< (nth 1 a) (nth 1 b)))
                          (t (< (nth 2 a) (nth 2 b)))))))))

(defun mindwtr-render--graft-org-only (rendered id org-only)
  "Inject preserved org-only body for ID into RENDERED after PROPERTIES :END:."
  (let ((p (and org-only (gethash id org-only))))
    (if (not (and p (plist-get p :body))) rendered
      (let ((i (string-match "\n:END:\n" rendered)))
        (if (not i) rendered
          (let ((cut (+ i (length "\n:END:\n"))))
            (concat (substring rendered 0 cut) (plist-get p :body)
                    (substring rendered cut))))))))

(defun mindwtr-render--entity (e kind level org-only)
  "Render entity E (KIND) at LEVEL, injecting extra-props and org-only body
for E's id from ORG-ONLY (a hash id -> (:body STR :extra PLIST), or nil)."
  (let* ((id (plist-get e :id))
         (p (and org-only (gethash id org-only)))
         (e2 (plist-put (plist-put (copy-sequence e) :mw-kind kind)
                        :mw-extra-props (and p (plist-get p :extra)))))
    (mindwtr-render--graft-org-only (mindwtr-render-heading e2 level e2) id org-only)))

(defun mindwtr-render--live (entities &optional drop-archived)
  "Return ENTITIES without tombstones (and without archived if DROP-ARCHIVED)."
  (cl-remove-if (lambda (e)
                  (or (plist-get e :deletedAt)
                      (and drop-archived (equal (plist-get e :status) "archived"))))
                entities))

(defun mindwtr-render-appdata (appdata &optional org-only)
  "Render APPDATA to the canonical GTD-list org layout, returning a string.
ORG-ONLY, when given, is a hash id -> (:body STR :extra PLIST) of org-only
content to preserve across a reconcile.  Tombstoned and archived entities
are not rendered."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         (areas (mindwtr-render--live (plist-get appdata :areas)))
         (projects (mindwtr-render--live (plist-get appdata :projects) t))
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks) t))
         (out ""))
    ;; Standalone task lists (no project, no section), placed by status.
    (dolist (role '("inbox" "next-actions" "waiting" "someday" "reference"))
      (setq out (concat out (mindwtr-render--container role 1)))
      (dolist (e (mindwtr-render--sorted
                  (cl-remove-if-not
                   (lambda (e)
                     (and (not (plist-get e :projectId))
                          (not (plist-get e :sectionId))
                          (equal (mindwtr-model-status->list (plist-get e :status)) role)))
                   tasks)))
        (setq out (concat out (mindwtr-render--entity e 'task 2 org-only)))))
    ;; Projects, grouped by area then order; each with sections+tasks nested.
    (setq out (concat out (mindwtr-render--container "projects" 1)))
    (dolist (proj (mindwtr-render--sorted-projects projects area-order))
      (setq out (concat out (mindwtr-render--entity proj 'project 2 org-only)))
      (dolist (sec (mindwtr-render--sorted
                    (cl-remove-if-not
                     (lambda (s) (equal (plist-get s :projectId) (plist-get proj :id)))
                     sections)))
        (setq out (concat out (mindwtr-render--entity sec 'section 3 org-only)))
        (dolist (tk (mindwtr-render--sorted
                     (cl-remove-if-not
                      (lambda (tk) (equal (plist-get tk :sectionId) (plist-get sec :id)))
                      tasks)))
          (setq out (concat out (mindwtr-render--entity tk 'task 4 org-only)))))
      (dolist (tk (mindwtr-render--sorted
                   (cl-remove-if-not
                    (lambda (tk) (and (equal (plist-get tk :projectId) (plist-get proj :id))
                                      (not (plist-get tk :sectionId))))
                    tasks)))
        (setq out (concat out (mindwtr-render--entity tk 'task 3 org-only)))))
    ;; Areas of Focus reference section.
    (setq out (concat out (mindwtr-render--container "areas" 1)))
    (dolist (a (mindwtr-render--sorted areas))
      (setq out (concat out (mindwtr-render--entity a 'area 2 org-only))))
    out))
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-render.el test/mindwtr-render-test.el
git commit -m "feat(render): mindwtr-render-appdata canonical GTD-list layout"
```

---

## Task 5: Parse — `areaId` from `:MW_AREA:`; keep project/section ancestry

**Files:**
- Modify: `mindwtr-parse.el` (`mindwtr-parse--known-props`; `mindwtr-parse-buffer`; `mindwtr-parse-heading`)
- Test: `test/mindwtr-parse-test.el`

Areas are resolved from a name→id map built from the buffer's area headings; `projectId`/`sectionId` keep using ancestry; the old area-ancestry and `MW_AREA_ID`-override logic is removed.

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-parse-test.el`:

```elisp
(ert-deftest mindwtr-parse-area-from-property ()
  "areaId comes from :MW_AREA: resolved against Areas-of-Focus headings,
not from an ancestor area heading; project/section come from ancestry."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:MW_AREA: Personal\n:END:\n"
              "*** NEXT child\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT loose\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:MW_AREA: Personal\n:END:\n"
              "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
              "** Personal\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (proj (car (plist-get ad :projects)))
           (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get ad :tasks)))
           (t2 (seq-find (lambda (e) (equal (plist-get e :id) "t2")) (plist-get ad :tasks))))
      ;; project's area from its MW_AREA property
      (should (string= (plist-get proj :areaId) "a1"))
      ;; nested task: projectId from ancestry, NO areaId (no MW_AREA)
      (should (string= (plist-get t1 :projectId) "p1"))
      (should-not (plist-get t1 :areaId))
      ;; loose task: areaId from MW_AREA, no project
      (should (string= (plist-get t2 :areaId) "a1"))
      (should-not (plist-get t2 :projectId))
      ;; containers are not entities
      (should (= (length (plist-get ad :areas)) 1)))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-parse-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — area resolved by ancestry / `MW_AREA` ignored.

- [ ] **Step 3: Implement**

In `mindwtr-parse.el`:

a. Add `"MW_AREA"` to `mindwtr-parse--known-props` (and remove nothing else):

```elisp
(defconst mindwtr-parse--known-props
  '("MW_TYPE" "MW_ID" "MW_ENERGY" "MW_TIME_ESTIMATE" "MW_RECURRENCE"
    "MW_ASSIGNED_TO" "MW_FOCUS_TODAY" "MW_REVIEW_AT" "MW_LOCATION"
    "MW_TASK_MODE" "MW_SEQUENTIAL" "MW_FOCUSED" "MW_AREA_ID" "MW_AREA" "MW_ATTACH"
    "MW_CREATED" "MW_UPDATED" "MW_TAGS" "MW_CONTEXTS")
  "PROPERTIES keys the parser interprets; all others are preserved verbatim.")
```

b. Add the dynamic var and a map builder near the top (after the requires):

```elisp
(defvar mindwtr-parse--area-names nil
  "Hash name->id for resolving :MW_AREA:; dynamically bound by `mindwtr-parse-buffer'.")

(defun mindwtr-parse--build-area-names ()
  "Scan the current buffer for area headings, returning a name->id hash.
Warns on a duplicate name (keeps the first id)."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") "area")
         (let ((name (org-get-heading t t t t)) (id (mindwtr-parse--prop "MW_ID")))
           (when (and name id)
             (if (gethash name h)
                 (message "mindwtr: duplicate area name %S; keeping first" name)
               (puthash name id h)))))))
    h))

(defun mindwtr-parse--area-id (entity-area-name)
  "Resolve an :MW_AREA: ENTITY-AREA-NAME to an area id, or nil."
  (and entity-area-name mindwtr-parse--area-names
       (gethash entity-area-name mindwtr-parse--area-names)))
```

c. In `mindwtr-parse-heading`, set `areaId` from the `MW_AREA` property for project and task, and DROP the ancestry-based area derivation. Replace the project and task containment blocks:

For the project branch — currently in `mindwtr-parse-buffer` an `:areaId` is added via `mindwtr-parse--ancestor-id 'area`. Move area to the property. The cleanest place is in `mindwtr-parse-heading` itself. Add, right before the closing of the `(when (eq kind 'task) ...)` form is the task drawer fields, but containment is added in `mindwtr-parse-buffer`. To keep one source of truth, set `:areaId` in `mindwtr-parse-heading` for all kinds from `MW_AREA`:

In `mindwtr-parse-heading`, after the `(e (list :id id :mw-kind kind ...))` is built and the kind-specific title/status set, add:

```elisp
    (let ((aid (mindwtr-parse--area-id (mindwtr-parse--prop "MW_AREA"))))
      (when aid (setq e (plist-put e :areaId aid))))
```

d. In `mindwtr-parse-buffer`: (1) bind the area-names map; (2) remove the area-ancestry and `MW_AREA_ID`-override code. The `project`/`task` clauses become:

```elisp
(defun mindwtr-parse-buffer ()
  "Parse the current org buffer into a content appdata plist."
  (mindwtr-parse-ensure-keywords)
  (let ((mindwtr-parse--area-names (mindwtr-parse--build-area-names))
        tasks projects sections areas)
    (org-map-entries
     (lambda ()
       (let ((kind (mindwtr-parse--prop "MW_TYPE")))
         (when (and kind (not (string= kind "container")))
           (let ((e (mindwtr-parse-heading)))
             (pcase (intern kind)
               ('area (push (mindwtr-parse--strip-internal e) areas))
               ('project (push (mindwtr-parse--strip-internal e) projects))
               ('section
                (let ((pid (mindwtr-parse--ancestor-id 'project)))
                  (when pid (setq e (plist-put e :projectId pid))))
                (push (mindwtr-parse--strip-internal e) sections))
               ('task
                (let ((sid (mindwtr-parse--ancestor-id 'section))
                      (pid (mindwtr-parse--ancestor-id 'project)))
                  (cond (sid (setq e (plist-put e :sectionId sid)))
                        (pid (setq e (plist-put e :projectId pid)))))
                (push (mindwtr-parse--strip-internal e) tasks))))))))
    (list :tasks (nreverse tasks) :projects (nreverse projects)
          :sections (nreverse sections) :areas (nreverse areas))))
```

Note: `areaId` is now set inside `mindwtr-parse-heading` (step c) for every kind, so `mindwtr-parse-buffer` no longer touches area. The `:mw-area-override` key and `MW_AREA_ID` handling are removed.

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-parse.el test/mindwtr-parse-test.el
git commit -m "feat(parse): areaId from :MW_AREA: property; keep project/section ancestry"
```

---

## Task 6: Round-trip — `render-appdata → parse` is signature-stable

**Files:**
- Modify: `test/mindwtr-roundtrip-test.el` (update fixtures to the new layout; add full-appdata round-trip)
- Test: `test/mindwtr-roundtrip-test.el`

The existing roundtrip tests place a task under an `* Area` heading and rely on area-by-ancestry. Update them to the property model, and add a whole-appdata round-trip.

- [ ] **Step 1: Write/replace the failing test**

Replace the body of `mindwtr-roundtrip-render-parse-signature-stable` and add a full round-trip. The key new test:

```elisp
(ert-deftest mindwtr-roundtrip-appdata-signature-stable ()
  "render-appdata -> parse-buffer preserves every entity's content signature,
with areaId via MW_AREA and projectId via nesting."
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0))
               :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1" :order 0))
               :sections nil
               :tasks ((:id "t1" :mw-kind task :title "loose" :status "next"
                        :areaId "a1" :contexts ("@home") :order 0)
                       (:id "t2" :mw-kind task :title "child" :status "next"
                        :projectId "p1" :order 0))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((re (mindwtr-parse-buffer))
             (idx (make-hash-table :test 'equal)))
        (dolist (k '(:tasks :projects :areas))
          (dolist (e (plist-get re k)) (puthash (plist-get e :id) e idx)))
        (dolist (k '(:tasks :projects :areas))
          (dolist (orig (plist-get ad k))
            (let ((got (gethash (plist-get orig :id) idx)))
              (should got)
              (should (string= (mindwtr-signature got) (mindwtr-signature orig))))))))))
```

Also update `mindwtr-roundtrip-render-parse-signature-stable`, `mindwtr-roundtrip-render-is-stable`, `mindwtr-roundtrip-unsafe-contexts-use-drawer`, `mindwtr-roundtrip-safe-tags-stay-native`, `mindwtr-roundtrip-checklist-server-shape`, and `mindwtr-roundtrip-date-only-start-time`: replace the `"* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"` wrapper + `:areaId "a1"` reliance with a buffer that (a) renders the task at level 1 (or wraps it in a `* Next Actions` container) and (b) adds an `* Areas of Focus` section with a `** Personal` (`:MW_ID: a1`) heading, and sets `:MW_AREA: Personal` on the task. Concretely, the helper wrapper becomes:

```elisp
(defun mindwtr-roundtrip--wrap (task-text)
  "Wrap rendered TASK-TEXT in a minimal buffer with an Areas-of-Focus section."
  (concat "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
          task-text
          "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
          "** Personal\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"))
```

For each such test, render the task with `mindwtr-render-area-names` bound so `:MW_AREA: Personal` is emitted:

```elisp
(let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
  (puthash "a1" "Personal" mindwtr-render-area-names)
  (let ((text (mindwtr-roundtrip--wrap (mindwtr-render-heading TASK 2 SHADOW))))
    ... parse text, the task should resolve :areaId "a1" ...))
```

(Keep `mindwtr-roundtrip-containment-affects-signature` as-is — it tests signature directly and does not parse.)

- [ ] **Step 2: Run to verify it fails first, then passes**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-roundtrip-test.el -f ert-run-tests-batch-and-exit`
Expected: the new appdata test FAILs until Tasks 3-5 are in (they are), then PASSes after fixture updates; all roundtrip tests PASS.

- [ ] **Step 3: Commit**

```bash
git add test/mindwtr-roundtrip-test.el
git commit -m "test(roundtrip): full appdata round-trip under GTD-list layout"
```

---

## Task 7: Reconcile — full canonical rebuild preserving org-only content + point

**Files:**
- Modify: `mindwtr-reconcile.el` (`mindwtr-reconcile-buffer`; add collect/point helpers; keep `--rebuild-entry`/`restore-entity` for the restore action)
- Test: `test/mindwtr-reconcile-test.el`

`mindwtr-reconcile-buffer` becomes: collect per-id org-only body + extra-props from the current buffer, remember the entity id at point, erase, insert `mindwtr-render-appdata merged org-only`, restore point to that id.

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-reconcile-test.el`:

```elisp
(ert-deftest mindwtr-reconcile-builds-list-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas ((:id "a1" :name "Personal" :order 0))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
                    :sections nil
                    :tasks ((:id "t1" :title "loose next" :status "next")
                            (:id "t2" :title "child" :status "next" :projectId "p1"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "* Next Actions" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "loose next" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Projects" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "child" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Areas of Focus" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook-into-new-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      ;; an existing buffer (any layout) with a LOGBOOK under task t1
      (insert "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "renamed" :status "next"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "KEEPME" nil t))))))

(ert-deftest mindwtr-reconcile-archived-not-rendered ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "keep me" :status "next")
                            (:id "t2" :title "archived one" :status "archived"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "keep me" nil t))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "archived one" nil t))))))
```

Also update the pre-existing reconcile tests that assert the OLD area-heading layout: `mindwtr-reconcile-updates-existing-title`, `mindwtr-reconcile-preserves-logbook`, `mindwtr-reconcile-removes-tombstoned`, `mindwtr-reconcile-inserts-remote-new`, `mindwtr-reconcile-low-priority-does-not-crash`, and the Task-from-prior-work `mindwtr-reconcile-update-*` tests. For each: the *input* buffer layout no longer matters (reconcile erases it), so keep the merged appdata and the `search-forward` assertions, but drop assertions about specific outline levels or the `* Work` area heading (areas now render only under `* Areas of Focus`). Where a test passes an area like `(:areas ((:id "a1" :name "Work")))`, the area renders under Areas of Focus and tasks reference it via `:MW_AREA: Work`; assertions on task titles/keywords/fields still hold.

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-reconcile-test.el -f ert-run-tests-batch-and-exit`
Expected: new tests FAIL (old reconcile builds the old layout).

- [ ] **Step 3: Implement**

In `mindwtr-reconcile.el`, replace `mindwtr-reconcile-buffer` and add helpers. Keep `mindwtr-reconcile--body-start`, `mindwtr-reconcile--preserved-body`, `mindwtr-parse--extra-props`, `--rebuild-entry`, and `mindwtr-reconcile-restore-entity`.

```elisp
(defun mindwtr-reconcile--collect-org-only ()
  "Return a hash id -> (:body STR :extra PLIST) of org-only content for every
MW_ID heading in the current buffer, so a full rebuild can carry it across."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (let ((id (mindwtr-parse--prop "MW_ID"))
             (kind (mindwtr-parse--prop "MW_TYPE")))
         (when (and id kind (not (string= kind "container")))
           (let* ((end (save-excursion (outline-next-heading) (point)))
                  (body (mindwtr-reconcile--preserved-body
                         (intern kind) (mindwtr-reconcile--body-start) end))
                  (extra (mindwtr-parse--extra-props)))
             (when (or body extra)
               (puthash id (list :body body :extra extra) h)))))))
    h))

(defun mindwtr-reconcile--id-at-point ()
  "Return the MW_ID of the entity heading containing point, or nil."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((id (mindwtr-parse--prop "MW_ID")))
        (while (and (not id) (org-up-heading-safe))
          (setq id (mindwtr-parse--prop "MW_ID")))
        id))))

(defun mindwtr-reconcile--goto-id (id)
  "Move point to the heading whose MW_ID is ID, if present."
  (when id
    (goto-char (point-min))
    (let ((re (format ":MW_ID: *%s *$" (regexp-quote id))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)))))

(defun mindwtr-reconcile-buffer (merged)
  "Rebuild the current buffer to the canonical GTD-list layout of MERGED.
Org-only content (LOGBOOK/CLOCK, unknown PROPERTIES) is preserved per id,
and point is restored to the entity it was on."
  (mindwtr-parse-ensure-keywords)
  (let ((org-only (mindwtr-reconcile--collect-org-only))
        (at-id (mindwtr-reconcile--id-at-point)))
    (let ((inhibit-message t))
      (erase-buffer)
      (insert (mindwtr-render-appdata merged org-only)))
    (goto-char (point-min))
    (mindwtr-reconcile--goto-id at-id)))
```

Update `mindwtr-reconcile-restore-entity` to bind the area-names map (so `:MW_AREA:` is emitted when it rewrites one heading):

```elisp
(defun mindwtr-reconcile-restore-entity (entity kind)
  "Re-apply ENTITY (kind KIND) onto its existing heading in the current buffer.
\(docstring unchanged from prior version)"
  (let ((m (gethash (plist-get entity :id) (mindwtr-reconcile--id-markers)))
        (mindwtr-render-area-names (mindwtr-render--area-name-map (mindwtr-parse-buffer))))
    (if (not m)
        nil
      (save-excursion
        (goto-char m)
        (mindwtr-reconcile--rebuild-entry entity kind))
      (let ((re (mindwtr-reconcile--find-parsed (plist-get entity :id))))
        (if (and re (string= (mindwtr-signature re) (mindwtr-signature entity)))
            'restored
          'partial)))))
```

(`mindwtr-reconcile--rebuild-entry`, `--id-markers`, `--find-parsed` remain as they are.)

- [ ] **Step 4: Run to verify it passes**

Run the full suite (conventions header). Expected: all reconcile + roundtrip tests PASS. Fix any old-layout assertions per Step 1 guidance.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-reconcile.el test/mindwtr-reconcile-test.el
git commit -m "feat(reconcile): full canonical rebuild into GTD-list layout, org-only preserved"
```

---

## Task 8: Sync — archive-aware deletion detection

**Files:**
- Modify: `mindwtr-sync.el` (`mindwtr-sync-build-candidate` tombstone pass; `mindwtr-sync--stats` delete pass)
- Test: `test/mindwtr-sync-test.el`

A shadow entity that is absent from org must NOT be tombstoned when its status is `archived` (archived items are intentionally not rendered).

- [ ] **Step 1: Write the failing test**

Add to `test/mindwtr-sync-test.el`:

```elisp
(ert-deftest mindwtr-sync-archived-not-tombstoned ()
  "An archived shadow entity absent from org is not turned into a tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "live" :status "next" :rev 1)
                           (:id "t2" :title "arch" :status "archived" :rev 1))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "live" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t2 (seq-find (lambda (e) (equal (plist-get e :id) "t2")) (plist-get cand :tasks))))
    ;; t2 is echoed (still archived), NOT freshly tombstoned with :deletedAt NOW
    (should t2)
    (should-not (string= (or (plist-get t2 :deletedAt) "") "NOW"))
    ;; and stats does not count it as a delete
    (should (= (plist-get (mindwtr-sync--stats local shadow) :deleted) 0))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-sync-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — t2 gets `:deletedAt "NOW"` and `:deleted` counts 1.

- [ ] **Step 3: Implement**

In `mindwtr-sync.el`, the tombstone pass in `mindwtr-sync-build-candidate` currently guards `(unless (or (gethash id seen) (plist-get se :deletedAt)) ...)`. Add an archived guard:

```elisp
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (equal (plist-get se :status) "archived"))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
```

But an archived entity must still be ECHOED into the candidate (kept, not dropped), so the server retains it. After the tombstone `dolist`, archived shadow entities that were not seen are currently dropped from `out`. Add a second pass to echo them verbatim:

```elisp
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (when (and (not (gethash id seen))
                       (not (plist-get se :deletedAt))
                       (equal (plist-get se :status) "archived"))
              (push (mindwtr-sync--strip-device-local (copy-sequence se)) out))))
```

In `mindwtr-sync--stats`, the delete pass guards `(unless (or (gethash id seen) (plist-get se :deletedAt)) ...)`. Add the archived guard there too:

```elisp
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (equal (plist-get se :status) "archived"))
              (setq deleted (1+ deleted)))))
```

- [ ] **Step 4: Run to verify it passes** — full suite. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-sync.el test/mindwtr-sync-test.el
git commit -m "feat(sync): never tombstone archived shadow entities; echo them verbatim"
```

---

## Task 9: Integration — full suite, compile, dead-code sweep, manual bootstrap check

**Files:**
- Modify: `mindwtr-reconcile.el` (remove any now-unused old placement helpers), `mindwtr-render.el` (confirm), as needed
- Test: whole suite + `make compile`

- [ ] **Step 1: Dead-code check**

Search for now-unused functions from the old layout and remove them if nothing references them (check with grep across `*.el`, excluding tests that you have updated):

```bash
grep -rn "mindwtr-reconcile--container-marker\|mindwtr-reconcile--insert-entity\|mindwtr-reconcile--update-heading" --include="*.el" .
```

`--container-marker` and `--insert-entity` are superseded by `mindwtr-render-appdata`; remove them if unreferenced. (`--update-heading` was already removed earlier; confirm it is gone.) Keep `--rebuild-entry`, `--id-markers`, `--find-parsed`, `--body-start`, `--preserved-body` (used by restore + collect).

- [ ] **Step 2: Run the full suite**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l ert $(for f in test/*-test.el; do echo "-l $f"; done) -f ert-run-tests-batch-and-exit`
Expected: `0 unexpected`.

- [ ] **Step 3: Compile gate**

Run: `make compile`
Expected: exit 0, no warnings.

- [ ] **Step 4: Manual bootstrap smoke check (local, user-run)**

Re-render the user's shadow through the new layout without touching the server, to eyeball the structure:

```bash
emacs -Q --batch -L . -l mindwtr-util -l mindwtr-model -l mindwtr-signature -l mindwtr-render \
  --eval '(princ (mindwtr-render-appdata (mindwtr-util-json-decode (mindwtr-util-read-file "~/.emacs.d/mindwtr/shadow.json"))))'
```

Expected: top-level `* Inbox`, `* Next Actions`, `* Waiting`, `* Someday`, `* Reference`, `* Projects`, `* Areas of Focus`; projects grouped by area with nested tasks; no archived/tombstoned items; readable `MW_RECURRENCE`. (This is a read-only render — it does not sync.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: remove superseded reconcile placement helpers; layout v2 complete"
```

---

## Self-Review

**Spec coverage:**
- File layout (containers + Areas of Focus) → Tasks 1, 4, 7. ✓
- Status→list mapping (done in Next Actions; archived not rendered) → Tasks 1, 4. ✓
- Containment via property + ancestry → Task 5. ✓
- `MW_AREA` by name, resolved in-file → Tasks 3 (emit), 5 (resolve). ✓
- Archived shadow-only (hidden + not a delete; ARCH-from-org) → Tasks 4 (not rendered), 7 (removed via re-render), 8 (not tombstoned). ✓
- Ordering (areas/projects-by-area/others) → Task 4. ✓
- Recurrence readable → Task 2. ✓
- Round-trip & sync correctness preserved → Task 6 (round-trip), 8 (deletion), full suite Task 9. ✓
- Migration (re-bootstrap) → Task 9 Step 4 is the read-only preview; actual re-bootstrap is the user running `mindwtr-bootstrap`. ✓

**Type/name consistency:** `mindwtr-render-area-names` (dynamic, id→name) used in Tasks 3,4,7; `mindwtr-parse--area-names` (dynamic, name→id) in Task 5; `mindwtr-model-status->list` in Tasks 1,4; org-only hash shape `(:body STR :extra PLIST)` consistent in Tasks 4 (`--entity`/`--graft-org-only`) and 7 (`--collect-org-only`). ✓

**Placeholder scan:** no TBD/TODO; every code step shows complete code. ✓
