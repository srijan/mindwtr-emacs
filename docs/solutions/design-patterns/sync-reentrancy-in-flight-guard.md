---
title: "Synchronous HTTP spins a nested event loop: guard against timer re-entrancy mid-sync"
date: 2026-06-03
category: design-patterns
module: mindwtr
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Using url-retrieve-synchronously or any blocking HTTP call in a timer or hook"
  - "Adding a trigger path (hook, timer, focus event) that calls into the sync engine"
  - "Implementing debounce, periodic, or retry timers around synchronous I/O"
  - "Reasoning about concurrency in single-threaded Emacs Lisp with blocking network calls"
tags: [re-entrancy, nested-event-loop, synchronous-http, timers, backoff]
---

# Synchronous HTTP spins a nested event loop: guard against timer re-entrancy mid-sync

## Context
Emacs is single-threaded but **processes pending events while blocking on synchronous I/O**. When
`url-retrieve-synchronously` (the fallback in `mindwtr-api--default-http`, `mindwtr-api.el:54`)
blocks on the network, Emacs enters a nested event loop and runs any due timers — the periodic
sync timer, the save-debounce timer, the backoff retry timer. Without a guard, such a timer
re-enters the sync engine and launches a **second concurrent cycle** while a GET/PUT is in flight:
duplicate PUTs (two `:rev` bumps for one edit), racing backoff counters, and a corrupted `:tick`
check. The `plz.el` transport behaves identically — `:then 'sync` still processes events while
blocked, so this is not transport-specific.

## Guidance
A three-part pattern, all in `mindwtr.el`:

**1. In-flight flag as a `defvar` (so it can be `let`-bound):**

```elisp
;; mindwtr.el:64
(defvar mindwtr--sync-in-progress nil
  "Non-nil while a sync cycle is running.
Emacs' synchronous HTTP spins a nested event loop that runs pending timers, so a
periodic/debounce/retry timer can fire mid-sync; this guard stops a re-entrant
trigger from launching a second concurrent cycle.")
```

**2. Bind the flag with `let` — automatic reset on every exit path** (`mindwtr.el:159`):

```elisp
(defun mindwtr--sync-attempt ()
  (if mindwtr--sync-in-progress
      nil                                  ; re-entrant call: silent no-op
    (let ((mindwtr--sync-in-progress t)    ; dynamic binding auto-resets on any exit
          (buf (mindwtr--prepare)))
      (condition-case err
          (let ((res (mindwtr-sync-once buf ...)))
            (mindwtr--reset-backoff) ...)
        (mindwtr-api-error ...)
        (error ...)))))
```

Because `defvar` makes the variable special, the `let` uses dynamic scope and Emacs unwinds the
binding on **any** non-local exit — including a signal propagating past `condition-case`. This is
the Elisp equivalent of `unwind-protect` for the flag; no explicit reset is needed.

**3. Every automatic trigger checks the flag (and backoff state) first** (`mindwtr.el:221-232`):

```elisp
(defun mindwtr--auto-sync ()
  (unless (or mindwtr--sync-in-progress
              (timerp mindwtr--retry-timer)              ; a retry is already queued
              mindwtr--error-state
              (mindwtr--buffer-has-unsaved-edits-p))     ; unsaved-edits gate (PR #29)
    (mindwtr--sync-attempt)))
```

The fourth disjunct — the `buffer-modified-p` unsaved-edits gate — was added in PR #29 and is a
distinct concern (protecting in-progress edits, not concurrency); it is documented in
[[save-as-sync-commit-point]], including why it must be paired with an auto-save after reconcile.
This guard list is the single chokepoint both patterns extend.

A re-entrant timer fires `mindwtr--auto-sync`, sees the flag set, and returns immediately. The
**armed retry timer itself** is the "deferred retry" signal — no separate boolean — so overlapping
periodic/debounce triggers don't disturb the backoff cadence. Manual sync (`mindwtr-sync`,
`mindwtr.el:235`) bypasses the gate and calls `mindwtr--reset-backoff` first, so a user request
always runs regardless of backoff/error state. It also save-then-syncs (PR #29), so an explicit
sync never refuses on a dirty buffer — see [[save-as-sync-commit-point]].

## Why This Matters
A 2-second response on a 5-second periodic timer reliably spawns a second cycle before the first
finishes: a duplicate PUT, a second `:rev` bump for one change. The backoff retry timer is the
worst case — it fires exactly when the network is degraded and responses are slow, so
re-entrancy is most likely precisely when its consequences (duplicate writes during conflict
conditions) are most damaging.

## When to Apply
- Calling the sync engine from a new hook/timer: route through `mindwtr--auto-sync`, not directly,
  so the guard is checked.
- A new timer-driven side-effect that isn't safe to run concurrently with itself: apply the same
  `defvar` + `let` pattern.
- **Do not** add an explicit `(setq mindwtr--sync-in-progress nil)` anywhere — the `let` binding
  handles reset; an explicit clear before the cycle ends would defeat the guard.
- No `unwind-protect` is needed for the flag: `defvar` + `let` already gives unwind semantics
  regardless of the file's `lexical-binding` setting.

## Examples
Re-entrant timer during an in-flight PUT:
1. `mindwtr--sync-attempt` is running; `mindwtr--sync-in-progress` is `t`.
2. The network blocks; Emacs runs the due periodic timer → `mindwtr--auto-sync`.
3. It sees the flag set and returns — no second cycle, no duplicate PUT, backoff untouched.

## Related
- `mindwtr.el:64` flag, `:159` attempt, `:221` auto-sync gate (now four disjuncts), `:235`
  manual override. The gate's fourth disjunct (`mindwtr--buffer-has-unsaved-edits-p`, `:211`)
  belongs to [[save-as-sync-commit-point]] (PR #29), which extends this same chokepoint.
- `mindwtr-api.el:28-70` — both transport paths are synchronous.
- `test/mindwtr-test.el` — `mindwtr-auto-sync-defers-while-in-progress`. Commit `638c4a6`.
- The same synchronous transport's buffer ownership is [[url-el-synchronous-buffer-leak]].
