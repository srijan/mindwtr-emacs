---
title: Content signature must be an allow-list of synced fields, not a deny-list
date: 2026-06-03
category: design-patterns
module: mindwtr-signature
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Adding a new server field that is NOT mapped to the org representation"
  - "Extending mindwtr-model-content-fields with a newly synced field"
  - "Implementing change detection for an entity that projects through a lossy format"
  - "The server schema gains fields the client cannot round-trip"
tags: [change-detection, signature, allow-list, sync-storm, round-trip]
---

# Content signature must be an allow-list of synced fields, not a deny-list

## Context
Change detection hashes an entity's "content" (SHA-256) and compares it against the same hash of
the shadow (last-known-server) copy. For this to be correct, the hashed field set must **exactly**
match the set of fields that round-trip through org. If the hash includes any field org cannot
represent, the hash differs on every sync — because parsing the rendered org never reproduces
that field — so every entity carrying it registers as an `update` every cycle, with no user
change.

The server schema (`mindwtr-model-known-fields`, `mindwtr-model.el:172`) carries many fields
never mapped to org: `:isFocusedToday`, `:isSequential`, `:supportNotes`, `:tagIds`,
`:areaTitle`, `:reviewAt`, … These must be preserved verbatim from the shadow on write, but must
not influence whether an entity looks "changed."

## Guidance
**Iterate an explicit allow-list (`mindwtr-model-content-fields`); never deny-list a full entity
plist.** The allow-list *is* the interface contract between the parse/render layer and the sync
engine: it names exactly the fields the round-trip can reproduce, and therefore exactly the
fields whose changes are attributable to a user edit.

Current signature (`mindwtr-signature.el:59`):

```elisp
(dolist (k mindwtr-model-content-fields)
  (let ((v (plist-get entity k)))
    (unless (or (null v) (and (stringp v) (string-empty-p v)))
      (push (cons k (mindwtr-signature-canonical-value k v)) pairs))))
```

The allow-list (`mindwtr-model.el:150-164`):

```elisp
(defconst mindwtr-model-content-fields
  '(:name :title :status :priority :contexts :tags :description :checklist
    :startTime :dueDate :completedAt :areaId :projectId :sectionId
    :energyLevel :timeEstimate :assignedTo :location :taskMode)
  "Editable fields that round-trip through org and define the content signature.
This is an allow-list: any server field not named here (`:isFocusedToday',
`:isSequential', `:supportNotes', `:tagIds', `:areaTitle', `:reviewAt') is excluded
from change detection by construction -- it can neither drift a signature nor be
lost; it is preserved in the shadow and merged back on write.")
```

Three normalizations handle org's lossy aspects (`mindwtr-signature.el:30-44`): set-valued fields
(`:tags`, `:contexts`) are **sorted** (org tags have no order); datetime fields are **coarsened
to minute precision** (org timestamps have no sub-minute resolution); checklist items are reduced
to `(:title :isCompleted)`, dropping the server `:id` an org checkbox can't carry. The write-merge
(`mindwtr-sync--merge-content`, `mindwtr-sync.el:42-67`) uses the **same** allow-list and merges
unchanged fields from the shadow verbatim, preserving server-only fields untouched.

## Why This Matters
With a deny-list, every server field not explicitly excluded lands in the shadow hash but not the
local hash, so every entity carrying it drifts every cycle. This was live, not hypothetical: the
deny-list version (commit `2b6400b`) drove **30 of 32** entities to false drift; the allow-list
brought it to **0** (commit `4a3c677`). Each false `update` bumps `:rev` and sends a PUT, which
can corrupt server history and trip conflict detection for other clients.

The allow-list also makes the signature↔round-trip relationship explicit and checkable: adding a
field to `mindwtr-model-content-fields` means the round-trip suite
(`test/mindwtr-roundtrip-test.el`) must show it survives parse→render.

## When to Apply
- Adding a field to `mindwtr-model-content-fields`: first verify `mindwtr-parse.el` **and**
  `mindwtr-render.el` handle it.
- Server schema gains fields: add to `mindwtr-model-known-fields` (drift detection) but **not** to
  `mindwtr-model-content-fields` unless explicitly mapped to org syntax.
- Any change-detection over a lossy intermediate (text file, form, restricted schema): hash only
  what that intermediate can faithfully represent — not the full server record.

## Examples
A future boolean `:pinned`, not mapped to org:
- **Correct:** add to `mindwtr-model-known-fields` only. Signature ignores it; shadow preserves
  it; write-merge echoes it back unchanged.
- **Wrong:** add to `mindwtr-model-content-fields`. Every `:pinned t` entity becomes a false
  update every sync.

## Related
- `mindwtr-model.el:150` content-fields (allow-list), `:172` known-fields, `:141` shadow-only.
- `mindwtr-sync.el:42` `--merge-content` (same allow-list); commit `4a3c677`.
- The same false-drift session also fixed [[parser-single-most-specific-container-id]]. The
  byte-stability sibling of this idea is [[org-markdown-link-conversion-roundtrip]].
