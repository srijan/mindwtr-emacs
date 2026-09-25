---
title: "Conflict shows areaId overridden to (empty): the server's sync-repair cleared a reference to a deleted area"
date: 2026-09-25
category: integration-issues
module: mindwtr-report
problem_type: integration_issue
component: tooling
symptoms:
  - "Sync report says '1 local edit(s) overridden by newer remote edits' for a task you just gave an area"
  - "Conflict diff shows areaId with yours = the area id and server = (empty)"
  - "The winning server entity has a bumped rev and revBy \"sync-repair\""
  - "No other device edited the task itself"
root_cause: concurrency
resolution_type: code_fix
severity: medium
tags: [sync, report, conflict, rev-by, sync-repair, area-id, integrity-repair, server-behaviour, issue-28]
---

# Conflict shows areaId overridden to (empty): the server's sync-repair cleared a reference to a deleted area

## Problem

A task's area edit made in Emacs came back as a conflict with the server's `areaId` empty
(GitHub issue #28). Emacs sent the correct value. The Mindwtr server runs an integrity pass on
every write, and that pass emptied the reference because the area had been deleted on another
device. The pass writes a new revision stamped `revBy: "sync-repair"`, so it wins the merge and
looks the same as a real concurrent edit in the report.

## Symptoms

- Report: `1 local edit(s) overridden by newer remote edits.` followed by
  `areaId  yours : <area-id>  server: (empty)`.
- The server copy of the task carries a higher `rev` and `revBy "sync-repair"`, not a device id.
- It happens once, not every sync. Hitting it needs a race between this device's area
  assignment and another device deleting, or merging, that area.

## What Didn't Work

- **Suspecting the app drops `areaId` on standalone tasks.** Upstream's `Task` type carries
  `areaId`, the desktop editor reads and writes it, and the task merge allow-list has included it
  since upstream v1.1.0. A PUT of a standalone task with a live area to a 1.2.0 server and a GET
  back returned the area unchanged at the same `rev`/`revBy`. Nothing strips it systematically
  (issue #28 investigation).
- **Reproducing with a single PUT carrying the dangling reference.** `PUT /v1/data` validates the
  request body before merging, and a live task pointing at a deleted or missing area is rejected
  with 400 (`Invalid data: live task … references missing or deleted area …`,
  `apps/cloud/src/server-validation.ts:416-418` in the upstream checkout). The silent clear only
  happens when the payload is valid on its own and the area's tombstone is already in the stored
  data it merges with.

## Solution

No sync-engine change was needed. The fix (PR #47, closing #28) makes the report show who wrote
the winning server version, so this case can be told apart from a real edit on another device.
In `mindwtr-report.el`, each conflict block now prints the server entity's `revBy`:

```elisp
(let ((by (plist-get theirs :revBy)))
  (when by
    (insert (if (equal by "sync-repair")
                "      server edit by: sync-repair (server integrity repair, e.g. a referenced area or project was deleted)\n"
              (format "      server edit by: %s\n" by)))))
```

Nothing is printed when the server entity has no `revBy`. Covered by
`mindwtr-report-conflict-attributes-sync-repair`, `-attributes-device` and
`-no-revby-no-attribution-line` in `test/mindwtr-report-test.el`.

Reading the line:

- `server edit by: sync-repair` — the server tidied a reference. Restoring your edit (`r`) will
  not help if the area is gone: the same PUT will now be rejected, or repaired again. Choose a
  live area instead.
- `server edit by: <device id>` — a real concurrent edit. `r` is the right remedy.

## Why This Works

The server behaviour, read from the upstream core checkout (`~/workspace/srijan/Mindwtr`, at
`v1.3.1-133`; the smoke gate pins server 1.3.1):

- `packages/core/src/sync-types.ts:92`: `export const SYNC_REPAIR_REV_BY = 'sync-repair';`
- `PUT /v1/data` validates the body, then calls `mergeAppDataWithStats`, which finishes with
  `repairMergedSyncReferences(...)` (`packages/core/src/sync.ts:1173`). REST writes go through
  `finalizeCloudDataForWrite`, which runs the same repair (`apps/cloud/src/server.ts:357-372`).
- Every repaired entity goes through `withRepairRevision` (`packages/core/src/sync-normalization.ts:364-371`):

  ```ts
  rev: item.revBy === SYNC_REPAIR_REV_BY ? rev : nextRevision(item.rev),
  revBy: SYNC_REPAIR_REV_BY,
  ```

  The first repair bumps `rev`, so under revision-aware LWW the repaired copy beats the edit the
  client just proposed. Later repairs of an entity already stamped `sync-repair` keep its `rev`.

What `repairMergedSyncReferences` changes (`sync-normalization.ts:373-568`):

| Entity | Trigger | Effect |
|--------|---------|--------|
| Area | Two live areas share a name | Duplicates are merged (`dedupeLiveAreasByName`). References to the dropped id are remapped, not emptied |
| Project | `areaId` points at a deleted or missing area | `areaId` and `areaTitle` cleared |
| Project | Live area's name differs from `areaTitle`, or `areaId` was remapped | `areaId`/`areaTitle` rewritten |
| Section | Parent project deleted | Section tombstoned (`deletedAt` set) |
| Task | `projectId` points at a deleted project | `projectId` and `sectionId` cleared, `order`/`orderNum` dropped |
| Task | `projectId` points at a missing project | `projectId` cleared |
| Task | `areaId` points at a deleted or missing area | `areaId` cleared (the #28 case) |
| Task | Container conflict per `resolveTaskContainerHierarchy` (`packages/core/src/task-container-rules.ts:53`) | `sectionId` dropped when its section is gone or belongs to another project; `projectId` taken from the section when missing; `areaId` dropped whenever `projectId` is set |
| Settings | `gtd.defaultAreaId` was a deduped area | Remapped (no rev stamp) |

Other code also stamps `sync-repair` without touching references: purged-tombstone compaction
(`sync-normalization.ts:217`, `:296`, `tombstone-compaction.ts:111`), keeping a recurrence
`seriesId` (`sync.ts:314`), and filling a missing area `order` (`sync.ts:814`). A `sync-repair`
conflict usually means a reference was cleaned up, but the field diff under it shows what
actually changed.

## Prevention

- **Check `revBy` before treating an override as a client bug.** `sync-repair` means the server
  changed the data. Any other value names the device that wrote it.
- **Rule out the client-side cause of the same symptom.** `areaId -> (empty)` can also come from
  Emacs. Before PR #67, an archived or cancelled task's area was rendered as `:CATEGORY:` in the
  archive file, and the parser resolved that name against area headings in the archive buffer,
  which has none. That produced a *proposed* change (`areaId -> (empty)` in the outgoing list),
  not a conflict. PR #67 builds the name-to-id map once from the main file and passes it to every
  surface. Outgoing proposal = client bug; conflict with `revBy sync-repair` = server repair.
- **Emit one container per task.** `resolveTaskContainerHierarchy` strips `areaId` from any task
  that has a `projectId`. A parser regression that stamps both (see
  `parser-single-most-specific-container-id.md`) would come back as a `sync-repair` conflict
  on every task in a project.
- **To reproduce against a real server,** use two PUTs: (1) a standalone task with a live
  `areaId`; (2) a tombstone for that area with the task left out. The GET returns the task with
  `areaId` null, a bumped `rev` and `revBy "sync-repair"`. A single PUT containing the dangling
  reference gets a 400 and never reaches the repair.

## Related Issues

- GitHub issue #28 (investigation with the live 1.2.0 repro), closed by PR #47.
- PR #67 — the client-side `areaId -> (empty)` from archive-file `:CATEGORY:` resolution.
- `docs/solutions/logic-errors/parser-single-most-specific-container-id.md` — why the parser emits
  one container id; the server repair enforces the same rule.
- `docs/solutions/design-patterns/single-classifier-feeds-summary-and-detail.md` — how the report's
  conflict and field-diff blocks are built.
