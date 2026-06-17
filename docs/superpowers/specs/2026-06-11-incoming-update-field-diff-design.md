# Sync Report Change Detail

**Date:** 2026-06-11
**Status:** Approved

## Problem

The sync report lists counts but no detail for either direction of change:

**Local (proposed)** — only a count line, no list of what was pushed:
```
  Proposed — Created: 0   Updated: 2   Deleted: 0
  No conflicts. All local edits accepted.
```

**Remote (incoming)** — titles are listed but `updated` entries carry no field-level detail:
```
  Incoming from remote:
    ↓ Follow up and reply to the vendor (task) — updated
    ↓ tidy the garage shelves (task) — updated
```

After a sync the user has no signal about what actually changed in either direction.

## Goal

Show a per-entity list for both proposed and incoming changes. For `updated` entries in both directions, show one line per changed content field below the entity headline. The full target output:

```
  Proposed — Created: 1   Updated: 2   Deleted: 0
    ↑ New grocery list (task) — created
    ↑ Follow up with the supplier (task) — updated
        status: NEXT → DONE
        completedAt: (empty) → 2026-06-11T19:00
    ↑ Old reminder (task) — deleted
  Incoming from remote:
    ↓ Follow up and reply to the vendor (task) — updated
        status: DONE → ARCH
        projectId: (empty) → b1c2d3e4-0000-4000-8000-000000000001
    ↓ tidy the garage shelves (task) — updated
        status: DONE → ARCH
```

`created` and `deleted` entries show title only — no diff.

---

## Feature 1: Field diff for incoming remote `updated` entries

### Data flow

`mindwtr-sync--incoming-changes` already has both the shadow entity `s` (pre-sync baseline) and the merged entity `m` (post-sync server value) in scope when it classifies an `updated` change. Currently it discards them.

**Change:** add `:before s :after m` to the plist pushed for `updated` entries only:

```elisp
(push (list :id id :kind kind
            :title (mindwtr-model-entity-title m)
            :change 'updated
            :before s :after m)
      out)
```

No other cases (created, deleted) receive `:before`/`:after`.

### Rendering

In `mindwtr-report--insert-entry`, for each incoming change that is `updated` and carries `:before`/`:after`, call the existing `mindwtr-report--field-diff` and emit one indented line per changed field:

```
        field: old-value → new-value
```

8-space indent (4 more than the `↓` line). Field names strip the leading colon. Values pass through `mindwtr-report--fmt` (nil → `"(empty)"`, strings as-is, others `prin1`).

If `mindwtr-report--field-diff` returns nil (signatures differed but no content field changed), no diff lines are emitted.

### Module boundaries

No boundary changes. `mindwtr-sync.el` stores raw entity plists in the data structure; `mindwtr-report.el` calls `mindwtr-report--field-diff` as it already does for conflicts.

### Tests

- `mindwtr-sync-test.el`: assert that an `updated` incoming change carries `:before` and `:after` keys; assert that `created` and `deleted` entries do not.
- `mindwtr-report-test.el`: assert that an `updated` incoming change with differing `:before`/`:after` renders the field diff lines; assert that identical content fields produce no diff lines.

---

## Feature 2: Per-entity list for local proposed changes

### New function: `mindwtr-sync--local-changes`

A new function `(mindwtr-sync--local-changes local shadow)` mirrors the structure of `mindwtr-sync--incoming-changes` but compares `local` vs `shadow`:

- **created** — local entity whose id is absent from the shadow (or has no id yet). `:change 'created`, title from the local entity.
- **updated** — local entity whose content signature differs from its shadow twin. `:change 'updated`, `:before se :after le`.
- **deleted** — shadow entity absent from local, not already tombstoned, not rendered-absent (same three-part guard as `mindwtr-sync--stats`). `:change 'deleted`, title from the shadow entity.

Classification reuses `mindwtr-sync--classify` so the listed entities match what `stats` counts exactly — no drift between the count line and the detail list.

Return shape per element: `(:id ID :kind KIND :title TITLE :change CHANGE)` for created/deleted; additionally `:before SE :after LE` for updated.

### Call site

Computed at the same point as `incoming` (after `stats`, using the same `local` and `shadow` bindings). Passed to `mindwtr-report-show` as a new optional `local-changes` parameter added after the existing `incoming-changes` parameter.

The noop path (HEAD-match, `local-dirty` is false) never reaches this code — there are no local changes to list there.

### Rendering

In `mindwtr-report--insert-entry`, when `local-changes` is non-nil, emit the list immediately after the "Proposed" count line. Each entry uses `↑` (upward arrow, outgoing) instead of `↓`. Updated entries get the same 8-space-indented field diff as incoming updated entries. Format:

```
  Proposed — Created: X   Updated: Y   Deleted: Z
    ↑ Entity title (kind) — created
    ↑ Entity title (kind) — updated
        field: before → after
    ↑ Entity title (kind) — deleted
```

`mindwtr-report--change-label` already handles all three symbols; no new label mapping needed.

### Module boundaries

`mindwtr-sync--local-changes` lives in `mindwtr-sync.el` alongside `mindwtr-sync--incoming-changes`. `mindwtr-report.el` gains a `local-changes` parameter in `mindwtr-report-show` and `mindwtr-report--insert-entry`; rendering reuses `mindwtr-report--field-diff` and `mindwtr-report--fmt` unchanged.

### Tests

- `mindwtr-sync-test.el`: assert creates, updates (with `:before`/`:after`), and deletes are classified correctly; assert entity counts match `mindwtr-sync--stats` for the same local/shadow inputs.
- `mindwtr-report-test.el`: assert local-changes list renders with `↑` arrows and correct field diff for updated entries; assert nil `local-changes` produces no extra output.

---

## Out of scope

- Diff display for `created` or `deleted` entries in either direction.
- Truncating long field values (descriptions, checklists) — `mindwtr-report--fmt` is used as-is.
- Any change to conflict rendering.
