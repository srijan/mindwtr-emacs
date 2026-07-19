# Synced Archive Surface (issue #27) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Archived entities live in a second synced org file (`mindwtr_archive.org`) instead of vanishing: cloud-side archives appear there, local ARCH/trash refiles there immediately, edits there (including un-archiving and deleting) sync back to the cloud.

**Architecture:** The archive file is a **second render surface**, not a write-once log. "Archived" becomes a status whose render home is a different file: `mindwtr-sync-once` parses *both* files into one local AppData, builds one candidate, and reconciles *both* buffers from the merged result (main render drops archived entities exactly as today; a new archive render contains only them). This makes every requirement fall out of the existing sync semantics — cloud-only archives appear on reconcile, dedup is automatic (the file is rebuilt canonically each cycle), un-archiving in the archive file moves the entity home, and deleting from the archive file tombstones it. The immediate-refile commands are pure UX (move the subtree now instead of at next sync); correctness never depends on them. A one-way **migration latch** (the repo's existing pattern) guards the deploy seam: until the archive surface has been durably rendered once, an archived entity missing from local is echoed (old behavior), never tombstoned.

The orchestration is deliberately written as a **list of surfaces** — each a (buffer × render function) pair the cycle iterates uniformly for parse-merge, tick guards, backups, reconcile, and saves — rather than hardcoded "main + archive". This ships the *mechanism* of issue #18 (configurable bucket→file routing) with two fixed surfaces; #20 later reduces to adding routing config and per-bucket renders, with no orchestration rework.

**Tech Stack:** Emacs Lisp (floor: Emacs 28.1 / Org 9.5), ERT. Ship gate: `make test` + `rm -f *.elc && make compile`.

---

## Design decisions (read before executing)

1. **Archive file = synced canonical surface.** Rebuilt by reconcile every full cycle, like the main file. Consequences the docs must state loudly: **deleting a heading from the archive file deletes the entity on the server** (after the latch is set); editing the `ARCH` keyword to e.g. `NEXT` un-archives — the entity moves back to the main file on the next sync.
2. **Single flat file, no datetree, no year files.** org-gtd's `gtd_archive_<year>::datetree/` was a write-once append log; a synced surface must be deterministically regenerable from data, which a datetree keyed on "date archived here" is not. Layout: one `* Archive` container; archived standalone tasks first, then archived projects with their full subtrees (the server keeps an archived project's tasks inside it). Year-sharding can be added later by partitioning on `:completedAt`.
3. **Containment escape hatch.** `:projectId`/`:sectionId` are signature content fields normally derived from outline ancestry. An archived task whose project is still *live* cannot nest under that project (it renders in the other file), so the archive render emits explicit `:MW_PROJECT_ID:`/`:MW_SECTION_ID:` drawer properties and the parser honors them over ancestry. No new content fields → no signature migration.
4. **Deploy-seam latch (critical).** With the archive surface active and the strict semantics on, an archived shadow entity absent from local = user deletion → tombstone. On the *first* sync after upgrade the archive file doesn't exist yet, so every archived item would be mass-deleted. Until `mindwtr-shadow-archive-migrated-p`, absence of archived entities keeps today's echo-verbatim behavior; the latch flips only after the archive buffer's post-reconcile save is confirmed durable (same rule as the notes/fields latches at `mindwtr-sync.el:549-560`). Additionally, an archive file that is *missing on disk* (vs. present but emptied) always falls back to echo for that cycle and is recreated by reconcile — `rm` of the file must not read as "delete everything".
5. **Backfill.** The first reconcile with the surface active writes every archived entity on the server into the archive file. Potentially large; that is the point ("sync all archived items").
6. **Immediate refile is UX only.** `mindwtr-archive-item-at-point`, `mindwtr-set-status` choosing `ARCH`, and clarify's trash outcome move the subtree to the archive buffer right then (stamping explicit containment props as needed) and save both files. If any of it fails, the heading keeps its `ARCH` keyword in place and the next sync moves it — no correctness rides on the refile.
7. **Legacy mode preserved.** When the archive surface is inactive (main buffer visits no file and no custom path — e.g. every existing temp-buffer test), behavior is byte-identical to today: archived entities are not rendered anywhere and absence is echoed. All existing tests must stay green without modification (except clarify trash tests, which assert the old "stays in place" UX on a file-less buffer — those stay valid because temp buffers are legacy mode).
8. **Hand-added headings in the archive file** without `MW_TYPE` are *not* kind-inferred (a direct child of `* Archive` could be a task or a project); they quarantine under `* Sync Failures` with the standard note. Rendered content always carries `MW_TYPE`.
9. **Org-only content** (LOGBOOK/CLOCK) in archived subtrees is carried across rebuilds by the existing per-id org-only collection, now run on both buffers. (User accepted losing it; we get preservation nearly free anyway.)
10. **Issue #20 alignment.** The surface-list shape (decision above) is the #20 mechanism without the #20 policy. Two items from #20's checklist land here because the archive file makes them necessary now, not later: multi-file parse-merge with cross-file change detection (Task 5), and second-file `mindwtr-mode` + auto-sync trigger coverage (Task 7) — editing the archive file (un-archive by keyword, deletion) is a first-class flow, so saving it must arm the debounced sync, its unsaved edits must stand down background rebuilds, and it needs the Mindwtr keyword registration and keybindings.
11. **Archive path resolution is anchored on `mindwtr-file` first**, then the current buffer's file. Hooks and timers run with arbitrary current buffers (including the archive buffer itself), so derivation must not depend on which buffer is current when `mindwtr-file` is configured.

## File structure

| File | Change |
|------|--------|
| `mindwtr-archive.el` | **Create.** Surface plumbing (path/buffer/active-p) + immediate refile core + `mindwtr-archive-item-at-point` |
| `mindwtr-model.el` | **Modify.** Add `"archive"` list role + title |
| `mindwtr-parse.el` | **Modify.** `MW_PROJECT_ID`/`MW_SECTION_ID` known-props + explicit-containment override |
| `mindwtr-render.el` | **Modify.** Add `mindwtr-render-archive-appdata` + containment injection |
| `mindwtr-shadow.el` | **Modify.** `archive-migrated` latch (clone of notes latch) |
| `mindwtr-sync.el` | **Modify.** Archive-aware absence semantics; surface-list orchestration in `mindwtr-sync-once` |
| `mindwtr-reconcile.el` | **Modify.** `mindwtr-reconcile-buffer` takes an optional render function |
| `mindwtr-commands.el` | **Modify.** `mindwtr-set-status` routes `ARCH` to the refile core |
| `mindwtr-clarify.el` | **Modify.** Trash outcome refiles immediately when the surface is active |
| `mindwtr.el` | **Modify.** Auto-sync triggers, unsaved-edits gate, and manual-sync save cover the archive file |
| `test/mindwtr-archive-test.el` | **Create** |
| `test/mindwtr-test.el` | **Create.** Trigger/gate coverage for the archive file |
| `test/mindwtr-render-test.el`, `test/mindwtr-parse-test.el` (or model test file), `test/mindwtr-sync-test.el`, `test/mindwtr-clarify-test.el` | **Modify.** New cases |
| `README.md`, `CONCEPTS.md`, `AGENTS.md` | **Modify.** Docs |

