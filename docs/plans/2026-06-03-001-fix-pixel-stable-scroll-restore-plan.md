---
title: "fix: Pixel-stable scroll restore after reconcile via anchor-heading recenter"
type: fix
status: completed
date: 2026-06-03
origin: https://github.com/srijan/mindwtr-emacs/issues/25
depth: lightweight
---

# fix: Pixel-stable scroll restore after reconcile via anchor-heading recenter

## Summary

After a sync, `mindwtr-reconcile-buffer` rebuilds the whole file and re-anchors the window by
snapping it to the next `MW_ID`/`MW_LIST` heading at/after the pre-rebuild `window-start`. That
snap is only heading-granular: the viewport nudges a bit because the anchor discards how far
`window-start` sat into the previous entity, and because the rebuild reflows drawers so the
same heading no longer lands on the same screen row.

This plan makes the scroll restore **anchor-heading-relative** with a viewport-truthful
fallback. When the entity point will be restored to (the `at-id` anchor) was on-screen before
the rebuild, capture that heading's screen-line position and reproduce it with `recenter` after
the rebuild — the heading returns to its exact prior row, immune to drawer reflow below it.
When the anchor heading was *off-screen* (a background sync can fire while the user has scrolled
away without moving point), fall back to the existing `window-start` (`:top-id`) anchor, which
is truthful to what was actually at the top of the viewport. The fold and point-to-entity
restoration from an earlier PR (issue #20) are unchanged; only the scroll step changes. (see origin:
issue #22)

This is a low-severity polish fix serving the **Emacs-native editing** track in `STRATEGY.md`:
a background sync should not visibly move the buffer under the user.

---

## Problem Frame

`mindwtr-reconcile--snapshot-view` records `:top-id` — the first `MW_ID`/`MW_LIST` property
line at/after `(window-start win)` — and `mindwtr-reconcile--restore-view` re-anchors via
`(set-window-start win (line-beginning-position))` on that heading after the rebuild. Three
things make the restore imprecise (per issue #22):

1. **Heading-granularity snap.** The anchor is always the *next heading* at/after
   `window-start`, so a window that started mid-body or mid-drawer snaps to that heading's top,
   shifting the viewport.
2. **First line, not the original offset.** Restore uses the heading's `line-beginning-position`,
   discarding how far `window-start` was from it.
3. **Content reflow.** The rebuild rewrites drawers (`:MW_CREATED:` / `:MW_UPDATED:` /
   `:MW_AREA:`), so the same heading occupies a different screen row than before — any
   line-offset-based fix is stale the moment drawers reflow.

The reconcile path runs **after** the server PUT has committed (`mindwtr-sync.el`, past the
`buffer-chars-modified-tick` guard), so the restore must never throw and must touch only visual
state. The full-rebuild approach and the earlier PR fold/point machinery stay; this is a surgical
change to the scroll dimension only.

**In scope:** the scroll/vertical-position restore. **Not** in scope: cursor column / in-body
position preservation (point still lands on the entity heading-start, as today — explicitly
opted out of in the earlier PR brainstorm), and full signature-diffed incremental reconciliation
(deferred — see issue #3).

---

## Requirements

Traced from issue #22:

- **R1.** After a reconcile, the anchor entity's heading is returned to the vertical screen
  position it occupied before the rebuild: when it was on-screen, point (restored to that
  heading) is `recenter`ed to the heading's prior screen line, so the viewport does not visibly
  jump. (addresses imprecisions 1, 2, and 3 for the on-screen case)
- **R2.** The on-screen restore must be robust to content reflow *at or below the anchor
  heading* — it must not depend on line counts within the *rebuilt* buffer below the heading.
  The heading's screen line is measured pre-rebuild and reproduced by row. (Reflow in the
  region *above* the anchor heading — between `window-start` and the heading — still perturbs the
  count; measuring from the heading rather than the user's raw point keeps that region small.)
- **R2b.** When the anchor heading was *off-screen* before the rebuild, restore must fall back
  to the `window-start`-derived `:top-id` anchor (an earlier PR behavior) rather than recentering on an
  off-screen point — recentering there would scroll the viewport away from what the user was
  looking at.
- **R3.** With no live window (batch / `with-temp-buffer`), the scroll restore is a clean no-op:
  no anchor line and no `:top-id` resolve, `recenter`/`set-window-start` are skipped, no error.
- **R4.** Restore must never throw (the post-PUT `condition-case` is preserved) and must not
  perturb `buffer-modified-p` — it touches only `point`/window scroll, never content.
- **R5.** Fold restoration and point-to-entity restoration from an earlier PR are unchanged: folds are
  still reapplied per `(or MW_ID MW_LIST)` key, and point still lands on the `at-id` entity
  heading.

---

## Key Technical Decisions

- **Anchor scroll to the anchor entity's heading screen line, not the user's raw point.** The
  reconcile path forces point onto the `at-id` entity's heading-start (`mindwtr-reconcile--goto-id`
  → `org-back-to-heading`); the user's column / in-body position is *not* preserved (an earlier PR
  accepted limitation). So the only honest thing to reproduce is the **heading's** screen row,
  not the raw cursor's: measuring from the user's real point (which may sit deep in a body, or
  resolve via `--id-at-point` to an *ancestor* heading) and reapplying to the heading-start would
  put the heading where a body line used to be — an unbounded jump. Instead, at snapshot, measure
  the screen line of the heading the anchor (`at-id`) resolves to — the nearest ancestor heading
  bearing an `MW_ID`/`MW_LIST`, found the same way `--id-at-point` resolves `at-id` — and
  `recenter` that heading at restore. Capture and reapply are then apples-to-apples and the
  heading returns to its exact prior row. This is the issue's "Alternatively…" `recenter`
  suggestion, made precise; it is reflow-immune at/below the heading. (see origin: issue #22,
  "Proposed direction")
- **Pass the reconcile window explicitly to `count-screen-lines`; recenter via
  `with-selected-window`.** `count-screen-lines` computes line wrapping against the *selected*
  window unless a window is passed as its fourth argument, and `recenter` acts on the selected
  window. Reconcile fires on a background / focus auto-sync, when the buffer's window
  (`win = (get-buffer-window (current-buffer))`) is frequently **not** the selected window —
  different width means different wrapping and a wrong line count. So the snapshot must call
  `(count-screen-lines (window-start win) <heading-pos> nil win)` and restore must wrap the
  `recenter` in `(with-selected-window win …)`. Without this the fix silently anchors to the
  wrong row whenever the sync fires while another window is selected.
- **Keep `:top-id` as the off-screen / viewport-truthful fallback (hybrid).** The recenter path
  is preferred, but it is only correct when the anchor heading was *on-screen* before the
  rebuild. A background sync can fire while the user scrolled away (`C-v` / wheel) without moving
  point, leaving the anchor heading off-screen; recentering there would scroll the viewport to a
  place the user was not looking. The existing `:top-id` anchor (the heading at/after
  `window-start`) is truthful to the top of the viewport regardless of where point sits, so it is
  retained and used as the fallback when the anchor heading was off-screen (or does not resolve
  after the rebuild). This is a strict improvement over today — keep code that already works and
  is tested, gate it behind an on-screen check — rather than a deletion that would regress the
  scrolled-away tail.
- **Measure and reapply both with folds in effect — geometry stays consistent.** The snapshot
  runs before the rebuild while the user's real fold state is in effect, so `count-screen-lines`
  reflects what the user sees. Restore recenters **after** the fold loop has reapplied those
  folds, so the screen geometry at `recenter` time matches the geometry at measurement time.
  This is why the recenter must be the *last* step of restore, after fold reapplication.
- **Preserve point across the fold loop.** Today's scroll step is independent of point (it
  `save-excursion`s and re-finds `:top-id`). With point as the anchor, the fold loop's
  `org-map-entries` must not leave point displaced before `recenter` runs — wrap the fold loop
  in `save-excursion` so point stays on the `at-id` heading that `mindwtr-reconcile-buffer`
  established just before calling restore.
