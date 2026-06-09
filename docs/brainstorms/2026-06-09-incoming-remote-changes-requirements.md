---
date: 2026-06-09
topic: incoming-remote-changes
issue: 11
---

# Show Incoming Remote Changes in the Sync Report

## Summary

Add an "incoming from remote" section to the *Mindwtr Sync Report*: per-entity
lines for what mobile created, updated, or deleted since the last sync — the
benign merges that complete silently today. At the same time, turn the report
from a replace-every-sync buffer into an append-only, org-structured log keyed
by sync time, so the history of what came in is browsable rather than
overwritten.

---

## Problem Frame

The report already tells the user what *they* proposed and which of their edits
the server overrode (conflicts). But when mobile changes an entity the user did
not touch locally, the merge pulls that change in without a word — it is not a
conflict, so nothing surfaces. To learn that mobile renamed a task or deleted a
project, the user has to diff the Shadow against the merged result by hand.

This is the soft spot in the "no surprises" guarantee. The product's whole
premise is one coherent GTD source of truth across desk and mobile; a remote
change that lands invisibly means the desk view shifted under the user without
acknowledgement. A remotely-deleted task is the sharpest version — a heading
disappears with no record of why. The data needed to show all of this is already
in hand at report time: the pre-sync Shadow and the post-sync merged result are
both present in the sync cycle.

---

## Key Decisions

- **Incoming changes show as per-entity lines, not per-field diffs.** Each line
  names the entity (title + kind) and whether it was created, updated, or
  deleted. Field-level detail stays reserved for conflicts, where the user has
  to decide whether to restore — for a change they have already implicitly
  accepted by syncing, knowing *which* entity moved is enough.

- **The report becomes an append-only org-structured log.** Each sync worth
  reporting is a top-level org heading stamped with the sync time; sub-sections
  carry proposed counts, incoming changes, conflicts, and warnings. The buffer
  is foldable org, so old syncs collapse out of the way. It accumulates across
  the session and is rebuilt fresh only after the user kills the buffer.

- **Incoming changes append quietly.** Logging an incoming change does not pop
  the report window. Only conflicts, clock-skew, and parse warnings still steal
  a window — preserving today's behavior where a clean auto-sync does not flash
  the report every few seconds. The incoming history is there when the user
  chooses to look.

- **"Incoming" is computed against what this device pushed, not a raw
  Shadow→merged diff.** The merged result reflects the user's own accepted edits
  back, so a naive Shadow-vs-merged comparison would mislabel the user's own
  changes as remote. An entity counts as an incoming remote change only when the
  merged value differs from the candidate this device sent (by content
  signature), and the entity is not already reported as a conflict.

---

## Requirements

### Incoming changes

- R1. When a sync pulls a remote change to an entity the user did not edit
  locally, the report lists that entity under an "incoming from remote" section
  as a per-entity line carrying its title and kind (task / project / section /
  area).

- R2. Each incoming line is classified as created, updated, or deleted. A remote
  create is an entity present in the merged result but absent from the Shadow; a
  remote delete is an entity tombstoned in the merged result that was live in the
  Shadow; a remote update is any other content-signature difference.

- R3. The incoming set excludes the user's own accepted edits: an entity whose
  merged value matches the candidate this device pushed is not an incoming
  change. Comparison uses the content signature, so server-managed fields (`rev`,
  `updatedAt`, …) never register as changes.

- R4. The incoming set excludes entities already reported as conflicts. A
  conflict (the user edited locally and the server overrode it) appears only in
  the conflict section, never duplicated under incoming.

### Append-only log

- R5. Each sync worth reporting appends a new top-level org heading stamped with
  the sync time, rather than erasing and replacing prior report content.

- R6. A sync where nothing changed on either side (the HEAD-match no-op) does not
  append a heading. Only syncs carrying something to report — proposed changes,
  incoming changes, conflicts, skew, or parse warnings — produce an entry.

- R7. The log persists across syncs for the buffer's lifetime. When the user
  kills the report buffer, the next sync starts a fresh log. The buffer is
  in-memory only and is not written to disk.

### Restore behavior

- R8. The one-key restore action for a conflict stays live only on the most
  recent sync's heading. Conflict blocks under older sync headings are read-only
  history and carry no restore affordance.

- R9. When the report pops for an actionable event (conflict, skew, warning),
  point lands on the newest sync entry so the actionable content is visible
  without scrolling past prior history.

---

## Acceptance Examples

- AE1. Covers R1, R3. Mobile renames a task the user has not touched; the user
  also edits a different task locally and syncs. The report's incoming section
  lists the mobile-renamed task as updated. The user's own locally-edited task
  does not appear under incoming.

- AE2. Covers R2. Mobile deletes a project the user still has open at the desk.
  After sync, the incoming section lists that project as deleted, giving the user
  a record of why the heading disappeared.

- AE3. Covers R4. The user edits a task's title locally; mobile edited the same
  task more recently, so the server overrides the local edit. The task appears in
  the conflict section (with restore) and not under incoming.

- AE4. Covers R6. Auto-sync fires while neither side has changed. No new heading
  is appended; the log is unchanged.

- AE5. Covers R5, R8. Two syncs in a row each pull a distinct mobile change. The
  log shows two timestamped headings. If the second sync also had a conflict,
  restore works on the second (newest) heading only.

---

## Scope Boundaries

- Per-field detail for incoming updates (showing *what* changed within an entity,
  the way conflicts do) is deferred. Entity-level lines are the v1 shape.
- Persisting the log to a disk file is out of scope. The log is an ephemeral
  in-memory buffer.
- Acting on historical sync entries (restoring conflicts from older headings,
  re-triggering anything from a past sync) is out of scope — older entries are
  read-only history.

---

## Outstanding Questions

### Deferred to planning

- Newest-first vs oldest-first ordering of headings within the buffer, and where
  point rests on a quiet append vs an actionable pop. R9 fixes point on a pop;
  the quiet-append resting position and overall ordering are a UX call for
  planning.
- How the org-structured log coexists with the current `special-mode` keymap that
  drives restore (`r`) — whether the report mode derives from org-mode for
  folding or renders org-like text under a custom mode. An implementation choice,
  but it bears on R8's "newest heading only" restore scoping.

### Possible later revisits (user marked "for now")

- Whether incoming changes should eventually pop the window, not just append
  quietly (R3 / Key Decisions).
- Whether per-field detail for incoming updates is worth adding later.
