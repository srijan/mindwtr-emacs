---
date: 2026-06-26
topic: area-as-org-category
---

# Area as org CATEGORY — Requirements

## Summary

Store each item's Area in org's native `:CATEGORY:` property instead of the
custom `:MW_AREA:` property, so org's built-in agenda category filter (`<`)
narrows the agenda by Area with no custom filtering code. Areas remain synced
entities resolved by name; only the per-item storage moves.

## Problem Frame

Area is currently held in a `:MW_AREA:` drawer property storing the area name.
Nothing in the agenda is wired to it, so there is no easy way to filter the
agenda by Area: a `tags-todo "MW_AREA=..."` match doesn't inherit to tasks
nested under a project (those carry no `:MW_AREA:` and derive their area from
the project), so it silently misses most of an area's work. The only practical
option today is to eyeball the prefix column.

Org already has a first-class concept for exactly this — `CATEGORY` — with
interactive filtering (`<` / `org-agenda-filter-by-category`), automatic
subtree inheritance, and native prefix display. Adopting it makes Area "just
work" with org defaults rather than living in a parallel property the rest of
org doesn't understand. As a side benefit, it fills a slot that is currently
dead: org's default filename category renders as a useless `???` / `mindwtr:`
in this buffer (`mindwtr-agenda.el:106-111`).

## Key Decisions

- **Replace, don't duplicate.** `:CATEGORY:` becomes the single source of the
  per-item area assignment in org; `:MW_AREA:` is removed. Area remains a
  synced entity resolved by name to `:areaId`, and the content signature keeps
  hashing `:areaId` — only the org storage vehicle changes.

- **Name stays the stored value.** `:CATEGORY:` holds the area name, exactly as
  `:MW_AREA:` does today. No id-in-org scheme and no new rename machinery: an
  area rename on the server rewrites category values on the next render, the
  same path that handles `MW_AREA` names now.

- **Placement mirrors today; inheritance carries the rest.** `:CATEGORY:` is
  written on projects and standalone items. Tasks nested under a project carry
  no local category and inherit the project's via org's native CATEGORY
  inheritance — the same placement `MW_AREA` uses now, and what makes `<` filter
  project-child tasks for free.

- **Drawer property, never the `#+CATEGORY:` keyword.** Use the per-heading
  `:CATEGORY:` drawer property. The file-keyword form interns its value to a
  symbol (`org.el:4533`) and is buffer-wide — wrong for a per-item value.

- **Parse the local drawer value, not the inherited one.** Parsing must read
  the physical `:CATEGORY:` in each heading's own drawer and ignore org's
  inherited text-property value; otherwise every nested task would parse as
  carrying its parent's area and clobber the model. This continues today's
  behavior (project-child tasks store no area) — it is a correctness constraint
  on the parser, not a behavior change.

## Requirements

**Storage and round-trip**

- R1. A project's or standalone item's area is written to its `:CATEGORY:`
  drawer property as the area name; `:MW_AREA:` is no longer written.
- R2. Parsing resolves a heading's local `:CATEGORY:` name to `:areaId` (the
  resolution `MW_AREA` performs today), reading only the heading's own drawer,
  not an inherited value.
- R3. Tasks nested under a project carry no local `:CATEGORY:` and inherit the
  project's.
- R4. The change is round-trip byte-stable: `render(:areaId) -> :CATEGORY: name`
  and `parse -> name -> :areaId` reproduce identical bytes, so the content
  signature stays honest.
- R5. The `:areaId` content-signature / allow-list membership is preserved; area
  change detection behaves as before.

**Agenda**

- R6. `org-agenda-filter-by-category` (`<`) narrows the Engage agenda to the
  area under point, including tasks that inherit their area from a project.
- R7. The agenda prefix continues to show project for nested tasks and area
  otherwise; the resolver may read org's native category for the area case
  rather than `MW_AREA`.

**Commands and migration**

- R8. The set-area command writes `:CATEGORY:` instead of `:MW_AREA:`, keeping
  its current guard that refuses on a task already nested under a project or
  section.
- R9. Existing `:MW_AREA:` drawers are removed by the normal buffer rebuild on
  the next sync; no separate migration pass is added.

## Acceptance Examples

- AE1. **Covers R3, R6.** Given a project assigned to area "Work" with a NEXT
  task beneath it carrying no category, when the user presses `<` on that task's
  agenda line, then the agenda narrows to "Work" and the task remains visible.
- AE2. **Covers R1, R9.** Given an org file with a project carrying a legacy
  `:MW_AREA: Work` drawer, when a full sync rebuilds the buffer, then the
  project carries `:CATEGORY: Work` and no `:MW_AREA:` drawer.
- AE3. **Covers R2, R4.** Given a standalone task with `:CATEGORY: Personal`,
  when it is parsed, rendered, and re-parsed with no user edit, then the bytes
  and the content signature are unchanged.

## Scope Boundaries

- No dedicated per-area agenda view or command — interactive `<` filtering only.
- The areas-as-entities representation (the `* Areas of Focus` headings and
  their `:MW_ID:` etc.) is untouched; only the per-item area pointer changes.
- No category-grouped sorting or new agenda blocks.

## Dependencies / Assumptions

- The parser reserves both `MW_AREA` and `MW_AREA_ID` as drawer fields
  (`mindwtr-parse.el:18`); the replace must account for both. Planning to
  confirm the exact handling.
- Area names already satisfy org property-value constraints — single line, no
  leading/trailing whitespace, non-empty — because `MW_AREA` is parsed by the
  same property-value regex (`org.el:6029`, `6054`) today. No new character
  restriction is introduced by moving to `:CATEGORY:`.
- The unsynced-edit window is acceptable: a local `MW_AREA` edit made between
  deploy and the first sync, after the parser stops reading `MW_AREA`, is
  dropped. Area edits are rare and resync is immediate.

## Sources / Research

- `mindwtr-parse.el:18`, `:168`, `:199`, `:298-299` — `MW_AREA` reserved
  fields, name->id hash, and resolution to `:areaId`.
- `mindwtr-render.el:160-163`, `:259-264` — rendering `:areaId` as
  `:MW_AREA: name` and area-order project sorting.
- `mindwtr-model.el:158`, `:226` — `:areaId` on the content allow-list /
  signature fields.
- `mindwtr-commands.el:62-97` — set-area command and its project/section guard.
- `mindwtr-agenda.el:106-111`, `:136-140` — dead `???`/`mindwtr:` category slot
  and the existing `MW_AREA` prefix resolver that already inherits.
- `org.el:4533` (`#+CATEGORY:` interns to a symbol), `:6029`/`:6054`
  (property-value regex), `:8422` (`org-refresh-category-properties` subtree
  inheritance) — verified on Emacs 32; same paths on the 29.3 CI target.
