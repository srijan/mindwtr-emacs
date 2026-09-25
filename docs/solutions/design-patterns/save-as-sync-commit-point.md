---
title: "Save as the sync commit point: gate auto-sync on unsaved edits, auto-save after reconcile"
date: 2026-06-04
category: design-patterns
module: mindwtr-sync
problem_type: design_pattern
component: tooling
severity: high
root_cause: logic_error
resolution_type: workflow_improvement
applies_when:
  - "A background/periodic trigger can rebuild a buffer the user is actively editing (erase-buffer + insert)"
  - "You gate an automatic action on buffer-modified-p but the action itself marks the buffer modified"
  - "Establishing a save = commit point contract between an editor and a sync engine"
  - "An engine writes back into the buffer it syncs and must not echo its own write as a fresh edit"
  - "A save helper must distinguish user-initiated saves from engine-initiated saves"
related_components:
  - mindwtr
  - mindwtr-reconcile
tags: [emacs, org-mode, auto-sync, buffer-modified-p, auto-save, echo-suppression, commit-point, reconcile]
---

# Save as the sync commit point: gate auto-sync on unsaved edits, auto-save after reconcile

## Context
`mindwtr--auto-sync` fires on save, focus, and a 600s periodic timer. Every full cycle ends in
`mindwtr-reconcile-buffer`, which rebuilds the whole buffer from a fresh render (originally
`erase-buffer` + `insert`; since `353b301` a `replace-buffer-contents` diff)
(see [[preserving-buffer-view-state-across-reconcile]]). If a background sync fires while the
user has *stable, unsaved* edits, it yanks the buffer out from under them — discarding
in-progress typing and reflowing the buffer mid-edit. The companion fix (an earlier PR) hardened
scroll/fold restoration so the rebuild was *less* jarring; this attacks the **trigger** side so
the disruptive rebuild largely stops firing mid-edit at all.

The natural fix is to gate auto-sync on `buffer-modified-p`: stand down whenever the synced
buffer has unsaved edits. But that gate, **alone, self-wedges.** The reconcile rebuild itself
marks the buffer modified whenever the render changed any text (with the original
`erase` + `insert`, on every cycle). So the first successful sync leaves the
buffer dirty, the gate then reads `buffer-modified-p` as true on every subsequent tick, and
auto-sync never runs again. The gate is only correct when paired with an auto-save *after* the
content-changing reconcile — establishing a clean **"save = commit point"** contract.

## Guidance
The gate and the auto-save are a **matched correctness pair** — neither is shippable alone.

**The gate** (`mindwtr.el`) — a fourth disjunct added to the existing no-op conditions in
`mindwtr--auto-sync` (the three concurrency/backoff guards are documented in
[[sync-reentrancy-in-flight-guard]]):

```elisp
(defun mindwtr--file-buffer-dirty-p (path)
  (and path (let ((buf (find-buffer-visiting path)))   ; truename/symlink-safe
              (and buf (buffer-modified-p buf)))))

(defun mindwtr--buffer-has-unsaved-edits-p ()
  (or (mindwtr--file-buffer-dirty-p mindwtr-file)
      (mindwtr--file-buffer-dirty-p (mindwtr-archive-path))))  ; archive is a rebuild target too

(defun mindwtr--auto-sync ()
  (unless (or (mindwtr--sync-busy-p)
              (timerp mindwtr--retry-timer)
              mindwtr--error-state
              (mindwtr--buffer-has-unsaved-edits-p))   ; <- the gate
    (mindwtr--sync-attempt)))
```

Use `find-buffer-visiting`, not raw buffer-name matching — the same truename discipline as the
`file-equal-p` guard elsewhere. If the file isn't open, there are no unsaved edits and sync runs
freely.

**The paired auto-save** (`mindwtr-sync--finish`, `mindwtr-sync.el:1147-1171`) — at the end of
the *full-cycle* branch, after reconciling every surface, return each buffer to clean on disk.
Critically, this is **only** on
the full-cycle branch — never on the `:noop` (HEAD already matches) branch, which never rebuilds
and so must never save:

```elisp
(dolist (s surfaces)
  (with-current-buffer (plist-get s :buffer)
    (mindwtr-reconcile-buffer merged (plist-get s :render))))
;; the rebuild marks modified whenever the render changed text (an unchanged
;; buffer is a save-buffer no-op) -- never runs on :noop.  Closes the loop that keeps the gate from wedging.
(let ((save-failed (mindwtr-sync--save-surfaces surfaces)))   ; quiet-save t per surface
  (mindwtr-shadow-commit merged (or (plist-get got :etag) (plist-get put-resp :etag))
                         (unless save-failed <latches>))
  ... :save-failed save-failed)
```

