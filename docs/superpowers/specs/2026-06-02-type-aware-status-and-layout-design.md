# Mindwtr Org Layout v3 — Type-Aware Status, Buckets & Eager Relocation — Design

**Date:** 2026-06-02
**Status:** Approved design, pre-implementation
**Supersedes:** the file-layout, status→list mapping, and container sections of
`2026-06-01-mindwtr-gtd-list-layout-design.md` (v2). The containment-via-property
(`MW_AREA`), ordering, archived-handling, recurrence-rendering, and round-trip
sections of v2 are unchanged and still apply. The sync engine, shadow, signature,
conflict handling, backoff, and HTTP layers are untouched.

## Goal

Two coupled changes:

1. **Layout reorg.** Reshape the rendered GTD lists: merge Waiting standalone
   tasks into a renamed **Single Actions** bucket, split projects by status into
   active/waiting (top-level `* Projects`) vs. someday (`* Someday » Projects`),
   and introduce a `* Someday` parent container holding its own Single Actions
   and Projects sub-buckets.

2. **Interactive type-awareness.** When the package is loaded and `mindwtr-mode`
   is active, make it impossible (via interactive paths) to give a task a
   project-only status or vice-versa, set status through a type-aware
   `C-c C-t` replacement, and **eagerly relocate** a standalone task or project
   to its correct bucket on status change — without waiting for the next sync.
   A parser/validator **backstop** keeps unpoliceable paths (raw typing, capture,
   files edited outside the mode) from aborting a sync.

Re-parenting a task into/out of a project stays on native `org-refile` — no new
code — because containment is already outline nesting.

### Why

- Projects and tasks share one TODO keyword palette
  (`INBOX NEXT WAIT SOMEDAY REF ACTIVE | DONE ARCH`) but have **disjoint valid
  status subsets**. Today, assigning a type-invalid keyword (e.g. `NEXT` on a
  project) makes `mindwtr-model-keyword->status` throw and **aborts the entire
  sync** — the same cliff as the recently fixed `nil`-status bug. The interactive
  guard removes the common cause; the backstop removes the cliff.
- For a standalone task, the top-level bucket is derived from status at render
  time — the `:MW_LIST:` container is cosmetic, and hand-refiling between
  top-level lists is a no-op the next sync would redo. The only genuine
  structural move is into/out of a project (real re-parenting). The layout reorg
  leans into this: merging next+waiting+done into one bucket means the most
  common transitions (NEXT↔WAIT↔DONE) need neither a refile nor a relocation.
- Eager relocation keeps the buffer self-consistent between syncs instead of
  showing, say, a `SOMEDAY` task sitting under `* Single Actions` until the next
  reconcile rebuilds the file.

This is a presentation/parse/interaction change. `AppData`, entity fields, ids,
`rev`, change detection, server merge, and conflict reporting are untouched —
`parse(buffer) ⊕ shadow` must still reconstruct the same entities.

## File layout

Fixed top-level **list containers** (synthetic, never synced), in this order,
followed by the **Areas of Focus** reference section. `* Someday` is a container
whose children are themselves containers:

