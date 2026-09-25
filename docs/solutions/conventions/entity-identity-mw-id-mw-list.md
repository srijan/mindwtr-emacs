---
title: "Entity identity: MW_ID (entities) and MW_LIST (containers) are the sync keys; org :ID: is unrelated"
date: 2026-06-03
category: conventions
module: mindwtr
problem_type: convention
component: tooling
severity: low
applies_when:
  - "Adding server-identity lookup or cross-heading links in Elisp"
  - "Implementing point/scroll/fold anchoring across a buffer rebuild"
  - "Writing capture templates or new-entity provisioning code"
  - "Debugging why a heading lost its sync identity after a raw edit"
  - "Deciding whether to use org-id or MW_ID for a heading reference"
tags: [sync, identity, uuid, mw-id, mw-list, org-id, container, capture]
---

# Entity identity: MW_ID (entities) and MW_LIST (containers) are the sync keys; org :ID: is unrelated

## Context
The sync buffer uses two **disjoint** identity namespaces, both in the PROPERTIES drawer:

- **`MW_ID` — entity identity.** Every synced entity (task, project, section, area) carries
  `:MW_ID:`, a lowercase RFC-4122 v4 UUID from `mindwtr-util-uuid` (`mindwtr-util.el:19`). It is
  the server's primary key (which PUT/DELETE targets) and the shadow index key
  (`mindwtr-shadow-index`, `mindwtr-shadow.el:271`). The sync engine mints it lazily at
  candidate-build time — `(or (plist-get le :id) (mindwtr-util-uuid))` (`mindwtr-sync.el:391`, in `mindwtr-sync-build-candidate`); the
  capture template can stamp it eagerly (`mindwtr-capture.el:35-43`), noted as belt-and-suspenders.
- **`MW_LIST` — container role.** Container headings (`* Inbox`, `* Projects`, …) carry only
  `:MW_LIST:`, a role string from `mindwtr-model-list-roles` (`mindwtr-model.el:52`):
  `"inbox"`, `"projects"`, `"areas"`, etc. They carry **no** `MW_ID`
  (`mindwtr-render--container`, `mindwtr-render.el:269-272`, emits only `MW_TYPE: container` +
  `MW_LIST: <role>`).
- **org `:ID:`** (from `org-id-get-create`) is **not** in `mindwtr-parse--known-props`, so it lands
  in `:mw-extra-props`, is never read by the sync engine, and is preserved verbatim. It must
  **not** be used as a server identifier.

## Guidance
- Use `MW_ID` to identify a synced entity. Never substitute org `:ID:` as a server key.
- To locate **any** heading stably across a rebuild, query `(or MW_ID MW_LIST)` — not `:ID:`.
- A container intentionally has no `MW_ID`; code mapping over headings for `MW_ID` correctly skips
  containers.
- `MW_ID` is minted lazily for new headings that lack it; a capture-template heading has it minted
  eagerly. Both produce identical server behavior — the lazy path just means the UUID isn't
  visible in the file until the first sync's reconcile re-renders.
- Never assume a heading with no `MW_ID` is unsynced — it may be a container (never has one) or a
  freshly captured entity awaiting its first sync.

The two namespaces are disjoint because entity UUIDs (36-char hyphenated hex) and container role
strings (short lowercase words) cannot collide. This is exploited so one regex resolves either
(`mindwtr-heading-find-key` / `mindwtr-heading-goto-key`, `mindwtr-heading.el:151-164`):

```elisp
(mindwtr-heading--find-drawer-line
 (format "^[ \t]*:MW_\\(?:ID\\|LIST\\):[ \t]*%s[ \t]*$" (regexp-quote key)))
```

`mindwtr-reconcile--id-at-point` (`mindwtr-reconcile.el:134-144`, via `mindwtr-heading-nearest-id-pos`) returns the nearest entity's `MW_ID`, falling back
to the current heading's `MW_LIST` role — so a cursor on `* Projects` resolves to `"projects"`.
Fold snapshot/restore (`mindwtr-reconcile--snapshot-view` / `--restore-view`, `mindwtr-reconcile.el:198-330`) keys on `(or MW_ID MW_LIST)`, making view state stable across a
rebuild for both entity and container headings.

## Why This Matters
Confusing the three leads to: code querying org `:ID:` for server ops silently missing all
containers and returning stale UUIDs; point/scroll anchors keyed on `:ID:` losing position
whenever the cursor sits on a container; and capture templates stamping both `:ID:` and `:MW_ID:`
with different UUIDs (harmless — the org one is preserved as an unknown prop — but confusing to
read). The two UUID namespaces coexist in the same drawer and look identical by shape, so the
distinction must be deliberate.

## When to Apply
- Any Elisp that navigates, references, or links across headings in a Mindwtr buffer.
- Batch operations that match headings to server entities.
- Capture templates for entity kinds beyond tasks.
- Investigating a heading that "lost identity" after an edit (look for a missing `:MW_ID:` line).

## Examples
A container heading has no `MW_ID`:

```org
* Projects
:PROPERTIES:
:MW_TYPE: container
:MW_LIST: projects
:END:
```

An entity carrying both `:MW_ID:` and an org `:ID:` — the latter is desk-only and never reaches
the server (stored in `:mw-extra-props`, re-emitted verbatim).

## Related
- [[preserving-buffer-view-state-across-reconcile]] — fold/scroll restore keys on
  `(or MW_ID MW_LIST)`, depending directly on the disjointness here.
- [[silent-deletion-untyped-org-headings]] — a heading with only org `:ID:` (no `MW_TYPE`, no
  `MW_ID`) is treated as an orphan and quarantined unless under a recognized container.
- [[desk-only-vs-synced-property-boundary]] — why org `:ID:` is preserved but never synced.
- `mindwtr-heading-find-key`/`mindwtr-heading-goto-key` (`mindwtr-heading.el:151-164`); `mindwtr-capture-template`
  (`mindwtr-capture.el:35-43`); `mindwtr-sync` build-candidate lazy mint (`mindwtr-sync.el:391`).
