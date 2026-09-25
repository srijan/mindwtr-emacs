---
title: "One in-flight guard for the sync cycle: take it at launch, release it in the completion callback"
date: 2026-06-03
category: design-patterns
module: mindwtr
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Adding a trigger path (hook, timer, focus event, command) that calls into the sync engine"
  - "Changing how a sync cycle is launched or completed across async plz callbacks"
  - "Implementing debounce, periodic, or retry timers around the sync attempt"
  - "Reasoning about re-entrancy when a request may complete inline (url.el fallback, test stubs)"
tags: [re-entrancy, in-flight-guard, async-callbacks, timers, backoff, stale-reclaim]
---

# One in-flight guard for the sync cycle: take it at launch, release it in the completion callback

## Context
A sync cycle makes three network legs (HEAD, PUT, GET). Since commit `2039bfa` those legs run
asynchronously through `plz` callbacks: `mindwtr--sync-attempt` launches the cycle and returns,
and a single completion callback reports the result or error. For the whole round trip the
editor is live, so the periodic timer, the save-debounce timer, a focus hook, a backoff retry,
or the user's own `M-x mindwtr-sync` can all fire while a cycle is in flight. Without a guard,
any of them launches a second concurrent cycle: duplicate PUTs (two `:rev` bumps for one edit),
racing backoff counters, and a corrupted tick check.

The url.el fallback (`mindwtr-api--url-http`, used when `plz` is absent) still blocks on
`url-retrieve-synchronously` and completes inline. It spins a nested event loop that runs due
timers, so the original nested-loop re-entrancy survives on that path. The same guard covers
both.

### History
The first version of this guard (commit `5a24606`) was a `defvar` flag bound with `let` inside
`mindwtr--sync-attempt`. That was correct while every transport was synchronous: the whole cycle
ran inside the `let`, and dynamic unwinding released the flag on any exit, so the rule was
"never `setq` it". Commit `2039bfa` broke that assumption. Once the cycle outlives the function
that launched it, a `let` binding unwinds the moment the launch returns, while the requests are
still in flight. A dynamic `let` cannot span a callback gap (the commit message says so for the
strict-absence flag as well). The rule is now the reverse: the flag is `setq`'d at launch and
explicitly cleared.

## Guidance
All in `mindwtr.el`.

**1. The attempt function owns the guard.** `mindwtr--sync-attempt` checks the gates, then takes
the guard with `setq` together with a launch timestamp, and releases it in exactly two places:
the one completion callback, and a launch-time error arm that re-signals.

```elisp
(defun mindwtr--sync-attempt ()
  (unless (or (mindwtr--sync-busy-p) (mindwtr--capture-in-progress-p))
    (let ((buf (mindwtr--prepare)))          ; config errors signal before the guard
      (setq mindwtr--sync-in-progress t
            mindwtr--sync-started-at (float-time))
      (condition-case err
          (prog1 t
            (mindwtr-sync-once-async
             buf ...
             (lambda (res cb-err)
               (setq mindwtr--sync-in-progress nil
                     mindwtr--sync-started-at nil)
               (if cb-err (mindwtr--sync-handle-error cb-err)
                 (mindwtr--sync-handle-result res)))))
        ((error quit)                         ; C-g mid-launch, or a handler signal
         (setq mindwtr--sync-in-progress nil
               mindwtr--sync-started-at nil)
         (signal (car err) (cdr err)))))))
```

The async entry routes cycle errors through the callback, so the `condition-case` only catches a
`quit` or a signal from the handlers. Clearing there after the callback already ran is a no-op.
The function returns non-nil only when it launched a cycle; a stand-down returns nil.

**2. Every read goes through `mindwtr--sync-busy-p`, which reclaims a stale guard.** If the flag
has been set for longer than `mindwtr--sync-stale-seconds` (300), the busy-p check says so in the
echo area, clears the flag and timestamp, and returns nil. Nothing else reads
`mindwtr--sync-in-progress` directly.

**3. Every request is timeout-bounded.** `mindwtr-api--default-http` passes
`:timeout mindwtr-api-timeout` (60 s) to every `plz` call, so the completion callback always
fires, either with a response or through the status-0 error path. The stale reclaim is a
backstop for a bug that loses the callback. It turns a wedged guard into a delayed recovery, and
without it auto-sync would stand down forever.

**4. Every trigger respects the guard.**
- `mindwtr--auto-sync` (save, focus, periodic) stands down when any of these holds:
  `(mindwtr--sync-busy-p)`, an armed retry timer, `mindwtr--error-state`, or unsaved edits
  (`mindwtr--buffer-has-unsaved-edits-p`, see [[save-as-sync-commit-point]]).
