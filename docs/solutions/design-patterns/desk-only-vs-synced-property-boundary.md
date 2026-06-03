---
title: "Desk-only vs synced: non-MW_ drawer keys are preserved but never sync"
date: 2026-06-03
category: design-patterns
module: mindwtr
problem_type: design_pattern
component: tooling
severity: low
applies_when:
  - "Adding org-edna TRIGGER/BLOCKER properties to Mindwtr headings"
  - "Using org :ID: or LOGBOOK drawers alongside synced headings"
  - "Building local Emacs automation that hooks into mindwtr-set-status"
  - "Designing dependency chains expected to cascade to archived projects"
  - "Auditing what reaches the server vs what stays in the org file"
tags: [sync, org-mode, properties-drawer, org-edna, desk-only, architecture]
---

# Desk-only vs synced: non-MW_ drawer keys are preserved but never sync

## Context
The sync layer operates on a strict allow-list. `mindwtr-parse--known-props`
(`mindwtr-parse.el:15-20`) enumerates every PROPERTIES key the parser interprets — all
`MW_`-prefixed (`MW_TYPE`, `MW_ID`, `MW_ENERGY`, `MW_AREA`, `MW_TAGS`, …). Every drawer key *not*
in that list is collected by `mindwtr-parse--extra-props` (`mindwtr-parse.el:138-144`) into a
`:mw-extra-props` plist on the entity. That plist is never hashed by `mindwtr-signature` (which
signs only `mindwtr-model-content-fields`) and is stripped before the wire by
`mindwtr-sync--strip-internal-keys` (`mindwtr-sync.el:217-231`). On reconcile it is re-emitted
**verbatim** by `mindwtr-render-heading`'s unknown-props loop (`mindwtr-render.el:171-174`):

```elisp
(let ((extra (plist-get entity :mw-extra-props)) (i 0))
  (while (< i (length extra))
    (push (format ":%s: %s" (nth i extra) (nth (1+ i) extra)) lines)
    (setq i (+ i 2))))
```

LOGBOOK/CLOCK drawer content is preserved on a separate path,
`mindwtr-reconcile--preserved-body` (`mindwtr-reconcile.el:45-76`), grafted back after the
PROPERTIES `:END:`.

## Guidance
Any PROPERTIES key outside `mindwtr-parse--known-props` — org's own `:ID:`, org-edna `TRIGGER`/
`BLOCKER`, user-defined keys — **survives every sync intact but is never seen by the server.**
This is architectural, not a gap. Consequences:

- **org-edna `TRIGGER`/`BLOCKER`** fire via `org-trigger-hook`/`org-blocker-hook` when
  `mindwtr-set-status` calls `org-todo` (`mindwtr-commands.el:43`). The dependency is **desk-only**.
  It cannot replace server-side behavior (e.g. archiving a project's tasks when the project is
  archived — that cascade runs server-side and reflects back only on the next sync).
- **org `:ID:`** is preserved verbatim but is **not** the sync key (`:MW_ID:` is — see
  [[entity-identity-mw-id-mw-list]]).
- **Project archive** uses `ARCH`/`"archived"`. Archived projects are not rendered at all
  (`mindwtr-render--live` with `drop-archived t`, `mindwtr-render.el:261-265`), so a server-side
  archive cascade appears in Emacs as the project simply not rendering — not as an org state
  change you can intercept with `org-trigger-hook`.

## Why This Matters
A developer can safely add `TRIGGER`/`BLOCKER` chains for local automation without corrupting
server data — but those chains are inert to the server: closing a project server-side won't
respect them, and an org-edna blocker won't prevent a status change pushed to the server. The two
automation planes are **disjoint by construction**. Knowing the seam prevents designing local
automation that's silently expected to enforce a server-side invariant.

## When to Apply
- Designing org-edna / org-depend automation over a Mindwtr GTD file.
- Evaluating whether a local Emacs hook can substitute for a server-side workflow.
- Adding custom drawer keys for local tooling (time-tracking, review notes) that should never
  leak to the server.
- Auditing which properties survive a full buffer rebuild.

## Examples
An org-edna TRIGGER on a task:

```org
** NEXT Write release notes
:PROPERTIES:
:MW_TYPE: task
:MW_ID: a1b2c3d4-...
:TRIGGER: ids(e5f6g7h8-...) todo!(NEXT)
:END:
```

After reconcile, `:TRIGGER:` reappears byte-for-byte and fires locally via `org-trigger-hook`;
the server never sees it. A LOGBOOK entry is likewise preserved via
`mindwtr-reconcile--preserved-body`, re-grafted after PROPERTIES `:END:` — not parsed, not
signed, not sent.

## Related
- `mindwtr-parse--known-props` (`mindwtr-parse.el:15-20`) — the definitive allow-list.
- `mindwtr-model-content-fields` (`mindwtr-model.el:150-164`) — the change-detection allow-list
  ([[content-signature-allow-list-not-deny-list]]).
- `mindwtr-render-heading` unknown-props loop (`mindwtr-render.el:171-174`) — the re-graft point.
- `mindwtr-reconcile--preserved-body` (`mindwtr-reconcile.el:45-76`) — LOGBOOK/CLOCK preservation;
  same body-graft mechanism used by [[reconcile-partial-update-reverts-remote-edits]].