```org
#+TODO: INBOX(i) NEXT(n) WAIT(w) SOMEDAY(s) REF(r) ACTIVE(a) | DONE(d) ARCH(x)
* Inbox
  :PROPERTIES: :MW_TYPE: container :MW_LIST: inbox :END:
** INBOX Capture from meeting
   :PROPERTIES: :MW_TYPE: task :MW_ID: c3c2… :END:
* Single Actions
  :PROPERTIES: :MW_TYPE: container :MW_LIST: single-actions :END:
** NEXT Draft the quarterly planning notes
   :PROPERTIES: :MW_TYPE: task :MW_ID: 4431… :MW_AREA: Personal :END:
** WAIT Reply from the vendor
   :PROPERTIES: :MW_TYPE: task :MW_ID: 88aa… :END:
** DONE Decide and order the standing desk                  ← done lingers here until archived
* Projects
  :PROPERTIES: :MW_TYPE: container :MW_LIST: projects :END:
** ACTIVE Warranty claim for the router                  ← active + waiting; grouped by area, then :order
   :PROPERTIES: :MW_TYPE: project :MW_ID: 174f… :MW_AREA: Personal :END:
*** NEXT Research warranty options      ← project's tasks stay nested (any status)
    :PROPERTIES: :MW_TYPE: task :MW_ID: bd6a… :END:
** WAIT Expense the new laptop                       ← a waiting project sits here too
   :PROPERTIES: :MW_TYPE: project :MW_ID: ed8a… :MW_AREA: Work :END:
* Someday
  :PROPERTIES: :MW_TYPE: container :MW_LIST: someday :END:
** Single Actions
   :PROPERTIES: :MW_TYPE: container :MW_LIST: someday-single-actions :END:
*** SOMEDAY Learn woodworking
    :PROPERTIES: :MW_TYPE: task :MW_ID: 9f01… :END:
** Projects
   :PROPERTIES: :MW_TYPE: container :MW_LIST: someday-projects :END:
*** SOMEDAY Build a cabin                          ← someday project subtree lives under here
    :PROPERTIES: :MW_TYPE: project :MW_ID: a8a8… :END:
* Reference
  :PROPERTIES: :MW_TYPE: container :MW_LIST: reference :END:
** REF Office printer setup
   :PROPERTIES: :MW_TYPE: task :MW_ID: 5dd2… :END:
* Areas of Focus
  :PROPERTIES: :MW_TYPE: container :MW_LIST: areas :END:
** Personal
   :PROPERTIES: :MW_TYPE: area :MW_ID: f215… :END:
** Work
   :PROPERTIES: :MW_TYPE: area :MW_ID: fad1… :END:
```

### Container tree

The container set is now a small **tree**, not a flat list. Each node has a
stable `:MW_LIST:` role, a default title, and an outline level:

```
inbox                       (level 1)
single-actions              (level 1)
projects                    (level 1)
someday                     (level 1)
  someday-single-actions    (level 2)
  someday-projects          (level 2)
reference                   (level 1)
areas                       (level 1)
```

- Every container heading carries `:MW_TYPE: container` and its `:MW_LIST:`
  discriminator. `MW_LIST` — not the heading text — locates a list, so the user
  may rename the visible heading. Containers carry no `MW_ID`, are never sent to
  the server, and are skipped by the parser (which already ignores
  `MW_TYPE: container`).
- Container headings are **transparent to ancestry**: `mindwtr-parse--ancestor-id`
  matches on a specific `MW_TYPE` (`project`/`section`/`area`), so nesting a
  standalone task or a whole project under one or two container levels does not
  change what the parser derives. A someday standalone task under
  `* Someday » ** Single Actions` parses as a standalone task (no
  project/section ancestor); a someday project under `* Someday » ** Projects`
  parses with no container-derived parent.
- Reconcile creates any missing container on demand and keeps the fixed tree
  order/levels above. **Empty lists still render** (stable structure, valid
  refile targets, valid relocation targets).

## Status → bucket mapping

| Entity | Status | Bucket (`MW_LIST`) | TODO keyword |
|---|---|---|---|
| task (standalone) | inbox | `inbox` | INBOX |
| task (standalone) | next | `single-actions` | NEXT |
| task (standalone) | waiting | `single-actions` | WAIT |
| task (standalone) | done | `single-actions` (in place) | DONE |
| task (standalone) | someday | `someday-single-actions` | SOMEDAY |
| task (standalone) | reference | `reference` | REF |
| task (standalone) | archived | *not rendered* | (ARCH) |
| task (in a project/section) | *any* | stays nested under its project/section | — |
| project | active | `projects` | ACTIVE |
| project | waiting | `projects` | WAIT |
| project | someday | `someday-projects` | SOMEDAY |
| project | archived | *not rendered* | (ARCH) |

- **Done standalone tasks stay in Single Actions** with `DONE`; they linger until
  archived.
- **Project tasks never relocate by status** — a project's done/reference/someday
  tasks stay nested under the project (matching the data, where they keep their
  `projectId`/`sectionId`).
- The bucket a heading sits under is derived from status on render; on parse the
  status comes from the TODO keyword and the container is ignored. The two never
  disagree because status is single-sourced from the keyword.

## Interactive layer (mode-scoped)

All of this lives in `mindwtr-mode-map` and is active **only** in `mindwtr-mode`.
Outside the mode, org behaves normally and sync still works (consistent with the
existing "sync works without the mode" promise).

