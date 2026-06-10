---
title: Clarify session re-opens a trashed item because its marker queue collapses on write-back
date: 2026-06-10
category: logic-errors
module: mindwtr-clarify
problem_type: logic_error
component: tooling
symptoms:
  - "Trashing an inbox item in a clarify session re-opens the same trashed item instead of advancing"
  - "The trashed item is correctly archived (keyword becomes ARCH) yet the WIP buffer reloads it"
  - "Every relocating outcome (project, next, calendar, someday) advances correctly; only trash misbehaves"
  - "User report: after trash, the session does not go to the next item automatically"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [clarify, gtd, marker, mw-id, queue, write-back, inbox, trash, position-vs-identity]
---

# Clarify session re-opens a trashed item because its marker queue collapses on write-back

## Problem
The clarify session walks a queue of inbox items one at a time. The queue was held as Emacs
**markers**, one per item heading. When an item's outcome was decided, the write-back replaced
that item's subtree up to the start of the next heading — and the next item's marker, sitting
exactly on that boundary, **collapsed onto the start of the re-pasted item**. The `trash`
outcome (which archives the item in place) exposed this: the session re-opened the
just-trashed item instead of advancing to the next one.

## Symptoms
- Trashing an item during a clarify session re-opened **the same trashed item** instead of the
  next inbox item.
- The item was correctly archived in the source (keyword became `ARCH`), yet the WIP buffer
  reloaded it.
- Every *other* outcome (project, next, calendar, someday, reference…) advanced correctly, so
  the bug looked outcome-specific rather than structural.
- Reported by the user as "after trash, it does not go to the next one automatically." (session history)

## What Didn't Work
The original **marker-based queue** — `mindwtr-clarify--pending` held a marker per item, each
validated positionally on advance:

```elisp
;; before — queue of markers, validated by position on advance
(while (and mindwtr-clarify--pending (not found))
  (let ((m (pop mindwtr-clarify--pending)))
    (if (and (marker-buffer m)
             (with-current-buffer (marker-buffer m)
               (save-excursion
                 (goto-char m)
                 (and (org-at-heading-p) (mindwtr-clarify--in-inbox-p)))))
        (setq found m)
      (set-marker m nil))))
```

**Why it appeared to work for every outcome except trash:** the decide write-back replaces an
item's subtree *up to the start of the next heading*. The next queue marker sat exactly on that
boundary, so on replacement it collapsed onto the start of the re-pasted (current) item — it no
longer pointed at the next item. For every *relocating* outcome, the decided item is then **cut
out of the inbox** and moved elsewhere; that cut shifts everything up, and the collapsed marker
slides forward and lands back on the *real* next heading — correct, but only **by sheer luck** of
the relocation cutting the item away again. `trash` is the one outcome that **leaves the item in
place** (archived to `ARCH`, no render bucket, no relocation), so nothing was cut away, the
collapsed marker stayed parked on the trashed item, and `--advance` re-opened it. The
`org-at-heading-p`/`in-inbox-p` guard couldn't catch it: the trashed item is still a heading at
that position.

The "works for every case but one, and only because a *later, unrelated* step happens to fix up
the state" behavior is the tell — the design relied on a side effect of relocation, not on a
guarantee. Any future non-relocating outcome (a hypothetical "defer"/"snooze" that keeps the item
in the inbox) would have triggered the identical bug. (session history)

## Solution
Track the queue by **MW_ID** (stable UUID) instead of buffer markers. IDs survive the
subtree-replacing rewrites, relocations, and user edits that move or invalidate marker positions
(`mindwtr-clarify.el`, commit `749b95b`).

The queue field changed from markers to ids, and the session records its source buffer once:

```elisp
;; before
(defvar mindwtr-clarify--pending nil
  "Markers at the inbox items still to clarify in the current session.")

;; after — field now holds ids, not markers (docstring keeps the full rationale)
(defvar mindwtr-clarify--pending nil
  "MW_IDs of the inbox items still to clarify in the current session.")

(defvar mindwtr-clarify--source nil
  "The synced buffer the current clarify session walks.")
```

`--start` stamps an id on any item lacking one (a hand-written heading would get one on the next
sync anyway), then releases the markers immediately:

