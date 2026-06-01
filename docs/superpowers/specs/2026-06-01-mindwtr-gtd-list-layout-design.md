# Mindwtr Org Layout v2 — GTD Lists + Area-as-Property — Design

**Date:** 2026-06-01
**Status:** Approved design, pre-implementation
**Supersedes:** the "org ⇄ AppData bijection" / tree-structure sections of
`2026-06-01-mindwtr-org-sync-design.md`. The sync engine, shadow, signature,
conflict handling, backoff, and HTTP layers are unchanged.

## Goal

Change the org projection from a **containment tree** (Area → Project → Section →
Task, areas as top-level headings) to a **GTD-list layout**: fixed top-level lists
keyed by task status, projects keep their nested tasks, and an entity's **area
becomes a property** rather than an ancestor heading. Area entities live in a
reference section at the end of the file.

This is a presentation/parse change only. The data model (`AppData`, entity
fields, ids, `rev`), change detection, server merge, and conflict reporting are
untouched — `parse(buffer) ⊕ shadow` must still reconstruct the same entities.

### Why

The tree layout put projects and standalone area actions at the same outline
level under each area heading, which read as disorganized, and it offered no
GTD-list view in the file itself. The list layout matches how the system is
worked (process Inbox, pick Next Actions, review Projects) while keeping each
project visually together with its tasks.

## File layout

Fixed top-level **list containers** (synthetic, never synced), in this order,
followed by the **Areas of Focus** reference section:

```org
* Inbox
  :PROPERTIES: :MW_TYPE: container :MW_LIST: inbox :END:
* Next Actions
  :PROPERTIES: :MW_TYPE: container :MW_LIST: next-actions :END:
** NEXT Draft the quarterly planning notes
   :PROPERTIES: :MW_TYPE: task :MW_ID: c3c2… :MW_AREA: Personal :END:
   <description / checklist as today>
** NEXT Pay internet bill every 28th
   :PROPERTIES: :MW_TYPE: task :MW_ID: 4431… :MW_RECURRENCE: FREQ=MONTHLY :END:
** DONE Decide and order the standing desk                       ← done lingers here until archived
* Waiting
  :PROPERTIES: :MW_TYPE: container :MW_LIST: waiting :END:
* Someday
  :PROPERTIES: :MW_TYPE: container :MW_LIST: someday :END:
* Reference
  :PROPERTIES: :MW_TYPE: container :MW_LIST: reference :END:
* Projects
  :PROPERTIES: :MW_TYPE: container :MW_LIST: projects :END:
** ACTIVE Warranty claim for the router                      ← grouped by area, then :order
   :PROPERTIES: :MW_TYPE: project :MW_ID: 174f… :MW_AREA: Personal :END:
*** NEXT Research warranty options          ← project's tasks stay nested
    :PROPERTIES: :MW_TYPE: task :MW_ID: bd6a… :END:     ← no MW_AREA (area implied by project)
** ACTIVE Expense the new laptop
   :PROPERTIES: :MW_TYPE: project :MW_ID: ed8a… :MW_AREA: Work :END:
*** NEXT [#C] Talk to Dana…
** ACTIVE Test project 2                                ← area-less projects last
   :PROPERTIES: :MW_TYPE: project :MW_ID: a8a8… :END:
* Areas of Focus
  :PROPERTIES: :MW_TYPE: container :MW_LIST: areas :END:
** Personal
   :PROPERTIES: :MW_TYPE: area :MW_ID: f215… :END:
** Work
   :PROPERTIES: :MW_TYPE: area :MW_ID: fad1… :END:
```

### List containers

- Each top-level list and the Areas of Focus section is a heading with
  `:MW_TYPE: container` and a stable `:MW_LIST: <role>` discriminator
  (`inbox`, `next-actions`, `waiting`, `someday`, `reference`, `projects`,
  `areas`). `MW_LIST` — not the heading text — is how reconcile locates a list,
  so the user may rename the visible heading.