- **Guard the scroll step on a live window, inside the existing `condition-case`.** Both
  `recenter` and `set-window-start` require a live window; in batch there is none, so no anchor
  line is captured, `:top-id` resolution is skipped, and the scroll step is a no-op. The whole
  restore stays wrapped in `condition-case ... (error nil)` (R4). The load-bearing property of
  the scroll step is only that it **never errors** — the windowed test pins exact placement; the
  rationale does not assert a specific degraded position.

---

## Implementation Units

### U1. Anchor-heading recenter with a window-start fallback

**Goal:** Make the scroll restore return the anchor entity's heading to its prior on-screen row
via `recenter`, falling back to the existing `:top-id` `set-window-start` when that heading was
off-screen — so a mid-session sync stops nudging the viewport without regressing the
scrolled-away case.

**Requirements:** R1, R2, R2b, R3, R4, R5.

**Dependencies:** none.

**Files:**
- `mindwtr-reconcile.el` —
  - `mindwtr-reconcile--snapshot-view`: keep the existing `:top-id` capture (the `goto-char
    (window-start win)` + `re-search-forward` block, ~lines 230–235) as the fallback anchor. Add
    an `:anchor-line` capture: when there is a live window `win`, resolve the heading the point
    anchor will target (walk up from point to the nearest `MW_ID`/`MW_LIST` heading, the same way
    `--id-at-point` resolves `at-id`), and if that heading is within `win`'s visible region
    (between `window-start` and `window-end`), record
    `(count-screen-lines (window-start win) <heading-pos> nil win)`; otherwise leave `:anchor-line`
    nil so restore uses the `:top-id` fallback. Update the docstring's anchor description.
  - `mindwtr-reconcile--restore-view`: wrap the fold `org-map-entries` loop (~lines 258–266) in
    `save-excursion` so point stays on the `at-id` heading that `mindwtr-reconcile-buffer`
    established. Replace the scroll branch (~lines 267–276) with: when there is a live window —
    if `:anchor-line` is non-nil, `(with-selected-window win (recenter anchor-line))` (point is
    on the at-id heading); else fall back to the existing `:top-id` path
    (`--goto-id top-id` → `set-window-start`). When neither resolves, do nothing. Update the
    docstring.