```elisp
;; in --start, given the inbox-item MARKERS (in order):
(setq mindwtr-clarify--source (and markers (marker-buffer (car markers)))
      mindwtr-clarify--pending
      (mapcar (lambda (m)
                (prog1
                    (with-current-buffer (marker-buffer m)
                      (save-excursion
                        (goto-char m)
                        (org-back-to-heading t)
                        (or (mindwtr-parse--prop "MW_ID")
                            (let ((new (mindwtr-util-uuid)))
                              (org-set-property "MW_ID" new)
                              new))))
                  (set-marker m nil)))
              markers))
```

`--advance` re-finds each id by scanning the live source buffer, silently dropping any id whose
heading vanished or already left the inbox:

```elisp
;; after — re-find each id in the live buffer; drop ids that left the inbox
(while (and mindwtr-clarify--pending (not found))
  (let ((id (pop mindwtr-clarify--pending)))
    (when (buffer-live-p mindwtr-clarify--source)
      (with-current-buffer mindwtr-clarify--source
        (let ((pos (mindwtr-clarify--find-heading-by-id id)))
          (when (and pos
                     (save-excursion
                       (goto-char pos)
                       (mindwtr-clarify--in-inbox-p)))
            (setq found (cons id pos))))))))
(if (not found)
    (mindwtr-clarify--finish "done")
  (mindwtr-clarify--open-wip (car found) (cdr found)))
```

## Why This Works
**Positional markers are fragile across subtree-replacing buffer rewrites.** A marker is an
offset that Emacs auto-adjusts on insert/delete, but at the *exact boundary* of a replaced region
its behavior is ambiguous: when the write-back replaces `[heading-start … next-heading-start)`, a
marker sitting on `next-heading-start` collapses onto the start of the freshly inserted text
rather than tracking the logically-next item. The queue's invariant ("this marker points at the
next item") silently broke; relocating outcomes happened to restore it by cutting the current item
away, which is a coincidence of the relocation path, not a guarantee.

A **stable entity identity (MW_ID)** is a property *of the item*, not a coordinate *into the
buffer*, so it is invariant under buffer position changes, relocation, and user edits. Re-finding
the id on each `--advance` reconstructs the position from scratch against current buffer state, so
it is immune to the boundary-collapse mechanism entirely. It also yields a principled drop
condition: an id that no longer resolves to an inbox heading (vanished, archived in place, or
clarified by other means) is simply skipped — exactly the behavior trash needed.

## Prevention
- When a queue, cursor, or anchor must survive *in-place buffer rewrites that splice out and
  re-insert regions*, key it on **stable identity, not buffer position**. Markers are safe for
  read-only traversal but unreliable when the very regions they border get replaced. If the entity
  already carries a durable identity (here, the MW_ID sync key — see
  [[entity-identity-mw-id-mw-list]]), use it and re-resolve position on demand.
- Watch for the smell: "it works for every case except one, and only because a *later, unrelated*
  step happens to fix up the state." Relying on a side effect of a downstream step — rather than on
  an invariant the code guarantees — is a latent bug waiting for the one path that omits that step.
- Cover multi-item advance, not just single-outcome routing. The clarify suite had 385/385 passing
  when the bug shipped because it tested outcome routing and field mutation but never exercised the
  advance-after-trash path. (session history) The regression test
  `mindwtr-clarify-trash-advances-to-next-item` sets up two inbox items, trashes the first, and
  asserts both halves: the WIP now shows the next item (`looking-at-p "\\* INBOX Two"`,
  `mindwtr-clarify--source-id` = `"t2"`) **and** the trashed item really archived
  (`keyword-of "One"` = `"ARCH"`). It was confirmed red against the marker version, green after the
  fix. (session history)

## Related Issues
- Commit `749b95b` (markers → MW_IDs). The marker-based queue was carried unchanged through the
  org-gtd WIP-buffer rebuild (`f678f38`) before the trash path exposed it.
- [[reconcile-partial-update-reverts-remote-edits]] — the **sibling** of this bug. Same marker
  mechanic ("deleting/replacing a region collapses every marker inside it onto the boundary"), a
  different remedy: that fix keeps markers valid by **inserting before deleting**; this one
  **abandons markers for stable ids**. Together they are the two halves of "markers are fragile
  across subtree replacement — either order your mutations, or stop using markers."
- [[entity-identity-mw-id-mw-list]] — why MW_ID is the correct stable handle and why hand-written
  headings can be stamped one lazily.
- [[preserving-buffer-view-state-across-reconcile]] — the canonical statement of "key to stable
  IDs, never positions" across a buffer rebuild; this is the same principle applied to a session
  queue rather than fold/scroll state.
