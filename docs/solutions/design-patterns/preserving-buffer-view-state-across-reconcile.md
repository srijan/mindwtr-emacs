---
title: Preserving Emacs buffer view state across a full reconcile rebuild
date: 2026-06-03
last_updated: 2026-06-04
category: design-patterns
module: mindwtr-reconcile
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "An Emacs command rebuilds a buffer the user is actively viewing (erase-buffer + insert)"
  - "View state (folds, point, scroll) must survive a from-scratch rebuild"
  - "Headings carry stable identity keys (e.g. MW_ID / MW_LIST) usable as restore anchors"
  - "The rebuild runs on a background/periodic trigger that can fire mid-session"
  - "The package must support an Org version floor where org-fold-* is absent (Org 9.5 / Emacs 28.1)"
tags: [emacs, org-mode, buffer-view, fold-state, reconcile, scroll-anchor, recenter, cross-version]
---

# Preserving Emacs buffer view state across a full reconcile rebuild

## Context
`mindwtr-reconcile-buffer` is the heart of the sync path. After the server PUT commits, it
rebuilds the entire org buffer to the canonical GTD layout via `erase-buffer` + `insert` of
freshly rendered text. The full-rebuild approach is deliberate (the stopgap explicitly defers
signature-diffed in-place rewriting, tracked as issue #5) and has a real virtue:
render-before-erase means a render error leaves the buffer intact.

But a from-scratch rebuild produces a buffer that is **fully expanded, scrolled to the top,
with point at `point-min`**. The original code restored only point-to-heading. Everything else
the user could see was destroyed: collapsed subtrees sprang open, the global S-TAB cycle level
was lost, the window jumped (raw `window-start` is a char offset that points at unrelated text
after a rebuild), and point landed on the heading-start even if the user was editing deep in a
description. Because reconcile fires on periodic/focus auto-sync, this reset happened
**mid-session, unprompted** — "if a background sync keeps yanking the buffer out from under the
user, the desk surface isn't a joy to edit."

## Guidance
**Snapshot view state into an identity-keyed plist before the rebuild, reapply it after** —
three independent dimensions (folds, point, scroll), each degrading gracefully to "restore
nothing."

**Key everything to stable IDs, never positions.** Char offsets are meaningless after
`erase-buffer`+`insert`. Anchor every restorable thing to a heading's stable key — `MW_ID` for
entities (UUIDs), `MW_LIST` role for containers (Inbox, Projects, …). They never collide, so
one regex resolves either:

```elisp
(defun mindwtr-reconcile--goto-id (id)
  (when id
    (goto-char (point-min))
    (let ((re (format ":MW_\\(?:ID\\|LIST\\): *%s *$" (regexp-quote id))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)))))
```

**Snapshot must run BEFORE `mindwtr-parse-ensure-keywords`** — an implementation-time
discovery. That function can re-init org-mode (when the buffer's TODO keywords aren't
registered), and `(org-mode)` **wipes all fold state**. Snapshotting after it read a
fully-unfolded buffer every time (a probe confirmed `snap-t1=nil` — the snapshot saw no folds).
The fix was to hoist the snapshot to fire before `ensure-keywords`. *(session history)*

**Snapshot must use only cross-version-safe calls so it cannot throw.** The project floor is
Emacs 28.1 / Org 9.5, where the `org-fold-*` namespace doesn't exist (it arrived in Org 9.6).
An unguarded `org-fold-folded-p` would raise `void-function` on the minimum supported platform
— and the snapshot runs *after* the committed PUT and *outside* the restore guard, so a throw
there would abort an already-successful sync. Detection uses only `org-invisible-p`,
`org-current-level`, `window-start` (present and consistent on Org 9.5–9.8); fold *operations*
(restore-only) `fboundp`-dispatch to legacy `outline-*`: *(session history)*

```elisp
(defun mindwtr-reconcile--hide-subtree ()
  (if (fboundp 'org-fold-hide-subtree) (org-fold-hide-subtree) (outline-hide-subtree)))
(defun mindwtr-reconcile--hide-entry ()
  (if (fboundp 'org-fold-hide-entry) (org-fold-hide-entry) (outline-hide-entry)))
```

**Capture per-heading fold state as a three-way distinction** keyed by `(or MW_ID MW_LIST)`,
recorded only for headings whose own line is currently visible (a heading hidden because an
ancestor is collapsed is skipped — the ancestor's record covers it):

```elisp
(org-map-entries
 (lambda ()
   (let ((key (or (mindwtr-parse--prop "MW_ID")
                  (mindwtr-parse--prop "MW_LIST"))))
     (when (and key (not (org-invisible-p (line-beginning-position))))
       (puthash key
                (cond ((not (org-invisible-p (line-end-position))) 'open)
                      ((mindwtr-reconcile--child-heading-shown-p)   'contents)
                      (t                                            'folded))
                folds)))))
```

**Restore over the freshly-expanded buffer ONLY HIDES**, top-down, guarded by heading-line
visibility. Because the rebuilt buffer starts fully expanded, `open` is the default — nothing
to do. A `folded` ancestor hides its descendants first, so their now-invisible headings are
skipped; a `contents` ancestor hides only its own body, leaving children to apply their own
records. (The exact restore loop, contrasted against the inferior PR #1 version, is in
[Examples](#examples) below.)

**Restore scroll by content, not offset** — find the heading at/after the pre-rebuild
`window-start`, store its key (`:top-id`), and after the rebuild `set-window-start` to that
heading if it still resolves. **Wrap the whole restore in `condition-case ... (error nil)`** —
reconcile runs after the PUT commits, so a fold/redisplay hiccup that threw would surface as a
*spurious sync failure* even though the server already succeeded. Restore touches only visual
state (fold overlays, `window-start`/`recenter`), never content, so `buffer-modified-p` is
untouched by the restore itself. (Note: with PR #29 the engine now *auto-saves* after a
content-changing reconcile, so the buffer ends up **clean** on disk — see
[[save-as-sync-commit-point]]. That clean state comes from the engine save, not from restore;
restore remains content-neutral.)

**Pin the anchor heading's *screen row*, not just its first line** (PR #28). The `:top-id`
approach snapped `window-start` to a heading boundary, which still nudged the viewport: any
reflow at or above the anchor (property-drawer changes, body-length changes) moved the row the
user was reading. The refinement captures the anchor heading's **0-based screen line** before the
rebuild and reproduces it with `recenter` after — `count-screen-lines` (snapshot) and `recenter`
(restore) share the same 0-based row index, so a captured row N round-trips to N. This is a
*hybrid*, not a replacement: `:anchor-line` is the primary path; `:top-id` stays as the
off-screen fallback (retiring it would leave no recovery when the anchor scrolled off screen).
*(session history)*

```elisp
;; Snapshot -- record :anchor-line only when the heading is in the live window's
;; visible region, measured against the reconcile window WIN (not the selected one).
(let ((heading-pos (mindwtr-reconcile--anchor-heading-pos)))  ; (or MW_ID MW_LIST) walk-up
  (when (and heading-pos
             (<= (window-start win) heading-pos)
             (< heading-pos (window-end win)))
    (setq anchor-line (count-screen-lines (window-start win) heading-pos nil win))))

;; Restore -- recenter on the SELECTED window; WIN is often NOT selected on a
;; background sync, so re-assert the heading position before recentering.
(cond
 (anchor-line
  (let ((pt (point)))
    (with-selected-window win (goto-char pt) (recenter anchor-line))))
 (top-id
  (save-excursion
    (when (mindwtr-reconcile--goto-id top-id)              ; off-screen fallback
      (set-window-start win (line-beginning-position))))))
```

Pass the reconcile window explicitly to `count-screen-lines` and run `recenter` inside
`with-selected-window` — reconcile fires on background/focus sync, when the buffer's window is
frequently *not* the selected window, and an implicit measurement would compute the row against
the wrong window's width and wrapping. *(session history)*

## Why This Matters
Without this, every background sync visibly resets the buffer mid-edit, making the editing
surface hostile.

**The key compounding lesson is the evolution from the first fix (PR #1) to the second
(PR #23).** PR #1 restored a **global S-TAB cycle backdrop**: it captured
`org-cycle-global-status` (`overview`/`contents`/`all`/nil) and on restore applied
`org-overview`/`org-content` *first*, then ran a per-entity pass to re-open specific entities
on top. Container headings had no `MW_ID`, so they were *only* approximated by this backdrop —
that was the entire reason it existed.

This was inferior, and actually **buggy**, for a subtle reason: **`org-cycle-global-status` is a
stale, coarse proxy for the real per-heading state.** Local TAB expansions never reset that
variable. So a buffer opened folded (`overview`) and then worked in (TAB-expanding subtrees
locally) *still reported `overview`*. Every sync faithfully re-applied the `org-overview`
backdrop and **re-collapsed the whole buffer**, then the per-entity pass could only reopen the
dwindling set of entities still recorded as visible. The view **degraded further each sync** —
recorded-fold count was observed dropping 15 → 1 across successive syncs. *(session history)*

PR #23 fixed this by **dropping the backdrop entirely** and restoring fold state precisely per
heading. Two changes made that possible: (1) key folds by `(or MW_ID MW_LIST)` so containers
have a stable key too — removing the only reason the backdrop existed; (2) restore only ever
*hides* over the freshly-expanded buffer, so a sync can never fold more than the user actually
had folded. overview, contents, and fully-expanded all round-trip cleanly, and the
degrade-each-sync loop is gone.

> **The lesson: when restoring view state, derive it from the precise, per-element observable
> truth (what is actually hidden, per stably-keyed element), not from a coarse global mode flag
> that drifts out of sync with reality.** A global "current level" variable is a tempting
> shortcut but a lossy, often-stale summary; reconstructing from it over-applies.

A secondary PR #23 refinement: point and scroll anchors were originally `MW_ID`-only, so a
cursor parked on a *container* heading (which has only `MW_LIST`) resolved to nil and the
rebuild dumped point to `point-min`. Keying point/scroll by `(or MW_ID MW_LIST)` — the same way
folds are keyed — means a cursor on `* Projects` lands back on Projects after sync.

**The scroll dimension then went through a third iteration (PR #28): heading-granularity →
pixel-stable.** PR #23's `:top-id` was *content*-keyed (good) but still *heading-granular* — it
re-pinned the top of the window to a heading boundary, so the entry being read jumped a few rows
on every background sync even when its own content was unchanged. PR #28 replaced the primary
path with a screen-row `recenter` anchor (above): pin where the anchor heading sat *on screen*,
not where its first line lands. Two candidate designs were weighed — a plain `recenter` at the
saved point vs. measuring the anchor heading's screen line — and an adversarial review kept
`:top-id` as the off-screen fallback rather than retiring it, since recentering on an off-screen
point yanks the viewport to the top. *(session history)*

Two failure modes were caught in review and locked in with regression tests:

- **Stale window-point on a background sync.** Selecting a non-selected window resets buffer
  point to *that window's* own stored point, so `recenter` would center on a stale line. Restore
  re-asserts the heading position inside `with-selected-window` before recentering. The test
  asserts the recenter uses buffer point, not the stale window-point. *(session history)*
- **Anchor entity deleted by the same sync.** `--goto-id` then strands point at `point-min`;
  recentering there yanks the viewport to the top — the exact jump this change exists to prevent.
  So `mindwtr-reconcile-buffer` drops `:anchor-line` when the anchor no longer resolves, falling
  back to `:top-id`:

  ```elisp
  (unless (mindwtr-reconcile--goto-id at-id)
    (setq view (and view (plist-put view :anchor-line nil))))
  ```

`recenter`'s batch-mode determinism was verified before the windowed tests were written (a probe
confirmed `recenter 5` then `count-screen-lines` round-trips to 5), so the tests assert real rows
rather than skipping in non-interactive mode. *(session history)*

## When to Apply
- Any time an Emacs command rebuilds a buffer the user is actively viewing (full
  `erase-buffer`+`insert`, regeneration, re-render) rather than editing in place.
- When the rebuild can fire on a background/periodic trigger, so the reset is unprompted.
- Key all restored state (folds, point, scroll) to **stable per-element identifiers**, never to
  buffer positions or char offsets.
- Prefer reconstructing view state from the **precise per-element observable** (per-heading
  visibility) over a **coarse global mode variable**.
- When the operation runs *after* an irreversible side effect (a committed server write), wrap
  restore in `condition-case` so a cosmetic failure can't masquerade as an operation failure.
- When supporting an API version floor that lacks newer namespaces (Org 9.5 lacks `org-fold-*`),
  restrict the pre-rebuild snapshot to version-safe detection calls and `fboundp`-dispatch the
  operations.

## Examples
**Fold restore — global backdrop (PR #1, inferior) vs precise per-heading (PR #23, final):**

```elisp
;; BEFORE (PR #1): backdrop-then-override. Re-collapses the whole buffer to a STALE
;; org-cycle-global-status, then reopens recorded entities. Degrades each sync because
;; `overview' lingers after local TAB expansions.
(pcase global
  ('overview (org-overview))
  ('contents (org-content)))
(org-map-entries
 (lambda ()
   (let* ((id (mindwtr-parse--prop "MW_ID"))
          (st (and id (gethash id folds))))
     (cond ((eq st 'folded) (mindwtr-reconcile--hide-subtree))
           ((eq st 'open)   (mindwtr-reconcile--show-entry))))))

;; AFTER (PR #23): no backdrop. Buffer starts fully expanded; we ONLY hide, top-down,
;; keyed by (or MW_ID MW_LIST), guarded by heading-line visibility. Can never fold more
;; than the user actually had folded.
(org-map-entries
 (lambda ()
   (let* ((key (or (mindwtr-parse--prop "MW_ID") (mindwtr-parse--prop "MW_LIST")))
          (st  (and key (gethash key folds))))
     (when (not (org-invisible-p (line-beginning-position)))
       (pcase st
         ('folded   (mindwtr-reconcile--hide-subtree))
         ('contents (mindwtr-reconcile--hide-entry)))))))
```

The snapshot likewise dropped `:global`, replaced the two-state (`folded`/`open`) hash with a
three-state (`open`/`contents`/`folded`) hash, and changed the key from `MW_ID` to
`(or MW_ID MW_LIST)`. A provably-no-op `'all` backdrop branch was added then removed in review
— a fresh `erase`/`insert` is fully visible and the per-entity pass already re-folds what the
user had folded, so an `'all` backdrop applies nothing. *(session history)*

**Point/scroll container fix (PR #23)** — `--id-at-point` gained an `MW_LIST` fallback so a
cursor on a container heading resolves to a stable key instead of nil:

```elisp
;; BEFORE: MW_ID-only — cursor on `* Projects' (no MW_ID) returned nil; rebuild dropped
;;         point to point-min.  AFTER:
(let ((own-list (mindwtr-parse--prop "MW_LIST"))
      (id       (mindwtr-parse--prop "MW_ID")))
  (while (and (not id) (org-up-heading-safe))
    (setq id (mindwtr-parse--prop "MW_ID")))
  (or id own-list))
```

The scroll-anchor regex was widened the same way: `:MW_ID:` → `:MW_\(?:ID\|LIST\):`.

## Related
- Merge commits: PR #1 = `fba8b6b` (the stopgap); PR #23 = `787e8eb` (fixes #22). The
  degrade-each-sync fix is `49a9556`; the container point/scroll fix is `12c51cc`. The
  pixel-stable scroll iteration is PR #28 = `ebeefe7` (Closes #25); regression tests in
  `test/mindwtr-reconcile-test.el` (windowed recenter round-trip; stale-window-point;
  off-screen `:top-id` fallback; end-to-end deleted-anchor through `reconcile-buffer`).
- The **trigger-side** counterpart that stops the rebuild from firing mid-edit at all is
  [[save-as-sync-commit-point]] (PR #29) — this doc makes the rebuild *less jarring* when it
  fires; that one mostly stops it firing while you have unsaved edits. The two are complementary
  defenses.
- Full signature-diffed incremental reconciliation is deliberately deferred — issue #5.
- A separate multi-agent review flagged (3 reviewers, confidence 100, elevated to P1) that the
  snapshot ran outside the post-PUT `condition-case`; the snapshot was given its own guard
  before the PR shipped. *(session history)*
- Adjacent reconcile/sync-integrity work: [[silent-deletion-untyped-org-headings]] (quarantine
  before erase) and [[org-markdown-link-conversion-roundtrip]] (signature byte-stability).
