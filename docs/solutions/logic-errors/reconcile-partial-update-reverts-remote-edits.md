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
The buggy field-by-field rewriter (`mindwtr-reconcile--update-heading`, commit `41a2184`)
enumerated only part of the entry surface. Adding more `(org-entry-put ...)` calls to cover the
gaps doesn't work either: planning lines (`SCHEDULED:`/`DEADLINE:`/`CLOSED:`) are **not** drawer
properties and can't be set via `org-entry-put`. A correct in-place rewriter would have to
re-parse and rewrite the planning region, the body, and the checklist — essentially
reimplementing the renderer, and it would always lag behind schema additions.

## Solution
Replace the partial rewriter with `mindwtr-reconcile--rebuild-entry`, which rebuilds the whole
entry via the canonical renderer and re-grafts org-only body content
(`mindwtr-reconcile.el:78-116`, commit `b6699e5`):

```elisp
(defun mindwtr-reconcile--rebuild-entry (entity kind)
  (org-back-to-heading t)
  (let* ((level     (org-current-level))
         (extra     (mindwtr-parse--extra-props))
         (beg       (point))
         (end       (save-excursion (outline-next-heading) (point)))
         (preserved (mindwtr-reconcile--preserved-body
                     kind (mindwtr-reconcile--body-start) end))
         (e         (plist-put (plist-put (copy-sequence entity) :mw-kind kind)
                               :mw-extra-props extra))
         (rendered  (mindwtr-render-heading e level e)))
    (when preserved
      (let ((i (string-match "\n:END:\n" rendered)))
        (when i
          (let ((cut (+ i (length "\n:END:\n"))))
            (setq rendered (concat (substring rendered 0 cut) preserved (substring rendered cut)))))))
    ;; Insert BEFORE delete: keeps sibling markers valid (see Why This Works).
    (goto-char beg)
    (insert rendered)
    (delete-region (point) (+ (point) (- end beg)))))
```

The same commit fixed the id-marker bug by switching from `org-entry-get` to
`mindwtr-parse--prop` (`mindwtr-reconcile.el:19-29`), which scans the drawer text directly and
tolerates a LOGBOOK-above-PROPERTIES layout.

## Why This Works
**Completeness:** `mindwtr-render-heading` is the single authoritative serializer for every field
(planning lines, description, checklist, all drawer props, tags, priority). Rebuilding through it
means any field the server can change appears in the buffer, so the re-parsed signature equals
the server's and the next sync correctly sees "unchanged."

**Insert-before-delete marker invariant:** Emacs markers are position references; deleting a
region collapses every marker inside it onto the deletion point. The id→marker map covers all
headings *below* the one being rebuilt, so delete-then-insert collapses them all and forces a
full O(n) rescan per update — O(n²) total. Inserting the rendered string *first* shifts
downstream markers forward by its length; nothing collapses, the map stays valid, no rescan is
needed. Cost drops to O(n): 800 entities, 7.6 s → 0.09 s (~85×).

**Preserved content:** `mindwtr-reconcile--preserved-body` keeps what the renderer never emits —
for tasks, LOGBOOK/CLOCK drawers; for non-task entities, the entire free-prose body. Child
headings lie outside the entry region (`outline-next-heading` excludes them) and are untouched.

## Prevention
- Any code that updates buffer regions for a renderer-defined format should **invoke the
  renderer**, not patch individual fields. Treat partial in-place rewriters as an anti-pattern
  here.
- When building an id→position map for sequential buffer mutations, **always insert before
  deleting**, and document the invariant in the function's docstring.
- Use `mindwtr-parse--prop` (direct drawer scan), not `org-entry-get`, whenever the heading's
  PROPERTIES position isn't guaranteed (LOGBOOK-above-PROPERTIES breaks `org-entry-get`).

## Related Issues
- Commits `41a2184` (original partial rewriter) → `b6699e5` (fix). `--rebuild-entry` is now the
  single-heading restore path (`mindwtr-reconcile-restore-entity`); the full-buffer rebuild
  ([[preserving-buffer-view-state-across-reconcile]]) later superseded the incremental path for
  full syncs.
- Shares the signature-equality requirement with
  [[content-signature-allow-list-not-deny-list]].
