---
title: "One classifier feeds both summary counts and detail diffs; attach diff data where both sides are in scope"
date: 2026-06-12
category: design-patterns
module: mindwtr-sync / mindwtr-report
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "A report shows both a summary count line and a per-entity detail list for the same set of changes"
  - "Adding a new dimension or direction to a diff/sync report (e.g. an upward proposed-changes list)"
  - "A detail renderer could drift from the count it sits under if derived from a separate code path"
  - "The before/after data a detail view needs is already in scope at the point of classification"
  - "Preserving a module boundary: the sync layer stores raw entity plists; the report layer renders the diff"
related_components:
  - mindwtr-shadow
  - mindwtr-reconcile
tags: [sync, report, change-detection, classifier, field-diff, single-source-of-truth, before-after, module-boundary]
---

# One classifier feeds both summary counts and detail diffs; attach diff data where both sides are in scope

## Context
A bidirectional sync moves changes in two directions every cycle: local edits this device proposes
to push (outgoing), and remote edits the server returns (incoming). After each sync,
`mindwtr-report.el` renders a report buffer summarizing what happened.

Before this change, that report gave almost no signal about *what* changed:

- **Outgoing (proposed):** only a count line — `Proposed — Created: 0   Updated: 2   Deleted: 0`. The
  user knew two things were updated, not which entities or which fields.
- **Incoming (remote):** bare titles with a change label — `↓ Follow up... (task) — updated` — no
  field-level detail.

So the user was blind in both directions. They could not see that a task moved `status: NEXT → DONE`
or that the server filled in a `projectId`. The data needed for those diffs existed transiently
during the sync and was thrown away. The manual workaround that prompted the feature was diffing a
pre-sync and post-sync backup by hand to reconstruct what the report should have shown.
(session history)

## Guidance
Three rules, generalizable beyond this codebase:

**1. Attach the diff payload at the classification site that already holds both sides.** When you
classify a change as "updated," the comparison you just performed already has the before-value and
after-value in scope. Do not discard them and recompute a diff later in the rendering layer — push
them onto the change record right there. Here, `mindwtr-sync--incoming-changes` already held the
shadow entity (pre-sync baseline) and the merged entity (post-sync server value) when it decided an
entity was `updated`; the fix adds `:before`/`:after` to the plist — and *only* on the `updated`
branch, never `created`/`deleted`.

**2. Derive the summary and the detail from one classifier, so they cannot drift.** When you add a
per-item detail view next to an existing count, do not write a second, parallel classifier — it will
eventually disagree ("count says 2 updated but the list shows 3"). Factor the classification into one
function and have both the count and the detail consume it. The new `mindwtr-sync--local-changes`
(the proposed-changes list) reuses the exact `mindwtr-sync--classify` that `mindwtr-sync--stats` (the
count line) uses, including the identical three-part delete guard (tombstone / rendered-absent /
already-seen). Count and detail are now consistent *by construction*.

**3. Reuse one diff renderer across both directions.** The report already had a field-diff renderer
for the conflict block. Both proposed (`↑`) and incoming (`↓`) updates feed that *same* renderer.
Storing the data symmetrically (both directions carry `:before`/`:after` raw entity plists) lets the
rendering be symmetric too. The module boundary stays clean: `mindwtr-sync.el` stores raw entity
plists in the change records; `mindwtr-report.el` owns all diff formatting.

## Why This Matters
- **Consistency guarantee, not consistency hope.** Sharing the classifier makes "count matches list"
  a structural property rather than a coincidence two functions must maintain in lockstep. A future
  edit to the delete guard changes both at once.
- **Minimal plumbing.** The incoming-side diff cost one line (`:before s :after m`) because the data
  was already in scope — no new arguments threaded through call stacks, no second fetch, no recomputed
  comparison.
- **Observability.** The user gets a complete, field-level picture of both sides of a sync in one
  buffer — what they pushed and what the server pushed back — exactly the information needed to trust
  (or question) a silent merge.

