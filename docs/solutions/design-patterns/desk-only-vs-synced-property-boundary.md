---
title: "Desk-only vs synced: unknown drawer keys are preserved but never sync"
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

# Desk-only vs synced: unknown drawer keys are preserved but never sync

## Context
The sync layer operates on a strict allow-list. `mindwtr-parse--known-props`
(`mindwtr-parse.el:26-42`) enumerates every PROPERTIES key the parser interprets — `MW_`-prefixed
keys (`MW_TYPE`, `MW_ID`, `MW_ENERGY`, `MW_TAGS`, `MW_CLOCK_SYNCED`, …) plus org's `CATEGORY`
(the per-item area name). Every drawer key *not* in that list is collected by
`mindwtr-parse-extra-props` (`mindwtr-parse.el:172-178`) into a
`:mw-extra-props` plist on the entity. That plist is never hashed by `mindwtr-signature` (which
signs only `mindwtr-model-content-fields`) and is stripped before the wire by
`mindwtr-sync--strip-internal-keys` (`mindwtr-sync.el:726-737`). On reconcile it is re-emitted
**verbatim** by `mindwtr-render-heading`'s unknown-props loop (`mindwtr-render.el:234-238`):

```elisp
(let ((extra (plist-get entity :mw-extra-props)))
  (while extra
    (push (format ":%s: %s" (car extra) (cadr extra)) lines)
    (setq extra (cddr extra))))
```

LOGBOOK/CLOCK drawer content is preserved on a separate path,
`mindwtr-reconcile--preserved-body` (`mindwtr-reconcile.el:28`), grafted back after the
PROPERTIES `:END:`. One exception: closed CLOCK totals are read (`mindwtr-clock--logbook-minutes`)
and rolled into the synced `:timeSpentMinutes` (`mindwtr-sync--apply-clock-reconcile`), with the
device-local baseline in the known prop `MW_CLOCK_SYNCED`.

## Guidance
Any PROPERTIES key outside `mindwtr-parse--known-props` — org's own `:ID:`, org-edna `TRIGGER`/
`BLOCKER`, user-defined keys — **survives every sync intact but is never seen by the server.**
This is architectural, not a gap. Consequences:

- **org-edna `TRIGGER`/`BLOCKER`** fire via `org-trigger-hook`/`org-blocker-hook` when
  `mindwtr-set-status` calls `org-todo` (`mindwtr-commands.el:68`). The dependency is **desk-only**.
  It cannot replace server-side behavior (e.g. archiving a project's tasks when the project is
  archived — that cascade runs server-side and reflects back only on the next sync).
- **org `:ID:`** is preserved verbatim but is **not** the sync key (`:MW_ID:` is — see
  [[entity-identity-mw-id-mw-list]]).
- **Project archive** uses `ARCH`/`"archived"`. Archived projects are not rendered in the main file
  (`mindwtr-render--live` with `drop-archived t`, `mindwtr-render.el:339-344`), so a server-side
  archive cascade appears in Emacs as the project leaving the main file (and, when
  `mindwtr-archive-file` is set, reappearing in the archive surface) — not as an org state
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
`mindwtr-reconcile--preserved-body`, re-grafted after PROPERTIES `:END:` — its text is not
signed or sent, though its closed CLOCK total feeds `:timeSpentMinutes`.

## Related
- `mindwtr-parse--known-props` (`mindwtr-parse.el:26-42`) — the definitive allow-list.
- `mindwtr-model-content-fields` (`mindwtr-model.el:165`) — the change-detection allow-list
  ([[content-signature-allow-list-not-deny-list]]).
- `mindwtr-render-heading` unknown-props loop (`mindwtr-render.el:234-238`) — the re-graft point.
- `mindwtr-reconcile--preserved-body` (`mindwtr-reconcile.el:28`) — LOGBOOK/CLOCK preservation;
  same body-graft mechanism used by [[reconcile-partial-update-reverts-remote-edits]].
