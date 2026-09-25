---
title: Parser must store only the single most-specific container ID
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

# Parser must store only the single most-specific container ID

## Problem
The Mindwtr server model stores exactly **one** container reference per task — section overrides
project overrides area, whichever is innermost. The initial parser stamped *every* non-nil
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
   (cond (sid (setq e (plist-put e :sectionId sid)))
         (pid (setq e (plist-put e :projectId pid)))))   ; exclusive; no areaId from outline
 (push (mindwtr-parse--strip-internal e) tasks))
```

The explicit `MW_SECTION_ID`/`MW_PROJECT_ID` props are the archive surface's cross-file
carrier and win over ancestry per axis; the section-over-project exclusivity is unchanged.

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
The server's single-reference model and the parser's `cond` gate now agree: a task carries
exactly one of `{sectionId, projectId}` (or neither, if standalone), never both. The `:CATEGORY:`
property is written by the renderer *iff* `:areaId` is set and resolvable
(`mindwtr-render.el:188-191`), and read back through `mindwtr-parse--area-id` — closing the
round-trip. A task without an area has no `:CATEGORY:` property and so no spurious `areaId`.

## Prevention
- State the containment rule (section > project > area, mutually exclusive for tasks) **once**,
  near `mindwtr-model-content-fields`, so parser and reconcile share one source of truth instead
  of encoding it independently — the contradiction here came from two independent encodings.
- Covered by the areaId/CATEGORY parse test `mindwtr-parse-area-from-property` in
  `test/mindwtr-parse-test.el` (~:106).

## Related Issues
- Commit `ff28188` fixed this alongside the signature deny-list → allow-list transition
  ([[content-signature-allow-list-not-deny-list]]) in the same live smoke session.
- Commit `4a26292` introduced `MW_AREA:` as the area-id carrier, replacing outline nesting; superseded as carrier by `:CATEGORY:` in `8121472`.
