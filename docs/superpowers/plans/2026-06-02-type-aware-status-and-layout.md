# Type-Aware Status, v3 Buckets & Eager Relocation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the rendered GTD layout (v3 buckets) and add a mode-scoped interactive layer that makes invalid task/project status combos unreachable via keystrokes and relocates headings to the right bucket on status change — without waiting for sync.

**Architecture:** Layout is driven entirely by `mindwtr-render-appdata` (reconcile is a full rebuild that calls it, so reconcile needs no change). Status is single-sourced from the org TODO keyword. A parser/validator backstop degrades on type-invalid keywords instead of aborting sync. Interactive commands live in a new `mindwtr-commands.el`, wired into `mindwtr-mode-map`; re-parenting stays on native `org-refile`.

**Tech Stack:** Emacs Lisp (lexical-binding), `org`/`org-element`, `ert`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-02-type-aware-status-and-layout-design.md`

**Conventions:**
- Run the full suite: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l ert $(for f in test/*-test.el; do echo "-l $f"; done) -f ert-run-tests-batch-and-exit`
- Run one file's tests by name regexp:
  `emacs -Q --batch -L . -L test -l ert -l test/<file>-test.el --eval '(ert-run-tests-batch-and-exit "<name-regexp>")'`
- Compile gate: `make compile` (byte-compile-error-on-warn → prints `compile OK`).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Bucket roles (the `:MW_LIST:` discriminators): `inbox`, `single-actions`, `projects`, `someday`, `someday-single-actions`, `someday-projects`, `reference`, `areas`.

---

## Phase A — Layout v3 + backstop (no interactive commands)

### Task 1: Model — v3 bucket roles, titles, and status→bucket maps

**Files:**
- Modify: `mindwtr-model.el:43-66` (replace `mindwtr-model-list-roles`, `mindwtr-model--list-titles`, `mindwtr-model--status->list`; add a project status→bucket map)
- Test: `test/mindwtr-model-test.el:104-118` (update the two existing tests)

- [ ] **Step 1: Update the failing tests to the v3 expectations**

In `test/mindwtr-model-test.el`, replace the two tests at lines 104-118 with:

```elisp
(ert-deftest mindwtr-model-list-roles-and-titles ()
  (should (equal mindwtr-model-list-roles
                 '("inbox" "single-actions" "projects"
                   "someday" "someday-single-actions" "someday-projects"
                   "reference" "areas")))
  (should (string= (mindwtr-model-list-title "single-actions") "Single Actions"))
  (should (string= (mindwtr-model-list-title "someday-single-actions") "Single Actions"))
  (should (string= (mindwtr-model-list-title "someday-projects") "Projects"))
  (should (string= (mindwtr-model-list-title "areas") "Areas of Focus")))

(ert-deftest mindwtr-model-status->list-maps-standalone-statuses ()
  (should (string= (mindwtr-model-status->list "inbox") "inbox"))
  (should (string= (mindwtr-model-status->list "next") "single-actions"))
  (should (string= (mindwtr-model-status->list "waiting") "single-actions"))
  (should (string= (mindwtr-model-status->list "done") "single-actions"))
  (should (string= (mindwtr-model-status->list "someday") "someday-single-actions"))
  (should (string= (mindwtr-model-status->list "reference") "reference"))
  ;; archived has no list -> not rendered
  (should (null (mindwtr-model-status->list "archived"))))

(ert-deftest mindwtr-model-project-status->list-maps-project-statuses ()
  (should (string= (mindwtr-model-project-status->list "active") "projects"))
  (should (string= (mindwtr-model-project-status->list "waiting") "projects"))
  (should (string= (mindwtr-model-project-status->list "someday") "someday-projects"))
  (should (null (mindwtr-model-project-status->list "archived"))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-model-test.el --eval '(ert-run-tests-batch-and-exit "list-roles-and-titles\\|status->list")'`
Expected: FAIL — `mindwtr-model-project-status->list` is undefined and the role/title/mapping assertions don't match.

- [ ] **Step 3: Implement the model changes**

In `mindwtr-model.el`, replace the block at lines 43-66 (from `(defconst mindwtr-model-list-roles` through the end of `mindwtr-model-status->list`) with:

```elisp
(defconst mindwtr-model-list-roles
  '("inbox" "single-actions" "projects"
    "someday" "someday-single-actions" "someday-projects"
    "reference" "areas")
  "Every container role used as a `:MW_LIST:' discriminator.
`* Someday' is a container whose children are the `someday-single-actions'
and `someday-projects' containers; the rest are top-level.")

(defconst mindwtr-model--list-titles
  '(("inbox" . "Inbox") ("single-actions" . "Single Actions")
    ("projects" . "Projects") ("someday" . "Someday")
    ("someday-single-actions" . "Single Actions")
    ("someday-projects" . "Projects")
    ("reference" . "Reference") ("areas" . "Areas of Focus")))

(defun mindwtr-model-list-title (role)
  "Default heading text for a container ROLE."
  (or (cdr (assoc role mindwtr-model--list-titles))
      (error "Unknown list role: %s" role)))

(defconst mindwtr-model--status->list
  '(("inbox" . "inbox") ("next" . "single-actions") ("waiting" . "single-actions")
    ("done" . "single-actions") ("someday" . "someday-single-actions")
    ("reference" . "reference"))
  "STANDALONE task status -> container role.  `archived' is absent on purpose:
archived tasks are not rendered.")

