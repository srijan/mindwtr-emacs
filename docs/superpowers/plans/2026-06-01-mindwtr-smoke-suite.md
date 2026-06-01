# Mindwtr Live Smoke Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four throwaway `smoke-*.el` harnesses with one committed, reusable live smoke suite that exercises the full sync contract (read-only checks + an opt-in self-cleaning GTD write lifecycle) and surfaces server schema drift.

**Architecture:** A shared library `smoke/mindwtr-smoke.el` holds config, reporting/exit, pure helpers, diagnostics, and phase functions; a thin `smoke/run.el` selects and runs phases. The suite reuses the real sync code path (`mindwtr-render` → `mindwtr-parse` → `mindwtr-sync-build-candidate` → `mindwtr-api-put-data`). Pure logic is unit-tested offline against an in-memory mock transport via `mindwtr-api-http-function`.

**Tech Stack:** Emacs Lisp (Emacs 28.1+), `ert`, GNU Make. No new dependencies.

**Reference spec:** `docs/superpowers/specs/2026-06-01-mindwtr-smoke-suite-design.md`

**Conventions for the implementer:**
- Entities are plists keyed by Mindwtr JSON field names (`:id`, `:title`, `:status`, …). AppData is `(:tasks LIST :projects LIST :sections LIST :areas LIST :settings PLIST)`.
- Before every `make test` / `make compile`, delete stale bytecode: `find . -name '*.elc' -delete`. Stale `.elc` files mask source changes.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Work directly on `main` (the user authorized this; no worktree).
- `make compile` sets `byte-compile-error-on-warn t`, so the root package files must be warning-clean.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `mindwtr-model.el` (modify) | Add `mindwtr-model-known-fields` registry (schema-drift reference). |
| `mindwtr-util.el` (modify) | Expand `mindwtr-util-json-array-fields` to the full source-declared set. |
| `smoke/mindwtr-smoke.el` (create) | Shared library: config, reporting/exit, pure helpers, diagnostics, phases, write lifecycle. |
| `smoke/run.el` (create) | Entrypoint: configure, run read-only phases, optionally the write lifecycle, exit with summary code. |
| `Makefile` (modify) | Add `smoke` / `smoke-write` targets; add `-L smoke` to the `test` target. |
| `test/mindwtr-smoke-test.el` (create) | Offline ert tests: pure helpers, schema coverage, reporting/exit, full lifecycle against a mock server. |
| `smoke-test.el`, `smoke-diag.el`, `smoke-probe.el`, `smoke-write.el` (delete) | Throwaway harnesses, subsumed by the suite. |

---

## Task 1: Known-fields registry in the model

**Files:**
- Modify: `mindwtr-model.el` (after `mindwtr-model-device-local-fields`, ~line 83)
- Test: `test/mindwtr-model-test.el`

- [ ] **Step 1: Write the failing test**

Append to `test/mindwtr-model-test.el`:

```elisp
(ert-deftest mindwtr-model-known-fields-covers-entity-types ()
  "The registry has an entry per synced entity type with representative keys."
  (should (assq 'task mindwtr-model-known-fields))
  (should (assq 'project mindwtr-model-known-fields))
  (should (assq 'section mindwtr-model-known-fields))
  (should (assq 'area mindwtr-model-known-fields))
  ;; settings is intentionally excluded (verbatim passthrough)
  (should-not (assq 'settings mindwtr-model-known-fields))
  ;; representative keys transcribed from Mindwtr core types.ts
  (let ((task (cdr (assq 'task mindwtr-model-known-fields)))
        (proj (cdr (assq 'project mindwtr-model-known-fields)))
        (sec  (cdr (assq 'section mindwtr-model-known-fields)))
        (area (cdr (assq 'area mindwtr-model-known-fields))))
    (dolist (k '(:id :title :status :checklist :attachments :recurrence
                 :completedAt :purgedAt :deletedAt :rev :revBy))
      (should (memq k task)))
    (dolist (k '(:sequentialScope :supportNotes :attachments :dueDate :reviewAt
                 :isSequential :isFocused :areaTitle))
      (should (memq k proj)))
    (dolist (k '(:description :isCollapsed :deletedAtBeforeProjectArchive
                 :projectArchivedAt))
      (should (memq k sec)))
    (should (memq :icon area)))
  ;; every content field that applies to tasks is a known task key
  (dolist (k mindwtr-model-content-fields)
    (unless (eq k :name)                ; :name is an area field, not a task field
      (should (memq k (cdr (assq 'task mindwtr-model-known-fields)))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L test -l test/mindwtr-model-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-model-known-fields` is void.

- [ ] **Step 3: Add the registry**

In `mindwtr-model.el`, immediately after the `mindwtr-model-device-local-fields` defconst (the block ending ~line 83), insert:

```elisp
(defconst mindwtr-model-known-fields
  '((task    . (:id :title :status :priority :energyLevel :timeEstimate
                :assignedTo :taskMode :startTime :dueDate :recurrence
                :showFutureRecurrence :pushCount :tags :contexts :checklist
                :description :textDirection :attachments :location
                :projectId :sectionId :areaId :isFocusedToday :reviewAt
                :completedAt :statusBeforeProjectArchive
                :completedAtBeforeProjectArchive
                :isFocusedTodayBeforeProjectArchive :projectArchivedAt
                :order :orderNum :rev :revBy :createdAt :updatedAt
                :deletedAt :purgedAt))
    (project . (:id :title :status :color :order :tagIds :isSequential
                :sequentialScope :isFocused :supportNotes :attachments
                :dueDate :reviewAt :areaId :areaTitle :rev :revBy
                :createdAt :updatedAt :deletedAt))
    (section . (:id :projectId :title :description :order :isCollapsed
                :rev :revBy :createdAt :updatedAt :deletedAt
                :deletedAtBeforeProjectArchive :projectArchivedAt))
    (area    . (:id :name :color :icon :order :rev :revBy
                :createdAt :updatedAt :deletedAt)))
  "Every server key we recognize, per synced entity type.
Transcribed from the Mindwtr core `types.ts' interfaces (Task, Project,
Section, Area).  The smoke suite flags wire keys absent here as UNKNOWN
\(server drift); doubles as living documentation of the synced schema.
Extend it deliberately when a new server field is intentionally adopted.
Settings is excluded on purpose -- it is a large, deeply-nested blob
passed through verbatim and never rendered to org.")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L test -l test/mindwtr-model-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (all model tests).

