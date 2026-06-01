# Mindwtr ⇄ Org-mode Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an Emacs package that bidirectionally syncs a single org-mode GTD file with a self-hosted Mindwtr Cloud server via `GET/PUT /v1/data`, letting the server own conflict resolution.

**Architecture:** The org file is the human-editable projection of Mindwtr's `AppData`; a local *shadow* JSON holds sync metadata and opaque fields keyed by `id`. Each sync parses org, reconstructs full entities as `parse(heading) ⊕ shadow[id]`, bumps `rev` only on genuinely-changed entities, `PUT`s the candidate (server merges), re-`GET`s the authoritative merged snapshot, and reconciles it back into the buffer while preserving org-only content.

**Tech Stack:** Emacs Lisp (Emacs 28+), `ert` for tests, built-in `json-parse-string`/`json-serialize`, `iso8601`/`format-time-string` for dates, `auth-source` for the token, `plz.el` (with `url.el` fallback) for HTTP. Reference spec: `docs/superpowers/specs/2026-06-01-mindwtr-org-sync-design.md`.

**Key representation decision (deviation from spec's `cl-defstruct`):** entities are **plists keyed by Mindwtr JSON field names as keywords** (`:id`, `:title`, `:status`, `:updatedAt`, `:projectId`, …). With ~30 mostly-optional fields per task, plists round-trip JSON trivially (`json-parse-string :object-type 'plist`) and avoid struct boilerplate. `mindwtr-model.el` supplies the field registries, enums, and validation that the structs would otherwise enforce. An `appdata` is the plist `(:tasks (..) :projects (..) :sections (..) :areas (..) :settings (..))`.

**JSON conventions used everywhere:**
- Parse: `(json-parse-string s :object-type 'plist :array-type 'list :null-object nil :false-object :false)`
- Serialize: `(json-serialize obj :null-object nil :false-object :false)`
- Booleans: Emacs `t` ↔ JSON `true`; `:false` ↔ JSON `false`; `nil`/absent ↔ omitted/null.

---

## File Structure

| File | Responsibility |
|---|---|
| `mindwtr-util.el` | UUID, ISO↔org-timestamp conversion, device-id, JSON read/write, atomic file write. |
| `mindwtr-model.el` | Enums, status↔keyword & priority↔cookie maps, field registries (editable / shadow-only / display-mirror), `mindwtr-validate-appdata`. |
| `mindwtr-signature.el` | Deterministic content signature over editable fields. |
| `mindwtr-parse.el` | org buffer → appdata of *content* (no shadow merge yet). |
| `mindwtr-render.el` | appdata → canonical org text. |
| `mindwtr-shadow.el` | Shadow + ETag + device-id persistence; atomic writes; last-good backup. |
| `mindwtr-api.el` | Request construction + injectable transport for `GET`/`HEAD`/`PUT /v1/data`; error classification. |
| `mindwtr-sync.el` | Change detection, candidate build, full cycle orchestration, concurrency guard, backoff. |
| `mindwtr-reconcile.el` | Apply merged appdata into the buffer by `id`, preserving org-only drawers/point. |
| `mindwtr-report.el` | `*Mindwtr Sync Report*` buffer; conflict diffs; restore action. |
| `mindwtr.el` | Entry point: defcustoms, auth-source token, `mindwtr-mode`, commands, trigger wiring. |
| `test/*-test.el` | One test file per module. |
| `Makefile` | `make test`. |

Load/dependency order: `util → model → signature → parse → render → shadow → api → sync → reconcile → report → mindwtr`.

---

## Task 1: Project scaffold and test harness

**Files:**
- Create: `Makefile`
- Create: `mindwtr-util.el`
- Create: `test/mindwtr-util-test.el`

- [ ] **Step 1: Create the Makefile**

```makefile
EMACS ?= emacs

TESTS := $(wildcard test/*-test.el)

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile mindwtr*.el
```

- [ ] **Step 2: Write a failing smoke test**

`test/mindwtr-util-test.el`:

```elisp
;;; mindwtr-util-test.el --- Tests for mindwtr-util -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-util)

(ert-deftest mindwtr-util-loads ()
  "The util library provides its feature."
  (should (featurep 'mindwtr-util)))
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-util`.

- [ ] **Step 4: Create the minimal library**

`mindwtr-util.el`:

```elisp
;;; mindwtr-util.el --- Utilities for mindwtr sync -*- lexical-binding: t; -*-
;; Author: Srijan
;; Package-Requires: ((emacs "28.1"))
;;; Commentary:
;; Low-level helpers: identifiers, timestamps, JSON, atomic writes.
;;; Code:

(provide 'mindwtr-util)
;;; mindwtr-util.el ends here
```

- [ ] **Step 5: Run to verify it passes**

Run: `make test`
Expected: PASS — 1 test.

- [ ] **Step 6: Commit**

```bash
git add Makefile mindwtr-util.el test/mindwtr-util-test.el
git commit -m "chore: scaffold mindwtr package and ert harness"
```

---

## Task 2: Utilities — UUID, timestamps, JSON, atomic write

**Files:**
- Modify: `mindwtr-util.el`
- Modify: `test/mindwtr-util-test.el`

- [ ] **Step 1: Write failing tests**

Append to `test/mindwtr-util-test.el`:

```elisp
(ert-deftest mindwtr-util-uuid-format ()
  (let ((id (mindwtr-util-uuid)))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
             id))
    (should-not (string= id (mindwtr-util-uuid)))))

(ert-deftest mindwtr-util-iso-to-org-and-back ()
  (let ((iso "2026-01-01T10:00:00.000Z"))
    ;; ISO -> org inactive timestamp (rendered in local tz; round-trip via parse)
    (let* ((org (mindwtr-util-iso->org iso))
           (back (mindwtr-util-org->iso org)))
      (should (string-prefix-p "[" org))
      (should (string-suffix-p "]" org))
      ;; Round-trips to the same instant (to the second).
      (should (string= (mindwtr-util-iso-normalize back)
                       (mindwtr-util-iso-normalize iso))))))

(ert-deftest mindwtr-util-iso-normalize-truncates-millis ()
  (should (string= (mindwtr-util-iso-normalize "2026-01-01T10:00:00.500Z")
                   "2026-01-01T10:00:00Z")))

(ert-deftest mindwtr-util-json-roundtrip-plist ()
  (let* ((obj '(:id "x" :n 3 :flag t :off :false :tags ("a" "b")))
         (s (mindwtr-util-json-encode obj))
         (back (mindwtr-util-json-decode s)))
    (should (string= (plist-get back :id) "x"))
    (should (= (plist-get back :n) 3))
    (should (eq (plist-get back :flag) t))
    (should (eq (plist-get back :off) :false))
    (should (equal (plist-get back :tags) '("a" "b")))))

(ert-deftest mindwtr-util-atomic-write-and-read ()
  (let ((f (make-temp-file "mw-atomic")))
    (unwind-protect
        (progn
          (mindwtr-util-atomic-write f "hello")
          (should (string= (mindwtr-util-read-file f) "hello")))
      (delete-file f))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `mindwtr-util-uuid` undefined.

- [ ] **Step 3: Implement the helpers**

Insert before `(provide 'mindwtr-util)` in `mindwtr-util.el`:

```elisp
(require 'iso8601)

(defun mindwtr-util-uuid ()
  "Return a random RFC-4122 v4 UUID string."
  (let ((b (make-string 16 0)))
    (dotimes (i 16) (aset b i (random 256)))
    (aset b 6 (logior #x40 (logand (aref b 6) #x0f)))
    (aset b 8 (logior #x80 (logand (aref b 8) #x3f)))
    (let ((h (mapconcat (lambda (c) (format "%02x" c)) b "")))
      (format "%s-%s-%s-%s-%s"
              (substring h 0 8) (substring h 8 12) (substring h 12 16)
              (substring h 16 20) (substring h 20 32)))))

(defun mindwtr-util-iso-normalize (iso)
  "Normalize ISO-8601 string ISO to whole-second UTC `...Z' form."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (encode-time (iso8601-parse iso)) t))

(defun mindwtr-util-iso->org (iso)
  "Render ISO-8601 string ISO as an org inactive timestamp in local time."
  (format-time-string "[%Y-%m-%d %a %H:%M]" (encode-time (iso8601-parse iso))))

(defun mindwtr-util-org->iso (org-ts)
  "Parse org inactive/active timestamp ORG-TS to whole-second UTC ISO string."
  (let* ((clean (string-trim org-ts "[\\[<]" "[]>]"))
         (decoded (org-parse-time-string clean)))
    (format-time-string "%Y-%m-%dT%H:%M:%SZ" (encode-time decoded) t)))

(defun mindwtr-util-json-encode (obj)
  "Encode plist/list OBJ to a JSON string."
  (json-serialize obj :null-object nil :false-object :false))

(defun mindwtr-util-json-decode (s)
  "Decode JSON string S to a plist (arrays as lists)."
  (json-parse-string s :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun mindwtr-util-read-file (path)
  "Return the contents of PATH as a string, or nil if missing."
  (when (file-exists-p path)
    (with-temp-buffer
      (set-buffer-multibyte t)
      (insert-file-contents path)
      (buffer-string))))

(defun mindwtr-util-atomic-write (path content)
  "Write string CONTENT to PATH atomically (temp file + rename)."
  (let ((tmp (make-temp-file (concat (file-name-directory path) ".mw-tmp"))))
    (with-temp-file tmp
      (set-buffer-multibyte t)
      (insert content))
    (rename-file tmp path t)))
```

Add `(require 'org)` at the top of the file (needed for `org-parse-time-string`).

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS — all util tests.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-util.el test/mindwtr-util-test.el
git commit -m "feat(util): uuid, iso<->org timestamps, json, atomic write"
```

---

## Task 3: Model — enums, maps, field registries, validation

**Files:**
- Create: `mindwtr-model.el`
- Create: `test/mindwtr-model-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-model-test.el`:

```elisp
;;; mindwtr-model-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-model)

(ert-deftest mindwtr-model-task-status-keyword-roundtrip ()
  (dolist (pair '(("inbox" . "INBOX") ("next" . "NEXT") ("waiting" . "WAIT")
                  ("someday" . "SOMEDAY") ("reference" . "REF")
                  ("done" . "DONE") ("archived" . "ARCH")))
    (should (string= (mindwtr-model-status->keyword 'task (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-keyword->status 'task (cdr pair)) (car pair)))))

(ert-deftest mindwtr-model-project-status-keyword-roundtrip ()
  (dolist (pair '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
                  ("waiting" . "WAIT") ("archived" . "ARCH")))
    (should (string= (mindwtr-model-status->keyword 'project (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-keyword->status 'project (cdr pair)) (car pair)))))

(ert-deftest mindwtr-model-priority-cookie-roundtrip ()
  (dolist (pair '(("urgent" . ?A) ("high" . ?B) ("medium" . ?C) ("low" . ?D)))
    (should (eq (mindwtr-model-priority->cookie (car pair)) (cdr pair)))
    (should (string= (mindwtr-model-cookie->priority (cdr pair)) (car pair))))
  (should (null (mindwtr-model-priority->cookie nil))))

(ert-deftest mindwtr-model-shadow-only-field-p ()
  (should (mindwtr-model-shadow-only-field-p :rev))
  (should (mindwtr-model-shadow-only-field-p :color))
  (should-not (mindwtr-model-shadow-only-field-p :title)))

(ert-deftest mindwtr-model-validate-appdata-accepts-minimal ()
  (should (mindwtr-model-validate-appdata
           '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-appdata-rejects-task-without-id ()
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks ((:title "x" :status "next")) :projects nil
      :sections nil :areas nil :settings nil))))

(ert-deftest mindwtr-model-validate-appdata-rejects-bad-status ()
  (should-error
   (mindwtr-model-validate-appdata
    '(:tasks ((:id "1" :title "x" :status "bogus")) :projects nil
      :sections nil :areas nil :settings nil))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-model`.

- [ ] **Step 3: Implement the model**

`mindwtr-model.el`:

```elisp
;;; mindwtr-model.el --- Mindwtr data model & validation -*- lexical-binding: t; -*-
;;; Commentary:
;; Enums, status/priority maps, field registries, and appdata validation.
;;; Code:

(require 'mindwtr-util)

(defconst mindwtr-model-task-statuses
  '("inbox" "next" "waiting" "someday" "reference" "done" "archived"))

(defconst mindwtr-model-project-statuses
  '("active" "someday" "waiting" "archived"))

(defconst mindwtr-model--task-status-keywords
  '(("inbox" . "INBOX") ("next" . "NEXT") ("waiting" . "WAIT")
    ("someday" . "SOMEDAY") ("reference" . "REF")
    ("done" . "DONE") ("archived" . "ARCH")))

(defconst mindwtr-model--project-status-keywords
  '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
    ("waiting" . "WAIT") ("archived" . "ARCH")))

(defconst mindwtr-model-done-keywords '("DONE" "ARCH")
  "TODO keywords that count as org `done' states.")

(defun mindwtr-model--status-alist (kind)
  (pcase kind
    ('task mindwtr-model--task-status-keywords)
    ('project mindwtr-model--project-status-keywords)
    (_ (error "Unknown entity kind: %s" kind))))

(defun mindwtr-model-status->keyword (kind status)
  "Map STATUS string to its org TODO keyword for entity KIND."
  (or (cdr (assoc status (mindwtr-model--status-alist kind)))
      (error "Invalid %s status: %s" kind status)))

(defun mindwtr-model-keyword->status (kind keyword)
  "Map org TODO KEYWORD back to a STATUS string for entity KIND."
  (or (car (rassoc keyword (mindwtr-model--status-alist kind)))
      (error "Invalid %s keyword: %s" kind keyword)))

(defconst mindwtr-model--priority-cookies
  '(("urgent" . ?A) ("high" . ?B) ("medium" . ?C) ("low" . ?D)))

(defun mindwtr-model-priority->cookie (priority)
  "Map PRIORITY string to its org priority character, or nil."
  (when priority
    (or (cdr (assoc priority mindwtr-model--priority-cookies))
        (error "Invalid priority: %s" priority))))

(defun mindwtr-model-cookie->priority (cookie)
  "Map org priority character COOKIE to a PRIORITY string, or nil."
  (when cookie (car (rassoc cookie mindwtr-model--priority-cookies))))

(defconst mindwtr-model-shadow-only-fields
  '(:rev :revBy :deletedAt :color :icon :textDirection
    :order :orderNum :pushCount :showFutureRecurrence :completedOccurrences
    :purgedAt)
  "Fields stored only in the shadow, never written to org.")

(defconst mindwtr-model-display-mirror-fields '(:createdAt :updatedAt)
  "Fields rendered read-only into org; authoritative in the shadow.")

(defconst mindwtr-model-device-local-fields
  '(:lastSyncStats :lastSyncHistory :localStatus
    :pendingRemoteWriteAt :pendingRemoteWriteRetryAt :pendingRemoteWriteAttempts)
  "Fields that must be stripped before sending to the server.")

(defun mindwtr-model-shadow-only-field-p (field)
  "Non-nil if FIELD (a keyword) is shadow-only."
  (and (memq field mindwtr-model-shadow-only-fields) t))

(defun mindwtr-model-validate-appdata (appdata)
  "Signal an error if APPDATA is structurally invalid; else return t."
  (dolist (key '(:tasks :projects :sections :areas))
    (unless (listp (plist-get appdata key))
      (error "appdata %s must be a list" key)))
  (dolist (task (plist-get appdata :tasks))
    (unless (and (plist-get task :id) (stringp (plist-get task :id)))
      (error "task missing string id: %S" task))
    (let ((st (plist-get task :status)))
      (unless (member st mindwtr-model-task-statuses)
        (error "task %s has invalid status %S" (plist-get task :id) st))))
  (dolist (proj (plist-get appdata :projects))
    (unless (plist-get proj :id) (error "project missing id: %S" proj))
    (let ((st (plist-get proj :status)))
      (when (and st (not (member st mindwtr-model-project-statuses)))
        (error "project %s has invalid status %S" (plist-get proj :id) st))))
  (dolist (sec (plist-get appdata :sections))
    (unless (plist-get sec :id) (error "section missing id: %S" sec))
    (unless (plist-get sec :projectId)
      (error "section %s missing projectId" (plist-get sec :id))))
  (dolist (area (plist-get appdata :areas))
    (unless (plist-get area :id) (error "area missing id: %S" area)))
  t)

(provide 'mindwtr-model)
;;; mindwtr-model.el ends here
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-model.el test/mindwtr-model-test.el
git commit -m "feat(model): enums, status/priority maps, field registries, validation"
```

---

## Task 4: Signature — deterministic content hash over editable fields

**Files:**
- Create: `mindwtr-signature.el`
- Create: `test/mindwtr-signature-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-signature-test.el`:

```elisp
;;; mindwtr-signature-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-signature)

(ert-deftest mindwtr-signature-ignores-shadow-and-mirror-fields ()
  (let ((a '(:id "1" :title "x" :status "next" :rev 5 :updatedAt "A" :color "#fff"))
        (b '(:id "1" :title "x" :status "next" :rev 9 :updatedAt "B" :color "#000")))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-detects-editable-change ()
  (let ((a '(:id "1" :title "x" :status "next"))
        (b '(:id "1" :title "x" :status "done")))
    (should-not (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-order-insensitive-for-plist ()
  (let ((a '(:id "1" :title "x" :status "next"))
        (b '(:status "next" :title "x" :id "1")))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-signature-order-insensitive-for-list-fields ()
  ;; tags/contexts are sets — order must not matter.
  (let ((a '(:id "1" :title "x" :status "next" :tags ("a" "b")))
        (b '(:id "1" :title "x" :status "next" :tags ("b" "a"))))
    (should (string= (mindwtr-signature a) (mindwtr-signature b)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-signature`.

- [ ] **Step 3: Implement**

`mindwtr-signature.el`:

```elisp
;;; mindwtr-signature.el --- Content signatures -*- lexical-binding: t; -*-
;;; Commentary:
;; A stable hash over only the editable fields of an entity, used for
;; change detection.  Excludes shadow-only and display-mirror fields.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-signature--set-fields '(:tags :contexts)
  "Fields whose list value is a set (order-insensitive).")

(defun mindwtr-signature--canonical (entity)
  "Return a canonical alist of ENTITY's editable fields, sorted by key."
  (let (pairs (i 0))
    (while (< i (length entity))
      (let ((k (nth i entity)) (v (nth (1+ i) entity)))
        (unless (or (mindwtr-model-shadow-only-field-p k)
                    (memq k mindwtr-model-display-mirror-fields))
          (when (and (memq k mindwtr-signature--set-fields) (listp v))
            (setq v (sort (copy-sequence v) #'string<)))
          (push (cons k v) pairs)))
      (setq i (+ i 2)))
    (sort pairs (lambda (a b)
                  (string< (symbol-name (car a)) (symbol-name (car b)))))))

(defun mindwtr-signature (entity)
  "Return a stable SHA-256 signature string for ENTITY's editable content."
  (secure-hash 'sha256 (mindwtr-util-json-encode
                        (mindwtr-signature--canonical entity))))

(provide 'mindwtr-signature)
;;; mindwtr-signature.el ends here
```

Note: `json-serialize` accepts an alist of `(keyword . value)` as an object; `mindwtr-util-json-encode` wraps it. If `json-serialize` rejects the alist form during execution, convert pairs back to a flat plist before encoding.

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-signature.el test/mindwtr-signature-test.el
git commit -m "feat(signature): stable content hash over editable fields"
```

---

## Task 5: Parse a single heading → entity content plist

**Files:**
- Create: `mindwtr-parse.el`
- Create: `test/mindwtr-parse-test.el`

This task parses ONE heading (point inside it) into a content plist. Containment comes in Task 6.

- [ ] **Step 1: Write failing tests**

`test/mindwtr-parse-test.el`:

```elisp
;;; mindwtr-parse-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'mindwtr-parse)

(defmacro mindwtr-parse-test--with (text &rest body)
  "Insert TEXT in an org buffer, move to first heading, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       (org-next-visible-heading 1)
       ,@body)))

(ert-deftest mindwtr-parse-task-basic ()
  (mindwtr-parse-test--with
      "* WORKAREA
:PROPERTIES:
:MW_TYPE: area
:MW_ID: area-1
:END:
** NEXT [#B] Buy milk :@errands:focused:
SCHEDULED: <2026-02-09 Mon>
DEADLINE: <2026-02-15 Sun>
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:MW_ENERGY: medium
:END:
Some notes.
- [ ] sub a
- [X] sub b
"
    (org-next-visible-heading 1) ; move to the task
    (let ((e (mindwtr-parse-heading)))
      (should (string= (plist-get e :id) "t1"))
      (should (eq (plist-get e :mw-kind) 'task))
      (should (string= (plist-get e :title) "Buy milk"))
      (should (string= (plist-get e :status) "next"))
      (should (string= (plist-get e :priority) "high"))
      (should (equal (plist-get e :contexts) '("@errands")))
      (should (equal (plist-get e :tags) '("#focused")))
      (should (string= (plist-get e :energyLevel) "medium"))
      (should (string-match-p "2026-02-09" (plist-get e :startTime)))
      (should (string-match-p "2026-02-15" (plist-get e :dueDate)))
      (should (string= (plist-get e :description) "Some notes."))
      (should (equal (plist-get e :checklist)
                     '((:title "sub a" :done :false)
                       (:title "sub b" :done t)))))))

(ert-deftest mindwtr-parse-area-has-no-keyword ()
  (mindwtr-parse-test--with
      "* My Area
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
"
    (let ((e (mindwtr-parse-heading)))
      (should (eq (plist-get e :mw-kind) 'area))
      (should (string= (plist-get e :name) "My Area"))
      (should (null (plist-get e :status))))))

(ert-deftest mindwtr-parse-preserves-unknown-properties ()
  (mindwtr-parse-test--with
      "* NEXT Task :@x:
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t9
:CUSTOM_KEY: keepme
:END:
"
    (let ((e (mindwtr-parse-heading)))
      (should (string= (plist-get (plist-get e :mw-extra-props) "CUSTOM_KEY")
                       "keepme")))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-parse`.

- [ ] **Step 3: Implement single-heading parse**

`mindwtr-parse.el`:

```elisp
;;; mindwtr-parse.el --- org buffer -> appdata content -*- lexical-binding: t; -*-
;;; Commentary:
;; Parse org headings into Mindwtr entity content plists.  Sync metadata
;; and shadow-only fields are NOT produced here; they are merged from the
;; shadow later.  Each parsed entity carries internal keys:
;;   :mw-kind  -> one of area|project|section|task
;;   :mw-extra-props -> plist of unknown PROPERTIES keys to preserve
;;; Code:

(require 'org)
(require 'org-element)
(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-parse--known-props
  '("MW_TYPE" "MW_ID" "MW_ENERGY" "MW_TIME_ESTIMATE" "MW_RECURRENCE"
    "MW_ASSIGNED_TO" "MW_FOCUS_TODAY" "MW_REVIEW_AT" "MW_LOCATION"
    "MW_TASK_MODE" "MW_SEQUENTIAL" "MW_FOCUSED" "MW_AREA_ID" "MW_ATTACH"
    "MW_CREATED" "MW_UPDATED" "MW_TAGS" "MW_CONTEXTS")
  "PROPERTIES keys the parser interprets; all others are preserved verbatim.")

(defun mindwtr-parse--prop (key)
  "Return raw value of property KEY at point, or nil."
  (org-entry-get (point) key))

(defun mindwtr-parse--split-tags (tags)
  "Split org TAGS list into (contexts . hashtags) per the @-convention."
  (let (contexts hashtags)
    (dolist (tg tags)
      (if (string-prefix-p "@" tg)
          (push tg contexts)
        (push (concat "#" tg) hashtags)))
    (cons (nreverse contexts) (nreverse hashtags))))

(defun mindwtr-parse--planning (which)
  "Return ISO string for planning keyword WHICH (`scheduled'|`deadline'|`closed')."
  (let ((ts (cdr (assq which (org-entry-properties (point) 'special)))))
    (ignore ts)
    nil))

(defun mindwtr-parse--planning-iso (regexp)
  "Return ISO timestamp for a planning line matching REGEXP in this entry."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (when (re-search-forward regexp end t)
        (mindwtr-util-org->iso (match-string 1))))))

(defun mindwtr-parse--body ()
  "Return (description . checklist) for the entry at point.
Description is the prose body minus planning, drawers, and checklist items."
  (save-excursion
    (org-back-to-heading t)
    (let* ((el (org-element-at-point))
           (cbeg (org-element-property :contents-begin el))
           (end (save-excursion (outline-next-heading) (point)))
           (lines (when cbeg
                    (split-string (buffer-substring-no-properties cbeg end) "\n")))
           prose checklist (in-drawer nil))
      (dolist (ln lines)
        (cond
         ((string-match-p "^[ \t]*:[A-Za-z0-9_]+:[ \t]*$" ln) (setq in-drawer t))
         ((string-match-p "^[ \t]*:END:[ \t]*$" ln) (setq in-drawer nil))
         (in-drawer nil)
         ((string-match-p "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):" ln) nil)
         ((string-match "^[ \t]*- \\[\\([ X]\\)\\] \\(.*\\)$" ln)
          (push (list :title (match-string 2 ln)
                      :done (if (string= (match-string 1 ln) "X") t :false))
                checklist))
         (t (push ln prose))))
      (cons (string-trim (mapconcat #'identity (nreverse prose) "\n"))
            (nreverse checklist)))))

(defun mindwtr-parse--extra-props ()
  "Return a plist (string key -> value) of unknown PROPERTIES at point."
  (let (extra)
    (pcase-dolist (`(,k . ,v) (org-entry-properties (point) 'standard))
      (unless (member k mindwtr-parse--known-props)
        (setq extra (plist-put extra k v))))
    extra))

(defun mindwtr-parse-heading ()
  "Parse the org heading at point into a Mindwtr entity content plist."
  (org-back-to-heading t)
  (let* ((kind (intern (or (mindwtr-parse--prop "MW_TYPE")
                           (error "Heading has no MW_TYPE: %s"
                                  (org-get-heading t t t t)))))
         (id (mindwtr-parse--prop "MW_ID"))
         (title (org-get-heading t t t t))
         (todo (org-get-todo-state))
         (tags (org-get-tags nil t))
         (split (mindwtr-parse--split-tags tags))
         (e (list :id id :mw-kind kind
                  :mw-extra-props (mindwtr-parse--extra-props))))
    (pcase kind
      ('area (setq e (plist-put e :name title)))
      ((or 'project 'section 'task) (setq e (plist-put e :title title))))
    (when (and todo (memq kind '(task project)))
      (setq e (plist-put e :status (mindwtr-model-keyword->status kind todo))))
    (when (eq kind 'task)
      (let* ((body (mindwtr-parse--body))
             (pr (nth 3 (org-heading-components))))
        (setq e (plist-put e :priority (mindwtr-model-cookie->priority pr)))
        (setq e (plist-put e :contexts (car split)))
        (setq e (plist-put e :tags (cdr split)))
        (setq e (plist-put e :description (car body)))
        (when (cdr body) (setq e (plist-put e :checklist (cdr body))))
        (let ((s (mindwtr-parse--planning-iso "SCHEDULED: *\\(<[^>]+>\\)"))
              (d (mindwtr-parse--planning-iso "DEADLINE: *\\(<[^>]+>\\)"))
              (c (mindwtr-parse--planning-iso "CLOSED: *\\(\\[[^]]+\\]\\)")))
          (when s (setq e (plist-put e :startTime s)))
          (when d (setq e (plist-put e :dueDate d)))
          (when c (setq e (plist-put e :completedAt c))))
        (dolist (p '(("MW_ENERGY" . :energyLevel) ("MW_TIME_ESTIMATE" . :timeEstimate)
                     ("MW_ASSIGNED_TO" . :assignedTo) ("MW_LOCATION" . :location)
                     ("MW_TASK_MODE" . :taskMode)))
          (let ((v (mindwtr-parse--prop (car p))))
            (when v (setq e (plist-put e (cdr p) v)))))))
    e))
```

(Tests for `:startTime`/`:dueDate` use `re-search-forward` from the heading; ensure point is on the heading when `mindwtr-parse-heading` is called — it calls `org-back-to-heading` first.)

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS. If planning regexps need tuning for your org timestamp format, adjust and re-run until green.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-parse.el test/mindwtr-parse-test.el
git commit -m "feat(parse): single heading -> entity content plist"
```

---

## Task 6: Parse the whole buffer → appdata with containment

**Files:**
- Modify: `mindwtr-parse.el`
- Modify: `test/mindwtr-parse-test.el`

- [ ] **Step 1: Write failing test**

Append to `test/mindwtr-parse-test.el`:

```elisp
(ert-deftest mindwtr-parse-buffer-containment ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work
:PROPERTIES:
:MW_TYPE: area
:MW_ID: a1
:END:
** ACTIVE Big Project
:PROPERTIES:
:MW_TYPE: project
:MW_ID: p1
:END:
*** Planning
:PROPERTIES:
:MW_TYPE: section
:MW_ID: s1
:END:
**** NEXT Do thing :@x:
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
")
      (org-mode)
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks)))
             (proj (car (plist-get ad :projects)))
             (sec  (car (plist-get ad :sections))))
        (should (= (length (plist-get ad :areas)) 1))
        (should (string= (plist-get proj :areaId) "a1"))
        (should (string= (plist-get sec :projectId) "p1"))
        (should (string= (plist-get task :projectId) "p1"))
        (should (string= (plist-get task :sectionId) "s1"))
        (should (string= (plist-get task :areaId) "a1"))
        ;; mw internal keys stripped from output entities:
        (should (null (plist-member task :mw-kind)))))))

(ert-deftest mindwtr-parse-buffer-skips-inbox-container ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox
:PROPERTIES:
:MW_TYPE: container
:END:
** INBOX capture this
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
")
      (org-mode)
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks))))
        (should (= (length (plist-get ad :tasks)) 1))
        (should (null (plist-get task :projectId)))
        (should (null (plist-get task :areaId)))))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `mindwtr-parse-buffer` undefined.

- [ ] **Step 3: Implement buffer parse with containment**

Append to `mindwtr-parse.el` before `(provide ...)`:

```elisp
(defconst mindwtr-parse--internal-keys '(:mw-kind :mw-extra-props :mw-ancestors)
  "Keys used during parsing that must be stripped from output entities.")

(defun mindwtr-parse--strip-internal (e)
  "Return E without internal :mw-* keys (but keep :mw-extra-props in metadata)."
  (let (out (i 0))
    (while (< i (length e))
      (unless (memq (nth i e) '(:mw-kind :mw-ancestors))
        (setq out (plist-put out (nth i e) (nth (1+ i) e))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-parse--ancestor-id (kind)
  "Return MW_ID of the nearest ancestor heading whose MW_TYPE is KIND, or nil."
  (save-excursion
    (let (found)
      (while (and (not found) (org-up-heading-safe))
        (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") (symbol-name kind))
          (setq found (mindwtr-parse--prop "MW_ID"))))
      found)))

(defun mindwtr-parse-buffer ()
  "Parse the current org buffer into a content appdata plist."
  (let (tasks projects sections areas)
    (org-map-entries
     (lambda ()
       (let ((kind (mindwtr-parse--prop "MW_TYPE")))
         (when (and kind (not (string= kind "container")))
           (let ((e (mindwtr-parse-heading)))
             (pcase (intern kind)
               ('area (push (mindwtr-parse--strip-internal e) areas))
               ('project
                (let ((aid (mindwtr-parse--ancestor-id 'area)))
                  (when aid (setq e (plist-put e :areaId aid))))
                (push (mindwtr-parse--strip-internal e) projects))
               ('section
                (let ((pid (mindwtr-parse--ancestor-id 'project)))
                  (when pid (setq e (plist-put e :projectId pid))))
                (push (mindwtr-parse--strip-internal e) sections))
               ('task
                (let ((pid (mindwtr-parse--ancestor-id 'project))
                      (sid (mindwtr-parse--ancestor-id 'section))
                      (aid (or (mindwtr-parse--prop "MW_AREA_ID")
                               (mindwtr-parse--ancestor-id 'area))))
                  (when pid (setq e (plist-put e :projectId pid)))
                  (when sid (setq e (plist-put e :sectionId sid)))
                  (when aid (setq e (plist-put e :areaId aid))))
                (push (mindwtr-parse--strip-internal e) tasks))))))))
    (list :tasks (nreverse tasks) :projects (nreverse projects)
          :sections (nreverse sections) :areas (nreverse areas))))
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-parse.el test/mindwtr-parse-test.el
git commit -m "feat(parse): whole-buffer parse with containment from nesting"
```

---

## Task 7: Render — appdata → canonical org text

**Files:**
- Create: `mindwtr-render.el`
- Create: `test/mindwtr-render-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-render-test.el`:

```elisp
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
    (should (string-match-p "^\\*\\*\\*\\* \\[#B\\] NEXT Buy milk" text))
    (should (string-match-p ":@errands:focused:" text))
    (should (string-match-p ":MW_TYPE: task" text))
    (should (string-match-p ":MW_ID: t1" text))
    (should (string-match-p ":MW_ENERGY: medium" text))
    (should (string-match-p ":MW_CREATED: \\[2026-01-01" text))
    (should (string-match-p "^notes$" text))))

(ert-deftest mindwtr-render-area-no-keyword ()
  (let ((text (mindwtr-render-heading
               '(:id "a1" :mw-kind area :name "Work" :mw-extra-props nil) 1 nil)))
    (should (string-match-p "^\\* Work" text))
    (should (string-match-p ":MW_TYPE: area" text))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-render`.

- [ ] **Step 3: Implement render**

`mindwtr-render.el`:

```elisp
;;; mindwtr-render.el --- appdata -> canonical org text -*- lexical-binding: t; -*-
;;; Commentary:
;; Deterministic rendering of entities to org.  The inverse of mindwtr-parse.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-render--drawer-order
  '(:energyLevel :timeEstimate :recurrence :assignedTo :focusToday
    :reviewAt :location :taskMode :sequential :focused :areaId :attach)
  "Canonical order of content properties in the drawer.")

(defconst mindwtr-render--prop-names
  '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
    (:recurrence . "MW_RECURRENCE") (:assignedTo . "MW_ASSIGNED_TO")
    (:focusToday . "MW_FOCUS_TODAY") (:reviewAt . "MW_REVIEW_AT")
    (:location . "MW_LOCATION") (:taskMode . "MW_TASK_MODE")
    (:sequential . "MW_SEQUENTIAL") (:focused . "MW_FOCUSED")
    (:areaId . "MW_AREA_ID") (:attach . "MW_ATTACH")))

(defun mindwtr-render--tags (task)
  "Render org tag string `:a:b:' for TASK contexts+tags, or empty."
  (let ((all (append (plist-get task :contexts)
                     (mapcar (lambda (s) (string-remove-prefix "#" s))
                             (plist-get task :tags)))))
    (if all (concat " :" (mapconcat #'identity all ":") ":") "")))

(defun mindwtr-render--checklist (task)
  "Render TASK checklist items as org checkboxes."
  (mapconcat (lambda (it)
               (format "- [%s] %s"
                       (if (eq (plist-get it :done) t) "X" " ")
                       (plist-get it :title)))
             (plist-get task :checklist) "\n"))

(defun mindwtr-render-heading (entity level shadow)
  "Render ENTITY at outline LEVEL (1-based), using SHADOW for mirror fields.
Returns a string ending with a newline."
  (let* ((kind (plist-get entity :mw-kind))
         (stars (make-string level ?*))
         (todo (when (memq kind '(task project))
                 (let ((st (plist-get entity :status)))
                   (when st (concat (mindwtr-model-status->keyword kind st) " ")))))
         (cookie (when (eq kind 'task)
                   (let ((c (mindwtr-model-priority->cookie
                             (plist-get entity :priority))))
                     (when c (format "[#%c] " c)))))
         (title (or (plist-get entity :title) (plist-get entity :name)))
         (tags (if (eq kind 'task) (mindwtr-render--tags entity) ""))
         (lines (list (concat stars " " (or cookie "") (or todo "") title tags))))
    ;; planning line (tasks)
    (when (eq kind 'task)
      (let (parts)
        (when (plist-get entity :startTime)
          (push (format "SCHEDULED: %s"
                        (replace-regexp-in-string
                         "\\`\\[\\|\\]\\'" (lambda (m) (if (string= m "[") "<" ">"))
                         (mindwtr-util-iso->org (plist-get entity :startTime))))
                parts))
        (when (plist-get entity :dueDate)
          (push (format "DEADLINE: %s"
                        (replace-regexp-in-string
                         "\\`\\[\\|\\]\\'" (lambda (m) (if (string= m "[") "<" ">"))
                         (mindwtr-util-iso->org (plist-get entity :dueDate))))
                parts))
        (when parts (push (mapconcat #'identity (nreverse parts) " ") lines))))
    ;; properties drawer
    (push ":PROPERTIES:" lines)
    (push (format ":MW_TYPE: %s" kind) lines)
    (push (format ":MW_ID: %s" (plist-get entity :id)) lines)
    (dolist (k mindwtr-render--drawer-order)
      (let ((v (plist-get entity k)))
        (when v
          (push (format ":%s: %s" (cdr (assq k mindwtr-render--prop-names))
                        (if (eq v t) "t" v))
                lines))))
    ;; display-mirror fields from shadow
    (when shadow
      (when (plist-get shadow :createdAt)
        (push (format ":MW_CREATED: %s"
                      (mindwtr-util-iso->org (plist-get shadow :createdAt))) lines))
      (when (plist-get shadow :updatedAt)
        (push (format ":MW_UPDATED: %s"
                      (mindwtr-util-iso->org (plist-get shadow :updatedAt))) lines)))
    ;; preserved unknown properties
    (let ((extra (plist-get entity :mw-extra-props)) (i 0))
      (while (< i (length extra))
        (push (format ":%s: %s" (nth i extra) (nth (1+ i) extra)) lines)
        (setq i (+ i 2))))
    (push ":END:" lines)
    ;; body: description then checklist (tasks)
    (when (eq kind 'task)
      (let ((desc (plist-get entity :description))
            (cl (mindwtr-render--checklist entity)))
        (when (and desc (> (length desc) 0)) (push desc lines))
        (when (> (length cl) 0) (push cl lines))))
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))

(provide 'mindwtr-render)
;;; mindwtr-render.el ends here
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-render.el test/mindwtr-render-test.el
git commit -m "feat(render): entity -> canonical org heading"
```

---

## Task 8: Round-trip property tests (parse ∘ render)

**Files:**
- Create: `test/mindwtr-roundtrip-test.el`
- Modify: `mindwtr-parse.el` / `mindwtr-render.el` as needed to make them inverse.

This is the highest-risk area (spec: "canonical-form drift"). Fix parse/render until these pass.

- [ ] **Step 1: Write the failing property test**

`test/mindwtr-roundtrip-test.el`:

```elisp
;;; mindwtr-roundtrip-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)

(defconst mindwtr-roundtrip--task
  '(:id "t1" :mw-kind task :title "Buy milk" :status "next" :priority "high"
    :contexts ("@errands") :tags ("#focused") :energyLevel "medium"
    :timeEstimate "1hr" :description "Line one.\nLine two."
    :checklist ((:title "a" :done :false) (:title "b" :done t))
    :startTime "2026-02-09T00:00:00Z"
    :mw-extra-props ("CUSTOM_KEY" "keepme")))

(ert-deftest mindwtr-roundtrip-render-parse-signature-stable ()
  "render -> parse preserves the editable content signature."
  (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading mindwtr-roundtrip--task 2 shadow)))
         (sig-before (mindwtr-signature mindwtr-roundtrip--task)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks))))
        (should (string= (mindwtr-signature task) sig-before))
        (should (string= (plist-get (plist-get task :mw-extra-props) "CUSTOM_KEY")
                         "keepme"))))))

(ert-deftest mindwtr-roundtrip-render-is-stable ()
  "render(parse(render(x))) == render(parse(render(x))) (idempotent text)."
  (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
         (t1 (mindwtr-render-heading mindwtr-roundtrip--task 2 shadow)))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n" t1)
        (org-mode))
      (let* ((task (car (plist-get (mindwtr-parse-buffer) :tasks)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence task) :mw-kind 'task) 2 shadow)))
        (should (string= t1 t2))))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL initially (signature mismatch and/or text drift) — this is the signal to align parse/render.

- [ ] **Step 3: Reconcile parse/render until inverse**

Iteratively adjust `mindwtr-parse.el` and `mindwtr-render.el` so the two property tests pass. Likely fixes:
- Ensure `:checklist` `:done` uses `t`/`:false` consistently in both directions.
- Ensure `startTime` with midnight renders to a date-only `<...>` and parses back to the same instant (normalize to `T00:00:00Z` if no time-of-day).
- Ensure `mw-extra-props` survive parse→render→parse.

Do NOT proceed until both tests are green.

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/mindwtr-roundtrip-test.el mindwtr-parse.el mindwtr-render.el
git commit -m "test(roundtrip): parse/render are inverse on editable content"
```

---

## Task 9: Shadow store — persistence, ETag, device-id

**Files:**
- Create: `mindwtr-shadow.el`
- Create: `test/mindwtr-shadow-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-shadow-test.el`:

```elisp
;;; mindwtr-shadow-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-shadow)

(defmacro mindwtr-shadow-test--with-dir (&rest body)
  `(let* ((dir (make-temp-file "mw-shadow" t))
          (mindwtr-shadow-directory dir))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest mindwtr-shadow-save-load-roundtrip ()
  (mindwtr-shadow-test--with-dir
   (let ((ad '(:tasks ((:id "t1" :title "x" :status "next" :rev 3))
               :projects nil :sections nil :areas nil :settings (:theme "dark"))))
     (mindwtr-shadow-save ad)
     (let ((loaded (mindwtr-shadow-load)))
       (should (equal (plist-get (car (plist-get loaded :tasks)) :id) "t1"))
       (should (= (plist-get (car (plist-get loaded :tasks)) :rev) 3))))))

(ert-deftest mindwtr-shadow-load-empty-when-absent ()
  (mindwtr-shadow-test--with-dir
   (let ((ad (mindwtr-shadow-load)))
     (should (null (plist-get ad :tasks))))))

(ert-deftest mindwtr-shadow-etag-roundtrip ()
  (mindwtr-shadow-test--with-dir
   (mindwtr-shadow-set-etag "abc123")
   (should (string= (mindwtr-shadow-get-etag) "abc123"))))

(ert-deftest mindwtr-shadow-device-id-stable ()
  (mindwtr-shadow-test--with-dir
   (let ((id (mindwtr-shadow-device-id)))
     (should (stringp id))
     (should (string= id (mindwtr-shadow-device-id))))))

(ert-deftest mindwtr-shadow-index-by-id ()
  (let ((ad '(:tasks ((:id "t1" :rev 1) (:id "t2" :rev 2))
              :projects nil :sections nil :areas nil)))
    (let ((idx (mindwtr-shadow-index ad :tasks)))
      (should (= (plist-get (gethash "t2" idx) :rev) 2)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-shadow`.

- [ ] **Step 3: Implement**

`mindwtr-shadow.el`:

```elisp
;;; mindwtr-shadow.el --- Local shadow + sync state -*- lexical-binding: t; -*-
;;; Commentary:
;; Persists the last-synced AppData (the shadow), the remote ETag, and a
;; stable device id.  All writes are atomic.
;;; Code:

(require 'mindwtr-util)

(defvar mindwtr-shadow-directory
  (expand-file-name "mindwtr/" user-emacs-directory)
  "Directory holding shadow.json, etag, and device-id.")

(defun mindwtr-shadow--path (name)
  (expand-file-name name mindwtr-shadow-directory))

(defun mindwtr-shadow--ensure-dir ()
  (unless (file-directory-p mindwtr-shadow-directory)
    (make-directory mindwtr-shadow-directory t)))

(defun mindwtr-shadow-load ()
  "Load and return the shadow AppData plist (empty appdata if absent)."
  (let ((s (mindwtr-util-read-file (mindwtr-shadow--path "shadow.json"))))
    (if s (mindwtr-util-json-decode s)
      '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))

(defun mindwtr-shadow-save (appdata)
  "Persist APPDATA as the shadow, keeping one last-good backup."
  (mindwtr-shadow--ensure-dir)
  (let ((path (mindwtr-shadow--path "shadow.json")))
    (when (file-exists-p path)
      (copy-file path (mindwtr-shadow--path "shadow.bak.json") t))
    (mindwtr-util-atomic-write path (mindwtr-util-json-encode appdata))))

(defun mindwtr-shadow-get-etag ()
  (mindwtr-util-read-file (mindwtr-shadow--path "etag")))

(defun mindwtr-shadow-set-etag (etag)
  (mindwtr-shadow--ensure-dir)
  (mindwtr-util-atomic-write (mindwtr-shadow--path "etag") (or etag "")))

(defun mindwtr-shadow-device-id ()
  "Return the stable device id, generating and persisting one if needed."
  (let ((path (mindwtr-shadow--path "device-id")))
    (or (mindwtr-util-read-file path)
        (let ((id (format "emacs-%s-%s" (or (system-name) "host")
                          (substring (mindwtr-util-uuid) 0 8))))
          (mindwtr-shadow--ensure-dir)
          (mindwtr-util-atomic-write path id)
          id))))

(defun mindwtr-shadow-index (appdata key)
  "Return a hash table id->entity for APPDATA's KEY list (e.g. :tasks)."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e (plist-get appdata key))
      (puthash (plist-get e :id) e h))
    h))

(provide 'mindwtr-shadow)
;;; mindwtr-shadow.el ends here
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-shadow.el test/mindwtr-shadow-test.el
git commit -m "feat(shadow): atomic shadow/etag/device-id persistence"
```

---

## Task 10: API client — request build + injectable transport

**Files:**
- Create: `mindwtr-api.el`
- Create: `test/mindwtr-api-test.el`

Transport is injected via `mindwtr-api-http-function` so tests need no network and no `plz`.

- [ ] **Step 1: Write failing tests**

`test/mindwtr-api-test.el`:

```elisp
;;; mindwtr-api-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-api)

(defmacro mindwtr-api-test--stub (response &rest body)
  "Bind the transport to return RESPONSE (a plist) and capture the request."
  (declare (indent 1))
  `(let* ((captured nil)
          (mindwtr-api-base-url "https://mw.example/")
          (mindwtr-api-token "secret")
          (mindwtr-api-http-function
           (lambda (req) (setq captured req) ,response)))
     (cl-flet ((req () captured)) ,@body)))

(ert-deftest mindwtr-api-get-data-parses-and-returns-etag ()
  (mindwtr-api-test--stub
      '(:status 200 :headers (("ETag" . "v9"))
        :body "{\"tasks\":[{\"id\":\"t1\"}],\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}")
    (let ((res (mindwtr-api-get-data)))
      (should (string= (plist-get res :etag) "v9"))
      (should (string= (plist-get (car (plist-get (plist-get res :appdata) :tasks)) :id)
                       "t1"))
      ;; request was built correctly
      (should (string= (plist-get (req) :method) "GET"))
      (should (string= (plist-get (req) :url) "https://mw.example/v1/data"))
      (should (string= (cdr (assoc "Authorization" (plist-get (req) :headers)))
                       "Bearer secret")))))

(ert-deftest mindwtr-api-head-returns-etag ()
  (mindwtr-api-test--stub
      '(:status 200 :headers (("ETag" . "v9")) :body "")
    (should (string= (mindwtr-api-head-etag) "v9"))
    (should (string= (plist-get (req) :method) "HEAD"))))

(ert-deftest mindwtr-api-put-sends-json-body ()
  (mindwtr-api-test--stub
      '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}")
    (let ((res (mindwtr-api-put-data
                '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
      (should (eq (plist-get res :ok) t))
      (should (string= (plist-get (req) :method) "PUT"))
      (should (string-match-p "\"tasks\"" (plist-get (req) :body))))))

(ert-deftest mindwtr-api-classifies-401 ()
  (mindwtr-api-test--stub
      '(:status 401 :headers nil :body "unauthorized")
    (should-error (mindwtr-api-get-data) :type 'mindwtr-api-auth-error)))

(ert-deftest mindwtr-api-classifies-429-retryable ()
  (mindwtr-api-test--stub
      '(:status 429 :headers nil :body "slow down")
    (condition-case err (mindwtr-api-get-data)
      (mindwtr-api-error (should (plist-get (cdr err) :retryable))))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-api`.

- [ ] **Step 3: Implement the API layer**

`mindwtr-api.el`:

```elisp
;;; mindwtr-api.el --- Mindwtr Cloud REST client -*- lexical-binding: t; -*-
;;; Commentary:
;; GET/HEAD/PUT /v1/data with an injectable transport.  The default
;; transport uses plz.el when available, else url.el.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)

(defvar mindwtr-api-base-url nil "Base URL of the Mindwtr Cloud server (trailing slash ok).")
(defvar mindwtr-api-token nil "Bearer token for the Mindwtr Cloud server.")

(define-error 'mindwtr-api-error "Mindwtr API error")
(define-error 'mindwtr-api-auth-error "Mindwtr API authentication failed"
  'mindwtr-api-error)

(defun mindwtr-api--default-http (req)
  "Default transport for REQ using plz if present, else url.el.
REQ is (:method :url :headers :body).  Returns (:status :headers :body)."
  (if (require 'plz nil t)
      (let (status hdrs body)
        (plz (intern (downcase (plist-get req :method))) (plist-get req :url)
          :headers (plist-get req :headers)
          :body (plist-get req :body)
          :as 'response :then 'sync
          :else (lambda (e)
                  (let ((r (plz-error-response e)))
                    (setq status (plz-response-status r)
                          hdrs (plz-response-headers r)
                          body (plz-response-body r)))))
        ;; success path
        (when (null status)
          (let ((r (plz (intern (downcase (plist-get req :method))) (plist-get req :url)
                     :headers (plist-get req :headers) :body (plist-get req :body)
                     :as 'response :then 'sync)))
            (setq status (plz-response-status r)
                  hdrs (plz-response-headers r)
                  body (plz-response-body r))))
        (list :status status :headers hdrs :body body))
    ;; url.el fallback
    (let ((url-request-method (plist-get req :method))
          (url-request-extra-headers (plist-get req :headers))
          (url-request-data (when (plist-get req :body)
                              (encode-coding-string (plist-get req :body) 'utf-8))))
      (with-current-buffer (url-retrieve-synchronously (plist-get req :url) t)
        (goto-char (point-min))
        (let* ((status (progn (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                              (string-to-number (or (match-string 1) "0"))))
               (etag (progn (goto-char (point-min))
                            (when (re-search-forward "^ETag: *\\(.*\\)$" nil t)
                              (string-trim (match-string 1)))))
               (body (progn (goto-char (point-min))
                            (when (re-search-forward "\n\n" nil t)
                              (buffer-substring-no-properties (point) (point-max))))))
          (list :status status :headers (when etag (list (cons "ETag" etag)))
                :body body))))))

(defvar mindwtr-api-http-function #'mindwtr-api--default-http
  "Function taking a request plist and returning a response plist.")

(defun mindwtr-api--url (path)
  (concat (string-trim-right mindwtr-api-base-url "/") path))

(defun mindwtr-api--headers (&optional with-content-type)
  (append (list (cons "Authorization" (concat "Bearer " mindwtr-api-token)))
          (when with-content-type '(("Content-Type" . "application/json")))))

(defun mindwtr-api--header (resp name)
  (cdr (assoc-string name (plist-get resp :headers) t)))

(defun mindwtr-api--check (resp)
  "Signal a classified error if RESP is not 2xx; else return RESP."
  (let ((status (plist-get resp :status)))
    (cond
     ((and (>= status 200) (< status 300)) resp)
     ((= status 401) (signal 'mindwtr-api-auth-error (list :status 401)))
     ((or (= status 429) (>= status 500))
      (signal 'mindwtr-api-error (list :status status :retryable t)))
     (t (signal 'mindwtr-api-error (list :status status :retryable nil
                                         :body (plist-get resp :body)))))))

(defun mindwtr-api-get-data ()
  "GET /v1/data.  Return (:appdata PLIST :etag STRING)."
  (let* ((resp (mindwtr-api--check
                (funcall mindwtr-api-http-function
                         (list :method "GET" :url (mindwtr-api--url "/v1/data")
                               :headers (mindwtr-api--headers)))))
         (body (plist-get resp :body)))
    (list :appdata (mindwtr-util-json-decode body)
          :etag (mindwtr-api--header resp "ETag"))))

(defun mindwtr-api-head-etag ()
  "HEAD /v1/data.  Return the ETag string (or nil)."
  (let ((resp (mindwtr-api--check
               (funcall mindwtr-api-http-function
                        (list :method "HEAD" :url (mindwtr-api--url "/v1/data")
                              :headers (mindwtr-api--headers))))))
    (mindwtr-api--header resp "ETag")))

(defun mindwtr-api-put-data (appdata)
  "PUT /v1/data with APPDATA.  Return the decoded response plist."
  (let ((resp (mindwtr-api--check
               (funcall mindwtr-api-http-function
                        (list :method "PUT" :url (mindwtr-api--url "/v1/data")
                              :headers (mindwtr-api--headers t)
                              :body (mindwtr-util-json-encode appdata))))))
    (mindwtr-util-json-decode (plist-get resp :body))))

(provide 'mindwtr-api)
;;; mindwtr-api.el ends here
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS. (Default transport is exercised only in manual integration; unit tests use the stub.)

- [ ] **Step 5: Commit**

```bash
git add mindwtr-api.el test/mindwtr-api-test.el
git commit -m "feat(api): GET/HEAD/PUT /v1/data with injectable transport + error classes"
```

---

## Task 11: Change detection & candidate build

**Files:**
- Create: `mindwtr-sync.el`
- Create: `test/mindwtr-sync-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-sync-test.el`:

```elisp
;;; mindwtr-sync-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-sync)

(ert-deftest mindwtr-sync-build-candidate-create ()
  "A task absent from the shadow becomes a create: rev 1, gets id+createdAt."
  (let* ((local '(:tasks ((:id nil :mw-kind task :title "new" :status "next"))
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (stringp (plist-get task :id)))
    (should (= (plist-get task :rev) 1))
    (should (string= (plist-get task :createdAt) "2026-06-01T00:00:00Z"))
    (should (string= (plist-get task :revBy) "dev-1"))))

(ert-deftest mindwtr-sync-build-candidate-unchanged-echoes-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :revBy "phone" :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 7))
    (should (string= (plist-get task :revBy) "phone"))
    (should (string= (plist-get task :updatedAt) "U"))))

(ert-deftest mindwtr-sync-build-candidate-update-bumps-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "CHANGED" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 8))
    (should (string= (plist-get task :updatedAt) "NOW"))
    (should (string= (plist-get task :revBy) "dev-1"))
    (should (string= (plist-get task :createdAt) "C"))))

(ert-deftest mindwtr-sync-build-candidate-delete-tombstones ()
  "A task in the shadow but absent from local becomes a tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :createdAt "C"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :deletedAt) "NOW"))
    (should (= (plist-get task :rev) 4))))

(ert-deftest mindwtr-sync-candidate-carries-settings-verbatim ()
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :settings (:theme "dark" :gtd (:x 1))))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW")))
    (should (equal (plist-get cand :settings) '(:theme "dark" :gtd (:x 1))))))

(ert-deftest mindwtr-sync-candidate-strips-device-local-fields ()
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                      :createdAt "C" :localStatus "dirty"))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-member task :localStatus)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-sync`.

- [ ] **Step 3: Implement change detection + candidate build**

`mindwtr-sync.el` (initial — orchestration added in Task 14):

```elisp
;;; mindwtr-sync.el --- Sync engine -*- lexical-binding: t; -*-
;;; Commentary:
;; Change detection against the shadow and candidate-snapshot construction.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-shadow)

(defconst mindwtr-sync--entity-keys '(:tasks :projects :sections :areas))

(defun mindwtr-sync--strip-device-local (entity)
  "Return ENTITY without device-local fields."
  (let (out (i 0))
    (while (< i (length entity))
      (unless (memq (nth i entity) mindwtr-model-device-local-fields)
        (setq out (plist-put out (nth i entity) (nth (1+ i) entity))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-sync--merge-shadow-fields (local-entity shadow-entity)
  "Overlay LOCAL-ENTITY (content) on SHADOW-ENTITY (full), local wins for content."
  (let ((out (copy-sequence (or shadow-entity '()))) (i 0))
    (while (< i (length local-entity))
      (let ((k (nth i local-entity)))
        (unless (eq k :mw-kind)
          (setq out (plist-put out k (nth (1+ i) local-entity)))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-sync--classify (local-entity shadow-entity)
  "Return one of `create' `update' `unchanged' for LOCAL vs SHADOW."
  (cond
   ((null shadow-entity) 'create)
   ((string= (mindwtr-signature local-entity) (mindwtr-signature shadow-entity))
    'unchanged)
   (t 'update)))

(defun mindwtr-sync-build-candidate (local shadow device-id now)
  "Build a candidate AppData from LOCAL parse and SHADOW, stamping DEVICE-ID/NOW."
  (let ((cand (list :settings (plist-get shadow :settings))))
    (dolist (key mindwtr-sync--entity-keys)
      (let* ((shadow-idx (mindwtr-shadow-index shadow key))
             (seen (make-hash-table :test 'equal))
             out)
        ;; creates + updates + unchanged from local
        (dolist (le (plist-get local key))
          (let* ((id (or (plist-get le :id) (mindwtr-util-uuid)))
                 (le (plist-put (copy-sequence le) :id id))
                 (se (gethash id shadow-idx))
                 (klass (mindwtr-sync--classify le se))
                 (merged (mindwtr-sync--merge-shadow-fields le se)))
            (puthash id t seen)
            (pcase klass
              ('create
               (setq merged (plist-put merged :rev 1))
               (setq merged (plist-put merged :createdAt now))
               (setq merged (plist-put merged :updatedAt now))
               (setq merged (plist-put merged :revBy device-id)))
              ('update
               (setq merged (plist-put merged :rev (1+ (or (plist-get se :rev) 0))))
               (setq merged (plist-put merged :updatedAt now))
               (setq merged (plist-put merged :revBy device-id)))
              ('unchanged nil))
            (push (mindwtr-sync--strip-device-local merged) out)))
        ;; deletions: in shadow (live) but not seen locally
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen) (plist-get se :deletedAt))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
        (setq cand (plist-put cand key (nreverse out)))))
    cand))

(provide 'mindwtr-sync)
;;; mindwtr-sync.el ends here
```

Note: `:mw-extra-props` is carried through `merge-shadow-fields` and stripped before serialization in Task 14 (it must not be sent to the server). Add it to `mindwtr-model-device-local-fields`? No — it's an internal key, not a JSON field; strip it explicitly in the PUT path (Task 14).

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-sync.el test/mindwtr-sync-test.el
git commit -m "feat(sync): change detection + candidate snapshot construction"
```

---

## Task 12: Reconcile — write merged appdata into the buffer, preserving org-only content

**Files:**
- Create: `mindwtr-reconcile.el`
- Create: `test/mindwtr-reconcile-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-reconcile-test.el`:

```elisp
;;; mindwtr-reconcile-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-reconcile)

(ert-deftest mindwtr-reconcile-updates-existing-title ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT old title :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "new title" :status "next"
                             :areaId "a1" :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work" :rev 1)) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "new title" nil t))
      (should-not (save-excursion (search-forward "old title" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "done" :areaId "a1"
                             :rev 6 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "KEEPME" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "DONE" nil t))))))

(ert-deftest mindwtr-reconcile-removes-tombstoned ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT gone :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "gone" :status "next" :areaId "a1"
                             :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should-not (search-forward "gone" nil t)))))

(ert-deftest mindwtr-reconcile-inserts-remote-new ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t2" :title "fresh" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-06-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "fresh" nil t)))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr-reconcile`.

- [ ] **Step 3: Implement reconcile**

Reconcile strategy: build an id→marker map of existing headings; for each merged live entity, update in place (preserving `LOGBOOK`/unknown drawers by editing only title/keyword/priority/tags/planning/known-props/description/checklist), or insert under its container; delete tombstoned headings. The simplest robust approach that preserves org-only content is **field-level edit** of the existing subtree rather than wholesale re-render.

`mindwtr-reconcile.el`:

```elisp
;;; mindwtr-reconcile.el --- Apply merged appdata into the org buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Updates the current buffer to reflect a merged AppData by id, editing
;; recognized fields in place and preserving org-only drawers (LOGBOOK,
;; unknown PROPERTIES) and the user's point.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-util)

(defun mindwtr-reconcile--id-markers ()
  "Return a hash MW_ID -> marker at heading start for every entity heading."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (let ((id (org-entry-get (point) "MW_ID")))
         (when id (puthash id (point-marker) h)))))
    h))

(defun mindwtr-reconcile--container-marker (markers entity)
  "Return marker of ENTITY's container heading, or nil for top-level."
  (let ((parent (or (plist-get entity :sectionId)
                    (plist-get entity :projectId)
                    (plist-get entity :areaId))))
    (and parent (gethash parent markers))))

(defun mindwtr-reconcile--update-heading (entity kind)
  "Rewrite recognized parts of the heading at point from ENTITY (kind KIND).
Preserves LOGBOOK and unknown properties."
  ;; title + keyword + priority + tags
  (let* ((title (or (plist-get entity :title) (plist-get entity :name)))
         (todo (when (memq kind '(task project))
                 (and (plist-get entity :status)
                      (mindwtr-model-status->keyword kind (plist-get entity :status))))))
    (org-edit-headline title)
    (when (memq kind '(task project)) (org-todo (or todo 'none)))
    (when (eq kind 'task)
      (let ((c (mindwtr-model-priority->cookie (plist-get entity :priority))))
        (org-priority (or c 'remove)))
      (org-set-tags (append (plist-get entity :contexts)
                            (mapcar (lambda (s) (string-remove-prefix "#" s))
                                    (plist-get entity :tags))))))
  ;; known scalar properties
  (dolist (p '((:energyLevel . "MW_ENERGY") (:timeEstimate . "MW_TIME_ESTIMATE")
               (:assignedTo . "MW_ASSIGNED_TO") (:location . "MW_LOCATION")
               (:taskMode . "MW_TASK_MODE")))
    (let ((v (plist-get entity (car p))))
      (if v (org-entry-put (point) (cdr p) (format "%s" v))
        (org-entry-delete (point) (cdr p)))))
  ;; display-mirror timestamps
  (when (plist-get entity :createdAt)
    (org-entry-put (point) "MW_CREATED" (mindwtr-util-iso->org (plist-get entity :createdAt))))
  (when (plist-get entity :updatedAt)
    (org-entry-put (point) "MW_UPDATED" (mindwtr-util-iso->org (plist-get entity :updatedAt)))))

(defun mindwtr-reconcile--insert-entity (entity kind markers)
  "Insert ENTITY (kind KIND) as a new heading under its container."
  (let* ((cmark (mindwtr-reconcile--container-marker markers entity))
         (level (if cmark
                    (1+ (save-excursion (goto-char cmark) (org-current-level)))
                  1)))
    (if cmark
        (progn (goto-char cmark)
               (org-end-of-subtree t t)
               (unless (bolp) (insert "\n")))
      (goto-char (point-max)) (unless (bolp) (insert "\n")))
    (let ((e (plist-put (copy-sequence entity) :mw-kind kind)))
      (insert (mindwtr-render-heading e level
                                      (list :createdAt (plist-get entity :createdAt)
                                            :updatedAt (plist-get entity :updatedAt)))))))

(defun mindwtr-reconcile-buffer (merged)
  "Reconcile the current buffer to reflect MERGED AppData."
  (save-excursion
    (let ((markers (mindwtr-reconcile--id-markers)))
      ;; deletions first
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (e (plist-get merged key))
          (when (plist-get e :deletedAt)
            (let ((m (gethash (plist-get e :id) markers)))
              (when m (goto-char m) (org-back-to-heading t)
                    (org-cut-subtree) (remhash (plist-get e :id) markers))))))
      ;; updates + inserts, parents before children (areas->projects->sections->tasks)
      (dolist (key '(:areas :projects :sections :tasks))
        (let ((kind (intern (substring (symbol-name key) 1
                                       (1- (length (symbol-name key)))))))
          (dolist (e (plist-get merged key))
            (unless (plist-get e :deletedAt)
              (let ((m (gethash (plist-get e :id) markers)))
                (if m
                    (progn (goto-char m) (org-back-to-heading t)
                           (mindwtr-reconcile--update-heading e kind))
                  (mindwtr-reconcile--insert-entity e kind markers)
                  ;; refresh markers so children find newly-inserted parents
                  (setq markers (mindwtr-reconcile--id-markers)))))))))))

(provide 'mindwtr-reconcile)
;;; mindwtr-reconcile.el ends here
```

Note: `:areas` → kind `area` via `substring` drops the trailing `s` (`:tasks`→`task`, `:areas`→`area`, `:sections`→`section`, `:projects`→`project`). Verify this holds for each key during execution; if `:areas`→`area` needs special-casing, add an explicit alist.

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS. Adjust `org-set-tags`/`org-priority`/`org-todo` calls to your Org version's signatures until green.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-reconcile.el test/mindwtr-reconcile-test.el
git commit -m "feat(reconcile): id-keyed buffer update preserving org-only content"
```

---

## Task 13: Conflict detection, backup, and the sync report

**Files:**
- Create: `mindwtr-report.el`
- Create: `test/mindwtr-report-test.el`
- Modify: `mindwtr-sync.el` (add conflict comparison)

- [ ] **Step 1: Write failing tests**

`test/mindwtr-report-test.el`:

```elisp
;;; mindwtr-report-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-sync)
(require 'mindwtr-report)

(ert-deftest mindwtr-sync-detect-conflicts-finds-lost-edit ()
  "A locally-changed task whose merged result differs is a lost edit."
  (let* ((candidate '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8
                               :revBy "dev-1"))
                      :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "THEIRS" :status "next" :rev 9
                            :revBy "phone"))
                   :projects nil :sections nil :areas nil))
         (changed-ids '("t1"))
         (conflicts (mindwtr-sync-detect-conflicts candidate merged changed-ids)))
    (should (= (length conflicts) 1))
    (let ((c (car conflicts)))
      (should (string= (plist-get c :id) "t1"))
      (should (string= (plist-get (plist-get c :mine) :title) "MINE"))
      (should (string= (plist-get (plist-get c :theirs) :title) "THEIRS")))))

(ert-deftest mindwtr-sync-detect-conflicts-ignores-accepted-edit ()
  (let* ((candidate '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8))
                      :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8))
                   :projects nil :sections nil :areas nil)))
    (should (null (mindwtr-sync-detect-conflicts candidate merged '("t1"))))))

(ert-deftest mindwtr-report-renders-buffer ()
  (let ((buf (mindwtr-report-show
              '(:created 2 :updated 1 :deleted 0)
              '((:id "t1" :mine (:title "MINE") :theirs (:title "THEIRS")))
              nil)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (should (search-forward "Created: 2" nil t))
          (should (search-forward "t1" nil t))
          (should (search-forward "MINE" nil t)))
      (kill-buffer buf))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `mindwtr-sync-detect-conflicts` / `mindwtr-report-show` undefined.

- [ ] **Step 3: Implement conflict detection (sync) + report**

Append to `mindwtr-sync.el` before `(provide ...)`:

```elisp
(defun mindwtr-sync--find (appdata id)
  "Find entity with ID in APPDATA across all entity lists."
  (catch 'hit
    (dolist (key mindwtr-sync--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (string= (plist-get e :id) id) (throw 'hit e))))
    nil))

(defun mindwtr-sync-detect-conflicts (candidate merged changed-ids)
  "Return a list of lost-edit conflicts for CHANGED-IDS comparing CANDIDATE vs MERGED."
  (let (conflicts)
    (dolist (id changed-ids)
      (let ((mine (mindwtr-sync--find candidate id))
            (theirs (mindwtr-sync--find merged id)))
        (when (and mine theirs
                   (not (string= (mindwtr-signature mine)
                                 (mindwtr-signature theirs))))
          (push (list :id id :mine mine :theirs theirs) conflicts))))
    (nreverse conflicts)))
```

`mindwtr-report.el`:

```elisp
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
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-report.el test/mindwtr-report-test.el mindwtr-sync.el
git commit -m "feat(report): conflict detection + sync report buffer"
```

---

## Task 14: Sync orchestration — the full cycle

**Files:**
- Modify: `mindwtr-sync.el`
- Modify: `test/mindwtr-sync-test.el`

- [ ] **Step 1: Write failing test (end-to-end with stubbed API)**

Append to `test/mindwtr-sync-test.el`:

```elisp
(require 'mindwtr-api)
(require 'mindwtr-reconcile)

(ert-deftest mindwtr-sync-once-end-to-end ()
  "A local edit is PUT, merged result is reconciled, shadow updated."
  (let* ((dir (make-temp-file "mw-e2e" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         ;; server echoes our PUT as the merged result, bumping nothing
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2"))
                           :body put-body))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          ;; seed shadow so the task is an UPDATE, not create
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get result :ok))
            ;; PUT included the changed title and bumped rev
            (should (string-match-p "do it" put-body))
            ;; shadow now reflects merged state
            (let ((task (car (plist-get (mindwtr-shadow-load) :tasks))))
              (should (string= (plist-get task :title) "do it")))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `mindwtr-sync-once` undefined.

- [ ] **Step 3: Implement orchestration**

Append to `mindwtr-sync.el` before `(provide ...)`:

```elisp
(require 'mindwtr-parse)
(require 'mindwtr-api)
(require 'mindwtr-reconcile)
(require 'mindwtr-report)

(defun mindwtr-sync--strip-internal-keys (appdata)
  "Remove internal :mw-* keys from every entity in APPDATA (for the wire)."
  (let ((out (list :settings (plist-get appdata :settings))))
    (dolist (key mindwtr-sync--entity-keys)
      (setq out (plist-put out key
                           (mapcar
                            (lambda (e)
                              (let (clean (i 0))
                                (while (< i (length e))
                                  (unless (memq (nth i e) '(:mw-kind :mw-extra-props))
                                    (setq clean (plist-put clean (nth i e) (nth (1+ i) e))))
                                  (setq i (+ i 2)))
                                clean))
                            (plist-get appdata key)))))
    out))

(defun mindwtr-sync--changed-ids (local shadow)
  "Return ids of entities that are create/update vs SHADOW."
  (let (ids)
    (dolist (key mindwtr-sync--entity-keys)
      (let ((idx (mindwtr-shadow-index shadow key)))
        (dolist (le (plist-get local key))
          (let* ((id (plist-get le :id))
                 (se (and id (gethash id idx))))
            (when (and id (not (eq (mindwtr-sync--classify le se) 'unchanged)))
              (push id ids))))))
    ids))

(defun mindwtr-sync-once (buffer now)
  "Run one full sync cycle for org BUFFER, stamping changes with NOW.
Return (:ok t :conflicts LIST) or signals on hard error."
  (with-current-buffer buffer
    (let* ((shadow (mindwtr-shadow-load))
           (device (mindwtr-shadow-device-id))
           (tick (buffer-chars-modified-tick))
           (local (mindwtr-parse-buffer))
           (changed (mindwtr-sync--changed-ids local shadow))
           (candidate (mindwtr-sync-build-candidate local shadow device now))
           (wire (mindwtr-sync--strip-internal-keys candidate)))
      (mindwtr-model-validate-appdata wire)
      ;; PUT (server merges), then authoritative GET
      (mindwtr-api-put-data wire)
      (let* ((got (mindwtr-api-get-data))
             (merged (plist-get got :appdata))
             (conflicts (mindwtr-sync-detect-conflicts wire merged changed)))
        ;; abort if buffer changed mid-sync
        (unless (= tick (buffer-chars-modified-tick))
          (error "mindwtr: buffer changed during sync; aborting"))
        ;; backup before mutating the buffer
        (when (buffer-file-name)
          (let ((bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
            (make-directory bdir t)
            (write-region (point-min) (point-max)
                          (expand-file-name
                           (format "mindwtr-%s.org"
                                   (format-time-string "%Y%m%dT%H%M%S")) bdir))))
        (mindwtr-reconcile-buffer merged)
        (mindwtr-shadow-save merged)
        (mindwtr-shadow-set-etag (plist-get got :etag))
        (mindwtr-report-show
         (list :created (length changed) :updated 0 :deleted 0)
         conflicts nil)
        (list :ok t :conflicts conflicts)))))
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mindwtr-sync.el test/mindwtr-sync-test.el
git commit -m "feat(sync): full cycle orchestration with backup + concurrency guard"
```

---

## Task 15: Entry point — defcustoms, auth-source, mode, commands, triggers

**Files:**
- Create: `mindwtr.el`
- Create: `test/mindwtr-test.el`

- [ ] **Step 1: Write failing tests**

`test/mindwtr-test.el`:

```elisp
;;; mindwtr-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr)

(ert-deftest mindwtr-mode-sets-todo-keywords ()
  (with-temp-buffer
    (mindwtr-mode)
    (should (member "NEXT" (mapcar #'car org-todo-kwd-alist)))
    (should (member "ACTIVE" (mapcar #'car org-todo-kwd-alist)))))

(ert-deftest mindwtr-token-prefers-explicit-var ()
  (let ((mindwtr-auth-token "explicit"))
    (should (string= (mindwtr--resolve-token) "explicit"))))

(ert-deftest mindwtr-sync-command-is-interactive ()
  (should (commandp 'mindwtr-sync)))
```

- [ ] **Step 2: Run to verify failure**

Run: `make test`
Expected: FAIL — `Cannot open load file: mindwtr`.

- [ ] **Step 3: Implement the entry point**

`mindwtr.el`:

```elisp
;;; mindwtr.el --- Sync org-mode GTD with Mindwtr Cloud -*- lexical-binding: t; -*-
;; Author: Srijan
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (plz "0.7"))
;; Keywords: outlines, convenience
;;; Commentary:
;; Bidirectional sync between a single org file and a self-hosted Mindwtr
;; Cloud server.  Entry command: `mindwtr-sync'.
;;; Code:

(require 'org)
(require 'auth-source)
(require 'mindwtr-api)
(require 'mindwtr-sync)
(require 'mindwtr-shadow)

(defgroup mindwtr nil "Sync org with Mindwtr Cloud." :group 'org)

(defcustom mindwtr-server-url nil
  "Base URL of the Mindwtr Cloud server, e.g. https://mw.example."
  :type '(choice (const nil) string) :group 'mindwtr)

(defcustom mindwtr-auth-token nil
  "Bearer token.  If nil, looked up via auth-source for `mindwtr-server-url'."
  :type '(choice (const nil) string) :group 'mindwtr)

(defcustom mindwtr-file nil
  "Path to the org file synced with Mindwtr."
  :type '(choice (const nil) file) :group 'mindwtr)

(defcustom mindwtr-sync-idle-debounce 5
  "Seconds of idle after a save before an automatic sync fires."
  :type 'integer :group 'mindwtr)

(defcustom mindwtr-sync-interval 600
  "Seconds between periodic background syncs (nil disables)."
  :type '(choice (const nil) integer) :group 'mindwtr)

(defvar mindwtr--timer nil)
(defvar mindwtr--debounce-timer nil)

(defconst mindwtr--todo-keywords
  '((sequence "INBOX(i)" "NEXT(n)" "WAIT(w)" "SOMEDAY(s)" "REF(r)" "ACTIVE(a)"
              "|" "DONE(d)" "ARCH(x)")))

(define-derived-mode mindwtr-mode org-mode "Mindwtr"
  "Major mode for the Mindwtr-synced org file."
  (setq-local org-todo-keywords mindwtr--todo-keywords)
  (org-mode-restart)
  (setq-local org-priority-highest ?A)
  (setq-local org-priority-lowest ?D)
  (setq-local org-priority-default ?C))

(defun mindwtr--resolve-token ()
  "Return the bearer token from `mindwtr-auth-token' or auth-source."
  (or mindwtr-auth-token
      (let* ((host (url-host (url-generic-parse-url mindwtr-server-url)))
             (found (car (auth-source-search :host host :require '(:secret)))))
        (when found
          (let ((s (plist-get found :secret)))
            (if (functionp s) (funcall s) s))))
      (error "mindwtr: no auth token (set mindwtr-auth-token or auth-source)")))

(defun mindwtr--prepare ()
  "Validate config and bind API vars; return the sync buffer."
  (unless mindwtr-server-url (error "mindwtr: set `mindwtr-server-url'"))
  (unless mindwtr-file (error "mindwtr: set `mindwtr-file'"))
  (setq mindwtr-api-base-url mindwtr-server-url
        mindwtr-api-token (mindwtr--resolve-token))
  (find-file-noselect mindwtr-file))

;;;###autoload
(defun mindwtr-sync ()
  "Run one synchronization cycle now."
  (interactive)
  (let ((buf (mindwtr--prepare)))
    (condition-case err
        (let ((res (mindwtr-sync-once buf (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))))
          (message "mindwtr: sync ok%s"
                   (if (plist-get res :conflicts)
                       (format " (%d conflict(s) — see report)"
                               (length (plist-get res :conflicts)))
                     "")))
      (mindwtr-api-auth-error (message "mindwtr: authentication failed (check token)"))
      (mindwtr-api-error (message "mindwtr: server error %s"
                                  (plist-get (cdr err) :status)))
      (error (message "mindwtr: %s" (error-message-string err))))))

;;;###autoload
(defun mindwtr-bootstrap ()
  "Fetch the remote snapshot and render a fresh `mindwtr-file' (overwrites)."
  (interactive)
  (mindwtr--prepare)
  (when (or (not (file-exists-p mindwtr-file))
            (yes-or-no-p "Overwrite local mindwtr file from server? "))
    (let* ((got (mindwtr-api-get-data))
           (appdata (plist-get got :appdata)))
      (with-current-buffer (find-file-noselect mindwtr-file)
        (erase-buffer)
        (mindwtr-mode)
        (mindwtr-reconcile-buffer appdata)
        (save-buffer))
      (mindwtr-shadow-save appdata)
      (mindwtr-shadow-set-etag (plist-get got :etag))
      (message "mindwtr: bootstrapped from server"))))

(defun mindwtr--maybe-debounced-sync ()
  "Schedule a debounced sync after saving the mindwtr file."
  (when (and mindwtr-file buffer-file-name
             (file-equal-p buffer-file-name mindwtr-file))
    (when mindwtr--debounce-timer (cancel-timer mindwtr--debounce-timer))
    (setq mindwtr--debounce-timer
          (run-with-idle-timer mindwtr-sync-idle-debounce nil #'mindwtr-sync))))

;;;###autoload
(define-minor-mode mindwtr-auto-sync-mode
  "Globally enable automatic Mindwtr syncing (save-debounce + periodic + focus)."
  :global t :group 'mindwtr
  (if mindwtr-auto-sync-mode
      (progn
        (add-hook 'after-save-hook #'mindwtr--maybe-debounced-sync)
        (add-function :after after-focus-change-function #'mindwtr--on-focus)
        (when mindwtr-sync-interval
          (setq mindwtr--timer
                (run-with-timer mindwtr-sync-interval mindwtr-sync-interval
                                #'mindwtr--periodic-sync))))
    (remove-hook 'after-save-hook #'mindwtr--maybe-debounced-sync)
    (remove-function after-focus-change-function #'mindwtr--on-focus)
    (when mindwtr--timer (cancel-timer mindwtr--timer) (setq mindwtr--timer nil))))

(defvar mindwtr--last-focus-sync 0)
(defun mindwtr--on-focus (&rest _)
  "Sync on frame focus, throttled to 30s."
  (when (and (frame-focus-state)
             (> (- (float-time) mindwtr--last-focus-sync) 30))
    (setq mindwtr--last-focus-sync (float-time))
    (ignore-errors (mindwtr-sync))))

(defun mindwtr--periodic-sync ()
  "Periodic sync that skips work when the remote ETag is unchanged."
  (ignore-errors
    (mindwtr--prepare)
    (let ((etag (mindwtr-api-head-etag)))
      (unless (equal etag (mindwtr-shadow-get-etag))
        (mindwtr-sync)))))

(provide 'mindwtr)
;;; mindwtr.el ends here
```

- [ ] **Step 4: Run to verify pass**

Run: `make test`
Expected: PASS. `mindwtr-mode` test may need `org-mode-restart` guarded under batch; if it errors in batch, wrap that call in `(ignore-errors ...)` and assert on `org-todo-keywords` instead of `org-todo-kwd-alist`.

- [ ] **Step 5: Commit**

```bash
git add mindwtr.el test/mindwtr-test.el
git commit -m "feat(mindwtr): entry point, mode, commands, auto-sync triggers"
```

---

## Task 16: Byte-compile clean + README

**Files:**
- Create: `README.md`
- Run: `make compile`

- [ ] **Step 1: Byte-compile and fix warnings**

Run: `make compile`
Expected: no errors. Fix any `free variable`/`unused lexical` warnings (add `require`s, `defvar`s, or `_` prefixes).

- [ ] **Step 2: Write the README**

`README.md` covering: what it does, install (`mindwtr-server-url`, `auth-source` entry, `mindwtr-file`), `M-x mindwtr-bootstrap` then `M-x mindwtr-sync`, enabling `mindwtr-auto-sync-mode`, the org schema (MW_TYPE/MW_ID, status keywords, priority, tags/contexts), and the conflict report.

- [ ] **Step 3: Run full test suite**

Run: `make test`
Expected: ALL PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README; chore: byte-compile clean"
```

---

## Self-Review

**Spec coverage:**
- Snapshot sync `GET/HEAD/PUT` + server merge → Tasks 10, 14. ✓
- Shadow + ETag + device-id → Task 9. ✓
- org↔AppData bijection (containment, native fields, drawer, display-mirror created/updated) → Tasks 5–8. ✓
- Canonical form / signature excludes shadow+mirror fields → Tasks 4, 8. ✓
- Change detection create/update/unchanged/delete with rev bumping → Task 11. ✓
- Settings opaque pass-through; device-local stripping → Task 11 (tests `...carries-settings-verbatim`, `...strips-device-local-fields`). ✓
- Tombstones in shadow, not rendered; reconcile removes tombstoned → Tasks 11, 12. ✓
- Conflict surfacing + backup + report (no silent loss) → Tasks 13, 14. ✓
- Concurrency guard (buffer tick) → Task 14. ✓
- Error classification + auth-source token → Tasks 10, 15. ✓
- Triggers: manual + debounced-save + periodic(HEAD) + focus → Task 15. ✓
- Preserve org-only content (LOGBOOK/unknown props) → Tasks 5, 12 (tests assert preservation). ✓
- v1 scope: link attachments via `MW_ATTACH` property (Tasks 5/7 drawer field); **file-byte transfer, org-gtd importer, recurrence-object fidelity, retry/backoff loop deferred to Phase 2.** Backoff classification exists (Task 10) but the retry *loop* (5s→5m, 12 attempts) is intentionally not wired in v1 — noted here as a known gap to add in Phase 2.

**Placeholder scan:** No "TBD"/"implement later". Every code step has complete code. A few steps flag version-specific Org API signatures (`org-set-tags`, `org-priority`, `org-todo`) and planning-regex tuning to verify during execution — these are real, runnable starting points, not placeholders.

**Type consistency:** Entity plists keyed by Mindwtr JSON names throughout; internal keys `:mw-kind`/`:mw-extra-props` introduced in parse (Task 5), consumed in render/reconcile (Tasks 7, 12), stripped before wire (Task 14). `mindwtr-shadow-index`, `mindwtr-signature`, `mindwtr-model-status->keyword`, `mindwtr-sync-build-candidate`, `mindwtr-sync-detect-conflicts`, `mindwtr-reconcile-buffer`, `mindwtr-sync-once` names used consistently across tasks.

**Known risks carried from spec:** parse/render idempotency (gated by Task 8 before any sync logic is trusted); Org-version API drift in reconcile (Task 12); the `:areas`→`area` key-singularization shortcut (flagged in Task 12).
