---
title: "feat: Store Area in org's native CATEGORY property"
type: feat
date: 2026-06-26
origin: docs/brainstorms/2026-06-26-area-as-org-category-requirements.md
---

# feat: Store Area in org's native CATEGORY property

## Summary

Move each item's Area out of the custom `:MW_AREA:` drawer property and into
org's native `:CATEGORY:` drawer property. Area stays a name-resolved synced
entity (`:areaId` on the content allow-list); only the per-item org storage
vehicle changes. This makes org's built-in agenda category filter (`<`) narrow
the Engage agenda by Area with no custom filtering code, and fills the dead
`???` / `mindwtr:` category slot.

---

## Problem Frame

Area lives today in a `:MW_AREA:` drawer property holding the area name
(`mindwtr-render.el:160-163` writes it, `mindwtr-parse.el:298-299` resolves it
to `:areaId`). Nothing in the agenda is wired to it: a `tags-todo` match on
`MW_AREA` does not inherit to tasks nested under a project, so it silently
misses most of an area's work, and the only practical filter today is eyeballing
the prefix column.

Org already has a first-class concept for this — `CATEGORY` — with interactive
filtering (`<` / `org-agenda-filter-by-category`), automatic subtree
inheritance, and native prefix display. Adopting it makes Area "just work" with
org defaults instead of living in a parallel property the rest of org does not
understand.

The lossless round-trip invariant is non-negotiable (`STRATEGY.md:14`,
`CONCEPTS.md` round-trip byte-stability): rendering `:areaId` to org and parsing
it back must reproduce identical bytes, or the content signature phantom-churns
on every sync.

---

## Key Technical Decisions

- KTD1. **Drawer property, never the `#+CATEGORY:` keyword.** Use the
  per-heading `:CATEGORY:` drawer property. The file-keyword form interns its
  value to a symbol and is buffer-wide (`org.el:4533`) — wrong for a per-item
  value. (origin KTD: "Drawer property, never the `#+CATEGORY:` keyword.")

- KTD2. **Parse the drawer-local value only.** Parsing reads the physical
  `:CATEGORY:` in each heading's own PROPERTIES drawer and ignores org's
  inherited text-property value. The existing `mindwtr-parse--prop` /
  `mindwtr-parse--drawer-alist` already scan the heading's own drawer (not
  `org-entry-get` inheritance), so this is satisfied by reading
  `(mindwtr-parse--prop "CATEGORY")` — no new inheritance handling. Reading the
  inherited value would make every nested task parse as carrying its parent's
  area and clobber the model (R2/R3).

- KTD3. **Transitional read-fallback to survive the deploy seam.** Parse
  resolves `:CATEGORY:`, falling back to a legacy `:MW_AREA:` value when
  `:CATEGORY:` is absent. Render only ever emits `:CATEGORY:`, so a buffer
  migrates to the new vehicle on its first rebuild and `:MW_AREA:` disappears
  (R1/R9). Rationale: `:MW_AREA:` has *always* rendered, so a legacy on-disk
  buffer carries it for every area-bearing entity. If the parser simply stopped
  reading `MW_AREA`, the first post-upgrade sync would parse every such heading
  as having no area — a false-empty that, against the shadow, reads as the user
  clearing the area everywhere and risks a mass area-removal push to the server
  (the exact hazard in `docs/solutions/design-patterns/migration-latch-for-newly-signed-fields.md`).
  The fallback reads the real value instead, so no area is ever misread as
  empty — strictly safer than the brainstorm's accepted "dropped edits" stance
  and simpler than wiring `:areaId` into the boolean migration-latch. (Refines
  origin R9 and the origin "unsynced-edit window is acceptable" assumption.)

- KTD4. **Add `CATEGORY` to the parser's known-props; keep `MW_AREA` /
  `MW_AREA_ID` reserved.** `CATEGORY` is not `MW_`-prefixed, so without this it
  would be collected as an unknown property into `:mw-extra-props` and
  re-rendered verbatim — double-handling the value. `MW_AREA` must stay in
  `mindwtr-parse--known-props` (consumed, not preserved): if it were removed,
  the unknown-property path would preserve a legacy `:MW_AREA:` and re-render it
  forever, resurrecting the old vehicle and defeating R1/R9. `MW_AREA_ID`
  remains a defensive reservation — nothing reads or writes it; leaving it
  listed keeps it out of `:mw-extra-props`.