Makefile needs no change (globs `mindwtr*.el`, `test/*-test.el`).

---

### Task 0: Branch

- [ ] **Step 1:**

```bash
cd /path/to/mindwtr-emacs
git checkout -b feat/37-synced-archive-surface
```

---

### Task 1: Surface plumbing (`mindwtr-archive.el`)

**Files:** Create `mindwtr-archive.el`, `test/mindwtr-archive-test.el`

- [ ] **Step 1: Failing tests**

```elisp
;;; mindwtr-archive-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-archive)

(ert-deftest mindwtr-archive-path-derives-from-main-file ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/mw/tasks.org")
    (unwind-protect
        (let ((mindwtr-file nil))
          (should (string= (mindwtr-archive-path) "/tmp/mw/mindwtr_archive.org")))
      (setq buffer-file-name nil))))

(ert-deftest mindwtr-archive-path-honors-custom-string-and-function ()
  (let ((mindwtr-archive-file "/tmp/elsewhere/arch.org"))
    (should (string= (mindwtr-archive-path) "/tmp/elsewhere/arch.org")))
  (let ((mindwtr-archive-file (lambda () "/tmp/fn/arch.org")))
    (should (string= (mindwtr-archive-path) "/tmp/fn/arch.org"))))

(ert-deftest mindwtr-archive-inactive-without-file-or-custom ()
  (with-temp-buffer
    (let ((mindwtr-archive-file nil)
          (mindwtr-file nil))
      (should-not (mindwtr-archive-path)))))

(ert-deftest mindwtr-archive-path-anchors-on-mindwtr-file-first ()
  "Hooks and timers call this from arbitrary buffers (including the archive
buffer itself), so when `mindwtr-file' is configured it must anchor the
derivation regardless of the current buffer."
  (with-temp-buffer
    (let ((mindwtr-archive-file nil)
          (mindwtr-file "/tmp/mw/tasks.org"))
      (should (string= (mindwtr-archive-path) "/tmp/mw/mindwtr_archive.org")))))

(provide 'mindwtr-archive-test)
;;; mindwtr-archive-test.el ends here
```

Run: `make test` → FAIL (`Cannot open load file: mindwtr-archive`).

- [ ] **Step 2: Implement**

```elisp
;;; mindwtr-archive.el --- The synced archive surface -*- lexical-binding: t; -*-
;;; Commentary:
;; Archived entities live in a second synced org file: the sync engine parses
;; it as part of local state and reconcile rebuilds it canonically each cycle
;; (see mindwtr-render-archive-appdata).  This module owns the surface's
;; location and buffer, plus the immediate-refile commands -- pure UX sugar
;; that moves a freshly archived subtree over right away instead of at the
;; next sync; correctness never depends on them.
;;; Code:

(require 'org)
(require 'mindwtr-parse)

(defvar mindwtr-file)                          ; defcustom in mindwtr.el
(declare-function mindwtr-mode "mindwtr")

(defconst mindwtr-archive-file-name "mindwtr_archive.org"
  "Default archive file name, created beside the synced org file.")

(defcustom mindwtr-archive-file nil
  "Location of the synced archive file.
nil        -- derive: `mindwtr-archive-file-name' in the main org file's
              directory; the surface is inactive when the main buffer
              visits no file.
a string   -- that path.
a function -- called with no arguments in the main org buffer; must
              return a path."
  :group 'mindwtr
  :type '(choice (const :tag "Beside the synced org file" nil)
                 (string :tag "Path")
                 (function :tag "Function returning a path")))

(defun mindwtr-archive-path ()
  "Absolute path of the archive file, or nil when the surface is inactive.
Derivation is anchored on `mindwtr-file' first so hooks and timers resolve
the same path from any current buffer; the current buffer's file is the
fallback for file-visiting buffers used without `mindwtr-file' (tests)."
  (cond
   ((stringp mindwtr-archive-file) (expand-file-name mindwtr-archive-file))
   ((functionp mindwtr-archive-file)
    (expand-file-name (funcall mindwtr-archive-file)))
   ((or (bound-and-true-p mindwtr-file) (buffer-file-name))
    (expand-file-name
     mindwtr-archive-file-name
     (file-name-directory (expand-file-name
                           (or (bound-and-true-p mindwtr-file)
                               (buffer-file-name))))))))

(defun mindwtr-archive-buffer (&optional no-create)
  "Return a buffer visiting the archive file, or nil when inactive.
Creates the (empty) file's buffer unless NO-CREATE and the file is absent.
The buffer gets `mindwtr-mode' (keyword registration, status keybindings)
when available, since editing the archive file is a first-class flow."
  (let ((path (mindwtr-archive-path)))
    (when (and path (or (file-exists-p path) (not no-create)))
      (let ((buf (find-file-noselect path)))
        (with-current-buffer buf
          (when (and (fboundp 'mindwtr-mode)
                     (not (derived-mode-p 'mindwtr-mode)))
            (let ((org-inhibit-startup t)) (mindwtr-mode))))
        buf))))

(provide 'mindwtr-archive)
;;; mindwtr-archive.el ends here
```

- [ ] **Step 3:** `make test` → PASS. `rm -f *.elc && make compile` → clean.
- [ ] **Step 4:** Commit: `git add mindwtr-archive.el test/mindwtr-archive-test.el && git commit -m "feat(archive): archive surface location plumbing"`

---

### Task 2: Model role + explicit containment in the parser

**Files:** `mindwtr-model.el`, `mindwtr-parse.el`, tests in `test/mindwtr-parse-test.el` (create if absent; check for an existing parse test file first and append there)

- [ ] **Step 1: Failing tests**

```elisp
(ert-deftest mindwtr-parse-explicit-containment-props-win ()
  "MW_PROJECT_ID / MW_SECTION_ID set :projectId/:sectionId without ancestry,
and do not leak into extra-props."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
              "** ARCH orphaned but owned\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
              ":MW_PROJECT_ID: p9\n:END:\n"
              "** ARCH sectioned\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n"
              ":MW_SECTION_ID: s9\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1"))
                         (plist-get ad :tasks)))
           (t2 (seq-find (lambda (e) (equal (plist-get e :id) "t2"))
                         (plist-get ad :tasks))))
      (should (equal (plist-get t1 :projectId) "p9"))
      (should (equal (plist-get t1 :status) "archived"))
      (should (equal (plist-get t2 :sectionId) "s9"))
      (should-not (plist-get t1 :mw-extra-props)))))

(ert-deftest mindwtr-parse-ancestry-still-wins-when-no-explicit-prop ()
  "Tasks nested under a project in the archive file get projectId from
ancestry, exactly like the main file."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
              "** ARCH Old project\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "*** DONE step\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let* ((ad (mindwtr-parse-buffer))
           (t1 (car (plist-get ad :tasks))))
      (should (equal (plist-get t1 :projectId) "p1")))))