**The quiet-save helper** — saves without re-arming the sync debounce, and never throws (it runs
in the post-PUT region where a throw would masquerade as a sync failure):

```elisp
(defun mindwtr-sync--save-buffer-quietly (&optional protect-content)
  (if (not (buffer-file-name))
      :skipped                                  ; non-file (temp) buffer: no-op
    (let ((mindwtr--inhibit-save-sync t))       ; surgical echo suppression
      (condition-case err
          (progn
            (if protect-content
                (let ((before-save-hook nil)) (save-buffer))  ; engine save
              (save-buffer))                                   ; manual save
            t)
        (error
         (message "mindwtr: buffer save failed: %s" (error-message-string err))
         nil)))))                                ; failure -> nil, never throws
```

**The surgical inhibit flag** — a dedicated dynamic variable checked *only* by the debounce
scheduler, not a blanket `(let ((after-save-hook nil)))`. Declared in `mindwtr-sync.el` (the
lower layer both files see) so it compiles clean under `error-on-warn`:

```elisp
(defvar mindwtr--inhibit-save-sync nil
  "Non-nil while the engine writes the synced buffer itself.")

(defun mindwtr--maybe-debounced-sync ()   ; the after-save-hook handler
  (unless mindwtr--inhibit-save-sync       ; <- only this handler stands down
    (when (and mindwtr-file buffer-file-name
               (file-equal-p buffer-file-name mindwtr-file))
      (when mindwtr--debounce-timer (cancel-timer mindwtr--debounce-timer))
      (setq mindwtr--debounce-timer
            (run-with-idle-timer mindwtr-sync-idle-debounce nil
                                 #'mindwtr--auto-sync)))))
```

The flag is `let`-bound `t` and never `setq`-reset, so it auto-unwinds on any non-local exit.
It was modelled on the then-`let`-bound `mindwtr--sync-in-progress` guard *(session history)*;
since the async rewrite (2039bfa) that guard is `setq`'d across the cycle's callback window, so
the two no longer share the idiom.

**Asymmetric `before-save-hook` handling** via `protect-content`:
- **Engine save** (auto-save after reconcile, bootstrap overwrite) passes `t` →
  `before-save-hook` suppressed, so a content-mutating user hook (formatter,
  trailing-whitespace cleanup) can't churn engine-canonical reconciled content and phantom-churn
  the next sync's signature.
- **Manual save** (`mindwtr-sync`) passes nothing → `before-save-hook` runs, exactly as a real
  `C-x C-s` would, because a manual sync *is* an ordinary user save.

**Manual sync = save-then-sync escape hatch** — bypasses the gate and always leaves the buffer
clean, so an explicit request never refuses on a dirty buffer — the one exception is a live
org-capture into a synced file, which both paths refuse (`mindwtr--capture-in-progress-p`,
`mindwtr.el:339-365`; the unsaved-edits gate cannot cover it because a save clears the modified
flag while the capture is live):

```elisp
(defun mindwtr-sync ()
  (interactive)
  (when-let* ((cap (mindwtr--capture-in-progress-p)))
    (user-error "mindwtr: capture in progress (%s); finish, abort, or kill it first"
                (buffer-name cap)))
  (mindwtr--reset-backoff)
  ;; Echo-suppressed but NOT content-protected: user's before-save-hooks run.
  (dolist (path (list mindwtr-file (mindwtr-archive-path)))
    (when path
      (let ((buf (find-buffer-visiting path)))
        (when (and buf (buffer-modified-p buf))
          (with-current-buffer buf
            (mindwtr-sync--save-buffer-quietly))))))
  (message "mindwtr: syncing...")
  (mindwtr--sync-attempt))
```

**Failed save degrades to a visible, recoverable error** — not a silent stall
(`mindwtr--sync-handle-result`, `mindwtr.el:245-248`):

```elisp
((plist-get res :save-failed)
 (setq mindwtr--error-state
       "mindwtr: synced, but saving the file failed -- disk is stale vs server (M-x mindwtr-sync to retry)")
 (message "%s" mindwtr--error-state))
```

This reuses the persistent `mindwtr--error-state` machinery: it stands down auto-sync and is
cleared only by a manual `mindwtr-sync` (which save-then-syncs and recovers).

## Why This Matters
- **The wedge failure mode.** Gate-without-auto-save is *worse* than no gate: after the first
  sync the rebuild leaves the buffer dirty, the gate reads `buffer-modified-p` as true forever,
  and auto-sync silently dies. Whenever you gate an automatic action on a flag the action itself
  sets, you must close the loop by clearing that flag as part of the action. This trap was caught
  in design discussion *before* implementation — the gate and auto-save were specified as a single
  cycle from the start, never as two independent changes. *(session history)*
