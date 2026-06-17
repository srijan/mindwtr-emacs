---
title: "Align list-valued field diffs by identity (LCS), not position, to render compact renames"
date: 2026-06-16
category: design-patterns
module: mindwtr-report
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "Rendering a human-readable diff of a list-valued field (checklist, tags, ordered items)"
  - "A single insertion or deletion would otherwise cascade into \"every later item changed\""
  - "Items carry a stable identity (e.g. title) usable to align old vs new sequences"
  - "Adjacent delete/insert pairs should read as renames rather than two unrelated changes"
  - "The same diff must be shown in two directions (Proposed ↑ and Incoming ↓)"
symptoms:
  - "A checklist change printed as a raw plist on one long line via prin1-to-string"
  - "Reordering or one insertion makes the whole list appear changed"
related_components:
  - mindwtr-signature
  - mindwtr-reconcile
tags: [diff-rendering, lcs, identity-alignment, rename-pairing, sync-report, checklist, shared-renderer]
---

# Align list-valued field diffs by identity (LCS), not position, to render compact renames

## Context
The post-sync report renders a per-field diff for every changed entity. Scalar fields (`title`,
`status`) render fine as `field: before → after`. But a `checklist` field is structured — a list of
`{title, isCompleted}` items — and the original renderer ran the whole before-list and after-list
through `prin1-to-string`, dumping raw Lisp onto one line:

```
checklist: ((:title "Review the intro draft" :isCompleted :false) ...) → ((:title "Review the intro draft - decided not to do it" :isCompleted t) ...)
```

Two problems compounded: the line is an unreadable wall of keyword noise, and even parsed it tells
you nothing about *which* item changed or *how* (renamed? checked off? added? removed?). The fix
replaces it with a `checklist:` header followed by one compact line per *changed* item, omitting
everything unchanged.

## Guidance
Four reusable rules for diffing an ordered list of identified items for human display:

**1. Align by stable identity, not by position — via an LCS alignment.** Each item has a natural key
(its title). Run a longest-common-subsequence alignment keyed on that title to classify each item as
*match*, *delete*, or *insert*. Equal-title items anchor as matches even when they moved, so the diff
highlights the genuine insertion/deletion rather than a cascade. Index-zipping the two lists instead
falsely flags every item after an insertion point as "changed," because each now sits opposite a
different neighbor. Title is the key because checklist items carry no stable id — the title is the
only identity token available. (session history)

**2. Coalesce adjacent delete/insert runs into renames.** A rename appears in the raw alignment as a
delete (old title) immediately followed by an insert (new title), since the titles differ and LCS
cannot match them. Buffer consecutive deletes and inserts into a *change block*, then pair them
positionally across the whole block. When a paired `(del, ins)`'s titles look related (shared prefix
or enough common tokens), emit a single `~ old → new` rename line; an unrelated swap stays as separate
`-`/`+` lines.

**3. Render only the delta.** Omit unchanged items entirely. A matched item with no completion change
produces no output. Output length is proportional to *what changed*, not to list size.

**4. Share one renderer across both directions.** The same compact renderer feeds the Proposed (`↑`)
and Incoming (`↓`) sections, dispatched in one place: if the field is the checklist, render compactly;
otherwise fall back to the plain `field: before → after` line. Non-checklist fields and the conflict
block stay untouched, so the special-casing is contained. As a safety fallback, if the structured
diff yields zero change lines, fall back to the plain one-line form rather than emit an empty header.

## Why This Matters
- **Avoids false "everything changed."** Identity-based LCS alignment is the load-bearing decision.
  Position-based diffing turns a one-item insertion into an N-item "everything below shifted" report —
  actively misleading, and worse than no diff because it trains the reader to distrust the report.
- **Readability.** A reader scans `~ [ ]→[X] Buy milk` and instantly knows one item got checked off;
  the raw plist dump conveyed the same fact only after manual parsing.
- **Scales to long checklists.** Showing only the delta means a 40-item checklist with one toggle
  produces one line.
- **Rename clarity.** Pairing del/ins into `~ old → new` communicates intent ("this item was
  reworded") that two separate `-`/`+` lines obscure.

## When to Apply
Reach for this whenever you diff an **ordered list of identified items for human display** and the
items have a stable identity key separate from position:

- Checklists / subtask lists (identity = title).
- Tag or label sets on an entity.
- Ordered children (sections, list items, ordered config entries).
- Any before/after view where naive index-pairing cascades after a single insert/delete.

If the field is scalar, or the collection is unordered and you only care about set membership, simpler
approaches suffice. The rename-coalescing step is optional polish — add it only when in-place renaming
is common enough that `-`/`+` pairs would be noisy.

## Examples
Before (raw plist dump, one line):

```
checklist: ((:title "Review the intro draft" :isCompleted :false) (:title "Check the appendix links" :isCompleted :false)) → ((:title "Review the intro draft - decided not to do it" :isCompleted t) (:title "Check/fix the appendix links" :isCompleted :false))
```

After (header + one compact line per changed item):

```
checklist:
  ~ [ ]→[X] Review the intro draft → Review the intro draft - decided not to do it
  ~ Check the appendix links → Check/fix the appendix links
```

The output vocabulary is five line shapes:

```
~ [ ]→[X] old title → new title    rename, with a completion toggle
~ old title → new title            rename, completion unchanged
~ [ ]→[X] title                    pure completion toggle, title unchanged
+ [X] added title                  inserted item
- [ ] removed title                deleted item
```

Insertion does not cascade — inserting one item between two unchanged ones emits exactly one line; the
unchanged items are omitted:

```
+ [X] Merge the intro into the summary
```

A same-title completion flip renders one coalesced `~ [ ]→[X]` line; an unrelated delete + insert is
*not* coalesced (the relatedness test fails) and stays as two lines:

```
~ [ ]→[X] Buy milk          (same item, just toggled — one line)

- [ ] Old unrelated thing   (unrelated swap — two separate lines)
+ [X] Brand new thing
```

Implementation note: the rename pairing has a subtle trap. LCS emits *all* deletes in a block before
*all* inserts, so a first attempt that greedily zipped del/ins as they appeared mis-paired blocks with
multiple items. The fix collects the entire consecutive del/ins run first, then pairs positionally
across the whole block. (session history)

## Related
- [single-classifier-feeds-summary-and-detail](single-classifier-feeds-summary-and-detail.md) — the
  feature this rendering layer lives under (PR #49 symmetric report change lists). That doc decides
  *which* entities/fields changed; this one decides *how* a single list-valued field's items render.
- [entity-identity-mw-id-mw-list](../conventions/entity-identity-mw-id-mw-list.md) — the same
  align-by-stable-key principle, different key: headings align by `MW_ID` across a buffer rebuild,
  checklist items align by title via LCS.
- [preserving-buffer-view-state-across-reconcile](preserving-buffer-view-state-across-reconcile.md) —
  the same family of stable-identity anchoring so an edit does not cascade-shift everything.