- Containers carry no `MW_ID`, are never sent to the server, and are skipped by
  the parser (the parser already ignores `MW_TYPE: container`).
- Reconcile creates any missing container on demand and keeps them in the fixed
  order above. Empty lists are still rendered (so the structure is stable and
  the user can refile into them).

## Status → list mapping

A **standalone** task (no `projectId` and no `sectionId`) renders under the list
for its status:

| status | list | TODO keyword |
|---|---|---|
| inbox | Inbox | INBOX |
| next | Next Actions | NEXT |
| done | Next Actions (in place) | DONE |
| waiting | Waiting | WAIT |
| someday | Someday | SOMEDAY |
| reference | Reference | REF |
| archived | *not rendered* | (ARCH) |

- **Done standalone tasks stay in Next Actions** with the `DONE` keyword; they
  linger until archived. A standalone task whose status changes is re-filed to
  the matching list on the next reconcile.
- **Projects** all render under `* Projects` regardless of status
  (active/someday/waiting), each as a heading carrying its TODO keyword, with
  **their own tasks nested beneath them** (tasks of any status — including a
  project's done/reference tasks — stay nested, NOT moved to a top-level list).
- **Sections** nest under their project; their tasks nest under the section.
- **Archived projects/tasks are not rendered** (see Archived handling).

The list a heading sits under is derived from status on render; on parse the
status comes from the TODO keyword, and the container is ignored. The two never
disagree about content because status is single-sourced from the keyword.

## Containment via property + ancestry

Parsing reconstructs the containment ids as follows:

- **`areaId`** ← the entity's own `:MW_AREA: <name>` property, resolved to an id
  by matching area headings under *Areas of Focus*. It is **not** inherited to
  nested tasks — each entity declares its own area (matching the data, where a
  project's tasks carry no `areaId`; the area is implied by the project).
- **`projectId`** ← nearest ancestor heading with `MW_TYPE: project`.
- **`sectionId`** ← nearest ancestor heading with `MW_TYPE: section`.
- List containers and *Areas of Focus* are transparent to ancestry (they are
  `MW_TYPE: container`, which `mindwtr-parse--ancestor-id` already skips since it
  matches on a specific `MW_TYPE`).

### The `MW_AREA` property

- Holds the area **name** for readability (`:MW_AREA: Personal`), resolved to the
  area id via a name→id map built from the *Areas of Focus* headings during
  parse. No shadow dependency — the mapping is self-contained in the file.
- Emitted by render only when the entity has an `areaId`, looking up the name
  from the area entities (id→name map). A project carries `MW_AREA`; a task
  nested under a project normally does not (its `areaId` is nil in the data).
- **Edge — duplicate area names:** if two areas share a name, the name→id map is
  ambiguous; resolve to the first match and emit a WARN. Area names are unique in
  practice; a future hardening could fall back to an `MW_AREA_ID` property.

## Archived handling (shadow-only)

"Archived" means "exists on the server, hidden from org." It must never be
confused with a local deletion.

- **Render/reconcile:** entities with `status = archived` are not rendered; if one
  becomes archived server-side, reconcile removes its heading from the buffer
  (the same path tombstones use today).
- **Deletion detection:** `mindwtr-sync-build-candidate` and
  `mindwtr-sync--stats` already skip shadow entities with `deletedAt` when
  deciding what is a local delete. They must **also** skip entities with
  `status = archived` — those are expected to be absent from org and must not be
  tombstoned.
- **Archive-from-org (free):** marking a heading `ARCH` parses to
  `status = archived`; that is a normal content change, so the next sync pushes
  it, and reconcile then removes the heading. No special gesture needed.

## Ordering

Within every list, render in this order:

- **Areas of Focus:** area entities by their `:order`.
- **Projects** under `* Projects`: grouped by area, the groups ordered by the
  **area's `:order`** (matching the Areas of Focus order), area-less projects
  last; within a group, projects by `:order`.
- **Other lists / nested tasks:** by `:order` then `:orderNum` when present, in a
  stable sort (entities without an order keep their incoming relative order).

Ordering is display-only — org position is not parsed into `order`/`orderNum`
(those remain shadow/server-owned), so reordering in org does not push, and
sorting on render does not perturb the signature.

## Recurrence rendering

`MW_RECURRENCE` renders as a readable string — the `rrule` (e.g. `FREQ=MONTHLY`)
when present, else the human `rule` (e.g. `monthly`) — instead of the raw Lisp
plist. Recurrence is server-owned (not in the content signature, not parsed back
from org), so this is display-only and round-trip-safe.

## Module impact

| File | Change |
|---|---|
| `mindwtr-model.el` | Add the status→list map and the ordered list of container roles. |
| `mindwtr-parse.el` | `areaId` from `MW_AREA` (+ area name→id map from *Areas of Focus* headings) instead of ancestry; keep `projectId`/`sectionId` from ancestry; ignore container headings (already done). Parse area headings wherever they appear (under *Areas of Focus*). |
| `mindwtr-render.el` | Emit `:MW_AREA: <name>` (id→name map) on entities with an area; readable recurrence; no area heading rendering. |
| `mindwtr-reconcile.el` | Build/maintain the fixed list containers + *Areas of Focus*; place each entity by status/type; group/sort; skip + remove archived; resolve `MW_AREA` names. The id-marker and rebuild machinery is reused. |
| `mindwtr-sync.el` | Deletion detection skips `status = archived` shadow entities (in addition to `deletedAt`). |
| `mindwtr.el` | `mindwtr-mode` already defines the keyword set; no functional change expected. |

## Round-trip & sync correctness (preserved)

- `signature(parse(render(x)) ⊕ shadow) == signature(x)` for unchanged content —
  the linchpin idempotency property — must still hold. Containment ids now flow
  through `MW_AREA` (areas) and ancestry (projects/sections); they are content
  signature fields, so this is the highest-risk area and is covered by
  round-trip tests below.
- The blast-radius gate, conflict detection, backoff, HEAD short-circuit, and
  UTF-8 encoding fixes are unaffected.

## Migration

No released version exists and the shadow is a rebuildable cache. Existing
area-heading files (e.g. a previously bootstrapped `~/mindwtr.org`) are migrated
by re-running `mindwtr-bootstrap`, which renders the new layout from the server
snapshot. No in-place file migration is built.

## Testing strategy

- **Round-trip (core):** for each list and for nested project/section/task,
  `render → parse` preserves the content signature, including `areaId` resolved
  via `MW_AREA`, `projectId`/`sectionId` via ancestry.
- **Area property:** `MW_AREA: <name>` resolves to the correct id; an entity with
  no area emits no `MW_AREA` and parses to no `areaId`; duplicate-name WARN.
- **Status → list placement:** each status renders under the right container;
  a standalone done task lands in Next Actions with `DONE`.
- **Projects grouping/order:** projects group by area then `:order`; area-less
  last; nested tasks keep their order.
- **Archived:** an archived entity is not rendered; a shadow entity with
  `status = archived` absent from org is NOT tombstoned by build-candidate; an
  org heading marked `ARCH` pushes `archived` and is then removed on reconcile.
- **Containers:** missing containers are created in fixed order; renaming a
  container's heading text but keeping `MW_LIST` still resolves it; empty lists
  render.
- **Recurrence:** renders as the rrule/rule string, not a Lisp sexp.

## Open risks

- **Idempotency under the new containment plumbing** is the top risk — area
  resolution and project ancestry must reproduce exactly what the server sent.
  Guarded by the round-trip property tests, which must pass before the sync path
  is trusted.
- **Duplicate area names** (documented edge; first-match + WARN).
- **List churn for done items** — Next Actions accumulates done tasks until they
  are archived; acceptable and matches the chosen workflow.