- Manual `mindwtr-sync` resets backoff and saves first, but it still goes through
  `mindwtr--sync-attempt`, so it is also ignored while a cycle is in flight. It bypasses the
  backoff, error-state, and unsaved-edits gates. It does not bypass the in-flight guard.
- `mindwtr--retry-sync` (the backoff timer) re-arms at the same delay when the attempt stands
  down, without advancing `mindwtr--retry-attempts` (commit `221871f`). The timer was already
  cleared and the completion callback that would re-arm it never runs, so without this the
  backoff chain ends silently. An attempt that never left does not count as a failure.

**5. An edit during the async gap aborts before anything commits.** Because the editor is live
between legs, `mindwtr-sync--check-ticks` compares each surface's post-parse
`buffer-chars-modified-tick` before the PUT ("before push") and after it ("after push"). An edit
typed during the HEAD round trip aborts the cycle cleanly through the callback, which releases
the guard.

## Why This Matters
With async requests, "in flight" spans real editor time: seconds on a slow link, up to the
request timeout on a dead one. The periodic and debounce timers fire within that window as a
matter of course. The backoff retry is the worst case: it fires exactly when the network is
degraded and responses are slow, so a second cycle is most likely when duplicate writes during
conflict conditions do the most damage.

The guard's liveness matters as much as its exclusion. A guard that is set and never cleared
silently disables all sync. The one-callback release, the launch-error release, the request
timeout, and the stale reclaim together make sure it always comes down.

## When to Apply
- Calling the sync engine from a new hook or timer: route through `mindwtr--auto-sync` (or at
  least `mindwtr--sync-attempt`), never `mindwtr-sync-once-async` directly.
- Reading whether a cycle is running: call `mindwtr--sync-busy-p`, not the raw flag.
- Adding a new completion path to the cycle: it must end in the single callback, which is the
  only normal release point. Do not clear the flag early from a stage.
- Adding a new network call: bound it with `mindwtr-api-timeout`, or the callback (and the guard
  release) can hang until the 300 s reclaim.
- Adding a timer that retries on stand-down: re-arm without advancing the attempt counter, as
  `mindwtr--retry-sync` does.
- Do not reintroduce a `let` binding of `mindwtr--sync-in-progress` around an async launch. It
  unwinds when the launch returns, before the callback runs.

## Examples
Re-entrant timer during an in-flight PUT (plz transport):
1. `mindwtr--sync-attempt` launches; the guard is set with a timestamp; the function returns t.
2. The periodic timer fires and calls `mindwtr--auto-sync`. `mindwtr--sync-busy-p` is non-nil,
   so it returns with no second cycle and no duplicate PUT.
3. A backoff retry fires in the same window. The attempt returns nil, so `mindwtr--retry-sync`
   re-arms at the same delay with the counter unchanged.
4. The PUT/GET complete; the callback clears the guard and reports.

Lost callback (a bug, not normal operation): the guard stays set. The first trigger after 300 s
calls `mindwtr--sync-busy-p`, which reports "previous sync never completed; reclaiming" and lets
that trigger launch a fresh cycle.

Tests that pin the design, in `test/mindwtr-test.el`:
- `mindwtr-async-attempt-holds-guard-and-arms-backoff-on-completion`: with a deferred transport
  the guard stays up across the async window, a second attempt is ignored, and a 503 delivered
  to the callback releases the guard and arms a retry.
- `mindwtr-sync-busy-p-reclaims-stale-guard`: an over-age guard is reclaimed; a fresh one holds.
- `mindwtr-retry-rearms-when-a-capture-stands-it-down`: a stood-down retry stays armed with its
  counter intact (exercised through the capture gate, which shares the same attempt path).
- `mindwtr-auto-sync-defers-while-in-progress`: the auto-sync gate with the flag set. Its
  docstring still describes the nested-event-loop case from the synchronous era.

In `test/mindwtr-sync-test.el`, `mindwtr-sync-once-async-aborts-before-put-on-edit-during-head`
covers the pre-PUT tick guard.

## Related
- [[save-as-sync-commit-point]]: the unsaved-edits disjunct in the same auto-sync gate, and why
  manual sync saves first.
- [[url-retrieve-synchronously-nil-buffer-crash-on-tls-drop]] and
  [[url-el-synchronous-buffer-leak]]: the url.el fallback transport, the one path that still
  completes inline.
- `mindwtr--capture-in-progress-p`: the second stand-down gate inside `mindwtr--sync-attempt`.
  It has no stale reclaim; killing the capture buffer is the recovery.
- Commits `5a24606` (original let-bound guard), `2039bfa` (async cycles, setq guard, stale
  reclaim, pre-PUT tick guard), `221871f` (retry re-arm on stand-down).