- `test/mindwtr-reconcile-test.el` — update the three tests that reference `:top-id` (they keep
  `:top-id` but gain an `:anchor-line nil` field so they exercise the fallback path) and add the
  new on-screen-recenter scenario (see Test scenarios).

**Approach:**
- The anchor needs nothing new threaded through `mindwtr-reconcile-buffer`: it already calls
  `(mindwtr-reconcile--goto-id at-id)` to put point on the entity heading immediately before
  `(mindwtr-reconcile--restore-view view)`. The fold loop runs under `save-excursion` (leaving
  point on that heading), then the scroll step recenters that heading to `:anchor-line`, or falls
  back to `:top-id`.
- **Snapshot/restore heading must match.** The heading `:anchor-line` is measured from must be
  the same heading `--goto-id at-id` lands on after the rebuild. Resolve it in snapshot by the
  same `(or MW_ID MW_LIST)` walk-up `--id-at-point` uses, so the common case (an entity heading
  carrying its own `MW_ID`) and the ancestor-resolution case agree. Document the rare mismatch
  (point under a heading with no id whose nearest id-bearing ancestor differs) as a benign
  fallback-to-`:top-id`-or-small-shift edge, not a bug.
- **Window-parameter correctness (load-bearing).** `count-screen-lines` must receive `win` as
  its fourth argument and the `recenter` must run inside `(with-selected-window win …)` —
  reconcile fires on background sync when `win` is often not the selected window, and the default
  selected-window parameters would compute the wrong wrap/row. See the KTD.