## When to Apply
- Any time you add a **detail/expanded view alongside an existing summary or count** — route the
  detail through the same classification logic that produces the count instead of writing a parallel
  walker.
- Any time you **surface a diff where the comparison already happened upstream** — capture both
  versions onto the record at that point rather than re-deriving the diff downstream.
- Any time you have **two symmetric directions** (request/response, local/remote, before/after) —
  store the data symmetrically so one renderer serves both.

Counter-indication: do not attach `:before`/`:after` to records that will never be diffed (here,
`created`/`deleted`). Attach the payload only on the branch that needs it.

The design was chosen over two rejected alternatives: recomputing the diff inside the report layer
(would force the report to know how to compare entity plists, duplicating classifier logic) and a
separate detail walker traversing the entry list again (would let the detail list drift from the
count). (session history)

## Examples
Before — counts only, incoming titles bare:

```
  Proposed — Created: 0   Updated: 2   Deleted: 0
  No conflicts. All local edits accepted.
  Incoming from remote:
    ↓ Follow up and reply to the vendor (task) — updated
    ↓ tidy the garage shelves (task) — updated
```

After — per-entity list both directions, one `field: old → new` line per changed field under each
`updated`:

```
  Proposed — Created: 1   Updated: 2   Deleted: 0
    ↑ New grocery list (task) — created
    ↑ Follow up with the supplier (task) — updated
        status: NEXT → DONE
        completedAt: (empty) → 2026-06-11T19:00
    ↑ Old reminder (task) — deleted
  Incoming from remote:
    ↓ Follow up and reply to the vendor (task) — updated
        status: DONE → ARCH
        projectId: (empty) → b1c2d3e4-0000-4000-8000-000000000001
```

`created`/`deleted` show title only; `↑` is outgoing/proposed, `↓` is incoming.

Rule 1 — the one-line payload attach, only on the `updated` branch (`mindwtr-sync--incoming-changes`,
where shadow `s` and merged `m` are already bound):

```elisp
(push (list :id id :kind kind
            :title (mindwtr-model-entity-title m)
            :change 'updated
            :before s :after m)   ; both sides already in scope
      out)
```

Rule 2 — the proposed list reuses the count's classifier and delete guard
(`mindwtr-sync--local-changes` mirrors `mindwtr-sync--stats` but emits records instead of
incrementing counters), so the list and the `Proposed —` count cannot disagree.

Edge case: if signatures differ but no *content* field changed (e.g. only an `updatedAt` timestamp
moved), the field-diff returns nil and no diff lines are emitted — the `updated` label still appears
with no sub-lines. (session history)

A stale `.elc` masked the new tests on the first `make test` run (6 failures); `make compile` before
`make test` cleared them — no logic defect. (session history) See
[stale-elc-shadows-updated-el-after-rebase](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md).

## Related
- [align-list-field-diffs-by-identity-lcs](align-list-field-diffs-by-identity-lcs.md) — the
  field-*value* rendering layer beneath this feature: how one list-valued field (the checklist) is
  diffed compactly. This doc decides *which* entities/fields changed; that one decides *how* a single
  field's items render.
- [content-signature-cannot-detect-remote-deletes](content-signature-cannot-detect-remote-deletes.md)
  — documents the same `--classify` / `--incoming-changes` / `--stats` family and the delete guard
  this feature's `--local-changes` reuses.
- [content-signature-allow-list-not-deny-list](content-signature-allow-list-not-deny-list.md) — the
  shared content-field allow-list that makes one field-diff renderer correct in both directions.
- [migration-latch-for-newly-signed-fields](migration-latch-for-newly-signed-fields.md) — a
  co-consumer of that same allow-list (signature / merge / report field-diff).
- Design spec: `docs/superpowers/specs/2026-06-11-incoming-update-field-diff-design.md` (PR #49).
