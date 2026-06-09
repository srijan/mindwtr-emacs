---
title: "org-map-entries with nil scope hangs emacs --batch on an unsaved buffer"
date: 2026-06-09
category: runtime-errors
module: mindwtr-parse / mindwtr-reconcile
problem_type: runtime_error
component: tooling
symptoms:
  - "Dockerized CI job hung for ~2h on a bootstrap/sync test until killed"
  - "`Non-existent agenda file …  [R]emove/[A]bort?` prompt blocks under --batch"
  - "Stray agenda-file prompt thrown at users on a fresh mindwtr-bootstrap"
  - "Hang reproduces only before the org file's first save (file not on disk)"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags:
  - org-mode
  - batch
  - ci
  - org-map-entries
  - buffer-file-name
  - headless
  - macro
---

# org-map-entries with nil scope hangs emacs --batch on an unsaved buffer

## Problem

`mindwtr` scans org buffers with `org-map-entries` to build its name/id maps, collect org-only content, and snapshot/restore the fold view. Every one of these scans called `org-map-entries` with a **nil scope** (map the current buffer). What we missed is that a nil scope is not a pure buffer operation: when `buffer-file-name` is set, `org-map-entries` hands that file to Org's agenda machinery (`org-agenda-prepare-buffers` → `org-check-agenda-file`). If the file is not on disk, `org-check-agenda-file` **interactively prompts**:

```
Non-existent agenda file /path/to/file.org.  [R]emove from list or [A]bort?
```

Under `emacs --batch` there is no stdin to answer that prompt, so it blocks forever. This surfaced when the new dockerized smoke CI ran `mindwtr-bootstrap`, which rebuilds the buffer *before* its first save — the file does not exist yet, the prompt fires, and the job stalled for roughly two hours until it was killed. The same path throws a stray prompt at a real user mid-`mindwtr-bootstrap` before the org file has ever been written.

## Symptoms

- Dockerized CI hung for ~2h on `mindwtr-bootstrap-saves-and-suppresses-echo` until the runner timed it out.
- `Non-existent agenda file …  [R]emove from list or [A]bort?` printed, then no further output under `--batch`.
- Once the bootstrap/reconcile hang was cleared, `mindwtr-sync-once-prunes-stale-backups` exposed the *same* hang in the parse scans (first sync parses the live, never-saved buffer).
- A stray prompt appeared interactively on a fresh bootstrap, before the file's initial save.
- Reproduces only when `buffer-file-name` points at a path not yet on disk.

## What Didn't Work

- **Passing a scope of `'tree`/`'region`** — wrong semantics; these scans genuinely need to map the whole buffer.
- **Treating it as a test-only artifact** — it is not. `mindwtr-sync-once` and `mindwtr-bootstrap` both operate on the live buffer before its first save in normal use, so the prompt is a real user-facing defect, not just a CI quirk.
- **Adding `timeout-minutes` to the CI jobs and stopping there** — this was added (and kept) as a safety net so a future batch-mode hang fails in minutes instead of stalling for hours, but it converts a hang into a red build; it does not fix the hang.
- **Relying on the smoke suite's incidental immunity** — the smoke tests run inside `with-temp-buffer`, where `buffer-file-name` is already nil, so they never tripped the prompt and masked the problem on the unit path.

## Solution