- **Fold-then-recenter ordering / hidden anchor.** Measuring at snapshot (folds in effect) and
  recentering after the fold loop reapplies them keeps screen geometry consistent. One benign
  edge: if the at-id heading becomes invisible under a *restored ancestor fold*, `save-excursion`
  restores point into a hidden region and `recenter` centers on a now-hidden row. That is the
  state the user had (they folded the ancestor); call it out so it is not mistaken for a bug.
- The scroll step mirrors today's no-window guard, so the batch path stays a deterministic no-op
  (no anchor line, no `:top-id` resolution attempted under a window).
- Directional note (not implementation spec): `(count-screen-lines beg end nil win)` returns a
  1-based count of screen lines in the region; `(recenter N)` places point on 0-based row N. The
  implementer reconciles the off-by-one and pins it with the windowed test below rather than
  asserting it blind here. `recenter` with an out-of-range row does not error (the load-bearing
  property); exact placement in that case is not asserted.

**Patterns to follow:**
- The existing no-window guard pattern around `:top-id` (snapshot returns nil; restore's scroll
  branch is skipped) — `mindwtr-reconcile--snapshot-view` / `--restore-view`.
- `docs/solutions/design-patterns/preserving-buffer-view-state-across-reconcile.md` — the
  snapshot-before / condition-case-guarded-restore contract, the cross-version-safe-snapshot
  rule, and the "key to stable IDs, never positions" principle this change respects (point is
  re-anchored by `at-id`, not by char offset).

**Execution note:** Start by extending `mindwtr-reconcile-no-window-skips-scroll-anchor` to also
assert `:anchor-line` is nil (alongside the existing `:top-id` nil) and that reconcile falls
through cleanly — watch the `:anchor-line` assertion fail against the current snapshot, pinning
the new snapshot field and the restore no-window guard before wiring the windowed recenter.

**Test scenarios** (ERT + `with-temp-buffer`/`org-mode`, matching existing tests in
`test/mindwtr-reconcile-test.el`):
- Covers R3. **(extend `mindwtr-reconcile-no-window-skips-scroll-anchor`, ~line 567)** With no
  live window, `(mindwtr-reconcile--snapshot-view)` returns both `:top-id` nil **and**
  `:anchor-line` nil, and `mindwtr-reconcile-buffer` completes without signalling and produces
  the rebuilt layout (`* Single Actions` present). Keep the existing `:top-id` nil assertion; add
  the `:anchor-line` nil assertion.
- Covers R2b + R4. **(update `mindwtr-reconcile-restore-view-tolerates-unresolved-anchor`,
  ~line 585)** Restoring a view with a ghost fold key, `:anchor-line nil`, and a `:top-id` that
  no longer resolves does not throw, and a still-resolving recorded fold is applied — proving
  restore runs to completion through the fallback branch. Add `:anchor-line nil` to the view;
  keep `:top-id "ghost"` as the unresolved-fallback probe and the ghost *fold* key as the
  tolerance probe. Note: this test asserts `(should (null (mindwtr-reconcile--restore-view view)))`
  — restore's final form must still evaluate to nil on the no-window path, so the no-op scroll
  branch must not change the function's return value.
- Covers R4. **(update `mindwtr-reconcile-restore-view-preserves-modified-flag`, ~line 605)**
  With `:anchor-line nil` (and `:top-id nil`), restore still applies a fold and leaves
  `buffer-modified-p` nil. Add the `:anchor-line nil` field. (Recenter / set-window-start only
  move point/window scroll, never content, so the modified flag stays clean regardless.)
- Covers R5. Regression: an existing fold-restore test (a folded heading stays folded; an open
  heading stays open after reconcile) still passes unchanged — the fold loop's new
  `save-excursion` wrapper must not alter fold behavior.
