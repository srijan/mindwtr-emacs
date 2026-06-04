# Cleanup Old Backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically delete pre-sync backups older than a configurable age (default 3 days) after each sync.

**Architecture:** A new `mindwtr-shadow-prune-backups` helper in `mindwtr-shadow.el` deletes `backups/mindwtr-<timestamp>.org` files whose filename-embedded timestamp is older than `mindwtr-backup-retention-days`. It is called from the post-PUT path in `mindwtr-sync.el`, right after the fresh backup is written, wrapped in `condition-case` so it can never abort a sync. Non-matching files are never touched.

**Tech Stack:** Emacs Lisp (min Emacs 28.1 / Org 9.5), ERT for tests, `make test` + `make compile` ship gate.

**Spec:** `docs/superpowers/specs/2026-06-04-cleanup-old-backups-design.md`

---

## File Structure

| File | Change |
|------|--------|
| `mindwtr-shadow.el` | Add `mindwtr-backup-retention-days` defcustom + `mindwtr-shadow--backup-time` + `mindwtr-shadow-prune-backups`. |
| `test/mindwtr-shadow-test.el` | Add unit tests for the prune helper. |
| `mindwtr-sync.el` | Call `mindwtr-shadow-prune-backups` after the backup write, guarded by `condition-case`. |
| `test/mindwtr-sync-test.el` | Add one integration test proving a stale backup is pruned during a full sync. |
| `README.md` | Document the new defcustom and auto-cleanup behavior. |

**Note on defcustom placement:** The existing defcustoms live in `mindwtr.el`, but this one goes in `mindwtr-shadow.el` instead. `mindwtr-shadow.el` does not `require` `mindwtr.el` (the dependency runs the other way), and `make compile` uses `byte-compile-error-on-warn t` — referencing the variable from shadow.el while it is defined in mindwtr.el would be a free-variable warning and fail the build. Co-locating the defcustom with the helper that reads it keeps the compile clean. It still tags `:group 'mindwtr`.

---

## Task 1: Prune helper + configuration in `mindwtr-shadow.el`

**Files:**
- Modify: `mindwtr-shadow.el` (add defcustom + two helpers before the `(provide ...)` line)
- Test: `test/mindwtr-shadow-test.el`

- [ ] **Step 1: Write the failing tests**

Append to `test/mindwtr-shadow-test.el` (before any trailing comment line). The existing `mindwtr-shadow-test--with-dir` macro binds both `dir` and `mindwtr-shadow-directory` to a fresh temp directory.

```elisp
(defun mindwtr-shadow-test--make-backup (name)
  "Create an empty backup file NAME under the backups dir."
  (let ((bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
    (make-directory bdir t)
    (write-region "" nil (expand-file-name name bdir))))

(defun mindwtr-shadow-test--backup-exists-p (name)
  (file-exists-p (expand-file-name (concat "backups/" name)
                                   mindwtr-shadow-directory)))

;; Fixed clock: 2026-06-04 12:00:00 local.  Cutoff at retention 3 = 2026-06-01 12:00.
(defun mindwtr-shadow-test--now () (encode-time 0 0 12 4 6 2026))

(ert-deftest mindwtr-shadow-prune-deletes-old-backup ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260530T120000.org") ; 5 days old
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should-not (mindwtr-shadow-test--backup-exists-p "mindwtr-20260530T120000.org")))))

(ert-deftest mindwtr-shadow-prune-keeps-recent-backup ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260604T080000.org") ; same day
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20260604T080000.org")))))

(ert-deftest mindwtr-shadow-prune-disabled-keeps-everything ()
  (mindwtr-shadow-test--with-dir
   (mindwtr-shadow-test--make-backup "mindwtr-20200101T000000.org") ; ancient
   (let ((mindwtr-backup-retention-days nil))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20200101T000000.org")))
   (let ((mindwtr-backup-retention-days 0))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20200101T000000.org")))))

(ert-deftest mindwtr-shadow-prune-leaves-foreign-files ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "notes.txt")              ; not ours
     (mindwtr-shadow-test--make-backup "mindwtr-garbage.org")    ; ours-shaped, unparseable
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should (mindwtr-shadow-test--backup-exists-p "notes.txt"))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-garbage.org")))))

(ert-deftest mindwtr-shadow-prune-missing-dir-is-noop ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     ;; no backups/ dir created at all
     (should-not (file-directory-p
                  (expand-file-name "backups/" mindwtr-shadow-directory)))
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now)) ; must not error
     (should t))))

(ert-deftest mindwtr-shadow-prune-mixed-directory ()
  (mindwtr-shadow-test--with-dir
   (let ((mindwtr-backup-retention-days 3))
     (mindwtr-shadow-test--make-backup "mindwtr-20260530T120000.org") ; old → go
     (mindwtr-shadow-test--make-backup "mindwtr-20260604T080000.org") ; new → stay
     (mindwtr-shadow-test--make-backup "keep-me.org")                 ; foreign → stay
     (mindwtr-shadow-prune-backups (mindwtr-shadow-test--now))
     (should-not (mindwtr-shadow-test--backup-exists-p "mindwtr-20260530T120000.org"))
     (should (mindwtr-shadow-test--backup-exists-p "mindwtr-20260604T080000.org"))
     (should (mindwtr-shadow-test--backup-exists-p "keep-me.org")))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rm -f *.elc test/*.elc && make test 2>&1 | tail -20`