### `mindwtr-set-status` — the `C-c C-t` replacement

- Bound in `mindwtr-mode-map`, shadowing `org-todo`.
- Reads `MW_TYPE` at point and offers **only** that kind's keywords, with their
  fast-access keys:
  - task → `INBOX(i) NEXT(n) WAIT(w) SOMEDAY(s) REF(r) | DONE(d) ARCH(x)`
  - project → `ACTIVE(a) WAIT(w) SOMEDAY(s) | ARCH(x)`
  - On a `container` heading or a heading with no `MW_TYPE`, fall back to plain
    `org-todo`.
- Presents the choice via a single `read-char-choice`-style prompt keyed by the
  fast keys; the chosen keyword is applied with `(org-todo "WAIT")`.
- After the keyword is set, it runs **bucket relocation** (below).

### Type-aware cycling (enforcement level **b**)

- Remap `S-<right>` / `S-<left>` in `mindwtr-mode-map` to wrappers that cycle only
  through the **valid keywords for the entity at point** (skipping the others in
  the shared sequence), then run bucket relocation. On a container/typeless
  heading, fall back to `org-shiftright`/`org-shiftleft`.
- This makes every interactive keystroke path type-correct. Raw text edits,
  capture, and programmatic `org-todo` are intentionally **not** intercepted —
  they are covered by the backstop.

### Bucket relocation

A shared helper invoked after any status change made through the commands above:

- Determine the entity kind from `MW_TYPE`.
- **Standalone task** (no `projectId`/`sectionId` ancestor): compute the target
  bucket from the new status (table above). If it differs from the container the
  heading currently sits under, **refile the subtree** under the target container
  heading (located by `MW_LIST`). Reuses org's outline move; the heading's level
  is adjusted to sit directly under the container.
- **Project**: compute the target bucket (`projects` vs `someday-projects`). If it
  differs, move the **entire project subtree** (sections + tasks) under the target
  container.
- **Project task / section**: never relocate (status change stays in place).
- **Archived edge:** `archived` has no bucket. On setting a standalone task or a
  project to `ARCH`, **leave the heading in place**; the next sync drops it (the
  sync report already notes removals). Eagerly deleting a heading the user is
  looking at is more surprising than a one-sync delay.
- If the target container heading does not exist in the buffer (e.g. a
  hand-trimmed file), create it in its fixed tree position before refiling. Empty
  containers normally render, so this is a safety net.

## Backstop — graceful degradation for unpoliceable paths

A keyword can still be org-recognized but invalid for its type when it arrives via
raw typing, capture, or a file edited outside `mindwtr-mode`. Today this throws
and aborts the sync. New behavior:

- Add `mindwtr-model-keyword->status-safe (kind keyword)` returning `nil` instead
  of erroring on a type-invalid keyword. `mindwtr-model-keyword->status` (the
  erroring form) is kept for internal call sites that require validity.
- In `mindwtr-parse-heading`, use the safe form. On a type-invalid keyword,
  **omit `:status`** from the parsed entity (do not throw) and record the heading
  in a warnings accumulator.
- Shadow-merge then preserves the entity's **prior status** (existing entity), so
  nothing is lost and the sync proceeds. For a **new** entity with no prior status,
  fall back to a type default: task → `inbox`, project → `active`.
- The skipped headings are surfaced in the `*Mindwtr Sync Report*` so the mismatch
  is visible, not silent.

This is the same "degrade, don't abort" principle as the keyword-registration fix.
It also means `mindwtr-model-validate-appdata` will not see a `nil` task status
arising from this path (the parser now supplies a status or the shadow does).

## Module impact