- KTD5. **Agenda prefix resolver reads the literal `CATEGORY` drawer text —
  never `org-entry-get` in any form.** CATEGORY is a special property: org
  dispatches it to the filename-fallback branch *before* the inherit check
  (`org.el` `org-entry-get` special-property cond), so **both**
  `(org-entry-get (point) "CATEGORY" t)` **and the bare non-inherited
  `(org-entry-get (point) "CATEGORY")`** return the buffer/filename category —
  the dead `???` / `mindwtr:` value — when no `CATEGORY` property exists in the
  ancestry. Either would break the prefix resolver's "nil when no area" contract
  (`mindwtr-agenda--resolve-prefix` expects nil to fall through to the empty
  marker) and leak the dead category onto every area-less line. The resolver
  therefore walks ancestors reading each heading's own literal `:CATEGORY:`
  drawer line (a regex scan of the PROPERTIES drawer, the shape
  `mindwtr-parse--drawer-alist` uses) and returns nil when no ancestor carries
  one — `org-get-category` and `org-entry-get` are both off-limits for this read.
  `mindwtr-agenda.el` deliberately does not `require` `mindwtr-parse`, so the
  drawer read is inlined in the agenda resolver (or, if dedup is wanted, factored
  into `mindwtr-util`, which both already require). The native `<` filter (R6)
  needs nothing from us — it works once drawer `CATEGORY` values exist and org's
  category refresh spreads them down the subtree.

- KTD6. **`:areaId` stays on the content allow-list unchanged.** Only the org
  storage vehicle changes; `:areaId` remains in `mindwtr-model-content-fields`
  (`mindwtr-model.el:158`) so area change detection behaves as before (R5).
  Per the allow-list-last discipline
  (`docs/solutions/design-patterns/content-signature-allow-list-not-deny-list.md`),
  the round-trip byte-stability oracle (U2 test scenarios) must pass before the
  change lands — `:areaId` is already proven on the list, so this is "keep, do
  not regress."

---

## Requirements

Carried from the origin requirements doc; IDs preserved.

**Storage and round-trip**

- R1. A project's or standalone item's area is written to its `:CATEGORY:`
  drawer property as the area name; `:MW_AREA:` is no longer written.
- R2. Parsing resolves a heading's local `:CATEGORY:` name to `:areaId`,
  reading only the heading's own drawer, not an inherited value.
- R3. Tasks nested under a project carry no local `:CATEGORY:` and inherit the
  project's.
- R4. The change is round-trip byte-stable: `render(:areaId) -> :CATEGORY: name`
  and `parse -> name -> :areaId` reproduce identical bytes, so the content
  signature stays honest.
- R5. `:areaId` content-signature / allow-list membership is preserved; area
  change detection behaves as before.

**Agenda**

- R6. `org-agenda-filter-by-category` (`<`) narrows the Engage agenda to the
  area under point, including tasks that inherit their area from a project.
- R7. The agenda prefix continues to show project for nested tasks and area
  otherwise; the resolver reads org's category (drawer-local, inheritance-aware,
  no filename fallback) for the area case.

**Commands and migration**

- R8. The set-area command writes `:CATEGORY:` instead of `:MW_AREA:`, keeping
  its guard that refuses on a task already nested under a project or section.
- R9. Existing `:MW_AREA:` drawers are removed by the normal buffer rebuild on
  the next sync; no separate migration pass is added (KTD3 provides the
  read-fallback that makes this safe).

---

## Implementation Units

### U1. Render the area as `:CATEGORY:`

**Goal:** Emit `:CATEGORY: <name>` in place of `:MW_AREA: <name>` for every
area-bearing entity.

**Requirements:** R1, R4.

**Dependencies:** none.

**Files:**
- `mindwtr-render.el` (the area block at `:160-163`; defvar docstring at `:10-12`)
- `test/mindwtr-render-test.el`

**Approach:** Change the special-cased area line to format `":CATEGORY: %s"`.
Keep the `mindwtr-render-area-names` id->name resolution and the
set-when-resolvable guard exactly as-is — only the property key changes. The
line stays in its current drawer position (right after `:MW_ID:`), so render
output is deterministic. Update the `mindwtr-render-area-names` docstring, which
references `:MW_AREA:`. Do not touch the generic `mindwtr-render--drawer-order` /
`mindwtr-render--prop-names` tables — area is not part of that loop.

**Patterns to follow:** The existing special-case block at `mindwtr-render.el:160-163`;
the area-emission tests already in `test/mindwtr-render-test.el` (around `:59-72`).

**Test scenarios:**
- Covers R1. An entity with a resolvable `:areaId` renders a `:CATEGORY: <name>`
  line and no `:MW_AREA:` line.
