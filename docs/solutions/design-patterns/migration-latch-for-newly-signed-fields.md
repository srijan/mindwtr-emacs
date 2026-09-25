---
title: "Migration-latch pattern: guard the first sync after signing a field old buffers never rendered"
date: 2026-06-09
category: design-patterns
module: mindwtr-shadow / mindwtr-sync
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Promoting a field into the content-signature allow-list (`mindwtr-model-content-fields`)"
  - "Existing on-disk buffers were written by a renderer that never emitted that field's value"
  - "An absent/empty parse of the field is indistinguishable from a deliberate user clear"
  - "Change detection PUTs an empty value over a server-authored value (last-write-wins)"
  - "The field can be authored on another client (mobile) the local buffer has never seen"
tags:
  - migration-latch
  - data-loss
  - change-detection
  - content-signature
  - deploy-transition
  - shadow-state
  - last-write-wins
  - sync
---

# Migration-latch pattern: guard the first sync after signing a field old buffers never rendered

## Context

mindwtr-emacs syncs local org buffers with Mindwtr Cloud. Change detection works by hashing a "content signature" over an *allow-list* of fields (`mindwtr-model-content-fields` in `mindwtr-model.el`) and comparing the parsed buffer against the **shadow** (the last-known-server copy). A field that is not on the allow-list is invisible to change detection: it can neither drift a signature nor be clobbered, because it is preserved verbatim in the shadow and merged back on write.

an earlier PR promoted `:supportNotes` (project notes) onto that allow-list (commit `c7bd3fa`) so project notes finally participate in change detection, write-merge, and the override report. The allow-list is deliberately kind-agnostic and shared by every consumer — signature, `mindwtr-sync--merge-content`, and the report field-diff all read the same list — so the promotion was a one-line change to the `defconst`.

That one line opened a data-loss trap on the *first sync after the upgrade*. This doc is about the pattern that closes it: a **one-way migration latch** in the shadow. The hole was not in the original plan — it was surfaced across two separate rounds of post-implementation code review, and the *second* review found that the first fix was itself still subtly wrong (see Why This Matters). *(session history)*

## Guidance

**When you start signing a field that EXISTING buffers were written without rendering, the first post-upgrade sync is a data-loss trap. Gate it with a one-way migration latch in the shadow, and flip the latch only after a CONFIRMED save.**

The mechanism has three parts.

**1. A persistent one-way latch in the shadow** (`mindwtr-shadow.el`). Latches are rows in `mindwtr-shadow-latches` (`notes`, `fields` for the reserved boolean drawer fields, `archive` for the archive surface); a new latch is one more row:

```elisp
(defconst mindwtr-shadow-latches
  '((notes . "notes-migrated")
    (fields . "fields-migrated")
    (archive . "archive-migrated")) ...)
(defun mindwtr-shadow-latched-p (latch)
  (and (mindwtr-shadow--get (mindwtr-shadow--latch-key latch)) t))
(defun mindwtr-shadow-latch (latch)
  (mindwtr-shadow--put (mindwtr-shadow--latch-key latch) "1"))
```

**2. Pre-migration protection in the merge** (`mindwtr-sync--merge-content` takes a `protected-set` list). While the latch is unset, an *empty* local value for the protected notes field keeps the shadow value instead of clearing it. A real edited value is still adopted — protection suppresses only an empty local value, never a genuine edit:

```elisp
(if (mindwtr-sync--empty-p lv)
    ;; `:status' is mandatory ... never an intentional clear -- so keep SV.
    ;; PROTECTED-SET: a field the buffer could not yet render must
    ;; likewise keep SV (pre-migration), never clear.
    (unless (or (eq k :status)
                (and (memq k protected-set)
                     (not (mindwtr-sync--empty-p sv))))
      (setq out (mindwtr-sync--plist-remove out k)))
  (setq out (plist-put out k lv)))