```

Run: `make test` → first test FAILS (`:projectId` nil, prop in extra-props).

- [ ] **Step 2: Implement**

In `mindwtr-model.el` add `"archive"` to `mindwtr-model-list-roles` and `("archive" . "Archive")` to `mindwtr-model--list-titles`. Do **not** add it to the parser's kind-inference table (decision 8) — verify `mindwtr-parse--infer-kind`'s pcase has no catch-all that would match it (it returns nil for unknown roles; `"archive"` must keep returning nil for untyped headings).

In `mindwtr-parse.el`:
1. Add `"MW_PROJECT_ID"` and `"MW_SECTION_ID"` to `mindwtr-parse--known-props` (find the defconst; append both strings).
2. In `mindwtr-parse-buffer`'s task branch (`mindwtr-parse.el:376-380`), replace:

```elisp
               ('task
                (let ((sid (mindwtr-parse--ancestor-id 'section))
                      (pid (mindwtr-parse--ancestor-id 'project)))
                  (cond (sid (setq e (plist-put e :sectionId sid)))
                        (pid (setq e (plist-put e :projectId pid)))))
                (push (mindwtr-parse--strip-internal e) tasks))
```

with:

```elisp
               ('task
                ;; Explicit containment props (emitted by the archive render
                ;; for archived tasks whose project/section lives in the main
                ;; file) win over outline ancestry, which is the source of
                ;; truth everywhere else.
                (let ((xsid (mindwtr-parse--prop "MW_SECTION_ID"))
                      (xpid (mindwtr-parse--prop "MW_PROJECT_ID"))
                      (sid (mindwtr-parse--ancestor-id 'section))
                      (pid (mindwtr-parse--ancestor-id 'project)))
                  (cond (xsid (setq e (plist-put e :sectionId xsid)))
                        (xpid (setq e (plist-put e :projectId xpid)))
                        (sid (setq e (plist-put e :sectionId sid)))
                        (pid (setq e (plist-put e :projectId pid)))))
                (push (mindwtr-parse--strip-internal e) tasks))
```

(If the prop scan helper at heading is named differently than `mindwtr-parse--prop`, use whatever `mindwtr-reconcile--id-markers` uses — it is `mindwtr-parse--prop`.)

- [ ] **Step 3:** `make test` → PASS (including every pre-existing parse/round-trip test — the main render never emits these props, so nothing else changes). Compile gate clean.
- [ ] **Step 4:** Commit: `feat(parse): archive list role and explicit containment props`

---

### Task 3: The archive renderer

**Files:** `mindwtr-render.el`, tests in `test/mindwtr-render-test.el`

Selection rules:
- **Archived projects** (status `archived`, not tombstoned) render as full subtrees — project at level 2, its sections/tasks nested via the existing `mindwtr-render--project-subtree` with *non-dropping* task/section lists (an archived project's `done`/`next` children belong inside it).
- **Flat archived tasks**: status `archived`, not tombstoned, and *not* inside an archived-and-alive project (those are covered by the subtree). Rendered at level 2 with explicit `MW_PROJECT_ID`/`MW_SECTION_ID` injected when the task carries containment.

- [ ] **Step 1: Failing tests** (append to `test/mindwtr-render-test.el`)

```elisp
(defconst mindwtr-render-test--archive-appdata
  '(:tasks ((:id "t-flat" :title "flat archived" :status "archived")
            (:id "t-owned" :title "owned archived" :status "archived" :projectId "p-live")
            (:id "t-in-arch" :title "inside archived" :status "done" :projectId "p-arch")
            (:id "t-live" :title "live" :status "next")
            (:id "t-tomb" :title "ghost" :status "archived" :deletedAt "D"))
    :projects ((:id "p-arch" :title "Old proj" :status "archived")
               (:id "p-live" :title "Live proj" :status "active"))
    :sections nil :areas nil :settings nil))

(ert-deftest mindwtr-render-archive-layout-and-selection ()
  (let ((out (mindwtr-render-archive-appdata mindwtr-render-test--archive-appdata)))
    ;; Container and keyword line present.
    (should (string-match-p "^#\\+TODO: " out))
    (should (string-match-p "^\\* Archive\n" out))
    ;; Flat archived tasks render; the live-project-owned one carries the
    ;; explicit containment prop.
    (should (string-match-p "^\\*\\* ARCH flat archived" out))
    (should (string-match-p ":MW_PROJECT_ID: p-live" out))
    ;; The archived project renders as a subtree with its done child inside.
    (should (string-match-p "^\\*\\* ARCH Old proj" out))
    (should (string-match-p "^\\*\\*\\* DONE inside archived" out))
    ;; Live and tombstoned entities do not render here.
    (should-not (string-match-p "live\\b.*\n.*MW_ID: t-live" out))
    (should-not (string-match-p "ghost" out))
    (should-not (string-match-p "Live proj" out))))

(ert-deftest mindwtr-render-archive-round-trips-byte-stably ()
  "render -> parse -> render reproduces identical bytes (the repo's headline
invariant, applied to the new surface)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert (mindwtr-render-archive-appdata mindwtr-render-test--archive-appdata))
      (org-mode))
    (let* ((parsed (mindwtr-parse-buffer))
           ;; Re-attach the fields parse does not produce but render reads.
           (again (mindwtr-render-archive-appdata
                   (list :tasks (plist-get parsed :tasks)
                         :projects (append (plist-get parsed :projects)
                                           '((:id "p-live" :title "Live proj"
                                              :status "active")))
                         :sections nil :areas nil :settings nil))))
      (should (string= (buffer-string) again)))))
```

Run: `make test` → FAIL (`void-function mindwtr-render-archive-appdata`).

- [ ] **Step 2: Implement** (append to `mindwtr-render.el` before the `provide`)

```elisp
;;;; Archive surface

(defun mindwtr-render-archive--inject-containment (rendered e)
  "Splice explicit MW_PROJECT_ID/MW_SECTION_ID into RENDERED's drawer for E.
A flat archived task's project/section lives in another file, so outline
ancestry cannot carry containment; these props are the parser's escape hatch.
Injected immediately before the drawer's :END: so the position is fixed and
the bytes round-trip stably."
  (let ((sid (plist-get e :sectionId))
        (pid (plist-get e :projectId)))
    (if (not (or sid pid)) rendered
      (let ((i (string-match "\n:END:\n" rendered)))
        (if (not i) rendered
          (concat (substring rendered 0 (1+ i))
                  (if sid (format ":MW_SECTION_ID: %s\n" sid)
                    (format ":MW_PROJECT_ID: %s\n" pid))
                  (substring rendered (1+ i))))))))

(defun mindwtr-render-archive-appdata (appdata &optional org-only)
  "Render APPDATA's archived entities to the canonical archive layout.
The mirror of `mindwtr-render-appdata': exactly the entities that file drops
render here.  Archived projects appear as full subtrees (their sections and
tasks inside, whatever those tasks' statuses); other archived tasks render
flat under the `* Archive' container with explicit containment props when
their project/section lives in the main file.  ORG-ONLY as in
`mindwtr-render-appdata'."
  (let* ((mindwtr-render-area-names (mindwtr-render--area-name-map appdata))
         (area-order (mindwtr-render--area-order-map appdata))
         (projects (mindwtr-render--live (plist-get appdata :projects)))
         (sections (mindwtr-render--live (plist-get appdata :sections)))
         (tasks (mindwtr-render--live (plist-get appdata :tasks)))
         (arch-projs (cl-remove-if-not
                      (lambda (p) (equal (plist-get p :status) "archived"))
                      projects))
         (arch-proj-ids (mapcar (lambda (p) (plist-get p :id)) arch-projs))
         (arch-sec-ids (mapcar (lambda (s) (plist-get s :id))
                               (cl-remove-if-not
                                (lambda (s) (member (plist-get s :projectId)
                                                    arch-proj-ids))
                                sections)))
         (flat (cl-remove-if-not
                (lambda (tk)
                  (and (equal (plist-get tk :status) "archived")
                       (not (member (plist-get tk :projectId) arch-proj-ids))
                       (not (member (plist-get tk :sectionId) arch-sec-ids))))
                tasks))
         (out (concat (mindwtr-model-todo-keyword-line) "\n"
                      (mindwtr-render--container "archive" 1))))
    (dolist (tk (mindwtr-render--sorted flat))
      (setq out (concat out (mindwtr-render-archive--inject-containment
                             (mindwtr-render--entity tk 'task 2 org-only) tk))))
    (dolist (proj (mindwtr-render--sorted-projects arch-projs area-order))
      (setq out (concat out (mindwtr-render--project-subtree
                             proj 2 sections tasks org-only))))
    out))
```

Check `mindwtr-render--container`: it renders a role via `mindwtr-model-list-title`, which Task 2 taught about `"archive"`. If `--container` hardcodes a role table instead, extend it the same way.

- [ ] **Step 3:** `make test` → PASS. Compile clean.
- [ ] **Step 4:** Commit: `feat(render): canonical archive surface renderer`

---

### Task 4: Absence semantics + migration latch

**Files:** `mindwtr-shadow.el`, `mindwtr-sync.el`, tests in `test/mindwtr-sync-test.el`

- [ ] **Step 1: Failing tests**

```elisp
(ert-deftest mindwtr-sync-archive-active-tombstones-missing-archived ()
  "With the archive surface active and migrated, an archived shadow entity
absent from local is a user deletion -> tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "archived" :rev 3))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (mindwtr-sync--archive-strict t)
         (cand (mindwtr-sync-build-candidate local shadow "dev" "NOW")))
    (let ((t1 (car (plist-get cand :tasks))))
      (should (equal (plist-get t1 :deletedAt) "NOW")))))

(ert-deftest mindwtr-sync-archive-inactive-echoes-missing-archived ()
  "Legacy behavior (surface inactive or latch unset): echoed verbatim."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "archived" :rev 3))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (mindwtr-sync--archive-strict nil)
         (cand (mindwtr-sync-build-candidate local shadow "dev" "NOW")))
    (let ((t1 (car (plist-get cand :tasks))))
      (should-not (plist-get t1 :deletedAt))
      (should (= (plist-get t1 :rev) 3)))))

(ert-deftest mindwtr-sync-archive-strict-treats-archived-project-as-live ()
  "Strict mode: an archived project renders (in the archive file), so a child
task absent from local is a deletion, not an expected absence."
  (let* ((shadow '(:tasks ((:id "c1" :title "kid" :status "done"
                            :projectId "p1" :rev 2))
                   :projects ((:id "p1" :title "P" :status "archived" :rev 2))
                   :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (mindwtr-sync--archive-strict t)
         (cand (mindwtr-sync-build-candidate local shadow "dev" "NOW")))
    (should (equal (plist-get (seq-find (lambda (e) (equal (plist-get e :id) "c1"))
                                        (plist-get cand :tasks))
                   :deletedAt)
                   "NOW"))))
```

Run: `make test` → FAIL (`void-variable mindwtr-sync--archive-strict`, then assertion failures).

- [ ] **Step 2: Implement the latch in `mindwtr-shadow.el`**

Clone the notes-migrated latch (find `mindwtr-shadow-notes-migrated-p` / `mindwtr-shadow-set-notes-migrated` and copy their exact storage mechanism — file or key — under the name `archive`):

```elisp
(defun mindwtr-shadow-archive-migrated-p ()
  "Non-nil once this client has durably rendered the archive surface once.
Until then a missing archived entity is echoed, never tombstoned: the deploy
seam where the archive file does not exist yet must not read as a mass
deletion.  Same pattern as `mindwtr-shadow-notes-migrated-p'."
  ...)

(defun mindwtr-shadow-set-archive-migrated () ...)
```

(Implement with the identical persistence calls the notes latch uses — keep them symmetrical.)

- [ ] **Step 3: Implement strict-mode absence semantics in `mindwtr-sync.el`**

Add near the top:

```elisp
(defvar mindwtr-sync--archive-strict nil
  "Non-nil while building a candidate with the archive surface active+migrated.
Strict semantics: archived entities render (in the archive file), so their
absence from local is a user deletion.  nil keeps the legacy echo behavior.
Let-bound by `mindwtr-sync-once'; a defvar (not a parameter) so the deep
call chain through build-candidate need not thread it.")
```

In `mindwtr-sync--live-container-ids` (`mindwtr-sync.el:131-148`), change the project condition to treat archived projects as live under strict mode:

```elisp
        (when (and id (not (plist-get p :deletedAt))
                   (or mindwtr-sync--archive-strict
                       (not (equal (plist-get p :status) "archived"))))
```

In `mindwtr-sync--rendered-absent-p` (`mindwtr-sync.el:150-166`), gate the archived escape and the no-list escape on legacy mode:

```elisp
  (or (and (not mindwtr-sync--archive-strict)
           (equal (plist-get se :status) "archived"))
      (pcase kind
        ('task
         (let ((sid (plist-get se :sectionId)) (pid (plist-get se :projectId)))
           (cond (sid (not (gethash sid (cdr live))))
                 (pid (not (gethash pid (car live))))
                 (t (and (not mindwtr-sync--archive-strict)
                         (null (mindwtr-model-status->list (plist-get se :status))))))))
        ...unchanged...
```

(Under strict mode the only status mapping to no list is `archived`, which now renders — so the `t` branch must stop excusing it.)

- [ ] **Step 4:** `make test` → all three new tests PASS; **every pre-existing sync test must still pass unchanged** (they run with the defvar at its nil default = legacy). Compile clean.
- [ ] **Step 5:** Commit: `feat(sync): strict absence semantics behind archive migration latch`

---

### Task 5: Two-buffer orchestration

**Files:** `mindwtr-reconcile.el`, `mindwtr-sync.el`, tests in `test/mindwtr-sync-test.el`

- [ ] **Step 1: Parameterize reconcile**

In `mindwtr-reconcile.el`, change the signature of `mindwtr-reconcile-buffer` (line 438) to `(merged &optional render-fn)` and replace the render call at line 466:

```elisp
           (rendered (funcall (or render-fn #'mindwtr-render-appdata)
                              merged org-only)))
```

Docstring: add "RENDER-FN (default `mindwtr-render-appdata') produces the canonical text; the archive surface passes `mindwtr-render-archive-appdata'."

- [ ] **Step 2: Failing end-to-end tests**

```elisp
(defun mindwtr-sync-test--with-files (main-content fn)
  "Run FN with a file-visiting main buffer (MAIN-CONTENT) and temp dirs bound.
FN is called with (main-buf dir archive-path) in the main buffer."
  (let* ((dir (make-temp-file "mw-2buf" t))
         (file (expand-file-name "tasks.org" dir))
         (apath (expand-file-name "mindwtr_archive.org" dir))
         (mindwtr-shadow-directory dir)
         (mindwtr-archive-file apath))
    (unwind-protect
        (progn
          (with-temp-file file (insert main-content))
          (let* ((org-inhibit-startup t)
                 (buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf (funcall fn buf dir apath))
              (dolist (b (list buf (find-buffer-visiting apath)))
                (when b
                  (with-current-buffer b (set-buffer-modified-p nil))
                  (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-moves-remote-archive-to-archive-file ()
  "A task the merged result marks archived disappears from the main file and
appears in the archive file, in one cycle."
  (let ((mindwtr-api-base-url "https://mw.example/")
        (mindwtr-api-token "x")
        (mindwtr-api-http-function
         (lambda (req)
           (pcase (plist-get req :method)
             ("PUT" '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
             ("GET" '(:status 200 :headers (("ETag" . "v2"))
                      :body "{\"tasks\":[{\"id\":\"t1\",\"title\":\"pay bill\",\"status\":\"archived\",\"rev\":2,\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-06-11T00:00:00Z\"}],\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}"))))))
    (mindwtr-sync-test--with-files
     (concat "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n"
             ":MW_LIST: single-actions\n:END:\n"
             "** DONE pay bill\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
     (lambda (_buf _dir apath)
       (mindwtr-shadow-save
        '(:tasks ((:id "t1" :title "pay bill" :status "done" :rev 1
                   :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
          :projects nil :sections nil :areas nil :settings nil))
       (mindwtr-sync-once (current-buffer) "2026-06-11T00:00:00Z")
       (goto-char (point-min))
       (should-not (search-forward "pay bill" nil t))
       (should (file-exists-p apath))
       (with-current-buffer (find-buffer-visiting apath)
         (goto-char (point-min))
         (should (search-forward "* Archive" nil t))
         (should (search-forward "ARCH pay bill" nil t)))
       ;; First successful two-surface cycle flips the latch.
       (should (mindwtr-shadow-archive-migrated-p))))))

(ert-deftest mindwtr-sync-once-unarchives-edited-archive-entry ()
  "Editing ARCH -> NEXT in the archive file pushes status next; the merged
result moves the heading back to the main file."
  (let* ((put-body nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v3")) :body put-body))))))
    (mindwtr-sync-test--with-files
     "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
     (lambda (_buf _dir apath)
       (mindwtr-shadow-save
        '(:tasks ((:id "t1" :title "revive me" :status "archived" :rev 2
                   :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
          :projects nil :sections nil :areas nil :settings nil))
       (mindwtr-shadow-set-archive-migrated)
       (with-temp-file apath
         (insert (mindwtr-model-todo-keyword-line) "\n"
                 "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
                 "** NEXT revive me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"))
       (mindwtr-sync-once (current-buffer) "NOW")
       ;; Pushed as next, rendered back into the main file...
       (goto-char (point-min))
       (should (search-forward "NEXT revive me" nil t))
       ;; ...and gone from the archive file.
       (with-current-buffer (find-buffer-visiting apath)
         (goto-char (point-min))
         (should-not (search-forward "revive me" nil t)))))))

(ert-deftest mindwtr-sync-once-first-cycle-does-not-tombstone-archived ()
  "Deploy seam: latch unset + no archive file => archived shadow entities are
echoed (not deleted) AND get rendered into the new archive file."
  (let* ((put-body nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v3")) :body put-body))))))
    (mindwtr-sync-test--with-files
     "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
     (lambda (_buf _dir apath)
       (mindwtr-shadow-save
        '(:tasks ((:id "t1" :title "old archived" :status "archived" :rev 2
                   :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
          :projects nil :sections nil :areas nil :settings nil))
       (mindwtr-sync-once (current-buffer) "NOW")
       (should-not (string-match-p "deletedAt" (or put-body "")))
       (with-current-buffer (find-buffer-visiting apath)
         (goto-char (point-min))
         (should (search-forward "old archived" nil t)))))))
```

Run: `make test` → FAIL (archive file never written; latch functions unused).

- [ ] **Step 3: Implement surface-list orchestration in `mindwtr-sync-once`**

The cycle iterates a **list of surfaces** — this is issue #18's mechanism with two fixed entries; #20 later swaps in a configurable list. Add to `mindwtr-sync.el` (and `(require 'mindwtr-archive)` in the requires block):

```elisp
(defun mindwtr-sync--surfaces (main-buf)
  "Return this cycle's render surfaces, in priority order.
Each surface is a plist (:buffer BUF :render FN :backup-prefix STR).  The
main buffer is always first -- on a duplicate id across surfaces the
earliest surface wins.  The archive surface is appended when active.
Issue #20 (bucket->file routing) generalizes this list; keep all
orchestration (parse-merge, ticks, backups, reconcile, saves) iterating it
rather than naming buffers."
  (let ((surfaces (list (list :buffer main-buf
                              :render #'mindwtr-render-appdata
                              :backup-prefix "mindwtr"))))
    (let ((abuf (with-current-buffer main-buf (mindwtr-archive-buffer))))
      (when abuf
        (setq surfaces
              (append surfaces
                      (list (list :buffer abuf
                                  :render #'mindwtr-render-archive-appdata
                                  :backup-prefix "mindwtr-archive"))))))
    surfaces))

(defun mindwtr-sync--parse-surfaces (surfaces)
  "Parse every surface buffer and merge into one local AppData.
Earlier surfaces win duplicate ids (a message notes the dropped copy).
Returns (APPDATA . WARNINGS): `mindwtr-parse--warnings' is per-parse-run
state, so each buffer's warnings are collected before the next parse."
  (let ((out (list :tasks nil :projects nil :sections nil :areas nil))
        (have (make-hash-table :test 'equal))
        (warnings nil))
    (dolist (s surfaces)
      (let ((ad (with-current-buffer (plist-get s :buffer)
                  (mindwtr-parse-buffer))))
        (setq warnings (append warnings (mindwtr-parse-warnings)))
        (dolist (key '(:tasks :projects :sections :areas))
          (dolist (e (plist-get ad key))
            (let ((id (plist-get e :id)))
              (if (and id (gethash id have))
                  (message "mindwtr: %s %s present in two files; using the first copy"
                           key id)
                (when id (puthash id t have))
                (setq out (plist-put out key
                                     (append (plist-get out key) (list e))))))))))
    (cons out warnings)))
```

Then rework `mindwtr-sync-once` (`mindwtr-sync.el:444`) — keep everything else intact:

```elisp
    (let* ((shadow (mindwtr-shadow-load))
           (device (mindwtr-shadow-device-id))
           (archive-path (mindwtr-archive-path))
           ;; Strict absence semantics only once the surface has been durably
           ;; rendered (latch) AND the file is present on disk -- a missing
           ;; file (first run, or the user rm'ed it) must read as "not yet
           ;; rendered", never as "everything was deleted".
           (mindwtr-sync--archive-strict
            (and archive-path
                 (file-exists-p archive-path)
                 (mindwtr-shadow-archive-migrated-p)))
           (surfaces (mindwtr-sync--surfaces (current-buffer)))
           (parsed (mindwtr-sync--parse-surfaces surfaces))
           (local (car parsed))
           (parse-warnings (cdr parsed))
           ;; Per-surface tick baselines (see the original tick comment).
           (ticks (mapcar (lambda (s)
                            (cons s (with-current-buffer (plist-get s :buffer)
                                      (buffer-chars-modified-tick))))
                          surfaces))
           ...)
```

In the full-cycle branch, generalize the per-buffer steps to loops over `surfaces`:

- **Tick guard** (line 512):

```elisp
            (pcase-dolist (`(,s . ,tick) ticks)
              (unless (= tick (with-current-buffer (plist-get s :buffer)
                                (buffer-chars-modified-tick)))
                (error "mindwtr: buffer changed during sync; aborting")))
```

- **Backup** (lines 514-525): loop the existing backup block over each surface whose buffer visits a file, using `(plist-get s :backup-prefix)` in place of the literal `"mindwtr"` in the name format.
- **Reconcile** (line 526):

```elisp
            (dolist (s surfaces)
              (with-current-buffer (plist-get s :buffer)
                (mindwtr-reconcile-buffer merged (plist-get s :render))))
```

- **Save + latch** (lines 538-560): save every surface buffer; any failure folds into the returned `:save-failed`. Flip the archive latch only when *all* saves succeeded and the archive surface was present:

```elisp
            (let ((save-failed
                   (seq-some (lambda (s)
                               (null (with-current-buffer (plist-get s :buffer)
                                       (mindwtr-sync--save-buffer-quietly t))))
                             surfaces)))
              ...
              (unless save-failed
                (when (cdr surfaces)   ; archive surface participated
                  (condition-case err
                      (mindwtr-shadow-set-archive-migrated)
                    (error (message "mindwtr: archive-migrated latch write failed: %s"
                                    (error-message-string err))))))
              ...)
```

- **Noop HEAD branch:** uses the combined `local` for stats, so a dirty archive file forces a full cycle automatically. No further change.

- [ ] **Step 4:** `make test` → all PASS, including all legacy temp-buffer sync tests (no file → `archive-path` nil → identical old path). Compile clean.
- [ ] **Step 5:** Commit: `feat(sync): parse and reconcile the archive file as a second surface (#37)`

---

### Task 6: Immediate refile + commands

**Files:** `mindwtr-archive.el`, `mindwtr-commands.el`, `mindwtr-clarify.el`, tests in `test/mindwtr-archive-test.el` + `test/mindwtr-clarify-test.el`

- [ ] **Step 1: Failing tests**

```elisp
(ert-deftest mindwtr-archive-item-at-point-moves-subtree-now ()
  "Refiles the heading into the archive buffer under * Archive, stamps ARCH,
and preserves containment of a task cut out from under its live project."
  (let* ((dir (make-temp-file "mw-refile" t))
         (file (expand-file-name "tasks.org" dir))
         (mindwtr-archive-file (expand-file-name "mindwtr_archive.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                    "** ACTIVE Live proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
                    "*** DONE finished step\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"))
          (let* ((org-inhibit-startup t)
                 (buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  (search-forward "finished step")
                  (mindwtr-archive-item-at-point)
                  ;; Gone from the main buffer; project remains.
                  (goto-char (point-min))
                  (should-not (search-forward "finished step" nil t))
                  (goto-char (point-min))
                  (should (search-forward "Live proj" nil t))
                  ;; In the archive buffer: ARCH keyword, level 2, explicit
                  ;; containment prop pointing at the live project.
                  (with-current-buffer (mindwtr-archive-buffer)
                    (goto-char (point-min))
                    (should (search-forward "** ARCH finished step" nil t))
                    (should (search-forward ":MW_PROJECT_ID: p1" nil t))
                    ;; Saved to disk.
                    (should-not (buffer-modified-p))))
              (dolist (b (list buf (find-buffer-visiting mindwtr-archive-file)))
                (when b (with-current-buffer b (set-buffer-modified-p nil))
                      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))
      (delete-directory dir t))))

(ert-deftest mindwtr-archive-item-at-point-errors-when-inactive ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* x\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((mindwtr-archive-file nil))
      (should-error (mindwtr-archive-item-at-point) :type 'user-error))))
```

Run: `make test` → FAIL (`void-function mindwtr-archive-item-at-point`).

- [ ] **Step 2: Implement the refile core** (append to `mindwtr-archive.el`)

```elisp
(defun mindwtr-archive--ensure-container (buf)
  "Make sure BUF holds the keyword line and `* Archive' container; return
the insertion point for new entries (end of buffer)."
  (with-current-buffer buf
    (let ((org-inhibit-startup t))
      (unless (derived-mode-p 'org-mode) (org-mode)))
    (goto-char (point-min))
    (unless (re-search-forward "^:MW_LIST: archive$" nil t)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (when (= (point-min) (point-max))
        (insert (mindwtr-model-todo-keyword-line) "\n"))
      (insert "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"))
    (point-max)))

(defun mindwtr-archive--save-quietly (buf)
  "Save BUF without chatter; never signal (UX path, not a data-safety gate)."
  (when (buffer-file-name buf)
    (condition-case nil
        (with-current-buffer buf
          (let ((inhibit-message t)) (basic-save-buffer)))
      (error nil))))

(defun mindwtr-archive--refile-at-point ()
  "Move the subtree at point into the archive buffer, now.
Point must be on a task or project heading with an MW_ID.  Stamps explicit
MW_PROJECT_ID/MW_SECTION_ID when the entity is a task leaving a live
project/section (ancestry is how containment is parsed; the archive file
cannot provide it).  Saves both buffers.  UX sugar only: if this fails the
heading still carries ARCH and the next sync performs the same move."
  (org-back-to-heading t)
  (let* ((abuf (or (mindwtr-archive-buffer)
                   (user-error "mindwtr-archive: archive surface inactive (no file)")))
         (kind (let ((mt (mindwtr-parse--mw-type)))
                 (if mt (intern mt) (mindwtr-parse--infer-kind))))
         (sid (and (eq kind 'task) (mindwtr-parse--ancestor-id 'section)))
         (pid (and (eq kind 'task) (mindwtr-parse--ancestor-id 'project))))
    (unless (memq kind '(task project))
      (user-error "mindwtr-archive: only tasks and projects can be archived"))
    (unless (mindwtr-parse--prop "MW_ID")
      (user-error "mindwtr-archive: heading has no MW_ID"))
    ;; Containment must survive losing its ancestry.
    (cond ((and sid (not (mindwtr-parse--prop "MW_SECTION_ID")))
           (org-set-property "MW_SECTION_ID" sid))
          ((and pid (not (mindwtr-parse--prop "MW_PROJECT_ID")))
           (org-set-property "MW_PROJECT_ID" pid)))
    (let ((subtree (progn (org-back-to-heading t)
                          (buffer-substring-no-properties
                           (point)
                           (save-excursion (org-end-of-subtree t t) (point))))))
      (org-back-to-heading t)
      (delete-region (point) (save-excursion (org-end-of-subtree t t) (point)))
      (with-current-buffer abuf
        (goto-char (mindwtr-archive--ensure-container abuf))
        (unless (bolp) (insert "\n"))
        (insert (mindwtr-archive--reroot subtree 2))))
    (mindwtr-archive--save-quietly abuf)
    (mindwtr-archive--save-quietly (current-buffer))))

(defun mindwtr-archive--reroot (text target)
  "Shift heading levels in subtree TEXT so its top heading sits at TARGET.
Same transform as `mindwtr-reconcile--reroot-subtree' (duplicated to avoid a
reconcile dependency from a command path)."
  (let* ((top (and (string-match "\\`\\(\\*+\\) " text)
                   (length (match-string 1 text))))
         (delta (and top (- target top))))
    (if (or (null delta) (= delta 0)) text
      (replace-regexp-in-string
       "^\\*+ "
       (lambda (stars+sp)
         (concat (make-string (max 1 (+ (1- (length stars+sp)) delta)) ?*) " "))
       text))))

;;;###autoload
(defun mindwtr-archive-item-at-point ()
  "Archive the task or project at point: set ARCH and refile it to the
archive file immediately.  The next sync pushes the archived status."
  (interactive)
  (org-back-to-heading t)
  (org-todo "ARCH")
  (mindwtr-archive--refile-at-point)
  (message "mindwtr: archived to %s" (mindwtr-archive-path)))
```

(Verify the names `mindwtr-parse--mw-type`, `mindwtr-parse--ancestor-id`, `mindwtr-parse--prop` against `mindwtr-parse.el` — all three are used by reconcile/parse today.)

- [ ] **Step 3: Hook `mindwtr-set-status`** (`mindwtr-commands.el:34-47`) — replace the `(when kw ...)` body:

```elisp
        (when kw
          (save-excursion (org-back-to-heading t) (org-todo kw))
          (if (and (string= kw "ARCH") (mindwtr-archive-path))
              (mindwtr-archive--refile-at-point)
            (mindwtr-commands--relocate kind)))
```

Add `(require 'mindwtr-archive)` to `mindwtr-commands.el`.

- [ ] **Step 4: Hook clarify trash** (`mindwtr-clarify.el:319-321`) — replace the `?x` branch:

```elisp
    ;; Trash: ARCH.  With the archive surface active the heading refiles to
    ;; the archive file right now; otherwise it keeps its place until the
    ;; next sync moves it.  The session queue is id-based, so a vanished
    ;; heading is skipped, not re-presented.
    (?x (let ((org-log-done nil)) (org-todo "ARCH"))
        (if (mindwtr-archive-path)
            (mindwtr-archive--refile-at-point)
          (mindwtr-commands--relocate 'task)))
```

Add `(require 'mindwtr-archive)` to `mindwtr-clarify.el`. Check `test/mindwtr-clarify-test.el` for trash-outcome tests: ones running in temp buffers (no file → surface inactive) still exercise the stays-in-place path and must pass unchanged; if any uses a file-visiting fixture, update its expectation to the refile behavior.

- [ ] **Step 5:** `make test` → PASS. Compile clean.
- [ ] **Step 6:** Commit: `feat(archive): immediate refile on ARCH/trash + mindwtr-archive-item-at-point`

---

### Task 7: Auto-sync triggers and edit gates cover the archive file

**Files:** `mindwtr.el`, create `test/mindwtr-test.el`

Editing the archive file is a first-class flow (un-archive by keyword edit, deletion), so it needs the same treatment as the main file (this is the "auto-sync save trigger must cover every routed file" item from issue #18, needed now): saving it arms the debounced sync, its unsaved edits stand down background rebuilds, and the manual `mindwtr-sync` saves it first. (`mindwtr-mode` in the archive buffer was already handled by `mindwtr-archive-buffer` in Task 1.)

- [ ] **Step 1: Failing tests** — create `test/mindwtr-test.el`:

```elisp
;;; mindwtr-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr)

(defmacro mindwtr-test--with-two-files (&rest body)
  "BODY with `mindwtr-file' + archive file existing in a temp dir.
Binds `dir', `mindwtr-file', and `apath'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "mw-trig" t))
          (mindwtr-file (expand-file-name "tasks.org" dir))
          (apath (expand-file-name "mindwtr_archive.org" dir))
          (mindwtr-archive-file nil)
          (mindwtr--debounce-timer nil))
     (unwind-protect
         (progn
           (with-temp-file mindwtr-file (insert "* Inbox\n"))
           (with-temp-file apath (insert "* Archive\n"))
           ,@body)
       (when (timerp mindwtr--debounce-timer)
         (cancel-timer mindwtr--debounce-timer))
       (dolist (f (list mindwtr-file apath))
         (let ((b (find-buffer-visiting f)))
           (when b
             (with-current-buffer b (set-buffer-modified-p nil))
             (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))
       (delete-directory dir t))))

(ert-deftest mindwtr-save-in-archive-file-arms-debounce ()
  "after-save in the archive buffer schedules the debounced auto-sync,
exactly like a save of the main file."
  (mindwtr-test--with-two-files
    (with-current-buffer (find-file-noselect apath)
      (mindwtr--maybe-debounced-sync)
      (should (timerp mindwtr--debounce-timer)))))

(ert-deftest mindwtr-save-elsewhere-does-not-arm-debounce ()
  (mindwtr-test--with-two-files
    (let ((other (expand-file-name "notes.org" dir)))
      (with-temp-file other (insert "x"))
      (with-current-buffer (find-file-noselect other)
        (unwind-protect
            (progn (mindwtr--maybe-debounced-sync)
                   (should-not (timerp mindwtr--debounce-timer)))
          (set-buffer-modified-p nil)
          (kill-buffer))))))

(ert-deftest mindwtr-dirty-archive-buffer-stands-down-auto-sync ()
  "Unsaved edits in the archive buffer must gate background rebuilds, or a
sync could erase in-progress un-archive edits."
  (mindwtr-test--with-two-files
    (with-current-buffer (find-file-noselect apath)
      (goto-char (point-max))
      (insert "edit")
      (should (mindwtr--buffer-has-unsaved-edits-p)))))

(provide 'mindwtr-test)
;;; mindwtr-test.el ends here
```

Run: `make test` → the first and third tests FAIL (debounce never armed for the archive path; gate ignores the archive buffer).

- [ ] **Step 2: Implement in `mindwtr.el`**

`mindwtr--maybe-debounced-sync` (`mindwtr.el:281-291`) — extend the file match:

```elisp
    (when (and mindwtr-file buffer-file-name
               (or (file-equal-p buffer-file-name mindwtr-file)
                   (let ((ap (mindwtr-archive-path)))
                     (and ap (file-equal-p buffer-file-name ap)))))
```

`mindwtr--buffer-has-unsaved-edits-p` (`mindwtr.el:214-222`) — check both buffers:

```elisp
(defun mindwtr--buffer-has-unsaved-edits-p ()
  "Non-nil when the synced file OR the archive file has unsaved buffer edits.
Nil when `mindwtr-file' is unset or neither file is open in a buffer (no
buffer means no in-progress edits, so an automatic sync is free to run and
rebuild).  Both surfaces are full rebuild targets, so both gate."
  (when mindwtr-file
    (seq-some (lambda (path)
                (when path
                  (let ((buf (find-buffer-visiting path)))
                    (and buf (buffer-modified-p buf)))))
              (list mindwtr-file (mindwtr-archive-path)))))
```

`mindwtr-sync` (`mindwtr.el:250-254`) — save-then-sync covers both:

```elisp
  (when mindwtr-file
    (dolist (path (list mindwtr-file (mindwtr-archive-path)))
      (when path
        (let ((buf (find-buffer-visiting path)))
          (when (and buf (buffer-modified-p buf))
            (with-current-buffer buf
              (mindwtr-sync--save-buffer-quietly)))))))
```

(`mindwtr.el` already gets `mindwtr-archive-path` transitively via `mindwtr-sync` → `mindwtr-archive`; no new require needed, but add `(require 'mindwtr-archive)` explicitly anyway — it is used directly now.)

- [ ] **Step 3:** `make test` → PASS. `rm -f *.elc && make compile && rm -f *.elc` → clean.
- [ ] **Step 4:** Commit: `feat(mindwtr): auto-sync triggers and edit gates cover the archive file`

---

### Task 8: Documentation

**Files:** `README.md`, `CONCEPTS.md`, `AGENTS.md`

- [ ] **Step 1: README.** Add a top-level section near the file-layout docs:

```markdown
### The archive file

Archived work lives in a second synced file, `mindwtr_archive.org`
(`mindwtr-archive-file`), beside your tasks file. It is a real sync surface,
rebuilt canonically on every cycle — not an append-only log:

- Anything archived anywhere (locally, on another device, or by the
  server's auto-archive) appears in it after the next sync.
- Setting `ARCH` via `mindwtr-set-status`, trashing in clarify, or
  `M-x mindwtr-archive-item-at-point` refiles the heading there immediately.
- Changing an entry's keyword (e.g. `ARCH` → `NEXT`) un-archives it: the
  next sync moves it back into the tasks file.
- **Deleting a heading from the archive file deletes the entity on the
  server**, exactly as it does in the tasks file.
- The archive buffer is a full citizen: it opens in `mindwtr-mode`, saving
  it arms the same debounced auto-sync as the tasks file, and its unsaved
  edits stand down background rebuilds.

The first sync after enabling backfills every archived item from the
server. The very first cycle is guarded by a migration latch: until the
archive file has been written once, missing archived items are never
interpreted as deletions.
```

Also update the trash row (`README.md:205`): `ARCH; refiled to the archive file immediately (or on the next sync when the buffer visits no file)`, and rewrite the now-stale "Archived projects preserve their tasks" note (line ~474): archived projects now render in the archive file with their tasks; the preserved-on-server explanation stays for legacy mode.

- [ ] **Step 2: CONCEPTS.md.** Add under "Sync data model" (or a new "Archive" heading):

```markdown
### Archive surface
The second synced render surface: the archive file holds exactly the
entities the main render drops for being archived, rebuilt canonically by
Reconcile each cycle. "Archived" is thereby a status whose render home is a
different file — un-archiving an entry moves it back, deleting one is a
real deletion (Tombstone). Containment that outline ancestry cannot express
across files rides on explicit MW_PROJECT_ID/MW_SECTION_ID properties. The
surface's first render is guarded by a Migration latch so a not-yet-created
archive file is never read as a mass deletion.
```

- [ ] **Step 3: AGENTS.md.** File-table row after `mindwtr-shadow.el`:

```markdown
| `mindwtr-archive.el` | Archive surface (location, immediate refile, `mindwtr-archive-item-at-point`) |
```

And add one line to "Conventions & invariants": "The archive file is a synced surface with the same round-trip byte-stability obligations as the main file."

- [ ] **Step 4:** `make test && rm -f *.elc && make compile && rm -f *.elc` → green/clean.
- [ ] **Step 5:** Commit: `docs: document the synced archive surface (#37)`

---

### Task 9: Manual verification against a live server

- [ ] Archive a task on the phone/web app → `mindwtr-sync` → it lands in `mindwtr_archive.org`; the backfill on the very first sync brings all historical archived items.
- [ ] `mindwtr-archive-item-at-point` on a task under a live project → moves instantly with `MW_PROJECT_ID`; next sync pushes archived; the other client agrees.
- [ ] Trash an inbox item in clarify → heading moves to the archive file immediately, session advances.
- [ ] Edit an archive entry's keyword `ARCH` → `NEXT` and just save (with `mindwtr-auto-sync-mode` on) → the debounced sync fires on its own and the entry returns to the tasks file, un-archived on the other client.
- [ ] Delete an entry from the archive file, sync → it is deleted on the server (verify intentionally, with a throwaway item).
- [ ] Archive a project with done children on the other client, sync → full subtree appears in the archive file; un-archive it there → subtree returns (the README's standing TODO about this path can then be resolved).
- [ ] `make smoke-docker` still green.
- [ ] `gh issue close 37 --repo srijan/mindwtr-emacs` once merged.