- **Echo suppression must be surgical.** A blanket `(let ((after-save-hook nil)))` would silence
  *all* after-save handlers (recentf, backups, the user's own hooks). The dedicated
  `mindwtr--inhibit-save-sync` flag is checked by exactly one handler — the debounce scheduler —
  so the engine's own write doesn't echo a stray HEAD-only sync ~5s later, while every other
  after-save handler still runs.
- **Failed save must surface.** When the save fails, the shadow/etag have already advanced, so
  the on-disk file is now stale vs the server *and* the unsaved-edits gate would stand down every
  future tick silently. Surfacing it as a persistent error state makes the divergence visible and
  gives the user a one-command recovery path.
- **Auto-save removes the revert escape, so recovery shifts to per-conflict restore.** Because
  the engine now writes the buffer clean, `revert-buffer` is no longer a "discard and start over"
  path. The conflict report still auto-pops, the per-conflict `r`-restore re-applies your version
  directly into the buffer (disk-independent — unaffected by auto-save), and a
  `Pre-sync backup: <path>` line is surfaced as the fallback.

## When to Apply
- Any debounced or periodic background process that rebuilds a user-edited buffer in place (full
  `erase` + `insert`, regeneration, re-render). The moment you gate that process on
  `buffer-modified-p` to protect in-progress edits, you must also auto-save after the rebuild to
  re-establish a clean commit point — otherwise the gate wedges the process permanently.
- When an engine writes back into the buffer it watches: suppress *only* the engine's own
  re-trigger via a dedicated flag, never by nulling the whole hook.
- When a side effect runs after an irreversible commit (a server PUT): catch save failures and
  degrade to a visible, recoverable error state — never throw (it would masquerade as a sync
  failure) and never swallow silently (disk diverges invisibly).

## Examples
The steady-state loop the contract produces:

```
edit  -> buffer dirty -> auto-sync stands down (gate)      [in-progress work is safe]
save  (C-x C-s) -> after-save-hook -> debounce -> auto-sync
sync cycle -> reconcile rebuild (render changed text -> dirty)
           -> engine quiet-save (content-protected, echo-suppressed) -> clean
next tick -> gate sees clean buffer -> free to run
```

Before/after of the trigger contract:

```elisp
;; BEFORE: debounce fires for every save, including the engine's own writes;
;;         auto-sync runs regardless of unsaved edits -> rebuilds mid-edit.
;;         reconcile ended at: (mindwtr-reconcile-buffer merged) -> buffer left dirty.

;; AFTER: engine saves are echo-suppressed (mindwtr--inhibit-save-sync);
;;        auto-sync gates on unsaved edits (mindwtr--buffer-has-unsaved-edits-p);
;;        reconcile auto-saves content-protected to restore the clean commit point.
```

## Related
- Commits: `0eb01b4` (echo-suppression infra + debounce early-return), `3876947` (auto-save
  after reconcile + gate), `8beb614` (manual save-then-sync + bootstrap echo suppression).
  an earlier PR. Plan: `docs/plans/2026-06-03-002-feat-gate-autosync-on-saved-state-plan.md`.
- Shares the `mindwtr--auto-sync` gate with [[sync-reentrancy-in-flight-guard]] (the in-flight
  disjunct is now `mindwtr--sync-busy-p`).
- The rebuild-side counterpart that makes the rebuild less jarring when it *does* fire is
  [[preserving-buffer-view-state-across-reconcile]] (trigger-side vs. rebuild-side defenses).
- Full signature-diffed incremental reconciliation (issue #3) would eliminate the full
  rebuild this contract works around. Pre-sync buffer backup verification is issue #4.
- `test/mindwtr-sync-test.el`, `test/mindwtr-test.el` — quiet-save happy/skip/error paths,
  debounce suppression, the gate truth table and all guard interactions, `:noop`-never-writes,
  save-failure isolation + error-state signalling, manual save-then-sync, bootstrap echo
  suppression. `make test` 239/239 (+23 new); `make compile` clean under `error-on-warn`.
  Engine save tests use real file-visiting buffers — the existing `with-temp-buffer` tests have
  `buffer-file-name` nil, where the save guard passes vacuously.
- Two test-authoring gotchas surfaced while writing this coverage *(session history)*: (1) a
  `before-save-hook` test bound its sentinel and the hook in the **same** `let`, so the lambda
  captured a free variable and the test passed in isolation but failed under the full suite — fixed
  by sequencing with `let*`; (2) fixtures using a placeholder `:createdAt "C"` made `iso8601-parse`
  throw *before* the save path was reached — use real ISO timestamps in sync fixtures.