Expected: FAIL — `void-function mindwtr-shadow-prune-backups` (and `void-variable mindwtr-backup-retention-days`).

- [ ] **Step 3: Write the implementation**

In `mindwtr-shadow.el`, add the defcustom right after the `mindwtr-shadow-directory` defvar (around line 11), and the two helpers immediately before the `(provide 'mindwtr-shadow)` line.

Defcustom (after the `mindwtr-shadow-directory` defvar):

```elisp
(defcustom mindwtr-backup-retention-days 3
  "Delete pre-sync backups older than this many days after each sync.
Age is measured from the timestamp encoded in the backup filename.
nil or 0 disables cleanup (backups are kept forever)."
  :type '(choice (const :tag "Keep forever" nil) integer)
  :group 'mindwtr)
```

Helpers (before `(provide 'mindwtr-shadow)`):

```elisp
(defun mindwtr-shadow--backup-time (filename)
  "Return the encoded time parsed from a backup FILENAME, or nil.
FILENAME is a non-directory name like \"mindwtr-20260604T080500.org\".
Returns nil for any name that does not match the mindwtr backup pattern."
  (when (string-match
         "\\`mindwtr-\\([0-9]\\{8\\}\\)T\\([0-9]\\{6\\}\\)\\.org\\'" filename)
    (let ((d (match-string 1 filename))
          (tm (match-string 2 filename)))
      (encode-time (string-to-number (substring tm 4 6))  ; sec
                   (string-to-number (substring tm 2 4))  ; min
                   (string-to-number (substring tm 0 2))  ; hour
                   (string-to-number (substring d 6 8))   ; day
                   (string-to-number (substring d 4 6))   ; month
                   (string-to-number (substring d 0 4)))))) ; year

