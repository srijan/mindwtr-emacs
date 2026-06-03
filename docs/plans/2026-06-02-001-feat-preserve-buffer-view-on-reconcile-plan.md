---
title: "feat: Preserve buffer view state across reconcile (stopgap)"
type: feat
status: completed
date: 2026-06-02
origin: docs/superpowers/specs/2026-06-02-incremental-reconciliation-stopgap-design.md
issue: incremental reconciliation (preserve buffer state)
depth: lightweight
---

# feat: Preserve buffer view state across reconcile (stopgap)

## Summary

`mindwtr-reconcile-buffer` rebuilds the whole file (`erase-buffer` + `insert`) on every
sync and restores only point to the current entity's heading. The rebuild discards all
user-visible view state — folds, global S-TAB cycle level, scroll position — so a sync that
fires mid-session visibly resets the buffer: collapsed subtrees spring open and the window
jumps. This plan adds a snapshot-before / restore-after pass around the existing rebuild that
reapplies fold state (keyed by `MW_ID`), the global cycle state, and a content-anchored
scroll position. It deliberately keeps the full rebuild — no signature diffing, no in-place
per-entity surgery. Full incremental reconciliation is a deferred follow-up (see origin:
`docs/superpowers/specs/2026-06-02-incremental-reconciliation-stopgap-design.md`).

This serves the **Emacs-native editing** and **Sync & conflict reconciliation** tracks in
`STRATEGY.md`: if a background sync keeps yanking the buffer out from under the user, the
desk surface isn't a joy to edit, which the lossless-round-trip approach depends on.

---

## Problem Frame

The reconcile path runs **after** the server PUT has already committed (`mindwtr-sync.el`,
just past the `buffer-chars-modified-tick` concurrency guard). Today it:

1. collects per-id org-only content,
2. records the `MW_ID` at point,
3. `erase-buffer` + `insert` of the freshly rendered canonical layout,
4. moves point back to the recorded entity's heading.

Everything else the user could see — which subtrees were folded, whether they had S-TAB'd
to overview/contents, and where the window was scrolled — is lost, because the buffer is
rebuilt from scratch and re-inserted fully expanded. Point lands on the heading line even if
the user was editing several lines into a description.

Scope of this work: restore the three view-state dimensions the origin spec names. **Not** in
scope: preserving the exact cursor column / in-body position (point still lands on the
heading-start, as today — explicitly opted out of during brainstorming), and full
signature-diffed incremental rewrite.

---

## Requirements

Traced from the origin spec:

- **R1.** Entity headings (`MW_ID`-bearing) that were folded before a reconcile are folded
  again afterward; headings that were open stay open.
- **R2.** The global S-TAB cycle state (`org-cycle-global-status`: `overview` / `contents` /
  `all` / nil) is reapplied after the rebuild.
- **R3.** Scroll position is restored by anchoring to the `MW_ID` at/after the pre-rebuild
  `window-start` — not by reusing the now-stale char offset.
- **R4.** Restore must never throw. Reconcile runs post-PUT; any fold/redisplay failure is
  swallowed so the sync still reports success with the rebuilt buffer intact.
- **R5.** Restore must not perturb `buffer-modified-p` beyond what `erase-buffer`+`insert`
  already did — it touches only visual state (fold overlays, `window-start`), never content.
- **R6.** Fold state follows an entity across a status-change bucket relocation, because it is
  keyed by `MW_ID`, not buffer position.

---

## Key Technical Decisions

- **Anchor scroll to content, not char offset.** Raw `window-start` is a buffer position
  that points at unrelated text after a full rebuild. We capture the `MW_ID` of the entity
  heading at/after `window-start` and re-derive the position post-rebuild. (origin: scroll
  anchor decision.)