- An entity with no `:areaId` renders neither `:CATEGORY:` nor `:MW_AREA:`.
- An entity whose `:areaId` is not resolvable in `mindwtr-render-area-names`
  renders no category line (no crash, no empty `:CATEGORY:`).

**Verification:** `test/mindwtr-render-test.el` passes; a rendered area-bearing
heading contains `:CATEGORY:` and no `:MW_AREA:`. (The byte-identity round-trip
that closes R4 lives in U2, where the parser half lands.)

### U2. Parse `:CATEGORY:` to `:areaId` with legacy fallback

**Goal:** Resolve a heading's local `:CATEGORY:` name to `:areaId`, falling back
to a legacy `:MW_AREA:` value when `:CATEGORY:` is absent, and stop the new key
leaking into preserved unknown properties.

**Requirements:** R2, R3, R4, R5, R9.

**Dependencies:** U1 (for the joint round-trip and idempotence assertions).

**Files:**
- `mindwtr-parse.el` (`known-props` at `:15-20`; the area resolution at `:298-299`;
  `mindwtr-parse--area-id` docstring at `:198-201`)
- `test/mindwtr-parse-test.el`
- `test/mindwtr-roundtrip-test.el`

**Approach:** Replace the single `(mindwtr-parse--prop "MW_AREA")` read with
`(or (mindwtr-parse--prop "CATEGORY") (mindwtr-parse--prop "MW_AREA"))` before
name->id resolution. Both reads go through `mindwtr-parse--drawer-alist`, which
scans the heading's own drawer only — satisfying the drawer-local constraint
(KTD2) with no inheritance handling. Add `"CATEGORY"` to
`mindwtr-parse--known-props`; keep `"MW_AREA"` and `"MW_AREA_ID"` listed (KTD4).
Update the `mindwtr-parse--area-id` docstring, which names `:MW_AREA:`. Leave
`mindwtr-parse--build-area-names` untouched — it keys on `MW_TYPE=area`
headings, not on the per-item area property.

**Patterns to follow:** The kind-agnostic reserved-field resolution block at
`mindwtr-parse.el:280-299`; the area-property tests in
`test/mindwtr-parse-test.el` (`mindwtr-parse-area-from-property`, around `:105-131`).

**Test scenarios:**
- Covers R2. A standalone task with `:CATEGORY: Personal` parses to the matching
  `:areaId`.
- Covers R3. A task nested under a project, carrying no local `:CATEGORY:`,
  parses with `:areaId` nil (it inherits the project's area only for display, not
  in the model) — and carries no `:projectId`+`:areaId` dual-container.
- Covers R9. Legacy seam: a heading with `:MW_AREA: Work` and no `:CATEGORY:`
  still parses to the correct `:areaId` (the fallback fires) — guards against the
  first-post-upgrade false-clear.
- Precedence: a heading carrying both `:CATEGORY: Work` and a stale
  `:MW_AREA: Personal` resolves from `:CATEGORY:` (Work).
- `:CATEGORY:` does not appear in the parsed entity's `:mw-extra-props`.
- Covers R4. Byte-identity idempotence: `render == render(parse(render(x)))` for
  an area-bearing entity, wired through the existing
  `mindwtr-roundtrip-render-is-stable` helper. (Needs both the U1 render change
  and this unit's parse change, which is why it lands here, not in U1.)
- Covers R4, R5. Round-trip signature stability: render -> parse reproduces the
  area-bearing entity's content signature unchanged (wired through
  `mindwtr-roundtrip-render-parse-signature-stable` and the full-appdata
  `mindwtr-roundtrip-appdata-signature-stable`).

**Verification:** `test/mindwtr-parse-test.el` and `test/mindwtr-roundtrip-test.el`
pass, including the new legacy-fallback, precedence, and byte-identity cases.

### U3. Set-area command writes `:CATEGORY:`

**Goal:** `mindwtr-set-area` writes the chosen area name to `:CATEGORY:` instead
of `:MW_AREA:`, keeping its existing guard.

**Requirements:** R8.

**Dependencies:** U2 (so a written `:CATEGORY:` parses back correctly).

**Files:**
- `mindwtr-commands.el` (`mindwtr-set-area` at `:69-97`)
- `test/mindwtr-commands-test.el`

**Approach:** Change `(org-set-property "MW_AREA" name)` at `:97` to
`(org-set-property "CATEGORY" name)`. Leave the project/section guard
(`:84-88`), the completion source (`mindwtr-set-area--names`, which reads
`MW_TYPE=area` headings), and the no-op-off-task/project behavior unchanged.
Update the docstring, which currently names the `MW_AREA` property.

