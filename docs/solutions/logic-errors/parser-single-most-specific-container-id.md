---
title: "Parser containment must match upstream's canonical form: no area on a project task, and a section carries its project"
last_updated: 2026-09-25
date: 2026-06-03
category: logic-errors
module: mindwtr-parse
problem_type: logic_error
component: tooling
symptoms:
  - "Phantom areaId drift on every task inside a project, even when areaId was never touched"
  - "After sync, the server-side areaId was cleared, silently re-parenting tasks"
  - "Signature comparison always shows the task as locally-changed vs the server snapshot"
  - "Complementary projectId drift (nil to a uuid) in the other direction"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [parser, containment, area-id, project-id, drift, signature, round-trip]
---

# Parser containment must match upstream's canonical form

## Problem
Upstream's canonical containment for a task (`resolveTaskContainerHierarchy`, Mindwtr core
`task-container-rules.ts`) is: a task in a project has **no** `areaId`, and a task in a section
carries the section **and** that section's `projectId`.  (This doc originally said section and
project were mutually exclusive too; that was wrong -- see "Second drift" below.) The initial parser stamped *every* non-nil
ancestor ID onto a task simultaneously, so a task under `* Projects / My Project` received both
`:projectId` and a spurious `:areaId` (from the grandparent area). That made the parsed entity
structurally different from the server's canonical form on every cycle — a phantom-drift loop.

## Symptoms
- Every task inside a project showed `areaId` drift each sync, untouched by the user.
- A sync that PUT the over-stamped entity cleared the server-side `areaId`, silently re-parenting.
- The task's content signature never matched the server snapshot, so it re-synced forever.

## What Didn't Work
The buggy `mindwtr-parse-buffer` task branch (commit `be77e92`) walked all three ancestor kinds
and set each one it found:

```elisp
;; BUGGY — stamps projectId AND areaId on a task-in-project
(let ((pid (mindwtr-parse--ancestor-id 'project))
      (sid (mindwtr-parse--ancestor-id 'section))
      (aid (or (mindwtr-parse--prop "MW_AREA_ID") (mindwtr-parse--ancestor-id 'area))))
  (when pid (setq e (plist-put e :projectId pid)))
  (when sid (setq e (plist-put e :sectionId sid)))
  (when aid (setq e (plist-put e :areaId aid))))
```

Meanwhile reconcile's placement helper already used the most-specific rule
`(or sectionId projectId areaId)` — so the parser emitted three parallel IDs while reconcile
consumed only the innermost, a direct contradiction. Keeping the `MW_AREA_ID` property override
alongside the ancestor walk didn't help: both sources produced the same spurious `:areaId`.

## Solution
Make the task containment `cond` exclusive, and move area resolution to an explicit drawer
property (commits `ff28188`, `4a26292`; since `8121472` that property is org's native
`:CATEGORY:`, with `:MW_AREA:` read only as a legacy fallback).

Task branch now (`mindwtr-parse.el:403-416`):

```elisp
('task
 (let ((sid (or (mindwtr-heading-prop "MW_SECTION_ID")
                (mindwtr-heading-ancestor-id 'section)))
       (pid (or (mindwtr-heading-prop "MW_PROJECT_ID")
                (mindwtr-heading-ancestor-id 'project))))
   (when sid (setq e (plist-put e :sectionId sid)))
   (when pid (setq e (plist-put e :projectId pid))))   ; section carries its project; no areaId from outline
 (push (mindwtr-parse--strip-internal e) tasks))
```

The explicit `MW_SECTION_ID`/`MW_PROJECT_ID` props are the archive surface's cross-file
carrier and win over ancestry per axis.

**Second drift (2026-09-25).** The first fix made section and project exclusive as well, so a
sectioned task created in the app (which carries both) parsed as `sectionId` only and every sync
pushed `projectId -> (empty)`; the server's repair restores it, so it churned forever.  Found by
`mindwtr-invariant-fixture-is-in-step` (`test/mindwtr-invariant-test.el`), the first check whose
fixture held a sectioned task with a project.  The parser now sets both.

`:areaId` is no longer derived from outline nesting for tasks. It comes only from an explicit
`:CATEGORY:` property (legacy `:MW_AREA:` fallback), resolved post-loop for every kind through
a `name->id` hash (`mindwtr-parse.el:339-342`):

```elisp
(let ((aid (mindwtr-parse--area-id
            (or (mindwtr-heading-prop "CATEGORY")
                (mindwtr-heading-prop "MW_AREA")))))
  (when aid (setq e (plist-put e :areaId aid))))   ; nil for tasks with no CATEGORY → nothing set
```

`:areaId :projectId :sectionId` are all in `mindwtr-model-content-fields` (`mindwtr-model.el:165`),
which is why a spurious `:areaId` always surfaced as signature drift.

## Why This Works
The parser now emits exactly upstream's canonical form: `{projectId}` or `{sectionId, projectId}`
for a project task, never an `areaId` alongside a project. The `:CATEGORY:`
property is written by the renderer *iff* `:areaId` is set and resolvable
(`mindwtr-render.el:188-191`), and read back through `mindwtr-parse--area-id` — closing the
round-trip. A task without an area has no `:CATEGORY:` property and so no spurious `areaId`.

## Prevention
- Take the containment rule from upstream's `resolveTaskContainerHierarchy`, not from memory, and
  state it **once**,
  near `mindwtr-model-content-fields`, so parser and reconcile share one source of truth instead
  of encoding it independently — the contradiction here came from two independent encodings.
- Covered by the areaId/CATEGORY parse test `mindwtr-parse-area-from-property` in
  `test/mindwtr-parse-test.el` (~:106).

## Related Issues
- Commit `ff28188` fixed this alongside the signature deny-list → allow-list transition
  ([[content-signature-allow-list-not-deny-list]]) in the same live smoke session.
- Commit `4a26292` introduced `MW_AREA:` as the area-id carrier, replacing outline nesting; superseded as carrier by `:CATEGORY:` in `8121472`.