| File | Change |
|---|---|
| `mindwtr-model.el` | Replace the flat `mindwtr-model-list-roles`/titles with the **container tree** (role, title, level, children) and helpers to walk it. Update `mindwtr-model--status->list` for the new buckets (`single-actions`, `someday-single-actions`) and add a **project** status→bucket map (`projects`, `someday-projects`). Add `mindwtr-model-keyword->status-safe`. Add per-kind valid-keyword accessors for the menu/cycling. |
| `mindwtr-render.el` | Render the nested container tree (recurse over the tree, emit containers at their levels, place standalone tasks by status bucket and projects by status bucket). Keep area grouping/order within `* Projects` and `* Someday » Projects`. |
| `mindwtr-parse.el` | Use `mindwtr-model-keyword->status-safe`; on a type-invalid keyword omit `:status` and accumulate a warning. Container-tree nesting is already transparent to ancestry. |
| `mindwtr-reconcile.el` | Build/maintain the container **tree** (create missing nodes in fixed order/levels); place each entity by status/type bucket; reuse the existing rebuild machinery. |
| `mindwtr-commands.el` *(new)* | `mindwtr-set-status`, the `S-<arrow>` cycling wrappers, the bucket-relocation helper, and the `mindwtr-mode-map` bindings (`C-c C-t`, `S-<left>`, `S-<right>`). |
| `mindwtr.el` | Require `mindwtr-commands`; wire the keymap into `mindwtr-mode`. Surface backstop warnings in the sync report. |

Re-parenting into/out of a project: native `org-refile` (`C-c C-w`), no code.

## Round-trip & sync correctness (preserved)

- `signature(parse(render(x)) ⊕ shadow) == signature(x)` for unchanged content
  must still hold. The container tree is transparent to ancestry, and status is
  still single-sourced from the keyword, so the new buckets do not change parsed
  containment. Covered by round-trip tests.
- The blast-radius gate, conflict detection, backoff, HEAD short-circuit, and
  UTF-8 handling are unaffected.
- Eager relocation only **moves** existing headings within the buffer; it does not
  alter any synced field, so it cannot perturb a content signature. (The bucket a
  task lands in is not a parsed field.)

## Migration

No released version exists and the shadow is a rebuildable cache. An existing
v2-layout `~/mindwtr.org` is migrated on the next sync: the parser reads it
(buckets are presentational; status comes from keywords), and reconcile rewrites
the file in the v3 tree. Re-running `mindwtr-bootstrap` also produces the v3
layout. No in-place file migration is built.

## Testing strategy

- **Layout (golden):** render empty appdata → the full container tree in order
  with correct levels; render populated appdata → standalone next/waiting/done in
  `* Single Actions`, someday standalone under `* Someday » Single Actions`,
  active and waiting projects under `* Projects`, someday project subtree under
  `* Someday » Projects`, reference under `* Reference`.
- **Bucket relocation:** `mindwtr-set-status` moves a standalone task
  next→someday→reference→next, each time landing under the right container;
  moves a project active→someday (whole subtree, sections+tasks) and back; a
  **project task** status change (NEXT→DONE) does **not** relocate it; setting a
  standalone task to ARCH leaves it in place.
- **Type-aware menu:** task menu offers no `ACTIVE`; project menu offers no
  `INBOX`/`NEXT`/`REF`; a container heading falls back to `org-todo`.
- **Type-aware cycling:** `S-<right>` on a project visits only `ACTIVE`/`WAIT`/
  `SOMEDAY`(/`ARCH`), skipping task-only keywords; on a task skips `ACTIVE`.
- **Backstop:** a project heading with `NEXT` parses without error, omits status
  so the shadow's prior status is preserved, and is listed in the report; a
  brand-new standalone task with an invalid keyword falls back to `inbox`; a
  brand-new project to `active`; `mindwtr-model-validate-appdata` does not abort.
- **Round-trip:** `render → parse` preserves the content signature for the v3
  layout, including someday projects and waiting projects, `areaId` via `MW_AREA`,
  `projectId`/`sectionId` via ancestry.
- **Containers:** missing containers (incl. the nested someday children) are
  created in fixed tree order; renaming a container's heading text but keeping
  `MW_LIST` still resolves it; empty lists render.

## Open risks

- **Round-trip under the nested container tree** — the new two-level containers
  must stay transparent to ancestry. Top risk; guarded by the round-trip tests,
  which must pass before the sync path is trusted.
- **Relocation level/indentation correctness** — moving a project subtree between
  containers at the same outline level must preserve relative section/task
  nesting. Covered by the relocation tests.
- **Backstop fall-back defaults** (new invalid task → `inbox`, project →
  `active`) are a judgement call; surfaced in the report so they are never silent.
- **List churn for done items** — Single Actions accumulates done tasks until
  archived; acceptable and matches the chosen workflow.