- **Cross-version org fold API (Emacs 28.1 / Org 9.5 floor).** `Package-Requires` is
  `((emacs "28.1"))` and the README promises "Emacs 28.1 or newer." Emacs 28.1 ships Org 9.5,
  but the `org-fold-*` namespace (`org-fold-folded-p`, `org-fold-hide-subtree`,
  `org-fold-show-entry`) only exists in Org 9.6+ (Emacs 29). Calling them on 28.1 is a
  `void-function` error. Two consequences drive the design: **(1)** fold *operations*
  (hide/show) must dispatch on `fboundp` to the legacy `outline-*` equivalents, and **(2)**
  fold *detection* must use `org-invisible-p`, which exists and behaves consistently in both
  9.5 and 9.8, instead of `org-fold-folded-p`. `org-invisible-p`, `org-overview`, `org-content`,
  and the `org-cycle-global-status` variable all exist across the 9.5–9.8 range.
- **Snapshot uses only cross-version-safe calls, so it cannot throw on 28.1.** The snapshot runs
  *before* the rebuild, outside the restore `condition-case`; if it raised `void-function` it
  would abort a sync that already committed server-side. Restricting it to `org-invisible-p` /
  `org-cycle-global-status` / `window-start` (all present on 28.1) keeps it safe. Restore's fold
  *operations* are additionally `fboundp`-dispatched and the whole restore is `condition-case`-wrapped.
- **Guard fold detection against ancestor folds.** A heading is recorded as folded only when
  its own heading line is *visible* (`org-invisible-p` at `line-beginning-position` is nil) but
  its body is hidden (`org-invisible-p` at `line-end-position` is non-nil). If the heading line
  is itself invisible, it's hidden only because an ancestor is collapsed — the ancestor's own
  record covers it — so we skip it to avoid a false positive.
- **Backdrop-then-override restore order.** Apply the global cycle backdrop first
  (`org-overview` / `org-content`), then explicitly set every `MW_ID` heading's fold state
  top-down (`org-fold-hide-subtree` if recorded folded, else `org-fold-show-entry`). This
  re-derives entity visibility on top of the backdrop, so entities the user had open are
  reopened even if `org-overview` collapsed their container.
- **`condition-case` around the entire restore.** Non-negotiable per R4 — a post-PUT throw
  would surface as a sync failure even though the server already committed. Snapshot is also
  defensive (it reads buffer state before the rebuild, so a failure there is harmless, but it
  is cheap to guard).
- **No `save-buffer`, no modified-flag fiddling.** Per R5, leave the buffer's dirty state
  exactly as the existing rebuild leaves it.

---

## Implementation Units

### U1. Fold-state snapshot and restore

**Goal:** Capture which `MW_ID` entity headings are folded before the rebuild and reapply
that fold state after, so a mid-session sync stops springing collapsed subtrees open. Deliver
the high-value half of the feature standalone.

**Requirements:** R1, R4, R5, R6.

**Dependencies:** none.

**Files:**
- `mindwtr-reconcile.el` — add two tiny `fboundp`-dispatch fold helpers
  (`mindwtr-reconcile--hide-subtree`, `mindwtr-reconcile--show-entry`),
  `mindwtr-reconcile--snapshot-view` (fold portion) and `mindwtr-reconcile--restore-view`
  (fold portion); call snapshot/restore in `mindwtr-reconcile-buffer` straddling the
  `erase-buffer`/`insert`.
- `test/mindwtr-reconcile-test.el` — tests.

**Approach:**
- **Fold-op dispatch helpers** (per the cross-version KTD): `--hide-subtree` →
  `(if (fboundp 'org-fold-hide-subtree) (org-fold-hide-subtree) (outline-hide-subtree))`;
  `--show-entry` → `(if (fboundp 'org-fold-show-entry) (org-fold-show-entry) (outline-show-entry))`.
  These are the only spots that touch the 9.6+ namespace, and they fall back to the
  `outline-*` functions that exist on Emacs 28.1 / Org 9.5.