Bind `buffer-file-name` to nil around each scan. With no file name, `org-map-entries` passes no files to the agenda machinery and never prompts. The fix landed in two original commits (PR #34) — `42e419a` (reconcile's four scans) and `0aa0288` (parse's two scans) — each hand-copying the binding plus a long explanatory comment at all six call sites.

That hand-copying drifted (one comment had decayed to a bare cross-reference), so `dd32c26` consolidated all six into a single guard macro in `mindwtr-util.el`, which now owns the binding and the rationale (`mindwtr-util.el:158-170`):

```elisp
(defmacro mindwtr-util--map-entries (func &rest args)
  "Run `org-map-entries' (FUNC plus optional ARGS) with `buffer-file-name' nil. ..."
  ;; (full docstring explains the agenda-file prompt hazard and why nil is safe)
  (declare (indent 1) (debug t))
  `(let ((buffer-file-name nil))
     (org-map-entries ,func ,@args)))
```

**Before** (`mindwtr-reconcile--id-markers`, pre-fix), with the binding inline and a duplicated comment:

```elisp
(defun mindwtr-reconcile--id-markers ()
  "Return a hash MW_ID -> marker at heading start for every entity heading."
  ;; `buffer-file-name' nil for the scan: `org-map-entries' (nil scope) otherwise
  ;; hands this buffer's file to Org's agenda-file machinery ...
  (let ((h (make-hash-table :test 'equal)) (buffer-file-name nil))
    (org-map-entries
     (lambda () ...))))
```

**After** (current), routed through the guard:

```elisp
(defun mindwtr-reconcile--id-markers ()
  "Return a hash MW_ID -> marker at heading start for every entity heading."
  (let ((h (make-hash-table :test 'equal)))
    (mindwtr-util--map-entries
     (lambda () ...))))
```

All six call sites now go through the macro:

- `mindwtr-parse.el` — `mindwtr-parse--build-area-names` (line 182), `mindwtr-parse-buffer` (line 338)
- `mindwtr-reconcile.el` — `mindwtr-reconcile--id-markers` (line 21), `--collect-org-only` (line 130), `--snapshot-view` (line 262), `--restore-view` (line 318)

A subtle improvement from the consolidation: the binding now scopes to *just* the `org-map-entries` call, tighter than the former `let`-wide bindings in snapshot/restore-view that held `buffer-file-name` nil across unrelated body code.

## Why This Works

A nil scope tells `org-map-entries` to map "agenda files plus the current buffer's file," which routes through `org-agenda-prepare-buffers`. That helper calls `org-check-agenda-file` on each file, and for a path not on disk it issues an interactive `[R]emove/[A]bort?` prompt. The agenda machinery only cares about the *file*, identified through `buffer-file-name`. With `buffer-file-name` let-bound to nil, there is no file to validate, so `org-map-entries` falls straight through to walking the current buffer's headings and never touches `org-check-agenda-file`.

Binding nil is safe because **these scans read only buffer text** — heading structure and `:PROPERTIES:` drawers parsed in-memory. None of them resolve, write, or compare against the backing file, so suppressing the file name cannot change a scan's result. The pinning test confirms exactly this contract: the callback still visits every heading, and it observes `buffer-file-name` as nil inside the scan.

## Prevention

- **Single source of truth.** `mindwtr-util--map-entries` is now the only place the binding lives. New scans must use it; the rationale travels with the macro instead of being re-pasted (and left to rot) at each site.
- **A regression test that fails if the binding is removed.** `test/mindwtr-util-test.el` adds `mindwtr-util--map-entries-neutralizes-buffer-file-name`: it sets `buffer-file-name` to a non-existent path, runs the macro over a two-heading buffer, and asserts the callback fired twice **and** saw `buffer-file-name` nil each time. Strip the binding from the macro and the second assertion captures the live file name, failing the test.
- **CI safety net.** Both CI jobs carry `timeout-minutes` (unit: 10, dockerized smoke: 20), so any future headless prompt fails fast instead of stalling for hours.
- **General rule.** In any batch/headless Emacs code, bind `buffer-file-name` to nil around `org-map-entries` (and any Org call that can reach the agenda-file machinery) unless you genuinely intend agenda-file processing. Never assume a nil scope is a pure buffer operation. More broadly: anything that can prompt interactively will hang under `emacs --batch`, where there is no stdin to answer it.

## Related Issues

- **GitHub PR #34** — original fixes (`42e419a` reconcile, `0aa0288` parse) and the `timeout-minutes` CI safety net.
- **`dd32c26`** — `refactor(parse,reconcile): route org-map-entries through one buffer-file-name guard` — consolidated the six inline bindings into `mindwtr-util--map-entries` and added the pinning test (review findings #2, #3).
- Sibling reconcile-correctness docs in `docs/solutions/logic-errors/` (`reconcile-partial-update-reverts-remote-edits.md`, `silent-deletion-untyped-org-headings.md`) cover content-correctness rather than this headless-prompt class. No existing doc covered the org-mode/batch interaction, so this is the first in `runtime-errors`.