- Covers R1/R2 (best-effort, windowed — on-screen recenter path). In a buffer displayed in a
  live temp window (e.g. `with-selected-window` on a throwaway window via `set-window-buffer`, or
  `save-window-excursion`), place point inside an entity whose heading sits a known number of
  screen lines below `window-start`, snapshot (asserting `:anchor-line` is non-nil), run
  `mindwtr-reconcile-buffer` on a `merged` that reflows an unrelated entity's drawer, and assert
  the anchor heading's post-restore screen line (`count-screen-lines (window-start win) <heading>
  nil win`) matches the captured value within a small tolerance. **If a deterministic live-window
  assertion proves environment-dependent in batch**, fall back to asserting the no-window no-op
  path deterministically and document windowed recenter as manual verification — consistent with
  the earlier PR plan's stance on batch window non-determinism. Note this explicitly in the test.
- Covers R2b (best-effort, windowed — fallback path). With a live window scrolled so the entity
  at point's heading is *off-screen* (above `window-start`), snapshot records `:anchor-line` nil
  but a non-nil `:top-id`; after reconcile the window is anchored via the `:top-id`
  `set-window-start` path, not recentered. Same batch-determinism fallback applies.

**Verification:** `make test` passes; the three updated `:top-id` tests are green against the
snapshot's new `:anchor-line` field; the fold-restore regression tests are unchanged and green;
a manual mid-session sync with the cursor partway down a long on-screen entry keeps that
entity's heading at roughly the same screen row instead of nudging the viewport; a manual sync
after scrolling away (cursor off-screen) still anchors the top of the viewport via the `:top-id`
fallback rather than yanking it to the cursor.

---

## Scope Boundaries

**In scope:** the scroll/vertical-position restore dimension of reconcile view restoration,
re-implemented as an anchor-heading `recenter` with the `:top-id` window-start fallback.

**Known limitations (accepted):**
- Point lands on the entity heading-start; cursor column / in-body line is not preserved
  (unchanged from an earlier PR). The restore reproduces the *anchor heading's* row exactly (that is why
  the screen line is measured from the heading, not the raw cursor), so a user editing several
  lines into a body sees the heading return to its prior row — the cursor's in-body row is not
  separately reproduced, but no unbounded jump occurs.
- Reflow in the region *above* the anchor heading (between `window-start` and the heading) still
  perturbs the on-screen restore slightly; measuring from the heading keeps that region small.
  Acceptable for a low-severity polish fix.

**Deferred to follow-up work:**
- Cursor column / in-body position preservation as a `(MW_ID, char-offset)` point anchor.
- Full signature-diffed incremental reconciliation, which would make scroll restoration moot for
  untouched entities (issue #3).

---

## Risks & Dependencies

- **Windowed-recenter test determinism in batch.** `with-temp-buffer` has no live window and
  minimal redisplay; `count-screen-lines`/`recenter` behavior in a synthesized batch window may
  not be deterministic. Mitigation: the no-window no-op path (R3) is the deterministic anchor of
  the test suite; the windowed screen-line assertion is best-effort with a documented fallback
  to manual verification, mirroring the earlier PR plan's treatment of windowed scroll.
- **Fold-loop point displacement.** The fold `org-map-entries` loop moves point across headings;
  if the `save-excursion` wrapper is omitted, `recenter` would fire on the wrong line.
  Mitigation: the `save-excursion` wrapper is part of U1's required change and is covered by the
  R1/R2 windowed scenario (and, indirectly, by the unchanged fold-regression tests still
  passing).
- **Restore throwing on the post-PUT path.** Unchanged risk from an earlier PR, unchanged mitigation:
  the entire restore stays wrapped in `condition-case ... (error nil)` (R4), and the snapshot's
  new `count-screen-lines` call is a cross-version-safe built-in present on the Emacs 28.1 floor,
  so it cannot raise `void-function` before the rebuild.