**Patterns to follow:** The existing command body and its guard at
`mindwtr-commands.el:69-97`; the set-area test in `test/mindwtr-commands-test.el`.

**Test scenarios:**
- Covers R8. Invoking set-area on a project (or standalone task) with a chosen
  existing area name writes a `:CATEGORY: <name>` drawer property.
- The guard still refuses (no property written) on a task nested under a project.
- No-op (message, no property) when point is not on a task/project heading.

**Verification:** `test/mindwtr-commands-test.el` passes; after set-area the
heading carries `:CATEGORY:` and the area round-trips to `:areaId`.

### U4. Agenda resolver reads category; native `<` filter

**Goal:** The Engage prefix resolver reads the inherited org category (drawer
property, no filename fallback) for the area case, and the native category
filter narrows by area.

**Requirements:** R6, R7.

**Dependencies:** U1 (drawer `CATEGORY` values must exist to inherit and filter).

**Files:**
- `mindwtr-agenda.el` (`mindwtr-agenda--resolve-area` at `:136-140`; calendar
  prefix docstring note about the dead category slot at `:101-111`)
- `test/mindwtr-agenda-test.el`

**Approach:** Replace `(org-entry-get (point) "MW_AREA" t)` with an
inheritance-aware read of the literal `CATEGORY` drawer text that returns nil
when no ancestor sets one. Reuse the *outline-walk skeleton* of
`mindwtr-agenda--nearest-project-marker` (`:113-126`) — `org-up-heading-safe`
up the ancestry, stopping at the first hit — but **not** its read call: that
function reads with `(org-entry-get (point) "MW_TYPE")`, and the analogous
`(org-entry-get (point) "CATEGORY")` is unsafe even without the inherit flag
(KTD5 — org routes CATEGORY to the filename-fallback branch before the inherit
check, so it returns the dead `???` / `mindwtr:` value instead of nil). Read the
literal `:CATEGORY:` drawer line at each ancestor instead (a regex scan of that
heading's PROPERTIES drawer, the shape `mindwtr-parse--drawer-alist` uses),
returning nil when none is found. R6 (`<` filtering) requires no code — org's
category refresh picks up the drawer `CATEGORY` and inherits it to nested tasks;
verify in a test rather than implement. Refresh the calendar-prefix docstring
note at `:101-111` (it explains the dead category slot the change now fills for
area-bearing lines; area-less lines still fall back to the filename category, so
do not overstate it).

**Execution note:** Verify org's category behavior on the Org 9.6 / Emacs 29.3
CI target before relying on it — both the inheritance-read shape and that `<`
filters project-child tasks by inherited drawer `CATEGORY`. Cold-scan category
caching has bitten this buffer before (`mindwtr-agenda.el:106-108`).

**Patterns to follow:** the outline-walk skeleton of
`mindwtr-agenda--nearest-project-marker` (`mindwtr-agenda.el:113-126`) — its
`org-up-heading-safe` ancestry loop only, not its `org-entry-get` read; the
literal-drawer scan in `mindwtr-parse--drawer-alist` (`mindwtr-parse.el:45-66`)
for the per-ancestor `CATEGORY` read; existing agenda resolver tests in
`test/mindwtr-agenda-test.el`.

**Test scenarios:**
- Covers R7. On a standalone task with `:CATEGORY: Work`, the resolver returns
  "Work".
- Covers R7. On a task nested under a project with `:CATEGORY: Work`, the
  resolver returns "Work" (inherited) — and the prefix still shows the owning
  project title (project wins over area in `mindwtr-agenda--resolve-prefix`).
- The resolver returns nil (not the filename category) for a heading with no
  `CATEGORY` in its ancestry, so the prefix falls through to the empty marker.
- Covers R6. With drawer `CATEGORY` set on a project, a category filter narrows
  to that area and a project-child task carrying no local category remains
  visible. (Build/refresh the agenda with `org-element-use-cache` bound nil per
  the Org 9.6 cold-scan guidance.)

**Verification:** `test/mindwtr-agenda-test.el` passes on Emacs 29.3 (Docker);
`<` on an area-bearing line narrows the Engage agenda by area.

---

## Acceptance Examples

- AE1. Covers R3, R6. Given a project assigned to area "Work" with a NEXT task
  beneath it carrying no category, when the user presses `<` on that task's
  agenda line, then the agenda narrows to "Work" and the task remains visible.
- AE2. Covers R1, R9. Given an org file with a project carrying a legacy
  `:MW_AREA: Work` drawer, when a full sync rebuilds the buffer, then the project
  carries `:CATEGORY: Work` and no `:MW_AREA:` drawer.
- AE3. Covers R2, R4. Given a standalone task with `:CATEGORY: Personal`, when it
  is parsed, rendered, and re-parsed with no user edit, then the bytes and the
  content signature are unchanged.
- AE4. Covers R9, KTD3. Given a legacy buffer where every project carries
  `:MW_AREA:` and none carries `:CATEGORY:`, when the first post-upgrade sync
  parses it against the shadow, then each project resolves its existing
  `:areaId` (no area is detected as cleared), and the rebuild rewrites each to
  `:CATEGORY:`.

---

## Scope Boundaries

- No dedicated per-area agenda view or command — interactive `<` filtering only.
- The areas-as-entities representation (`* Areas of Focus` headings and their
  `:MW_ID:` etc.) is untouched; only the per-item area pointer changes.
- No category-grouped sorting or new agenda blocks. The existing area-order
  project sort (`mindwtr-render--sorted-projects`, `mindwtr-render.el:257-273`)
  is unchanged — it keys on `:areaId`, not on the storage property.
- `MW_AREA_ID` reservation is left as-is (defensive, unread).

### Deferred to Follow-Up Work

- Remove the transitional `:MW_AREA:` read-fallback (KTD3) and drop `MW_AREA`
  from `mindwtr-parse--known-props` once all live buffers have been rebuilt to
  `:CATEGORY:`. Until then the fallback is harmless (render never emits
  `MW_AREA`, so steady-state buffers carry only `:CATEGORY:`).

---

## Risks & Dependencies

- **Org category drawer round-trip on 29.3.** The plan assumes org leaves a
  `:CATEGORY:` drawer line as literal buffer text (reading it only into a text
  property for the agenda) and never normalizes it, so byte-stability holds.
  Verify on the Emacs 29.3 / Org 9.6 CI target via Docker before merging — a
  silent rewrite would phantom-churn the signature.
- **`<` filtering of inherited categories on 29.3.** R6 relies on org's category
  refresh spreading a project's drawer `CATEGORY` to its child tasks. Verify the
  inherited filter case under Org 9.6, binding `org-element-use-cache` nil in the
  test per the recorded cold-scan deadline-drop bug
  (memory: org-96-cold-scan-cache-bug).
- **Known-props ordering trap.** Removing `MW_AREA` from known-props (rather than
  keeping it) would resurrect the old vehicle via the unknown-property
  preservation path — call-out captured in KTD4 and the U2 precedence test.
- **Forward-only release.** Once a buffer has been rebuilt to `:CATEGORY:`,
  reverting to a build whose parser lacks the `CATEGORY` read-path reintroduces
  the false-clear from the other side: every area-bearing heading parses
  `:areaId` empty and pushes a mass area-removal. KTD3 deliberately skips the
  `:areaId` migration-latch, so the safe rollback is to keep the read-side (parse
  `CATEGORY` + `MW_AREA` fallback) in place — do not revert the parser change
  alone.

---

## Sources / Research

- `mindwtr-render.el:160-163` (area emission), `:10-12` (area-names defvar),
  `:257-273` (area-order sort, unchanged).
- `mindwtr-parse.el:15-20` (`known-props`), `:45-70` (`drawer-alist` /
  `--prop`, drawer-local), `:198-201` (`--area-id`), `:280-299` (kind-agnostic
  reserved-field resolution).
- `mindwtr-model.el:155-180` (`:areaId` on the content allow-list).
- `mindwtr-commands.el:69-97` (`mindwtr-set-area` and its guard).
- `mindwtr-agenda.el:101-111` (dead category slot), `:113-126`
  (`nearest-project-marker` walk), `:136-140` (`resolve-area`).
- `mindwtr-sync.el:262-297` (migration-latch consumption — the seam KTD3 avoids
  by reading the real legacy value instead of protecting an empty).
- `docs/solutions/design-patterns/migration-latch-for-newly-signed-fields.md`,
  `.../content-signature-allow-list-not-deny-list.md`,
  `docs/solutions/logic-errors/parser-single-most-specific-container-id.md`.
- `docs/brainstorms/2026-06-26-area-as-org-category-requirements.md` (origin).
- `org.el:4533` (`#+CATEGORY:` interns to a symbol) — verified on Emacs 32; same
  path on the 29.3 CI target.
- Tests to mirror: `test/mindwtr-roundtrip-test.el`, `test/mindwtr-parse-test.el`,
  `test/mindwtr-render-test.el`, `test/mindwtr-commands-test.el`,
  `test/mindwtr-agenda-test.el`.