(defun mindwtr-shadow-prune-backups (&optional now)
  "Delete pre-sync backups older than `mindwtr-backup-retention-days'.
NOW defaults to `current-time' and is injectable for tests.  A no-op when
retention is nil or <= 0, or when the backups directory is absent.  Only
files matching the mindwtr-<timestamp>.org pattern with a parseable
timestamp are candidates; anything else is left untouched."
  (let ((days mindwtr-backup-retention-days)
        (bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
    (when (and days (> days 0) (file-directory-p bdir))
      (let ((cutoff (time-subtract (or now (current-time))
                                   (* days 24 60 60))))
        (dolist (f (directory-files bdir t nil t))
          (let ((btime (mindwtr-shadow--backup-time (file-name-nondirectory f))))
            (when (and btime (time-less-p btime cutoff))
              (delete-file f))))))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rm -f *.elc test/*.elc && make test 2>&1 | tail -20`
Expected: PASS — all six new `mindwtr-shadow-prune-*` tests pass, no regressions.

- [ ] **Step 5: Byte-compile clean**

Run: `rm -f *.elc && make compile 2>&1 | tail -20`
Expected: no errors, no warnings (the `byte-compile-error-on-warn t` gate stays green).

- [ ] **Step 6: Commit**

```bash
git add mindwtr-shadow.el test/mindwtr-shadow-test.el
git commit -m "feat(shadow): prune pre-sync backups older than retention (#30)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Wire the prune into the sync cycle

**Files:**
- Modify: `mindwtr-sync.el` (post-PUT backup block, around lines 360-367)
- Test: `test/mindwtr-sync-test.el`

- [ ] **Step 1: Write the failing integration test**

Append to `test/mindwtr-sync-test.el`. It visits a real file (the backup write is gated on `(buffer-file-name)`), pre-seeds a stale backup, runs a full mocked sync, and asserts the stale backup is gone while a fresh one exists.

```elisp
(ert-deftest mindwtr-sync-once-prunes-stale-backups ()
  "A full sync writes a fresh backup and prunes ones older than retention."
  (let* ((dir (make-temp-file "mw-prune" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-backup-retention-days 3)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (orgfile (expand-file-name "mw.org" dir))
         (bdir (expand-file-name "backups/" dir))
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (progn
          (make-directory bdir t)
          (write-region "" nil (expand-file-name "mindwtr-20200101T000000.org" bdir))
          (with-temp-buffer
            (setq buffer-file-name orgfile)
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                      "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :projects nil :sections nil
               :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")
            (set-buffer-modified-p nil))
          ;; stale backup pruned, at least one fresh mindwtr-*.org remains
          (should-not (file-exists-p
                       (expand-file-name "mindwtr-20200101T000000.org" bdir)))
          (should (seq-some (lambda (f) (string-match-p "\\`mindwtr-.*\\.org\\'" f))
                            (directory-files bdir))))
      (delete-directory dir t))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rm -f *.elc test/*.elc && make test 2>&1 | tail -20`
Expected: FAIL — the stale `mindwtr-20200101T000000.org` still exists (prune is not yet called from the sync path), so the `should-not` fails.

- [ ] **Step 3: Add the prune call to the backup block**

In `mindwtr-sync.el`, the backup-writing block currently reads:

```elisp
            (when (buffer-file-name)
              (let* ((bdir (expand-file-name "backups/" mindwtr-shadow-directory))
                     (bf (expand-file-name
                          (format "mindwtr-%s.org"
                                  (format-time-string "%Y%m%dT%H%M%S")) bdir)))
                (make-directory bdir t)
                (write-region (point-min) (point-max) bf)
                (setq backup-file bf)))
```

Change it to call the prune after the write, guarded so it can never throw (post-PUT path — see AGENTS.md "Post-PUT path must never throw"):

```elisp
            (when (buffer-file-name)
              (let* ((bdir (expand-file-name "backups/" mindwtr-shadow-directory))
                     (bf (expand-file-name
                          (format "mindwtr-%s.org"
                                  (format-time-string "%Y%m%dT%H%M%S")) bdir)))
                (make-directory bdir t)
                (write-region (point-min) (point-max) bf)
                (setq backup-file bf)
                (condition-case err
                    (mindwtr-shadow-prune-backups)
                  (error (message "mindwtr: backup cleanup skipped: %s"
                                  (error-message-string err))))))
```

(`mindwtr-sync.el` already `require`s `mindwtr-shadow`, so the function is in scope.)

- [ ] **Step 4: Run test to verify it passes**

Run: `rm -f *.elc test/*.elc && make test 2>&1 | tail -20`
Expected: PASS — `mindwtr-sync-once-prunes-stale-backups` passes, no regressions.

- [ ] **Step 5: Byte-compile clean**

Run: `rm -f *.elc && make compile 2>&1 | tail -20`
Expected: no errors, no warnings.

- [ ] **Step 6: Commit**

```bash
git add mindwtr-sync.el test/mindwtr-sync-test.el
git commit -m "feat(sync): prune stale pre-sync backups after each sync (#30)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Document the new option

**Files:**
- Modify: `README.md` (backup sentence ~line 122-124; customization table ~line 165-171)

- [ ] **Step 1: Update the backup-safety-net sentence**

Find (around line 122-124):

```markdown
backup of the whole file is also written to `backups/` under the data
directory on every sync as a final safety net.
```

Replace with:

```markdown
backup of the whole file is also written to `backups/` under the data
directory on every sync as a final safety net. Backups older than
`mindwtr-backup-retention-days` (default 3) are pruned automatically after
each sync; set it to `nil` to keep them forever.
```

- [ ] **Step 2: Add the defcustom to the customization summary table**

Find the last row of the table (around line 171):

```markdown
| `mindwtr-sync-interval` | `600` | Seconds between periodic syncs (`nil` disables). |
```

Add a row immediately after it:

```markdown
| `mindwtr-backup-retention-days` | `3` | Days to keep pre-sync backups; pruned after each sync (`nil`/`0` keeps forever). |
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): document mindwtr-backup-retention-days (#30)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the full ship gate one last time:

Run: `rm -f *.elc test/*.elc && make test && make compile`
Expected: all ERT tests pass; byte-compile clean.
