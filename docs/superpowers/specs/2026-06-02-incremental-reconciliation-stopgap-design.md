# Preserve buffer view state across reconcile (stopgap)

**Issue:** Incremental reconciliation (preserve buffer state)
**Date:** 2026-06-02
**Scope:** Strict stopgap only. Full incremental (signature-diffed in-place rewrite) is explicitly deferred to a follow-up.

## Problem

`mindwtr-reconcile-buffer` rebuilds the whole file (`erase-buffer` + `insert`) on every
sync and restores only point to the current entity's heading. The full rebuild discards
all user-visible view state: which subtrees are folded, the global S-TAB cycle state, and
scroll position. A sync that fires mid-session visibly resets the buffer — everything the
user had collapsed springs open and the window jumps.

## Goal

Snapshot the user-visible view state *before* the existing full rebuild and reapply it
*after*, so a sync stops resetting folds and scroll. This is the cheap stopgap named in the
issue. It deliberately keeps the `erase-buffer` + `insert` rebuild — no signature diffing,
no in-place per-entity surgery.

## Non-goals (deferred to full incremental)

- Rewriting only the entities that actually changed (signature-diffed in-place rebuild).
- Preserving the exact cursor column / in-body position. Point continues to land on the
  entity heading-start, exactly as today. (Explicitly opted out of for this stopgap.)
- Per-heading fold state for container headings (Inbox, Single Actions, Projects, Someday,
  Reference, Areas of Focus) — they carry no `MW_ID`, so they are only approximated by the
  global cycle backdrop.

## Design

Two new private helpers in `mindwtr-reconcile.el`, straddling the existing
`erase-buffer`/`insert` in `mindwtr-reconcile-buffer`:

```elisp
(defun mindwtr-reconcile-buffer (merged)
  (mindwtr-parse-ensure-keywords)
  (let* ((org-only (mindwtr-reconcile--collect-org-only))
         (at-id (mindwtr-reconcile--id-at-point))
         (view (mindwtr-reconcile--snapshot-view))     ; NEW — before erase
         (rendered (mindwtr-render-appdata merged org-only)))
    (let ((inhibit-message t))
      (erase-buffer)
      (insert rendered))
    (goto-char (point-min))
    (mindwtr-reconcile--goto-id at-id)
    (mindwtr-reconcile--restore-view view)))           ; NEW — after point restore
```

### `mindwtr-reconcile--snapshot-view` → plist

Captures exactly the three things the issue names. Returns a plist; every field is
optional and absent fields are simply not restored.

1. **`:folded`** — a hash `MW_ID -> t` of entity headings whose own subtree is collapsed.
   Walk headings with `org-map-entries`. For each `MW_ID` heading:
   - Skip it if its *heading line itself* is invisible (`org-invisible-p` at
     `line-beginning-position`) — that means it is hidden only because an ancestor is
     folded, and the ancestor's own record covers it. This guard avoids the false positive
     of recording a child as folded when only its parent is.
   - Otherwise, record the id when its body is folded: `org-fold-folded-p` at the end of
     the heading line (`line-end-position`).

2. **`:global`** — the buffer-local `org-cycle-global-status` symbol
   (`overview` / `contents` / `all` / `nil`), i.e. the current S-TAB level.

3. **`:top-id`** — a scroll anchor. Raw `window-start` is a char offset that is meaningless
   after a full rebuild, so anchor to content instead: the `MW_ID` of the entity heading
   at or after the live window's `window-start`. `nil` when there is no live window (the
   common case during a background auto-sync) — scroll restore is then skipped.

### `mindwtr-reconcile--restore-view` (snap)

Wrapped in `condition-case` (catch `error`, return `nil`) so a fold/redisplay hiccup can
**never** abort a sync — reconcile runs *after* the server PUT has already committed, so it
must not throw.

1. **Global backdrop first:** `overview` → `org-overview`; `contents` → `org-content`;
   `all`/`nil` → leave the freshly-inserted (fully shown) buffer as is.
2. **Per-entity fold state, top-down:** walk `MW_ID` headings via `org-map-entries`. If the
   id is in `:folded` → `org-fold-hide-subtree`; otherwise → `org-fold-show-entry` (reveals
   the entity's own body, leaving descendants to their own iteration). This re-derives every
   entity heading's visibility explicitly on top of the backdrop, so even if `org-overview`
   collapsed a container, the entities the user had open are reopened.
3. **Scroll:** if there is a live window and `:top-id` still resolves to a heading,
   `set-window-start` to that heading's `line-beginning-position`.

### Invariants

- **Must not throw.** Restore runs post-PUT; any failure inside it is swallowed so the sync
  still reports success and the rebuilt buffer is left intact.
- **Must not perturb the modified flag.** The `erase-buffer`+`insert` already marks the
  buffer modified; the fold/scroll operations touch only visual state (org-fold overlays and
  `window-start`), never content. Do not wrap restore in anything that would clear or
  re-stamp `buffer-modified-p`. The buffer's dirty state after reconcile is identical with
  or without this change — confirmed orthogonal to whether the buffer was saved at sync time.

## Interaction with unsaved buffer / in-flight edits (no change required)

For the record, since it was raised during design:

- The **buffer**, not the file, is the sync source of truth (`mindwtr-parse-buffer`), so
  unsaved edits present when a periodic/focus sync fires are pushed correctly.
- Edits made *during* the PUT/GET round-trip are caught by the existing
  `buffer-chars-modified-tick` guard (`mindwtr-sync.el`), which aborts the reconcile and
  leaves the user's in-progress edits untouched — snapshot/restore never runs in that case.
- A successful reconcile leaves the buffer modified-but-unsaved, exactly as today.

This feature changes none of the above.

## Known limitations (faithful to the issue's "less correct on moves")

- Container fold state is only approximated by the global backdrop, not preserved per heading.
- Point lands on the entity heading-start; cursor column / in-body position is not preserved.
- An entity that was self-folded *under* a folded ancestor is not re-folded (we skip
  recording it); when its ancestor is later expanded it appears open. Edge case.
- On a status change that relocates an entity to a different bucket, the fold state still
  follows the entity by `MW_ID` (it is re-folded in its new location) — so the stopgap
  actually handles moves better than the issue feared, because fold state is keyed by id,
  not position. The remaining "less correct" part is purely the container/ancestor cases above.

## Testing

New ERT tests in `test/mindwtr-reconcile-test.el`:

1. A folded task heading stays folded across a reconcile that changes an **unrelated** entity.
2. An unfolded heading stays unfolded across a reconcile.
3. Global `overview` is reapplied after a rebuild.
4. A task that changes status (bucket relocation) keeps its fold state in the new bucket.
5. Reconcile with **no live window** does not error and still restores fold state (covers the
   batch / background-sync path).
6. Restore is resilient: a reconcile completes and the buffer is correctly rebuilt even when
   fold operations are constrained (batch mode), proving the `condition-case` guard.