- [ ] **Step 5: Commit**

```bash
git add mindwtr-model.el test/mindwtr-model-test.el
git commit -m "feat: add known-fields schema registry for drift detection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Expand the JSON array-fields list

The `nil → []` encoder fix is keyed by field NAME. The source declares array-valued fields we haven't listed yet (`byDay`, `byMonthDay`, `externalCalendars`, `savedSearches`, `lastSyncHistory`); an empty one of those must serialize as `[]`, not be omitted.

**Files:**
- Modify: `mindwtr-util.el:` the `mindwtr-util-json-array-fields` defconst
- Test: `test/mindwtr-util-test.el`

- [ ] **Step 1: Write the failing test**

Append to `test/mindwtr-util-test.el`:

```elisp
(ert-deftest mindwtr-util-json-array-fields-covers-source-arrays ()
  "Nested array-valued keys from the source serialize as [] when nil,
while scalar nils are still omitted."
  ;; recurrence.byDay is an array; nil -> [] (not omitted, not null)
  (let ((s (mindwtr-util-json-encode '(:recurrence (:rule "weekly" :byDay nil)))))
    (should (string-match-p "\"byDay\":\\[\\]" s)))
  ;; settings array fields -> []
  (let ((s (mindwtr-util-json-encode '(:externalCalendars nil :savedSearches nil
                                       :lastSyncHistory nil))))
    (should (string-match-p "\"externalCalendars\":\\[\\]" s))
    (should (string-match-p "\"savedSearches\":\\[\\]" s))
    (should (string-match-p "\"lastSyncHistory\":\\[\\]" s)))
  ;; a scalar nil is still omitted
  (should-not (string-match-p "reviewAt"
                              (mindwtr-util-json-encode '(:reviewAt nil :id "x")))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L test -l test/mindwtr-util-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `byDay`/`externalCalendars`/… are omitted (treated as scalar nils), so the `[]` matches fail.

- [ ] **Step 3: Expand the array-fields list**

In `mindwtr-util.el`, replace the `mindwtr-util-json-array-fields` defconst with:

```elisp
(defconst mindwtr-util-json-array-fields
  '(:tasks :projects :sections :areas      ; appdata top-level
    :tags :contexts :checklist :attachments ; task (attachments also project)
    :tagIds                                  ; project
    :byDay :byMonthDay                       ; recurrence
    :savedFilters :savedSearches             ; settings
    :externalCalendars :lastSyncHistory)     ; settings
  "Plist keys whose value is a JSON array.
Emacs cannot tell an empty list from JSON null: both read back as nil.
A nil value for one of these keys must serialize as `[]'; a nil value
for any OTHER key is dropped, because nil means \"absent\" everywhere in
this model and the server rejects `[]' where it expects a scalar (e.g.
a task's deletedAt must be an ISO timestamp when present).  The set is
the union of array-valued field names across the Mindwtr core types
\(Task, Project, Recurrence, Settings); `:order' is deliberately absent
\(a number on entities, an array only inside settings.taskEditor, which
is echoed verbatim and never emitted nil by us).")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L test -l test/mindwtr-util-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (all util tests, including the existing `mindwtr-util-json-prep-omits-nil-scalars-keeps-empty-arrays`).

- [ ] **Step 5: Commit**

```bash
git add mindwtr-util.el test/mindwtr-util-test.el
git commit -m "fix: cover all source-declared array fields in JSON encoder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Smoke library scaffolding — config, reporting, exit

Creates the library file with the env/config and the reporting+exit machinery. Wires `-L smoke` into the test target so the offline tests can `require` it.

**Files:**
- Create: `smoke/mindwtr-smoke.el`
- Modify: `Makefile` (the `test` target)
- Create: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing test**

Create `test/mindwtr-smoke-test.el`:

```elisp
;;; mindwtr-smoke-test.el --- Tests for the live smoke suite -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-smoke)

(ert-deftest mindwtr-smoke-summary-exit-code ()
  "Summary returns non-zero exactly when a fail was recorded."
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-warn "b")
  (should (= 0 (mindwtr-smoke-summary)))
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-fail "c")
  (should (= 1 (mindwtr-smoke-summary)))
  ;; warn alone never fails the run
  (mindwtr-smoke-reset)
  (mindwtr-smoke-warn "only a warning")
  (should (= 0 (mindwtr-smoke-summary))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — cannot load `mindwtr-smoke` (file does not exist).

- [ ] **Step 3: Create the library with config + reporting**

Create `smoke/mindwtr-smoke.el`:

```elisp
;;; mindwtr-smoke.el --- Live smoke suite against a Mindwtr server -*- lexical-binding: t; -*-
;;; Commentary:
;; Reusable, committed smoke suite.  Read-only phases (connectivity,
;; snapshot+validate, schema coverage, render/parse round-trip) run by
;; default; an opt-in self-cleaning GTD write lifecycle exercises the PUT
;; path.  Run it via the Makefile so the token stays in your shell:
;;
;;   make smoke         ; read-only phases only
;;   make smoke-write   ; read-only phases + write lifecycle
;;
;; Config from the environment: MINDWTR_URL (required) and MINDWTR_TOKEN
;; (falls back to auth-source for the URL host when unset).
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-reconcile)
(require 'mindwtr-sync)
(require 'mindwtr)

;;;; Reporting + exit

(defvar mindwtr-smoke--counts nil
  "Plist (:pass N :fail N :warn N) of results for the current run.")

(defun mindwtr-smoke-reset ()
  "Reset the result counters."
  (setq mindwtr-smoke--counts (list :pass 0 :fail 0 :warn 0)))

(defun mindwtr-smoke--bump (key)
  (setq mindwtr-smoke--counts
        (plist-put mindwtr-smoke--counts key
                   (1+ (plist-get mindwtr-smoke--counts key)))))

(defun mindwtr-smoke-info (msg)
  "Print an indented diagnostic/info line MSG (not counted)."
  (message "       %s" msg))

(defun mindwtr-smoke-pass (label &rest details)
  "Record a pass for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :pass)
  (message "[PASS] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-fail (label &rest details)
  "Record a fail for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :fail)
  (message "[FAIL] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-warn (label &rest details)
  "Record a warning for LABEL (never affects exit code)."
  (mindwtr-smoke--bump :warn)
  (message "[WARN] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-summary ()
  "Print the run summary; return 1 if any fail was recorded, else 0."
  (message "---")
  (message "Summary: %d pass, %d fail, %d warn"
           (plist-get mindwtr-smoke--counts :pass)
           (plist-get mindwtr-smoke--counts :fail)
           (plist-get mindwtr-smoke--counts :warn))
  (if (> (plist-get mindwtr-smoke--counts :fail) 0) 1 0))

;;;; Config

(defun mindwtr-smoke-configure ()
  "Set `mindwtr-api-base-url' and `mindwtr-api-token' from the environment."
  (setq mindwtr-api-base-url
        (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
  (setq mindwtr-api-token
        (or (getenv "MINDWTR_TOKEN")
            (let ((mindwtr-server-url mindwtr-api-base-url))
              (ignore-errors (mindwtr--resolve-token)))
            (error "No token: set MINDWTR_TOKEN or an auth-source entry for the host"))))

(provide 'mindwtr-smoke)
;;; mindwtr-smoke.el ends here
```

- [ ] **Step 4: Wire `-L smoke` into the test target**

In `Makefile`, change the `test` target's command from:

```makefile
	$(EMACS) -Q --batch -L . -L test \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit
```

to (add `-L smoke`):

```makefile
	$(EMACS) -Q --batch -L . -L smoke -L test \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit
```

- [ ] **Step 5: Run test to verify it passes**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS — `mindwtr-smoke-summary-exit-code`.

- [ ] **Step 6: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el Makefile
git commit -m "feat: smoke suite scaffolding (config, reporting, exit)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Pure plist helpers + blast radius

**Files:**
- Modify: `smoke/mindwtr-smoke.el` (add a "Pure helpers" section before `(provide ...)`)
- Modify: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-smoke-test.el`:

```elisp
(ert-deftest mindwtr-smoke-plist-keys-and-same-p ()
  (should (equal (sort (mindwtr-smoke-plist-keys '(:a 1 :b 2)) #'string<)
                 '(:a :b)))
  (should (mindwtr-smoke-plist-same-p '(:a 1 :b 2) '(:b 2 :a 1)))
  (should-not (mindwtr-smoke-plist-same-p '(:a 1) '(:a 2)))
  (should-not (mindwtr-smoke-plist-same-p '(:a 1 :b 2) '(:a 1))))

(ert-deftest mindwtr-smoke-find-and-index ()
  (let ((ad '(:tasks ((:id "t1" :title "x") (:id "t2" :deletedAt "Z"))
              :projects ((:id "p1")) :sections nil :areas nil)))
    (should (string= (plist-get (mindwtr-smoke-find-by-id ad "t1") :title) "x"))
    (should (mindwtr-smoke-find-by-id ad "p1"))
    (should-not (mindwtr-smoke-find-by-id ad "nope"))
    ;; live index excludes tombstones
    (let ((idx (mindwtr-smoke-index-by-id ad t)))
      (should (gethash "t1" idx))
      (should-not (gethash "t2" idx)))))

(ert-deftest mindwtr-smoke-blast-radius-detects-only-changes ()
  (let ((prior '(:tasks ((:id "t1" :title "a" :rev 1)
                         (:id "t2" :title "b" :rev 1))
                 :projects nil :sections nil :areas nil)))
    ;; no change
    (should (null (mindwtr-smoke-blast-radius prior prior)))
    ;; update t1
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "A" :rev 2)
                              (:id "t2" :title "b" :rev 1))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t1")))
    ;; create t3
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "a" :rev 1)
                              (:id "t2" :title "b" :rev 1)
                              (:id "t3" :title "c" :rev 1))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t3")))
    ;; tombstone t2 (live -> deleted)
    (should (equal (mindwtr-smoke-blast-radius
                    '(:tasks ((:id "t1" :title "a" :rev 1)
                              (:id "t2" :title "b" :rev 2 :deletedAt "Z"))
                      :projects nil :sections nil :areas nil)
                    prior)
                   '("t2")))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — helper functions are void.

- [ ] **Step 3: Add the pure helpers**

In `smoke/mindwtr-smoke.el`, before `(provide 'mindwtr-smoke)`, insert:

```elisp
;;;; Pure helpers

(defconst mindwtr-smoke--entity-keys '(:tasks :projects :sections :areas))

(defun mindwtr-smoke-plist-keys (pl)
  "Return the list of keys in plist PL."
  (let (ks (i 0))
    (while (< i (length pl)) (push (nth i pl) ks) (setq i (+ i 2)))
    (nreverse ks)))

(defun mindwtr-smoke-plist-same-p (a b)
  "Non-nil if plists A and B have identical key->value sets (order-insensitive)."
  (let ((ka (mindwtr-smoke-plist-keys a)) (kb (mindwtr-smoke-plist-keys b)))
    (and (= (length ka) (length kb))
         (seq-every-p (lambda (k) (and (plist-member b k)
                                       (equal (plist-get a k) (plist-get b k))))
                      ka))))

(defun mindwtr-smoke-find-by-id (appdata id)
  "Return the entity with ID anywhere in APPDATA, or nil."
  (catch 'hit
    (dolist (key mindwtr-smoke--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (string= (plist-get e :id) id) (throw 'hit e))))
    nil))

(defun mindwtr-smoke-index-by-id (appdata &optional live-only)
  "Return a hash id->entity over all of APPDATA's entity lists.
With LIVE-ONLY non-nil, omit tombstoned entities (those with :deletedAt)."
  (let ((idx (make-hash-table :test 'equal)))
    (dolist (key mindwtr-smoke--entity-keys)
      (dolist (e (plist-get appdata key))
        (unless (and live-only (plist-get e :deletedAt))
          (puthash (plist-get e :id) e idx))))
    idx))

(defun mindwtr-smoke-blast-radius (wire prior)
  "Return the sorted list of entity ids that differ between PRIOR and WIRE.
Considers only the live view of each (tombstones are not live): an id is
in the radius if it is newly live in WIRE (create), no longer live in WIRE
\(delete/tombstone), or live in both but with different content (update)."
  (let ((wi (mindwtr-smoke-index-by-id wire t))
        (pi (mindwtr-smoke-index-by-id prior t))
        (ids (make-hash-table :test 'equal))
        out)
    (maphash (lambda (id w)
               (let ((p (gethash id pi)))
                 (when (or (null p) (not (mindwtr-smoke-plist-same-p w p)))
                   (puthash id t ids))))
             wi)
    (maphash (lambda (id _p)
               (unless (gethash id wi) (puthash id t ids)))
             pi)
    (maphash (lambda (id _) (push id out)) ids)
    (sort out #'string<)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (4 smoke tests now).

- [ ] **Step 5: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el
git commit -m "feat: smoke suite pure helpers and blast-radius gate

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Diagnostics (field-level diffs)

**Files:**
- Modify: `smoke/mindwtr-smoke.el` (add a "Diagnostics" section before `(provide ...)`)
- Modify: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-smoke-test.el`:

```elisp
(ert-deftest mindwtr-smoke-canonical-field-diff-reports-changed-fields ()
  "The canonical diff names a content field that differs and skips equal ones."
  (let ((lines (mindwtr-smoke-canonical-field-diff
                '(:title "old" :status "next")
                '(:title "new" :status "next"))))
    (should (seq-some (lambda (s) (string-match-p ":title" s)) lines))
    (should-not (seq-some (lambda (s) (string-match-p ":status" s)) lines))))

(ert-deftest mindwtr-smoke-key-diff-reports-differing-keys ()
  (let ((lines (mindwtr-smoke-key-diff '(:a 1 :b 2) '(:a 1 :b 9 :c 3))))
    (should (seq-some (lambda (s) (string-match-p ":b" s)) lines))
    (should (seq-some (lambda (s) (string-match-p ":c" s)) lines))
    (should-not (seq-some (lambda (s) (string-match-p ":a" s)) lines))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — diff functions are void.

- [ ] **Step 3: Add the diagnostics**

In `smoke/mindwtr-smoke.el`, before `(provide 'mindwtr-smoke)`, insert:

```elisp
;;;; Diagnostics (returned as lists of printable lines)

(defun mindwtr-smoke-canonical-field-diff (orig re)
  "Return diagnostic lines for content fields that differ between ORIG and RE.
Compares the signature's canonical plists, so it reports exactly the
fields that move the content signature."
  (let* ((co (mindwtr-signature--canonical-plist orig))
         (cr (mindwtr-signature--canonical-plist re))
         (allk (delete-dups (append (mindwtr-smoke-plist-keys co)
                                    (mindwtr-smoke-plist-keys cr))))
         lines)
    (dolist (k allk)
      (let ((vo (plist-get co k)) (vr (plist-get cr k)))
        (unless (equal vo vr)
          (push (format "%s: orig=%S  other=%S" k vo vr) lines))))
    (nreverse lines)))

(defun mindwtr-smoke-key-diff (a b)
  "Return diagnostic lines for every key whose value differs between A and B."
  (let ((allk (delete-dups (append (mindwtr-smoke-plist-keys a)
                                   (mindwtr-smoke-plist-keys b))))
        lines)
    (dolist (k allk)
      (unless (equal (plist-get a k) (plist-get b k))
        (push (format "%s: a=%S  b=%S" k (plist-get a k) (plist-get b k)) lines)))
    (nreverse lines)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (6 smoke tests).

- [ ] **Step 5: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el
git commit -m "feat: smoke suite field-level diagnostics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Schema-coverage computation + phase

**Files:**
- Modify: `smoke/mindwtr-smoke.el` (add a "Schema coverage" section before `(provide ...)`)
- Modify: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-smoke-test.el`:

```elisp
(ert-deftest mindwtr-smoke-schema-coverage-flags-unknown-and-unexercised ()
  "Unknown wire keys land in :unknown; known-but-absent keys in :unexercised."
  (let* ((ad '(:tasks ((:id "t1" :title "x" :status "next" :aiSummary "hi"))
               :projects nil :sections nil :areas nil))
         (cov (mindwtr-smoke-schema-coverage ad))
         (task (cdr (assq 'task cov))))
    (should (memq :aiSummary (plist-get task :unknown)))
    ;; a known task field not present on any task is unexercised, not unknown
    (should (memq :location (plist-get task :unexercised)))
    (should-not (memq :location (plist-get task :unknown)))
    ;; types with no entities report empty unknown
    (should (null (plist-get (cdr (assq 'area cov)) :unknown)))))

(ert-deftest mindwtr-smoke-phase-schema-coverage-warns-not-fails ()
  "An unknown key produces a WARN, never a FAIL."
  (mindwtr-smoke-reset)
  (mindwtr-smoke-phase-schema-coverage
   '(:tasks ((:id "t1" :title "x" :status "next" :aiSummary "hi"))
     :projects nil :sections nil :areas nil))
  (should (> (plist-get mindwtr-smoke--counts :warn) 0))
  (should (= 0 (plist-get mindwtr-smoke--counts :fail))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-smoke-schema-coverage` / `mindwtr-smoke-phase-schema-coverage` void.

- [ ] **Step 3: Add coverage computation + phase**

In `smoke/mindwtr-smoke.el`, before `(provide 'mindwtr-smoke)`, insert:

```elisp
;;;; Schema coverage

(defconst mindwtr-smoke--type->key
  '((task . :tasks) (project . :projects) (section . :sections) (area . :areas))
  "Map a known-fields entity type to its appdata list key.")

(defun mindwtr-smoke--union-keys (entities)
  "Return the set (deduped list) of keys appearing on any entity in ENTITIES."
  (let (acc)
    (dolist (e entities) (setq acc (append (mindwtr-smoke-plist-keys e) acc)))
    (delete-dups acc)))

(defun mindwtr-smoke-schema-coverage (appdata)
  "Compute per-type schema coverage for APPDATA against the known-fields registry.
Return an alist (TYPE . (:unknown KEYS :unexercised KEYS)): :unknown are
wire keys we do not model (server drift); :unexercised are known fields no
entity of that type uses on this instance."
  (mapcar
   (lambda (type)
     (let* ((known (cdr (assq type mindwtr-model-known-fields)))
            (live (mindwtr-smoke--union-keys
                   (plist-get appdata (cdr (assq type mindwtr-smoke--type->key)))))
            (unknown (seq-remove (lambda (k) (memq k known)) live))
            (unexercised (seq-remove (lambda (k) (memq k live)) known)))
       (cons type (list :unknown unknown :unexercised unexercised))))
   '(task project section area)))

(defun mindwtr-smoke-phase-schema-coverage (appdata)
  "Report schema coverage: UNKNOWN keys WARN; unexercised keys as one info line."
  (let ((cov (mindwtr-smoke-schema-coverage appdata)) (any-unknown nil))
    (dolist (entry cov)
      (let ((unknown (plist-get (cdr entry) :unknown)))
        (when unknown
          (setq any-unknown t)
          (mindwtr-smoke-warn
           (format "schema: %s has unknown keys" (car entry))
           (format "%S -- model may need updating for this server version"
                   unknown)))))
    (unless any-unknown
      (mindwtr-smoke-pass "schema coverage (no unknown keys)"))
    ;; one non-fatal info line listing model fields not seen on this instance
    (dolist (entry cov)
      (let ((unex (plist-get (cdr entry) :unexercised)))
        (when unex
          (mindwtr-smoke-info
           (format "%s fields not exercised on this instance: %S"
                   (car entry) unex)))))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (8 smoke tests).

- [ ] **Step 5: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el
git commit -m "feat: smoke suite schema-coverage phase

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Read-only phases (connectivity, snapshot, round-trip) + render helper

**Files:**
- Modify: `smoke/mindwtr-smoke.el` (add a "Read-only phases" section before `(provide ...)`)
- Modify: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing test (with the in-memory mock server)**

Append to `test/mindwtr-smoke-test.el`:

```elisp
(defun mindwtr-smoke-test--server (initial)
  "Return an `mindwtr-api-http-function' backed by an in-memory appdata.
A PUT replaces the whole state (full-replace, like the real server); GET
returns it re-encoded through JSON so nil/false/[] normalize as on the wire."
  (let ((state (copy-tree initial)) (etag 0))
    (lambda (req)
      (pcase (plist-get req :method)
        ("HEAD" (list :status 200
                      :headers (list (cons "ETag" (number-to-string etag)))
                      :body ""))
        ("GET" (list :status 200
                     :headers (list (cons "ETag" (number-to-string etag)))
                     :body (mindwtr-util-json-ascii state)))
        ("PUT" (setq state (mindwtr-util-json-decode (plist-get req :body)))
               (setq etag (1+ etag))
               (list :status 200 :headers nil :body "{\"ok\":true}"))))))

(defconst mindwtr-smoke-test--initial
  '(:tasks ((:id "t-keep" :title "keep me" :status "next" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"
             :contexts ("@computer") :tags nil))
    :projects nil :sections nil :areas nil :settings nil)
  "A minimal but valid server snapshot for offline phase tests.")

(ert-deftest mindwtr-smoke-readonly-phases-pass-on-clean-data ()
  (let* ((mindwtr-api-base-url "https://mock/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (mindwtr-smoke-test--server mindwtr-smoke-test--initial)))
    (mindwtr-smoke-reset)
    (should (mindwtr-smoke-phase-connectivity))
    (let ((ad (mindwtr-smoke-phase-snapshot)))
      (should ad)
      (mindwtr-smoke-phase-roundtrip ad))
    ;; clean data: no failures across connectivity + snapshot + round-trip
    (should (= 0 (plist-get mindwtr-smoke--counts :fail)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — phase functions / render helper void.

- [ ] **Step 3: Add the render helper and read-only phases**

In `smoke/mindwtr-smoke.el`, before `(provide 'mindwtr-smoke)`, insert:

```elisp
;;;; Buffer rendering helper

(defun mindwtr-smoke--render-appdata (appdata)
  "Erase the current buffer and render APPDATA into it as a Mindwtr org file."
  (erase-buffer)
  (let ((org-inhibit-startup t))
    (insert "#+TITLE: mw smoke\n")
    (org-mode))
  (mindwtr-parse-ensure-keywords)
  (mindwtr-reconcile-buffer appdata))

;;;; Read-only phases

(defun mindwtr-smoke-phase-connectivity ()
  "HEAD the server; PASS (returning t) on success, FAIL (returning nil) otherwise."
  (condition-case err
      (let ((etag (mindwtr-api-head-etag)))
        (mindwtr-smoke-pass "connectivity (HEAD)" (format "ETag: %s" (or etag "(none)")))
        t)
    (mindwtr-api-auth-error
     (mindwtr-smoke-fail "connectivity (HEAD)" "authentication failed (401)")
     nil)
    (error
     (mindwtr-smoke-fail "connectivity (HEAD)" (error-message-string err))
     nil)))

(defun mindwtr-smoke-phase-snapshot ()
  "GET + validate the snapshot.  Return the appdata, or nil on error."
  (condition-case err
      (let* ((got (mindwtr-api-get-data))
             (ad (plist-get got :appdata)))
        (mindwtr-smoke-pass
         "snapshot (GET)"
         (format "%d tasks, %d projects, %d sections, %d areas, settings:%s"
                 (length (plist-get ad :tasks)) (length (plist-get ad :projects))
                 (length (plist-get ad :sections)) (length (plist-get ad :areas))
                 (if (plist-get ad :settings) "present" "empty")))
        (condition-case verr
            (progn (mindwtr-model-validate-appdata ad)
                   (mindwtr-smoke-pass "validate-appdata"))
          (error (mindwtr-smoke-fail "validate-appdata" (error-message-string verr))))
        ad)
    (mindwtr-api-auth-error
     (mindwtr-smoke-fail "snapshot (GET)" "authentication failed (401)") nil)
    (error (mindwtr-smoke-fail "snapshot (GET)" (error-message-string err)) nil)))

(defun mindwtr-smoke-phase-roundtrip (appdata)
  "Render APPDATA to org, parse it back, and compare content signatures.
On drift, FAIL and print the per-field canonical diff for each entity."
  (condition-case err
      (with-temp-buffer
        (mindwtr-smoke--render-appdata appdata)
        (let* ((reparsed (mindwtr-parse-buffer))
               (orig-idx (mindwtr-smoke-index-by-id appdata))
               (drift 0) (checked 0))
          (dolist (key mindwtr-smoke--entity-keys)
            (dolist (re (plist-get reparsed key))
              (setq checked (1+ checked))
              (let ((orig (gethash (plist-get re :id) orig-idx)))
                (when (and orig (not (string= (mindwtr-signature re)
                                              (mindwtr-signature orig))))
                  (setq drift (1+ drift))
                  (mindwtr-smoke-fail
                   (format "round-trip drift id=%s title=%S"
                           (plist-get re :id)
                           (or (plist-get re :title) (plist-get re :name))))
                  (dolist (line (mindwtr-smoke-canonical-field-diff orig re))
                    (mindwtr-smoke-info line))))))
          (when (= drift 0)
            (mindwtr-smoke-pass
             (format "round-trip signature (%d entities clean)" checked)))))
    (error (mindwtr-smoke-fail "round-trip" (error-message-string err)))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (9 smoke tests).

- [ ] **Step 5: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el
git commit -m "feat: smoke suite read-only phases (connectivity, snapshot, round-trip)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Self-cleaning write lifecycle

Drives one throwaway task through `inbox → next → done → delete`, asserting after every PUT that the blast radius is exactly the target and that content round-trips. Wrapped in `unwind-protect` so cleanup always runs.

**Files:**
- Modify: `smoke/mindwtr-smoke.el` (add a "Write lifecycle" section before `(provide ...)`)
- Modify: `test/mindwtr-smoke-test.el`

- [ ] **Step 1: Write the failing test**

Append to `test/mindwtr-smoke-test.el`:

```elisp
(ert-deftest mindwtr-smoke-write-lifecycle-end-to-end ()
  "The lifecycle creates, mutates, transitions, and deletes a task with no
failures, leaving every pre-existing entity untouched."
  (let* ((mindwtr-api-base-url "https://mock/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (mindwtr-smoke-test--server mindwtr-smoke-test--initial)))
    (mindwtr-smoke-reset)
    (mindwtr-smoke-phase-write-lifecycle)
    (should (= 0 (plist-get mindwtr-smoke--counts :fail)))
    (let* ((final (plist-get (mindwtr-api-get-data) :appdata))
           (smoke (seq-find
                   (lambda (tk) (string-prefix-p
                                 "[mw-smoke]" (or (plist-get tk :title) "")))
                   (plist-get final :tasks)))
           (keep (mindwtr-smoke-find-by-id final "t-keep")))
      ;; the smoke task is gone or tombstoned
      (should (or (null smoke) (plist-get smoke :deletedAt)))
      ;; the pre-existing task survived unchanged
      (should keep)
      (should (string= (plist-get keep :title) "keep me"))
      (should-not (plist-get keep :deletedAt)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `mindwtr-smoke-phase-write-lifecycle` void.

- [ ] **Step 3: Add the write lifecycle**

In `smoke/mindwtr-smoke.el`, before `(provide 'mindwtr-smoke)`, insert:

```elisp
;;;; Write lifecycle (opt-in; self-cleaning)

(defconst mindwtr-smoke-device-id "mw-smoke"
  "Recognizable `revBy' device id stamped on lifecycle writes.")

(defun mindwtr-smoke--now ()
  "Current UTC instant as a whole-second ISO `...Z' string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun mindwtr-smoke--build-wire (local shadow now)
  "Build the wire payload from LOCAL parse and SHADOW, stamped with NOW."
  (mindwtr-sync--strip-internal-keys
   (mindwtr-sync-build-candidate local shadow mindwtr-smoke-device-id now)))

(defun mindwtr-smoke--replace-heading (id entity)
  "Replace the top-level heading with MW_ID ID by re-rendering ENTITY.
ENTITY is a task content plist; it is rendered at level 1 (the lifecycle
task has no container)."
  (let ((m (gethash id (mindwtr-reconcile--id-markers))))
    (unless m (error "smoke: heading %s not found in buffer" id))
    (goto-char m) (org-back-to-heading t) (org-cut-subtree)
    (insert (mindwtr-render-heading
             (plist-put (copy-sequence entity) :mw-kind 'task) 1 nil))))

(defun mindwtr-smoke--assert-target (label tgt desired exp-status exp-rev)
  "Assert TGT (server entity) matches DESIRED content and EXP-STATUS/EXP-REV.
Returns non-nil on full success.  On content drift prints the field diff."
  (let ((ok t))
    (cond
     ((null tgt)
      (setq ok nil) (mindwtr-smoke-fail (format "%s: target present" label)
                                        "not found after PUT"))
     (t
      (unless (equal (plist-get tgt :status) exp-status)
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: status" label)
                            (format "expected %S got %S"
                                    exp-status (plist-get tgt :status))))
      (unless (equal (plist-get tgt :rev) exp-rev)
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: rev" label)
                            (format "expected %S got %S"
                                    exp-rev (plist-get tgt :rev))))
      (unless (string= (mindwtr-signature desired) (mindwtr-signature tgt))
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: content round-trip" label))
        (dolist (line (mindwtr-smoke-canonical-field-diff desired tgt))
          (mindwtr-smoke-info line)))))
    (when ok (mindwtr-smoke-pass label))
    ok))

(defun mindwtr-smoke--step (label target-id edit-fn assert-fn)
  "Run one lifecycle step and return the new server appdata, or nil on failure.
GET the server, render it, run EDIT-FN to mutate the buffer, parse, build
the wire, assert the blast radius is exactly TARGET-ID, PUT, GET again, and
run ASSERT-FN with the new appdata and the target entity."
  (condition-case err
      (let ((prior (plist-get (mindwtr-api-get-data) :appdata)))
        (with-temp-buffer
          (mindwtr-smoke--render-appdata prior)
          (funcall edit-fn)
          (let* ((local (mindwtr-parse-buffer))
                 (now (mindwtr-smoke--now))
                 (wire (mindwtr-smoke--build-wire local prior now))
                 (radius (mindwtr-smoke-blast-radius wire prior)))
            (mindwtr-model-validate-appdata wire)
            (if (not (equal radius (list target-id)))
                (progn
                  (mindwtr-smoke-fail (format "%s: blast radius" label)
                                      (format "expected only (%s) got %S"
                                              target-id radius))
                  nil)
              (mindwtr-api-put-data wire)
              (let* ((after (plist-get (mindwtr-api-get-data) :appdata))
                     (tgt (mindwtr-smoke-find-by-id after target-id)))
                (funcall assert-fn after tgt)
                after)))))
    (error (mindwtr-smoke-fail (format "%s (error)" label)
                               (error-message-string err))
           nil)))

(defun mindwtr-smoke--cleanup (id baseline)
  "Delete the lifecycle task ID (tombstone) and confirm BASELINE is untouched.
BASELINE is the appdata captured before the lifecycle began.  Always safe
to call: a no-op PASS if the task is already gone."
  (condition-case err
      (let* ((prior (plist-get (mindwtr-api-get-data) :appdata))
             (tgt (mindwtr-smoke-find-by-id prior id)))
        (if (or (null tgt) (plist-get tgt :deletedAt))
            (mindwtr-smoke-pass "cleanup (already gone)")
          (with-temp-buffer
            (mindwtr-smoke--render-appdata prior)
            (let ((m (gethash id (mindwtr-reconcile--id-markers))))
              (when m (goto-char m) (org-back-to-heading t) (org-cut-subtree)))
            (let* ((local (mindwtr-parse-buffer))
                   (now (mindwtr-smoke--now))
                   (wire (mindwtr-smoke--build-wire local prior now))
                   (radius (mindwtr-smoke-blast-radius wire prior)))
              (if (not (equal radius (list id)))
                  (mindwtr-smoke-fail "cleanup: blast radius"
                                      (format "expected only (%s) got %S" id radius))
                (mindwtr-api-put-data wire)
                (let* ((after (plist-get (mindwtr-api-get-data) :appdata))
                       (t2 (mindwtr-smoke-find-by-id after id)))
                  (if (and t2 (not (plist-get t2 :deletedAt)))
                      (mindwtr-smoke-fail "cleanup (delete)" "task still live after delete")
                    (mindwtr-smoke-pass "cleanup (delete)"))
                  ;; final non-target drift check against the pre-lifecycle baseline
                  (let ((drift 0))
                    (dolist (key mindwtr-smoke--entity-keys)
                      (dolist (e (plist-get baseline key))
                        (let ((e2 (mindwtr-smoke-find-by-id after (plist-get e :id))))
                          (when (and e2 (not (string= (mindwtr-signature e)
                                                      (mindwtr-signature e2))))
                            (setq drift (1+ drift))
                            (mindwtr-smoke-info
                             (format "baseline drift id=%s" (plist-get e :id)))))))
                    (if (= drift 0)
                        (mindwtr-smoke-pass "lifecycle non-target drift: 0")
                      (mindwtr-smoke-fail
                       (format "lifecycle non-target drift: %d" drift))))))))))
    (error (mindwtr-smoke-fail "cleanup (error)" (error-message-string err)))))

(defun mindwtr-smoke-phase-write-lifecycle ()
  "Drive a throwaway task through inbox -> next -> done -> delete, self-cleaning."
  (let* ((baseline (plist-get (mindwtr-api-get-data) :appdata))
         (run-id (format-time-string "%Y%m%dT%H%M%S"))
         (id (mindwtr-util-uuid))
         (base-title (format "[mw-smoke] lifecycle %s" run-id))
         (desired (list :mw-kind 'task :id id :status "inbox" :title base-title
                        :contexts '("@computer") :tags '("#smoke")
                        :priority "high" :energyLevel "low" :dueDate "2026-06-15"
                        :checklist (list (list :title "step one" :isCompleted :false)
                                         (list :title "step two" :isCompleted :false)))))
    (unwind-protect
        (catch 'abort
          ;; CREATE in inbox
          (unless (mindwtr-smoke--step
                   "create (inbox)" id
                   (lambda () (goto-char (point-max))
                     (insert (mindwtr-render-heading desired 1 nil)))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "create (inbox)" tgt desired
                                                   "inbox" 1)))
            (throw 'abort nil))
          ;; MUTATE: edit title + complete the first checklist item
          (setq desired (plist-put (copy-sequence desired)
                                   :title (concat base-title " (edited)")))
          (setq desired (plist-put desired :checklist
                                   (list (list :title "step one" :isCompleted t)
                                         (list :title "step two" :isCompleted :false))))
          (unless (mindwtr-smoke--step
                   "mutate (title+checklist)" id
                   (lambda () (mindwtr-smoke--replace-heading id desired))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "mutate (title+checklist)" tgt
                                                   desired "inbox" 2)))
            (throw 'abort nil))
          ;; TRANSITION -> next
          (setq desired (plist-put (copy-sequence desired) :status "next"))
          (unless (mindwtr-smoke--step
                   "transition next" id
                   (lambda () (mindwtr-smoke--replace-heading id desired))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "transition next" tgt
                                                   desired "next" 3)))
            (throw 'abort nil))
          ;; TRANSITION -> done (with completedAt)
          (setq desired (plist-put (copy-sequence desired) :status "done"))
          (setq desired (plist-put desired :completedAt (mindwtr-smoke--now)))
          (mindwtr-smoke--step
           "transition done" id
           (lambda () (mindwtr-smoke--replace-heading id desired))
           (lambda (_after tgt)
             (when (mindwtr-smoke--assert-target "transition done" tgt desired "done" 4)
               (unless (plist-get tgt :completedAt)
                 (mindwtr-smoke-fail "transition done: completedAt"
                                     "completedAt not set"))))))
      ;; CLEANUP always runs
      (mindwtr-smoke--cleanup id baseline))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke -L test -l test/mindwtr-smoke-test.el -f ert-run-tests-batch-and-exit`
Expected: PASS (10 smoke tests). If a `rev` assertion fails, confirm the mock applies PUTs as full-replace (each update bumps rev by exactly 1).

- [ ] **Step 5: Run the full offline suite**

Run: `find . -name '*.elc' -delete && make test`
Expected: all tests pass (the prior 79 plus the new smoke tests).

- [ ] **Step 6: Commit**

```bash
git add smoke/mindwtr-smoke.el test/mindwtr-smoke-test.el
git commit -m "feat: smoke suite self-cleaning GTD write lifecycle

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Entrypoint + Makefile targets

**Files:**
- Create: `smoke/run.el`
- Modify: `Makefile` (add `smoke` and `smoke-write` targets)

- [ ] **Step 1: Create the entrypoint**

Create `smoke/run.el`:

```elisp
;;; run.el --- Mindwtr live smoke suite entrypoint -*- lexical-binding: t; -*-
;;; Commentary:
;; Loaded via the Makefile:  make smoke  /  make smoke-write
;; Read-only phases always run; the write lifecycle runs when the
;; MINDWTR_SMOKE_WRITE environment variable is set (the smoke-write target).
;;; Code:

(require 'mindwtr-smoke)

(mindwtr-smoke-reset)
(mindwtr-smoke-configure)
(message "== Mindwtr live smoke suite ==")
(message "Server: %s" mindwtr-api-base-url)

(when (mindwtr-smoke-phase-connectivity)
  (let ((ad (mindwtr-smoke-phase-snapshot)))
    (when ad
      (mindwtr-smoke-phase-schema-coverage ad)
      (mindwtr-smoke-phase-roundtrip ad))
    (when (getenv "MINDWTR_SMOKE_WRITE")
      (mindwtr-smoke-phase-write-lifecycle))))

(kill-emacs (mindwtr-smoke-summary))
;;; run.el ends here
```

- [ ] **Step 2: Add the Makefile targets**

Append to `Makefile`:

```makefile
.PHONY: smoke
smoke:
	$(EMACS) -Q --batch -L . -L smoke -l smoke/run.el

.PHONY: smoke-write
smoke-write:
	MINDWTR_SMOKE_WRITE=1 $(EMACS) -Q --batch -L . -L smoke -l smoke/run.el
```

- [ ] **Step 3: Verify the entrypoint loads cleanly (no server needed)**

Run: `find . -name '*.elc' -delete && emacs -Q --batch -L . -L smoke --eval '(require (quote mindwtr-smoke))' --eval '(message "loaded ok")'`
Expected: prints `loaded ok` with no errors (this loads the library without running the suite, so no server/token is needed).

- [ ] **Step 4: Verify the read-only suite runs against the real server**

Tell the user to run (token stays in their shell; never echo the real token):

```
make smoke MINDWTR_URL=https://mw.example MINDWTR_TOKEN=<your_token>
```

Expected: `[PASS] connectivity (HEAD)`, `[PASS] snapshot (GET)`, `[PASS] validate-appdata`, schema coverage line(s), `[PASS] round-trip signature (N entities clean)`, then `Summary: ... 0 fail` and exit 0. (If schema coverage WARNs about an unknown key, that is informational and still exit 0.)

- [ ] **Step 5: Commit**

```bash
git add smoke/run.el Makefile
git commit -m "feat: smoke suite entrypoint and make targets

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Retire the throwaway harnesses

**Files:**
- Delete: `smoke-test.el`, `smoke-diag.el`, `smoke-probe.el`, `smoke-write.el` (untracked files at repo root)

- [ ] **Step 1: Confirm they are untracked, then remove**

Run: `git status --porcelain smoke-test.el smoke-diag.el smoke-probe.el smoke-write.el`
Expected: each shows `??` (untracked). Then:

Run: `rm -f smoke-test.el smoke-diag.el smoke-probe.el smoke-write.el`

- [ ] **Step 2: Verify nothing references the old files**

Run: `grep -rn "smoke-test\|smoke-diag\|smoke-probe\|smoke-write" --include='*.el' --include='Makefile' --include='*.md' . ; echo "exit: $?"`
Expected: no matches in code/Makefile (matches only inside `docs/superpowers/` prose are fine). If `grep` prints nothing it exits 1 — that is the desired "no references" outcome.

- [ ] **Step 3: Full verification**

Run: `find . -name '*.elc' -delete && make test && make compile`
Expected: all tests pass; compile is warning-clean (the root `mindwtr*.el` files; `smoke/` is loaded interpreted and is exercised by `make test`).

- [ ] **Step 4: Confirm the working tree is clean**

Run: `git status --porcelain`
Expected: empty (the four deleted files were untracked, so their removal needs no commit; all new/modified tracked files were committed in Tasks 1-9).

---

## Self-Review

**Spec coverage:**
- Layout & invocation (`smoke/` dir, `make smoke`/`make smoke-write`) → Tasks 3, 9.
- Config (env + auth-source fallback) → Task 3 (`mindwtr-smoke-configure`).
- Reporting + exit codes → Task 3.
- Pure helpers (keys, find, index, plist-same-p) → Task 4.
- Diagnostics (canonical-field-diff, key-diff) → Task 5.
- Known-fields registry (model addition) → Task 1.
- JSON array-fields expansion (model adjustment) → Task 2.
- Schema-coverage phase (UNKNOWN WARN, MISSING→info, settings excluded) → Task 6.
- Read-only phases (connectivity, snapshot+validate, round-trip with auto-diag) → Task 7.
- Write lifecycle (create→mutate→next→done→delete, blast-radius gate, unwind-protect cleanup, baseline drift check) → Task 8.
- Self-test against mock transport → Tasks 7, 8.
- Migration (delete four harnesses) → Task 10.

All spec requirements map to a task.

**Placeholder scan:** No TBD/TODO/"handle errors"/"similar to" — every code step contains complete code; every run step has an exact command and expected output.

**Type consistency:** Function names are consistent across tasks (`mindwtr-smoke-plist-keys`, `mindwtr-smoke-find-by-id`, `mindwtr-smoke-index-by-id`, `mindwtr-smoke-plist-same-p`, `mindwtr-smoke-blast-radius`, `mindwtr-smoke-canonical-field-diff`, `mindwtr-smoke-key-diff`, `mindwtr-smoke-schema-coverage`, `mindwtr-smoke--render-appdata`, `mindwtr-smoke--build-wire`, `mindwtr-smoke--step`, `mindwtr-smoke--assert-target`, `mindwtr-smoke--cleanup`). Phase signatures: `mindwtr-smoke-phase-connectivity` (no args), `mindwtr-smoke-phase-snapshot` (no args, returns appdata), `mindwtr-smoke-phase-schema-coverage`/`mindwtr-smoke-phase-roundtrip` (take appdata), `mindwtr-smoke-phase-write-lifecycle` (no args) — all consistent with the Task 9 entrypoint calls. Reused existing functions verified against source: `mindwtr-sync-build-candidate (local shadow device-id now)`, `mindwtr-sync--strip-internal-keys`, `mindwtr-reconcile-buffer`, `mindwtr-reconcile--id-markers`, `mindwtr-render-heading (entity level shadow)`, `mindwtr-parse-buffer`, `mindwtr-signature--canonical-plist`, `mindwtr-model-validate-appdata`, `mindwtr-api-{head-etag,get-data,put-data}`, `mindwtr--resolve-token`.