```

`mindwtr-sync-build-candidate` takes `protect-empty-notes` and `protect-empty-fields` and unions, per kind, the notes field (non-task only, via `mindwtr-model-notes-field`) with `mindwtr-model-protected-boolean-fields`:

```elisp
(protected-set
 (append
  (and protect-empty-notes (not (eq kind 'task))
       (let ((nf (mindwtr-model-notes-field kind))) (and nf (list nf))))
  (and protect-empty-fields
       (mindwtr-model-protected-boolean-fields kind))))
```

The protected field is computed here, in `build-candidate`, rather than read from the parsed entity — because the parse path strips `:mw-kind`, so `merge-content` cannot recover the kind from the entity plist it receives. `build-candidate` is the layer that still knows the kind, so it passes the resolved set down explicitly. *(session history)*

Tasks are deliberately *never* protected: the old renderer always emitted a task `:description`, so an empty one is a real edit, not a pre-render artifact.

**3. Latch only after a confirmed save** (`mindwtr-sync--put-get`, the async push stage). The candidate is built with protection on until migrated:

```elisp
(protect-empty-notes (not (mindwtr-sync-cycle-latched-p cycle 'notes)))
(protect-empty-fields (not (mindwtr-sync-cycle-latched-p cycle 'fields)))
(candidate (mindwtr-sync-build-candidate local shadow device now
                                         protect-empty-notes protect-empty-fields))
```

and after `mindwtr-sync--finish` reconciles and saves every surface, `mindwtr-shadow-commit` writes shadow, etag, then latches — latches only when no save failed:

```elisp
(let ((save-failed (mindwtr-sync--save-surfaces surfaces)))
  (mindwtr-shadow-commit
   merged (plist-get got :etag)
   (unless save-failed
     (append '(notes fields)
             (and (mindwtr-sync-cycle-archive-active cycle) '(archive))))))
```

`mindwtr-shadow-commit` wraps each latch flip in its own `condition-case` (post-PUT must not throw).

The no-op branch intentionally does **not** latch: a no-op skips reconcile, so the buffer still holds the old note-less render and protection must stay on.

## Why This Matters

**The concrete data-loss scenario.** A project note authored on mobile lives in the server's `:supportNotes`. Before the upgrade the Emacs renderer never wrote project-note bodies into the buffer, so the on-disk `.org` has no note text. After upgrading, `:supportNotes` is on the allow-list. On the first sync:

1. Parse reads the absent note as an **empty** value.
2. Change detection compares empty (local) against the server note (shadow) — they differ, so it classifies this as a user **clear**.
3. The client PUTs the cleared field, and last-write-wins overwrites the mobile-authored note on the server.

Verified in the original review: a populated `:supportNotes` went to `nil` with a rev bump. This is silent data loss across a deploy/upgrade transition — exactly the kind of bug that does not appear in any single-version test, because the hazard lives in the *seam between two renderer versions*. (An adjacent, pre-existing instance of the same class: a section's server-authored `:description` was already being silently cleared to empty on *every* sync before this work, because it was never rendered → parsed nil → classified as an update. The notes round-trip fixed that as a side effect.) *(session history)*

The latch closes the seam: until a notes-capable client has reconciled the buffer at least once (re-rendering the note into it), an empty non-task note is treated as "not yet migrated" and the shadow value is preserved rather than cleared. After that first reconcile, the buffer genuinely carries the note, so a future empty value is a real clear and protection is dropped.

**Why latch-after-confirmed-save and not optimistically (commit `e18f21a`).** The latch was originally set right after `mindwtr-reconcile-buffer`, *before* the buffer was saved. A second code-review round flagged this as a data-loss path: if the save fails (read-only FS, full disk), the latch records "migrated" while the on-disk `.org` still holds the old note-less render. A later reload from that stale file parses empty notes with protection now **off**, and clears the server note via LWW — the exact bug the latch was built to prevent, merely deferred by one cycle. *(session history)*

The ordering rule is therefore: **the latch must fire only after the migrated state is durably observable.** The thing the latch *attests to* is "the note is rendered in the on-disk buffer," and that fact is not true until the save confirms. Latching on intent rather than on confirmed durability re-exposes the clobber. Each latch write is `condition-case`-guarded inside `mindwtr-shadow-commit` because it runs post-PUT — the server has already committed, so a latch-write hiccup must not throw and fail the sync.

## When to Apply

Reach for this pattern whenever **all** of the following hold:

- You are adding a field to a change-detection allow-list (or otherwise making a previously-ignored field participate in diff/write).
- Buffers/files already on disk were produced by code that did not render that field.
- An absent or empty parse of the field is **ambiguous** — it could mean "user cleared it" or "this artifact predates the field being rendered."
- The field can hold authoritative data authored elsewhere (another device, another client) that the local artifact has never observed.
- Your write path is last-write-wins or otherwise capable of pushing the empty value.

If the field was *always* rendered (like task `:description`), no latch is needed — an empty value is unambiguous. The latch is precisely for distinguishing "intentionally empty" from "empty because old."

**Connected discipline — allow-list-LAST.** `:supportNotes` was promoted to the allow-list (`c7bd3fa`) only *after* a byte-stability round-trip oracle (U2) proved the note round-trips through org and back unchanged. Promote-the-field-last is the upstream discipline; the migration latch is the downstream guard for the deploy seam that promotion opens. They are two halves of the same safe-rollout practice — see Related.

## Examples

**Before (the hazard, captured as a regression test `mindwtr-sync-deploy-transition-preserves-project-note`):** a stale buffer with a project heading but no body, against a shadow whose `:supportNotes` is `"Mobile-authored note."`. Without protection, the candidate clears it:

```elisp
;; WITHOUT protection the note is clobbered (documents the hazard)
(let ((proj (car (plist-get (mindwtr-sync-build-candidate
                             local shadow "dev-1" "NOW" nil) :projects))))
  (should (null (plist-get proj :supportNotes))))
```

**After (with the latch unset → protection on):**

```elisp
;; WITH protection (pre-migration) the server note is preserved
(let ((proj (car (plist-get (mindwtr-sync-build-candidate
                             local shadow "dev-1" "NOW" t) :projects))))
  (should (string= (plist-get proj :supportNotes) "Mobile-authored note.")))
```

**Protection is narrow.** A real edited note is still adopted pre-migration (`mindwtr-sync-protect-notes-still-adopts-a-real-edit`), and a genuinely emptied task `:description` still clears because tasks were always rendered (`mindwtr-sync-protect-notes-does-not-block-task-description-clear`).

**The save-ordering fix, captured as two regression tests** (modeled on the existing `save-failure-is-isolated` test): *(session history)*

- `mindwtr-sync-once-save-failure-does-not-latch-notes-migration` — with `save-buffer` stubbed to error ("disk full"), the cycle returns `:save-failed t` and `(mindwtr-shadow-latched-p 'notes)` stays `nil`, so protection survives for the next sync.
- `mindwtr-sync-once-latches-notes-migration-after-successful-save` — a clean full cycle returns `:save-failed nil` and the latch reads `t` afterward, so subsequent syncs stop protecting empty notes.

The bare latch round-trip itself is covered by `mindwtr-shadow-notes-migrated-latch` in `test/mindwtr-shadow-test.el`.

## Related

- [[content-signature-allow-list-not-deny-list]] — the allow-list discipline this field was promoted onto. Note the **allow-list-LAST** ordering: prove the field round-trips byte-stably *before* signing it. That promotion is what opens the deploy seam this latch guards.
- [[save-as-sync-commit-point]] — why the confirmed save is the commit point that the migration latch must fire after. The latch attests to durable on-disk state, so it is gated on `(not save-failed)` exactly as other post-save shadow writes are.
- [[silent-deletion-untyped-org-headings]] — adjacent data-loss-by-construction work in the same sync path; same class of "absent input read as an intentional removal."
- GitHub an earlier PR (commits `c7bd3fa` promote-to-allow-list, `b9f0a43` introduce latch, `e18f21a` latch-after-confirmed-save; generalized by `fedf6b7` (field-set guard) and `87c1b30` (latches flip via `mindwtr-shadow-commit`)).