- `mindwtr-reconcile--snapshot-view` returns a plist; in U1 it carries `:folded` — a hash
  `MW_ID -> t`. Build it with `org-map-entries` using only cross-version-safe calls: for each
  heading with an `MW_ID`, skip when `org-invisible-p` at `line-beginning-position` is non-nil
  (ancestor-folded), otherwise record the id when `org-invisible-p` at `line-end-position` is
  non-nil (own body hidden).
- `mindwtr-reconcile--restore-view` (wrapped in `condition-case ... (error nil)`): walk
  `MW_ID` headings top-down via `org-map-entries`; `mindwtr-reconcile--hide-subtree` when the
  id is in `:folded`, else `mindwtr-reconcile--show-entry`.
- Wire into `mindwtr-reconcile-buffer`: bind `(view (mindwtr-reconcile--snapshot-view))`
  alongside the existing `at-id` (before render/erase), and call
  `(mindwtr-reconcile--restore-view view)` as the last form, after `--goto-id`.

**Patterns to follow:**
- `mindwtr-reconcile--id-markers` / `--collect-org-only` for the `org-map-entries` +
  `mindwtr-parse--prop "MW_ID"` idiom (reconcile uses the parser's own prop scan, not
  `org-entry-get`).
- `mindwtr-reconcile-buffer`'s existing let-binding-before-erase structure.

**Execution note:** Start with a failing test asserting a folded task heading is still folded
after a reconcile that changes an unrelated entity.

**Test scenarios** (in `test/mindwtr-reconcile-test.el`, ERT + `with-temp-buffer`/`org-mode`
matching existing tests):
- Covers R1. A folded task heading stays folded after `mindwtr-reconcile-buffer` is called
  with a `merged` that changes a *different* entity's title. Fold by going to the heading and
  calling the dispatch helper (or `org-fold-hide-subtree`/`outline-hide-subtree`); assert
  `org-invisible-p` at `line-end-position` is non-nil after. (Detection assertion uses
  `org-invisible-p` so the test runs identically on Org 9.5 and 9.8.)
- Covers R1. An *unfolded* heading is still unfolded after reconcile (assert `org-invisible-p`
  at `line-end-position` is nil) — guards against over-folding.
- Covers R6. A task whose status changes (e.g. `inbox` → `next`, relocating it to a different
  bucket) and that was folded before, is folded again in its new location after reconcile.
- Covers R4. Reconcile completes without error in a `with-temp-buffer` (no live window, batch
  fold behavior) and the buffer is correctly rebuilt — proves the `condition-case` guard and
  the no-window path don't break the sync.
- Edge: a folded entity nested under a folded ancestor — reconcile does not error; the
  ancestor's fold state is what's asserted (documents the known ancestor-skip limitation).

**Verification:** `make test` passes; the new fold tests are present and green; a manual
sync with a collapsed subtree no longer expands it.

---

### U2. Global cycle state and scroll-anchor restore

**Goal:** Layer the two coarser view dimensions on top of U1: reapply the global S-TAB cycle
state and restore scroll by content anchor.

**Requirements:** R2, R3, R4, R5.

**Dependencies:** U1 (extends the same snapshot plist and restore function).

**Files:**
- `mindwtr-reconcile.el` — extend `--snapshot-view` with `:global` and `:top-id`; extend
  `--restore-view` with the backdrop and scroll steps.
- `test/mindwtr-reconcile-test.el` — tests.

**Approach:**
- Snapshot `:global` = the buffer-local `org-cycle-global-status` symbol. Snapshot `:top-id`
  = the `MW_ID` of the entity heading at/after `(window-start win)` where
  `win = (get-buffer-window (current-buffer))`; nil when there is no live window.
- Restore order inside the existing `condition-case`: **(1)** backdrop first — `overview` →
  `org-overview`, `contents` → `org-content`, `all`/nil → leave as-is; **(2)** the U1
  per-entity fold loop (already present, runs after the backdrop so it overrides container
  collapse); **(3)** scroll — when a live window and `:top-id` still resolve, `set-window-start`
  to that heading's `line-beginning-position`.