(defun mindwtr-model-status->list (status)
  "Return the list role a standalone task with STATUS renders under, or nil
when it must not be rendered (e.g. `archived')."
  (cdr (assoc status mindwtr-model--status->list)))

(defconst mindwtr-model--project-status->list
  '(("active" . "projects") ("waiting" . "projects")
    ("someday" . "someday-projects"))
  "Project status -> container role.  `archived' is absent (not rendered).")

(defun mindwtr-model-project-status->list (status)
  "Return the list role a project with STATUS renders under, or nil
when it must not be rendered (e.g. `archived')."
  (cdr (assoc status mindwtr-model--project-status->list)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-model-test.el --eval '(ert-run-tests-batch-and-exit "list-roles-and-titles\\|status->list")'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add mindwtr-model.el test/mindwtr-model-test.el
git commit -m "feat: v3 bucket roles, titles, and project status->bucket map

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Model — safe keyword lookup + type-aware status choices

**Files:**
- Modify: `mindwtr-model.el` (add after `mindwtr-model-keyword->status`, ~line 85)
- Test: `test/mindwtr-model-test.el` (append new tests)

These helpers are needed by the parser backstop (Task 4) and the interactive commands (Phase B): a non-erroring keyword→status, and an ordered list of valid `(KEYWORD . fast-char)` pairs per entity kind.

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-model-test.el`:

```elisp
(ert-deftest mindwtr-model-keyword->status-safe-returns-nil-on-mismatch ()
  ;; valid combos resolve like the erroring form
  (should (string= (mindwtr-model-keyword->status-safe 'task "NEXT") "next"))
  (should (string= (mindwtr-model-keyword->status-safe 'project "ACTIVE") "active"))
  ;; type-invalid combos return nil instead of erroring
  (should (null (mindwtr-model-keyword->status-safe 'project "NEXT")))
  (should (null (mindwtr-model-keyword->status-safe 'task "ACTIVE"))))

(ert-deftest mindwtr-model-status-choices-are-type-scoped-with-fast-keys ()
  (let ((task (mindwtr-model-status-choices 'task))
        (proj (mindwtr-model-status-choices 'project)))
    ;; tasks expose i/n/w/s/r + d/x, never ACTIVE
    (should (equal task '(("INBOX" . ?i) ("NEXT" . ?n) ("WAIT" . ?w)
                          ("SOMEDAY" . ?s) ("REF" . ?r) ("DONE" . ?d) ("ARCH" . ?x))))
    ;; projects expose a/s/w + x, never INBOX/NEXT/REF/DONE
    (should (equal proj '(("ACTIVE" . ?a) ("SOMEDAY" . ?s) ("WAIT" . ?w) ("ARCH" . ?x))))
    (should-not (assoc "ACTIVE" task))
    (should-not (assoc "NEXT" proj))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-model-test.el --eval '(ert-run-tests-batch-and-exit "keyword->status-safe\\|status-choices")'`
Expected: FAIL — `mindwtr-model-keyword->status-safe` and `mindwtr-model-status-choices` are undefined.

- [ ] **Step 3: Implement the helpers**

In `mindwtr-model.el`, immediately after `mindwtr-model-keyword->status` (ends ~line 85), insert:

```elisp
(defun mindwtr-model-keyword->status-safe (kind keyword)
  "Like `mindwtr-model-keyword->status' but return nil for a type-invalid KEYWORD.
Used by the parser backstop so an org-recognized keyword that is wrong for
KIND (e.g. NEXT on a project) does not abort the sync."
  (car (rassoc keyword (mindwtr-model--status-alist kind))))

(defconst mindwtr-model--keyword-fast-keys
  (let (alist)
    (dolist (kw (cdar mindwtr-model-todo-keywords))
      (when (string-match "\\`\\([A-Z]+\\)(\\(.\\))\\'" kw)
        (push (cons (match-string 1 kw) (string-to-char (match-string 2 kw))) alist)))
    (nreverse alist))
  "Alist KEYWORD -> fast-access char, parsed from `mindwtr-model-todo-keywords'.
The `|' separator entry has no `(key)' and is skipped.")

(defun mindwtr-model-status-choices (kind)
  "Return ((KEYWORD . CHAR) ...) of valid TODO keywords for entity KIND.
Ordered by the kind's status alist (active states first, then done states);
each keyword is paired with its fast-access char from the shared sequence."
  (mapcar (lambda (pair)
            (let ((kw (cdr pair)))
              (cons kw (cdr (assoc kw mindwtr-model--keyword-fast-keys)))))
          (mindwtr-model--status-alist kind)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-model-test.el --eval '(ert-run-tests-batch-and-exit "keyword->status-safe\\|status-choices")'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add mindwtr-model.el test/mindwtr-model-test.el
git commit -m "feat: model keyword->status-safe and type-scoped status choices

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Render — v3 layout (merged Single Actions, project-by-status split, nested Someday)

**Files:**
- Modify: `mindwtr-render.el:248-297` (rewrite `mindwtr-render-appdata`; add helpers above it)
- Test: `test/mindwtr-render-test.el:74-103` (update `mindwtr-render-appdata-builds-lists`; add a v3 golden test)

- [ ] **Step 1: Update/extend the failing tests**

In `test/mindwtr-render-test.el`, replace `mindwtr-render-appdata-builds-lists` (lines 74-103) with the version below, and add a new test after it:

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
    (should (string-match-p ":MW_AREA: Personal" text))
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-render-test.el --eval '(ert-run-tests-batch-and-exit "appdata-builds-lists\\|v3-splits")'`
Expected: FAIL — current render emits `* Next Actions`/`* Waiting` and a flat `* Projects` containing all statuses; no nested Someday.

- [ ] **Step 3: Implement the render restructure**

In `mindwtr-render.el`, insert these helpers immediately before `mindwtr-render-appdata` (before line 248):

```elisp
(defun mindwtr-render--standalone-for (role tasks)
  "Standalone (no projectId/sectionId) TASKS whose status maps to container ROLE."
  (cl-remove-if-not
   (lambda (e)
     (and (not (plist-get e :projectId))
          (not (plist-get e :sectionId))
          (equal (mindwtr-model-status->list (plist-get e :status)) role)))
   tasks))

(defun mindwtr-render--task-bucket (role level tasks org-only)
  "Render container ROLE at LEVEL, then standalone TASKS (pre-filtered) at LEVEL+1."
  (let ((out (mindwtr-render--container role level)))
    (dolist (e (mindwtr-render--sorted tasks))
      (setq out (concat out (mindwtr-render--entity e 'task (1+ level) org-only))))
    out))

(defun mindwtr-render--project-subtree (proj level sections tasks org-only)
  "Render PROJ at LEVEL, its sections at LEVEL+1 (their tasks LEVEL+2), and its
section-less tasks at LEVEL+1."
  (let ((out (mindwtr-render--entity proj 'project level org-only)))
    (dolist (sec (mindwtr-render--sorted
                  (cl-remove-if-not
                   (lambda (s) (equal (plist-get s :projectId) (plist-get proj :id)))
                   sections)))
      (setq out (concat out (mindwtr-render--entity sec 'section (1+ level) org-only)))
      (dolist (tk (mindwtr-render--sorted
                   (cl-remove-if-not
                    (lambda (tk) (equal (plist-get tk :sectionId) (plist-get sec :id)))
                    tasks)))
        (setq out (concat out (mindwtr-render--entity tk 'task (+ level 2) org-only)))))
    (dolist (tk (mindwtr-render--sorted
                 (cl-remove-if-not
                  (lambda (tk) (and (equal (plist-get tk :projectId) (plist-get proj :id))
                                    (not (plist-get tk :sectionId))))
                  tasks)))
      (setq out (concat out (mindwtr-render--entity tk 'task (1+ level) org-only))))
    out))

(defun mindwtr-render--projects-bucket (role level projects sections tasks area-order org-only)
  "Render container ROLE at LEVEL, then PROJECTS whose project-status maps to ROLE,
grouped by area, each as a subtree at LEVEL+1."
  (let ((out (mindwtr-render--container role level))
        (matched (cl-remove-if-not
                  (lambda (p)
                    (equal (mindwtr-model-project-status->list (plist-get p :status)) role))
                  projects)))
    (dolist (proj (mindwtr-render--sorted-projects matched area-order))
      (setq out (concat out (mindwtr-render--project-subtree
                             proj (1+ level) sections tasks org-only))))
    out))
```

Then replace `mindwtr-render-appdata` (lines 248-297) with:

```elisp
(defun mindwtr-render-appdata (appdata &optional org-only)
  "Render APPDATA to the canonical v3 GTD-list org layout, returning a string.
ORG-ONLY, when given, is a hash id -> (:body STR :extra PLIST) of org-only
content to preserve across a reconcile.  Tombstoned and archived entities
are not rendered."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         (areas (mindwtr-render--live (plist-get appdata :areas)))
         (projects (mindwtr-render--live (plist-get appdata :projects) t))
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks) t))
         ;; Lead with the in-buffer keyword line so org registers the Mindwtr
         ;; TODO sequence for this file regardless of the user's global config.
         (out (concat (mindwtr-model-todo-keyword-line) "\n")))
    ;; Inbox
    (setq out (concat out (mindwtr-render--task-bucket
                           "inbox" 1
                           (mindwtr-render--standalone-for "inbox" tasks) org-only)))
    ;; Single Actions (next | waiting | done)
    (setq out (concat out (mindwtr-render--task-bucket
                           "single-actions" 1
                           (mindwtr-render--standalone-for "single-actions" tasks) org-only)))
    ;; Projects (active | waiting), grouped by area
    (setq out (concat out (mindwtr-render--projects-bucket
                           "projects" 1 projects sections tasks area-order org-only)))
    ;; Someday parent with two nested children
    (setq out (concat out (mindwtr-render--container "someday" 1)))
    (setq out (concat out (mindwtr-render--task-bucket
                           "someday-single-actions" 2
                           (mindwtr-render--standalone-for "someday-single-actions" tasks)
                           org-only)))
    (setq out (concat out (mindwtr-render--projects-bucket
                           "someday-projects" 2 projects sections tasks area-order org-only)))
    ;; Reference
    (setq out (concat out (mindwtr-render--task-bucket
                           "reference" 1
                           (mindwtr-render--standalone-for "reference" tasks) org-only)))
    ;; Areas of Focus reference section
    (setq out (concat out (mindwtr-render--container "areas" 1)))
    (dolist (a (mindwtr-render--sorted areas))
      (setq out (concat out (mindwtr-render--entity a 'area 2 org-only))))
    out))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-render-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — all render tests, including `appdata-builds-lists`, `v3-splits-someday-and-waiting`, `orders-and-groups`, and `leads-with-todo-keyword-line`.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-render.el test/mindwtr-render-test.el
git commit -m "feat: v3 render layout (Single Actions, project-by-status, nested Someday)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Parse — backstop on type-invalid keywords

**Files:**
- Modify: `mindwtr-parse.el:156-157` (use the safe lookup; warn + omit status on mismatch)
- Test: `test/mindwtr-parse-test.el` (append a regression test)

- [ ] **Step 1: Write the failing test**

Append to `test/mindwtr-parse-test.el`:

```elisp
(ert-deftest mindwtr-parse-type-invalid-keyword-omits-status-not-errors ()
  "A project carrying a task-only keyword (NEXT) must not error or leak the
keyword into the title; it parses with no :status and warns."
  (mindwtr-parse-test--with
      (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** NEXT Build the deck\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
    ;; jump to the project heading (second heading)
    (goto-char (point-min))
    (re-search-forward "Build the deck")
    (org-back-to-heading t)
    (let ((e (mindwtr-parse-heading)))
      (should (string= (plist-get e :title) "Build the deck"))
      (should (null (plist-get e :status))))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-parse-test.el --eval '(ert-run-tests-batch-and-exit "type-invalid-keyword")'`
Expected: FAIL — `mindwtr-model-keyword->status` errors with `Invalid project keyword: NEXT`, aborting the parse.

- [ ] **Step 3: Implement the backstop in the parser**

In `mindwtr-parse.el`, replace the two lines at 156-157:

```elisp
    (when (and todo (memq kind '(task project)))
      (setq e (plist-put e :status (mindwtr-model-keyword->status kind todo))))
```

with:

```elisp
    (when (memq kind '(task project))
      (let ((status (and todo (mindwtr-model-keyword->status-safe kind todo))))
        (cond
         (status (setq e (plist-put e :status status)))
         (todo
          ;; An org-recognized keyword that is wrong for this kind (e.g. NEXT on
          ;; a project).  Omit the status rather than erroring -- the shadow
          ;; merge keeps the prior status (or a type default for a new entity),
          ;; so a stray keyword no longer aborts the whole sync.
          (display-warning
           'mindwtr
           (format "heading %S has TODO keyword %s, which is not a valid %s status; leaving its status unchanged"
                   title todo kind)
           :warning)))))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-parse-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — all parse tests, including the new backstop test. (A `display-warning` line may print to stderr during the run; that is expected.)

- [ ] **Step 5: Commit**

```bash
git add mindwtr-parse.el test/mindwtr-parse-test.el
git commit -m "feat: parser backstop — type-invalid keyword omits status, warns

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Sync — never clear mandatory status; default it for new entities

**Files:**
- Modify: `mindwtr-sync.el:56-63` (guard `:status` in `merge-content`)
- Modify: `mindwtr-sync.el:130-135` (default status in the `create` path) + add `mindwtr-sync--ensure-status`
- Test: `test/mindwtr-sync-test.el` (append two tests)

**Why:** `:status` is in `mindwtr-model-content-fields`. When the parser omits it (Task 4), `merge-content` sees an empty local value and would *remove* the field — clearing an existing entity's status and re-triggering the "invalid status nil" abort. The mandatory `:status` must never be cleared from a parse omission; a brand-new entity (no shadow) gets a type default.

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-sync-test.el`:

```elisp
(ert-deftest mindwtr-sync-merge-never-clears-status ()
  "When the local parse omits :status (type-invalid keyword), merge keeps the
shadow's status instead of clearing the mandatory field."
  (let* ((se '(:id "t1" :title "Task" :status "waiting" :rev 3))
         (le '(:id "t1" :title "Task"))            ; status omitted by the backstop
         (m (mindwtr-sync--merge-content le se)))
    (should (string= (plist-get m :status) "waiting"))))

(ert-deftest mindwtr-sync-build-candidate-defaults-new-entity-status ()
  "A brand-new local task with no status (parser omitted it) gets the type
default so validation does not abort."
  (let* ((local '(:tasks ((:title "Fresh") )    ; no :id, no :status
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "2026-06-02T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :status) "inbox"))
    ;; the candidate validates (no invalid nil status)
    (should (mindwtr-model-validate-appdata
             (mindwtr-sync--strip-internal-keys cand)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-sync-test.el --eval '(ert-run-tests-batch-and-exit "never-clears-status\\|defaults-new-entity-status")'`
Expected: FAIL — merge currently removes the empty `:status`; build-candidate produces a task with nil status that fails validation.

- [ ] **Step 3: Implement the guard and the default**

In `mindwtr-sync.el`, in `mindwtr-sync--merge-content`, replace the inner loop body (lines 56-62) with:

```elisp
    (dolist (k mindwtr-model-content-fields)
      (let ((lv (plist-get le k)) (sv (plist-get se k)))
        (unless (equal (mindwtr-sync--field-canonical k lv)
                       (mindwtr-sync--field-canonical k sv))
          (if (mindwtr-sync--empty-p lv)
              ;; `:status' is mandatory for task/project; an empty local value
              ;; means the parser could not determine it (a type-invalid or
              ;; missing keyword), never an intentional clear -- so keep SV.
              (unless (eq k :status)
                (setq out (mindwtr-sync--plist-remove out k)))
            (setq out (plist-put out k lv))))))
```

Add `mindwtr-sync--ensure-status` immediately before `mindwtr-sync-build-candidate` (before line 110):

```elisp
(defun mindwtr-sync--ensure-status (entity kind)
  "Default a missing status on a newly created ENTITY of KIND.
A type-invalid or missing keyword left the parser omitting :status; for a
brand-new entity there is no shadow status to inherit, so fall back to the
kind's default (task -> inbox, project -> active) so validation does not abort."
  (if (or (not (memq kind '(task project))) (plist-get entity :status))
      entity
    (plist-put (copy-sequence entity)
               :status (if (eq kind 'task) "inbox" "active"))))
```

In `mindwtr-sync-build-candidate`, change the `create` branch (lines 130-135) so the first line inside the `let` applies the default:

```elisp
                    ('create
                     (let ((m (mindwtr-sync--ensure-status
                               (mindwtr-sync--merge-content le se) kind)))
                       (setq m (plist-put m :rev 1))
                       (setq m (plist-put m :createdAt now))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-sync-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — all sync tests, including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-sync.el test/mindwtr-sync-test.el
git commit -m "feat: never clear mandatory status; default new-entity status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Round-trip — verify v3 layout parses back unchanged

**Files:**
- Modify: `test/mindwtr-roundtrip-test.el:125+` (extend the appdata fixture in `mindwtr-roundtrip-appdata-signature-stable` with v3-specific entities)

The container tree is transparent to ancestry, so the existing round-trip should hold; this task proves it for someday/waiting projects and a someday standalone task.

- [ ] **Step 1: Inspect and extend the fixture**

Read `test/mindwtr-roundtrip-test.el` lines 125-160 to find the `ad` fixture in `mindwtr-roundtrip-appdata-signature-stable`. Add these entities to its lists (keep the existing ones):

- to `:projects`: `(:id "pw" :title "Waiting proj" :status "waiting" :order 7)` and `(:id "ps" :title "Someday proj" :status "someday" :order 8)`
- to `:tasks`: `(:id "tsd" :title "Someday single" :status "someday" :order 9)` and a task under the someday project `(:id "tsp" :title "Someday proj task" :status "next" :projectId "ps" :order 0)`

The test already renders the fixture, parses it back, and asserts each entity's content signature is unchanged. No assertion edits are needed — the new entities are covered by the existing per-entity signature loop.

- [ ] **Step 2: Run the round-trip suite to verify it passes**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-roundtrip-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — every entity (including the someday/waiting projects and the someday standalone task) round-trips with a stable signature.

If a signature differs, the regression is in the render restructure (Task 3) — most likely a nesting-level bug that changed a derived `projectId`/`sectionId`. Fix render, not the test.

- [ ] **Step 3: Run the reconcile suite (full-rebuild sanity)**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-reconcile-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — reconcile delegates to `mindwtr-render-appdata`, so this confirms the new layout rebuilds cleanly.

- [ ] **Step 4: Run the full suite + compile gate**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l ert $(for f in test/*-test.el; do echo "-l $f"; done) -f ert-run-tests-batch-and-exit`
Then: `make compile`
Expected: all tests `expected`, `0 unexpected`; compile prints `compile OK`. Fix any fallout (most likely a stale `* Next Actions`/`* Waiting` string assertion in another test file).

- [ ] **Step 5: Commit**

```bash
git add test/mindwtr-roundtrip-test.el
git commit -m "test: round-trip the v3 layout (someday/waiting projects, someday single)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase B — Interactive layer (`mindwtr-commands.el`)

### Task 7: Commands — kind detection + type-aware status menu

**Files:**
- Create: `mindwtr-commands.el`
- Test: `test/mindwtr-commands-test.el`

- [ ] **Step 1: Write the failing tests**

Create `test/mindwtr-commands-test.el`:

```elisp
;;; mindwtr-commands-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'mindwtr-commands)
(require 'mindwtr-render)

(defmacro mindwtr-commands-test--with-appdata (appdata &rest body)
  "Render APPDATA into an org buffer with Mindwtr keywords registered, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-todo-keywords mindwtr-model-todo-keywords)
           (org-inhibit-startup t))
       (insert (mindwtr-render-appdata ,appdata))
       (org-mode))
     (goto-char (point-min))
     ,@body))

(ert-deftest mindwtr-commands-kind-at-point-reads-mw-type ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "Proj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next"))
        :settings nil)
    (re-search-forward "Loose")
    (should (eq (mindwtr-commands--kind-at-point) 'task))
    (re-search-forward "Proj")
    (should (eq (mindwtr-commands--kind-at-point) 'project))
    (goto-char (point-min))
    (re-search-forward "^\\* Inbox$")
    (should (eq (mindwtr-commands--kind-at-point) 'container))))

(ert-deftest mindwtr-commands-set-status-applies-chosen-keyword ()
  "set-status applies the keyword returned by the (stubbed) reader."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Loose" :status "next")) :settings nil)
    (re-search-forward "Loose")
    (cl-letf (((symbol-function 'mindwtr-commands--read-keyword)
               (lambda (&rest _) "WAIT")))
      (mindwtr-set-status))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "Loose")
      (org-back-to-heading t)
      (should (string= (org-get-todo-state) "WAIT")))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el --eval '(ert-run-tests-batch-and-exit "kind-at-point\\|applies-chosen")'`
Expected: FAIL — `mindwtr-commands.el` does not exist.

- [ ] **Step 3: Create `mindwtr-commands.el` with kind detection, the reader, and set-status**

Create `mindwtr-commands.el`:

```elisp
;;; mindwtr-commands.el --- Interactive type-aware status commands -*- lexical-binding: t; -*-
;;; Commentary:
;; Mode-scoped commands bound in `mindwtr-mode-map': a type-aware replacement
;; for `org-todo' that offers only the valid keywords for the entity at point,
;; type-aware status cycling, and eager relocation of a standalone task or a
;; project to the container matching its new status.  Re-parenting into/out of
;; a project stays on native `org-refile'.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)

(defun mindwtr-commands--kind-at-point ()
  "Return the MW_TYPE symbol of the heading at point, or nil."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((type (mindwtr-parse--prop "MW_TYPE")))
        (and type (intern type))))))

(defun mindwtr-commands--read-keyword (kind choices)
  "Prompt for one of CHOICES (list of (KEYWORD . CHAR)) for KIND.
Return the chosen keyword string, or nil on quit."
  (let* ((prompt (concat (format "%s status: " kind)
                         (mapconcat (lambda (c) (format "[%c]%s" (cdr c) (car c)))
                                    choices "  ")))
         (ch (read-char-choice prompt (mapcar #'cdr choices))))
    (car (rassq ch choices))))

;;;###autoload
(defun mindwtr-set-status ()
  "Set the TODO status of the entity at point, offering only type-valid keywords.
Shadows `org-todo' in `mindwtr-mode'.  After setting, relocate a standalone
task or a project to the container matching its new status."
  (interactive)
  (let ((kind (mindwtr-commands--kind-at-point)))
    (if (not (memq kind '(task project)))
        (call-interactively #'org-todo)
      (let ((kw (mindwtr-commands--read-keyword
                 kind (mindwtr-model-status-choices kind))))
        (when kw
          (save-excursion (org-back-to-heading t) (org-todo kw))
          (mindwtr-commands--relocate kind))))))

(provide 'mindwtr-commands)
;;; mindwtr-commands.el ends here
```

> Note: `mindwtr-commands--relocate` is defined in Task 8. Until then this file references it; the two tests in this task stub `mindwtr-commands--read-keyword` and exercise paths that call `--relocate` on a standalone task — so **implement Task 8 in the same working session before running the full suite**. To make Task 7's two tests pass in isolation, temporarily define a no-op `(defun mindwtr-commands--relocate (_kind) nil)` and replace it with the real one in Task 8. (The `applies-chosen-keyword` test only asserts the keyword, not the location.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el --eval '(ert-run-tests-batch-and-exit "kind-at-point\\|applies-chosen")'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add mindwtr-commands.el test/mindwtr-commands-test.el
git commit -m "feat: mindwtr-commands kind detection and type-aware set-status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Commands — eager bucket relocation

**Files:**
- Modify: `mindwtr-commands.el` (add relocation helpers; replace any temporary no-op `--relocate`)
- Test: `test/mindwtr-commands-test.el` (append relocation tests)

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-commands-test.el`:

```elisp
(defun mindwtr-commands-test--parent-list-of (title)
  "Return the MW_LIST role of the container the heading named TITLE sits under."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (regexp-quote title))
    (mindwtr-commands--parent-list-role)))

(ert-deftest mindwtr-commands-relocates-standalone-task-by-status ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Move me" :status "next")) :settings nil)
    ;; starts under single-actions
    (should (string= (mindwtr-commands-test--parent-list-of "Move me") "single-actions"))
    ;; next -> someday relocates to someday-single-actions
    (goto-char (point-min)) (re-search-forward "Move me") (org-back-to-heading t)
    (org-todo "SOMEDAY")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Move me")
                     "someday-single-actions"))
    ;; someday -> reference relocates to reference
    (goto-char (point-min)) (re-search-forward "Move me") (org-back-to-heading t)
    (org-todo "REF")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Move me") "reference"))))

(ert-deftest mindwtr-commands-relocates-project-subtree-with-children ()
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Child task" :status "next" :projectId "p1"))
        :settings nil)
    (should (string= (mindwtr-commands-test--parent-list-of "MyProj") "projects"))
    (goto-char (point-min)) (re-search-forward "MyProj") (org-back-to-heading t)
    (org-todo "SOMEDAY")
    (mindwtr-commands--relocate 'project)
    ;; project moved under someday-projects, child carried along (still its task)
    (should (string= (mindwtr-commands-test--parent-list-of "MyProj") "someday-projects"))
    (should (string= (mindwtr-commands-test--parent-list-of "Child task") "someday-projects"))
    ;; re-parse confirms the child still belongs to the project
    (let* ((ad (mindwtr-parse-buffer))
           (child (car (plist-get ad :tasks))))
      (should (string= (plist-get child :projectId) "p1")))))

(ert-deftest mindwtr-commands-project-task-does-not-relocate ()
  "A status change on a task inside a project leaves it nested under the project."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "MyProj" :status "active"))
        :sections nil
        :tasks ((:id "t1" :title "Inside" :status "next" :projectId "p1"))
        :settings nil)
    (goto-char (point-min)) (re-search-forward "Inside") (org-back-to-heading t)
    (org-todo "WAIT")
    (mindwtr-commands--relocate 'task)
    (let* ((ad (mindwtr-parse-buffer))
           (child (car (plist-get ad :tasks))))
      (should (string= (plist-get child :projectId) "p1")))))

(ert-deftest mindwtr-commands-archived-task-stays-in-place ()
  "Archiving a standalone task does not move it (archived has no bucket)."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Bye" :status "next")) :settings nil)
    (goto-char (point-min)) (re-search-forward "Bye") (org-back-to-heading t)
    (org-todo "ARCH")
    (mindwtr-commands--relocate 'task)
    (should (string= (mindwtr-commands-test--parent-list-of "Bye") "single-actions"))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el --eval '(ert-run-tests-batch-and-exit "relocates\\|does-not-relocate\\|stays-in-place")'`
Expected: FAIL — relocation helpers are not defined (or `--relocate` is the temporary no-op).

- [ ] **Step 3: Implement relocation in `mindwtr-commands.el`**

Replace any temporary `mindwtr-commands--relocate` stub with the following, inserted before the `(provide ...)` line:

```elisp
(defun mindwtr-commands--status-at-point (kind)
  "Status string for the KIND entity at point, derived from its TODO keyword."
  (let ((kw (save-excursion (org-back-to-heading t) (org-get-todo-state))))
    (and kw (mindwtr-model-keyword->status-safe kind kw))))

(defun mindwtr-commands--in-project-p ()
  "Non-nil if the heading at point has a project or section ancestor."
  (or (mindwtr-parse--ancestor-id 'section)
      (mindwtr-parse--ancestor-id 'project)))

(defun mindwtr-commands--target-role (kind)
  "Container role the KIND entity at point should live under, or nil for no move.
Only standalone tasks and projects relocate; archived statuses have no role."
  (pcase kind
    ('task
     (unless (mindwtr-commands--in-project-p)
       (mindwtr-model-status->list (mindwtr-commands--status-at-point 'task))))
    ('project
     (mindwtr-model-project-status->list (mindwtr-commands--status-at-point 'project)))
    (_ nil)))

(defun mindwtr-commands--parent-list-role ()
  "Return the MW_LIST role of the nearest container ancestor of point, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let (role)
      (while (and (not role) (org-up-heading-safe))
        (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") "container")
          (setq role (mindwtr-parse--prop "MW_LIST"))))
      role)))

(defun mindwtr-commands--container-marker (role)
  "Return a marker at the container heading whose MW_LIST is ROLE, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((re (format "^[ \t]*:MW_LIST:[ \t]*%s[ \t]*$" (regexp-quote role))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)
        (point-marker)))))

(defun mindwtr-commands--relocate (kind)
  "Move the KIND entity at point under the container matching its current status.
No-op when the target role is nil (archived / project task / section) or the
entity already sits directly under the target container."
  (let ((role (mindwtr-commands--target-role kind)))
    (when (and role (not (equal (mindwtr-commands--parent-list-role) role)))
      (let ((target (mindwtr-commands--container-marker role)))
        (when target
          (save-excursion
            (org-back-to-heading t)
            (let ((level (1+ (save-excursion (goto-char target) (org-current-level)))))
              (org-cut-subtree)
              (goto-char target)
              ;; To the start of the heading after this container's subtree
              ;; (or end of buffer) -- a clean line boundary -- then paste as
              ;; the container's last child at the computed level.
              (org-end-of-subtree t t)
              (org-paste-subtree level))))))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — all command tests (Task 7 + Task 8), including the project-subtree move that carries the child task.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-commands.el test/mindwtr-commands-test.el
git commit -m "feat: eager bucket relocation on status change

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Commands — type-aware status cycling

**Files:**
- Modify: `mindwtr-commands.el` (add cycle commands)
- Test: `test/mindwtr-commands-test.el` (append cycle tests)

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-commands-test.el`:

```elisp
(ert-deftest mindwtr-commands-cycle-task-skips-active ()
  "Forward-cycling a task walks only task keywords (never ACTIVE) and relocates."
  (mindwtr-commands-test--with-appdata
      '(:areas nil :projects nil :sections nil
        :tasks ((:id "t1" :title "Cyc" :status "inbox")) :settings nil)
    (goto-char (point-min)) (re-search-forward "Cyc") (org-back-to-heading t)
    ;; inbox -> next (first forward step from INBOX)
    (mindwtr-cycle-status-forward)
    (save-excursion (goto-char (point-min)) (re-search-forward "Cyc") (org-back-to-heading t)
      (should (string= (org-get-todo-state) "NEXT")))
    (should (string= (mindwtr-commands-test--parent-list-of "Cyc") "single-actions"))))

(ert-deftest mindwtr-commands-cycle-project-only-project-keywords ()
  "Cycling a project never lands on a task-only keyword."
  (mindwtr-commands-test--with-appdata
      '(:areas nil
        :projects ((:id "p1" :title "PCyc" :status "active")) :sections nil
        :tasks nil :settings nil)
    (let ((valid '("ACTIVE" "SOMEDAY" "WAIT" "ARCH")))
      (dotimes (_ 6)
        (goto-char (point-min)) (re-search-forward "PCyc") (org-back-to-heading t)
        (mindwtr-cycle-status-forward)
        (goto-char (point-min)) (re-search-forward "PCyc") (org-back-to-heading t)
        (should (member (org-get-todo-state) valid))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el --eval '(ert-run-tests-batch-and-exit "cycle")'`
Expected: FAIL — `mindwtr-cycle-status-forward` is undefined.

- [ ] **Step 3: Implement the cycle commands**

In `mindwtr-commands.el`, before `(provide ...)`, add:

```elisp
(defun mindwtr-commands--cycle (dir)
  "Cycle the entity at point by DIR (+1/-1) through its type-valid keywords,
then relocate.  Falls back to plain org shift-cycling off Mindwtr headings."
  (let ((kind (mindwtr-commands--kind-at-point)))
    (if (not (memq kind '(task project)))
        (call-interactively (if (> dir 0) #'org-shiftright #'org-shiftleft))
      (let* ((kws (mapcar #'car (mindwtr-model-status-choices kind)))
             (cur (save-excursion (org-back-to-heading t) (org-get-todo-state)))
             (idx (and cur (cl-position cur kws :test #'string=)))
             (next (cond ((null idx) (if (> dir 0) 0 (1- (length kws))))
                         (t (mod (+ idx dir) (length kws))))))
        (save-excursion (org-back-to-heading t) (org-todo (nth next kws)))
        (mindwtr-commands--relocate kind)))))

;;;###autoload
(defun mindwtr-cycle-status-forward ()
  "Cycle the entity at point to its next type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle 1))

;;;###autoload
(defun mindwtr-cycle-status-backward ()
  "Cycle the entity at point to its previous type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle -1))
```

Add `(require 'cl-lib)` to the top of `mindwtr-commands.el` (after `(require 'org)`) for `cl-position`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-commands-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — all command tests including cycling.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-commands.el test/mindwtr-commands-test.el
git commit -m "feat: type-aware status cycling commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Wire commands into `mindwtr-mode`

**Files:**
- Modify: `mindwtr.el` (require `mindwtr-commands`; bind keys in `mindwtr-mode-map`)
- Test: `test/mindwtr-test.el` (append a keybinding test)

- [ ] **Step 1: Write the failing test**

Append to `test/mindwtr-test.el`:

```elisp
(ert-deftest mindwtr-mode-binds-type-aware-status-keys ()
  "mindwtr-mode shadows C-c C-t and S-arrow with the type-aware commands."
  (with-temp-buffer
    (mindwtr-mode)
    (should (eq (lookup-key mindwtr-mode-map (kbd "C-c C-t")) #'mindwtr-set-status))
    (should (eq (lookup-key mindwtr-mode-map (kbd "S-<right>")) #'mindwtr-cycle-status-forward))
    (should (eq (lookup-key mindwtr-mode-map (kbd "S-<left>")) #'mindwtr-cycle-status-backward))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-test.el --eval '(ert-run-tests-batch-and-exit "binds-type-aware-status-keys")'`
Expected: FAIL — the keys are not bound (commands not required).

- [ ] **Step 3: Require the commands and bind the keys**

In `mindwtr.el`, add a require alongside the other requires (after `(require 'mindwtr-model)` at line 14):

```elisp
(require 'mindwtr-commands)
```

Immediately after the `(define-derived-mode mindwtr-mode ...)` form (after line 94), add:

```elisp
(define-key mindwtr-mode-map (kbd "C-c C-t") #'mindwtr-set-status)
(define-key mindwtr-mode-map (kbd "S-<right>") #'mindwtr-cycle-status-forward)
(define-key mindwtr-mode-map (kbd "S-<left>") #'mindwtr-cycle-status-backward)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `emacs -Q --batch -L . -L test -l ert -l test/mindwtr-test.el --eval '(ert-run-tests-batch-and-exit "binds-type-aware-status-keys")'`
Expected: PASS.

- [ ] **Step 5: Full suite + compile + commit**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l ert $(for f in test/*-test.el; do echo "-l $f"; done) -f ert-run-tests-batch-and-exit`
Then: `make compile`
Expected: all tests `expected`, `0 unexpected`; `compile OK`.

```bash
git add mindwtr.el test/mindwtr-test.el
git commit -m "feat: wire type-aware status commands into mindwtr-mode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: README — document the v3 layout and the interactive commands

**Files:**
- Modify: `README.md` (layout/keywords section and a new "Working the file" subsection)

- [ ] **Step 1: Update the TODO-keywords / layout prose**

In `README.md`, update the "Major mode" and "Org schema" areas to describe:
- The v3 buckets: `Inbox`, `Single Actions` (next/waiting/done), `Projects` (active/waiting, grouped by area), `Someday` (with nested `Single Actions` and `Projects`), `Reference`, `Areas of Focus`.
- That in `mindwtr-mode`, `C-c C-t` offers only the valid statuses for the entity type (task vs project), `S-<left>`/`S-<right>` cycle only type-valid keywords, and either gesture relocates a standalone task or a project to the matching bucket immediately.
- That re-parenting a task into/out of a project uses native `C-c C-w` (`org-refile`).
- That a type-invalid keyword arriving via an unguarded path (raw edit, capture, editing outside the mode) is degraded gracefully: the parser keeps the prior status (or a default for a brand-new entity) and emits a warning instead of aborting the sync.

- [ ] **Step 2: Verify the doc references match the code**

Confirm the bucket names and key bindings in the README exactly match `mindwtr-model-list-roles` and the `define-key` forms from Task 10.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README for v3 layout and type-aware status commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Layout reorg (Single Actions merge, project-by-status split, nested Someday) → Tasks 1, 3.
- Status→bucket maps (task + project) → Task 1.
- Type-aware `C-c C-t` (`mindwtr-set-status`) → Tasks 2, 7, 10.
- Eager bucket relocation (standalone tasks + projects; project tasks/sections never; archived stays) → Task 8.
- Type-aware `S-arrow` cycling (level **b**) → Tasks 2, 9, 10.
- Re-parenting via native `org-refile` → no code (documented in Task 11).
- Backstop: `keyword->status-safe`, parser omits + warns, merge never clears status, new-entity default → Tasks 2, 4, 5.
- Round-trip preserved under the nested tree → Task 6.
- Module layout (`mindwtr-commands.el` new; reconcile unchanged because it rebuilds via render) → Tasks 3, 7-10.
- README → Task 11.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the assertion.

**Type consistency:** Helper names are stable across tasks — `mindwtr-model-keyword->status-safe`, `mindwtr-model-status-choices`, `mindwtr-model-project-status->list`, `mindwtr-render--standalone-for`, `mindwtr-render--task-bucket`, `mindwtr-render--project-subtree`, `mindwtr-render--projects-bucket`, `mindwtr-commands--kind-at-point`, `mindwtr-commands--read-keyword`, `mindwtr-commands--relocate`, `mindwtr-commands--target-role`, `mindwtr-commands--parent-list-role`, `mindwtr-commands--container-marker`, `mindwtr-set-status`, `mindwtr-cycle-status-forward/backward`. Bucket roles match between Task 1 (model), Task 3 (render), and Task 8 (relocation).

**Cross-task ordering note:** Task 7 references `mindwtr-commands--relocate` (defined in Task 8). Implement Tasks 7 and 8 together, or use the documented temporary no-op stub so Task 7's tests pass in isolation.
