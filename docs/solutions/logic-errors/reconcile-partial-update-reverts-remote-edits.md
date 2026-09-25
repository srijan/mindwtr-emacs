---
title: Reconcile partial in-place updates silently revert remote edits
date: 2026-06-03
category: logic-errors
module: mindwtr-reconcile
problem_type: logic_error
component: tooling
symptoms:
  - "A remote-only edit to SCHEDULED/DEADLINE/CLOSED is not visible in the buffer after sync"
  - "A remote-only change to a task description or checklist is not visible after sync"
  - "Drawer props beyond the five hardcoded ones are not updated when changed remotely"
  - "The next sync re-PUTs the stale local value, silently winning over the server edit"
  - "Heavy reconcile loads are O(n-squared) slow (~7.6s for 800 updates vs ~0.09s fixed)"
root_cause: logic_error
resolution_type: code_fix
severity: critical
tags: [reconcile, bidirectional, in-place-update, renderer, marker, performance]
---

# Reconcile partial in-place updates silently revert remote edits

## Problem
`mindwtr-reconcile--update-heading` rewrote only a fixed subset of an entry in place — title,
TODO keyword, priority, tags, and five named drawer props. Any server-side change to
`SCHEDULED:`/`DEADLINE:`/`CLOSED:`, the description, the checklist, or other drawer props was
never written to the buffer. The next parse read the still-stale text, computed the old
signature, and the sync engine concluded "local unchanged" and **re-PUT the stale value** —
silently reverting the remote edit and breaking the bidirectional guarantee.

## Symptoms
- Remote-only edits to planning lines, description, or checklist were invisible after sync.
- The stale local value was pushed back on the following sync, overwriting the server.
- A LOGBOOK drawer placed *above* PROPERTIES caused `org-entry-get` to miss the heading's
  properties, so reconcile appended a **duplicate** heading instead of updating in place.
- Under hundreds of updates, reconcile was O(n²): ~7.6 s for 800 all-entity updates.

## What Didn't Work
The buggy field-by-field rewriter (`mindwtr-reconcile--update-heading`, commit `1389779`)
enumerated only part of the entry surface. Adding more `(org-entry-put ...)` calls to cover the
gaps doesn't work either: planning lines (`SCHEDULED:`/`DEADLINE:`/`CLOSED:`) are **not** drawer
properties and can't be set via `org-entry-put`. A correct in-place rewriter would have to
re-parse and rewrite the planning region, the body, and the checklist — essentially
reimplementing the renderer, and it would always lag behind schema additions.

## Solution
Replace the partial rewriter with `mindwtr-reconcile--rebuild-entry`, which rebuilds the whole
entry via the canonical renderer and re-grafts org-only body content
(`mindwtr-reconcile.el:66-114`, commit `62835c3`, later `353b301`):

```elisp
(defun mindwtr-reconcile--rebuild-entry (entity kind)
  (org-back-to-heading t)
  (let* ((level     (org-current-level))
         (extra     (mindwtr-parse-extra-props))
         (clock-id  (mindwtr-reconcile--running-clock-id))
         (beg       (point))
         (end       (mindwtr-heading-entry-end))
         (preserved (mindwtr-reconcile--preserved-body
                     kind (mindwtr-heading-body-start) end))
         (e         (plist-put (plist-put (copy-sequence entity) :mw-kind kind)
                               :mw-extra-props extra))
         (rendered  (mindwtr-render-heading e level e)))
    (when preserved
      (let ((i (string-match "\n:END:\n" rendered)))
        (when i
          (let ((cut (+ i (length "\n:END:\n"))))
            (setq rendered (concat (substring rendered 0 cut) preserved (substring rendered cut)))))))
    ;; Diff-replace the entry's region so markers stay put (see Why This Works).
    (save-restriction
      (narrow-to-region beg end)
      (mindwtr-reconcile--replace-buffer-contents rendered))
    (mindwtr-reconcile--restore-running-clock clock-id)))
```

The same commit fixed the id-marker bug by switching from `org-entry-get` to a literal drawer
scan, today `mindwtr-heading-prop` (`mindwtr-heading.el:95`), which scans the drawer text
directly and tolerates a LOGBOOK-above-PROPERTIES layout.

## Why This Works
**Completeness:** `mindwtr-render-heading` is the single authoritative serializer for every field
(planning lines, description, checklist, all drawer props, tags, priority). Rebuilding through it
means any field the server can change appears in the buffer, so the re-parsed signature equals
the server's and the next sync correctly sees "unchanged."

**Marker safety (history):** Emacs markers are position references; deleting a region
collapses every marker inside it onto the deletion point. At `62835c3` reconcile kept an
id→marker map covering all headings *below* the one being rebuilt, so delete-then-insert
collapsed them all and forced a full O(n) rescan per update — O(n²) total. That fix inserted the
rendered string *first*, shifting downstream markers forward so the map stayed valid: 800
entities, 7.6 s → 0.09 s (~85×). Insert-before-delete still drifted markers held *inside* the
entry, such as an open org-agenda line's marker, onto the next heading, so `353b301` replaced it
with a `replace-buffer-contents` diff narrowed to the entry's region, which makes minimal edits
and leaves those markers on their headings. The id→marker map itself was removed in `27c72e3`
in favour of a direct drawer-line search, today `mindwtr-heading-find-id`.

**Preserved content:** `mindwtr-reconcile--preserved-body` keeps what the renderer never emits —
for every note-bearing kind (task/project/section/person), drawer blocks and bare CLOCK lines;
for `area` (no notes field), the entire free-prose body. Child
headings lie outside the entry region (`outline-next-heading` excludes them) and are untouched.

## Prevention
- Any code that updates buffer regions for a renderer-defined format should **invoke the
  renderer**, not patch individual fields. Treat partial in-place rewriters as an anti-pattern
  here.
- When rewriting a buffer region that markers may point into, **prefer a diffing replacement**
  (`replace-buffer-contents`, narrowed to the region) so markers, including those other buffers
  hold, stay on their headings; insert-before-delete protects only markers outside the region.
- Use `mindwtr-heading-prop` (direct drawer scan), not `org-entry-get`, whenever the heading's
  PROPERTIES position isn't guaranteed (LOGBOOK-above-PROPERTIES breaks `org-entry-get`).

## Related Issues
- Commits `1389779` (original partial rewriter) → `62835c3` (fix). `--rebuild-entry` is now the
  single-heading restore path (`mindwtr-reconcile-restore-entity`); the full-buffer rebuild
  ([[preserving-buffer-view-state-across-reconcile]]) later superseded the incremental path for
  full syncs.
- Shares the signature-equality requirement with
  [[content-signature-allow-list-not-deny-list]].
- [[clarify-queue-markers-collapse-on-write-back]] is the **sibling** marker-collapse bug: the
  clarify session queue hit the same boundary-collapse on subtree replacement, but fixed it by
  abandoning markers for stable MW_IDs rather than by insert-before-delete. Three remedies for one
  class: order your mutations, diff-replace (`replace-buffer-contents`), or stop using markers.