- Reuse `mindwtr-reconcile--goto-id`'s `:MW_ID:` search idiom to resolve `:top-id` post-rebuild.

**Patterns to follow:**
- `mindwtr-reconcile--goto-id` for resolving an `MW_ID` to a heading position after the rebuild.

**Test scenarios:**
- Covers R2. Establish the overview state by setting **both** `(setq-local
  org-cycle-global-status 'overview)` (this is what the snapshot reads) **and** calling
  `org-overview` (this establishes the actual fold backdrop) — `org-overview` alone does *not*
  set `org-cycle-global-status`, so a test that calls only `org-overview` and asserts the
  variable was restored would prove nothing. After reconcile, assert the backdrop was reapplied
  by checking a deep entity heading is invisible (`org-invisible-p`) while a top-level container
  heading is visible.
- Covers R2 + R1 composition. With global `overview` set but one specific entity left open,
  after reconcile that entity's own body is shown (`org-fold-show-entry` effect) while others
  stay collapsed under the backdrop.
- Covers R3. With no live window (`with-temp-buffer`), `:top-id` is nil and reconcile skips
  scroll restore without error. (A windowed scroll-position assertion is environment-dependent
  in batch; if it can't be made deterministic, assert the no-window path is a clean no-op and
  leave windowed scroll to manual verification — note this in the test.)
- Covers R4. A snapshot with a `:top-id` that no longer resolves after the rebuild (entity was
  remotely deleted) does not error.

**Verification:** `make test` passes; manual sync from an S-TAB overview state stays in
overview; manual sync keeps the window roughly where it was.

---

## Scope Boundaries

**In scope:** the three view dimensions above, restored around the existing full rebuild.

**Known limitations (accepted, faithful to the origin spec's "less correct" framing):**
- Container headings (Inbox, Single Actions, Projects, Someday, Reference, Areas of Focus)
  have no `MW_ID`; their individual fold state is only approximated by the global backdrop.
- Point lands on the entity heading-start; cursor column / in-body position is not preserved.
- An entity self-folded *under* a folded ancestor is not re-folded; it appears open when the
  ancestor is later expanded.

**Deferred to follow-up work:**
- Full incremental reconciliation: signature-diff each merged entity against the buffer's
  parsed copy and only `--rebuild-entry` the changed ones, leaving untouched headings
  byte-identical (origin spec, "Non-goals"). This is the correct end state; the stopgap buys
  time.
- Point/column preservation as a `(MW_ID, char-offset)` anchor.

---

## Risks & Dependencies

- **Org version floor (Emacs 28.1 / Org 9.5).** The `org-fold-*` namespace is Org 9.6+, but
  the project supports Emacs 28.1 (Org 9.5). Mitigated by the cross-version KTD: detection uses
  `org-invisible-p` (present in 9.5 and 9.8), fold operations `fboundp`-dispatch to the legacy
  `outline-*` functions, and the snapshot is restricted to calls that exist on 28.1 so it
  cannot raise `void-function` before the rebuild. **Verify during implementation** that
  `outline-hide-subtree` / `outline-show-entry` produce the expected visibility on Org 9.5, and
  that `org-cycle-global-status` is bound there. If a clean dispatch proves impractical, the
  fallback is to feature-guard the whole snapshot/restore behind `(fboundp 'org-fold-folded-p)`
  so older Emacs simply keeps today's behavior rather than erroring.
- **Restore throwing on the post-PUT path.** Mitigated by the mandatory `condition-case`
  (R4) and a dedicated no-window/batch test (U1). This is the only failure mode that could
  turn a successful server sync into a user-visible error.
- **Batch-mode fold/window non-determinism in tests.** `with-temp-buffer` has no live window
  and minimal redisplay. Mitigation: assert fold state via `org-invisible-p` (works in batch,
  cross-version) and treat windowed scroll assertions as best-effort, falling back to verifying
  the no-window no-op path deterministically and documenting manual verification for windowed
  scroll.
