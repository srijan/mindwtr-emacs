---
title: "A sync during a live org-capture corrupts the capture, and the unsaved-edits gate cannot see it"
date: 2026-09-25
category: logic-errors
module: mindwtr
problem_type: logic_error
component: tooling
symptoms:
  - "A half-typed capture entry shows up on the server (and on the phone) before the capture is finished"
  - "C-c C-c after a mid-capture sync leaves a duplicate orphan heading under * Sync Failures"
  - "C-c C-k after a mid-capture sync deletes unrelated text, in one repro the whole file body"
  - "Occasional 'buffer changed during sync (after push)' errors while capturing"
root_cause: missing_constraint
resolution_type: code_fix
severity: critical
tags: [org-capture, indirect-buffer, marker, reconcile, auto-sync, unsaved-edits-gate, stand-down, backoff]
---

# A sync during a live org-capture corrupts the capture, and the unsaved-edits gate cannot see it

## Problem
`org-capture` inserts its template into the synced file's base buffer as soon as the capture
starts, and the user types into an indirect `CAPTURE-*` buffer whose region markers point into
that text. A sync cycle that fired mid-capture pushed the half-typed entry to the server and
then rebuilt the base buffer under the capture. Finishing or aborting the capture afterwards
operated on a stale region. Fixed in PR #57.

## Symptoms
Measured in a batch repro against the in-memory test server (PR #57 body):

| | before the fix | after |
|---|---|---|
| server tasks | the half-typed entry, pushed | none |
| `C-c C-c` | re-inserts a stale region; the file ends with a duplicate orphan `* Inbox` quarantined under `* Sync Failures` | clean finalize |
| `C-c C-k` | deletes everything the stale region now covers; in one run the whole body, leaving only the `#+TODO` line and `* Inbox` | clean abort |

The "sync errors" users saw came from a separate, safe path: a capture started or typed into
during the PUT/GET window trips the tick guard, which aborts before reconcile.

## What Didn't Work
- **The unsaved-edits gate** (`mindwtr--buffer-has-unsaved-edits-p`, `mindwtr.el:331`). It does
  hold at first: the template insertion marks the base buffer modified, so auto-sync stands
  down. It stops holding the moment anything saves the file mid-capture. External auto-savers
  that resolve an indirect buffer to its base and save on window or buffer switches do this
  (the reporter's trigger was one of them), and so does a plain `C-x C-s`. The save clears
  `buffer-modified-p` while the capture is still live, and the same save runs `after-save-hook`,
  which arms the 5-second idle debounce. The user sitting mid-capture is idle, so the cycle runs.
  `buffer-modified-p` answers "is there text not yet on disk", which is a different question
  from "is the user in the middle of an edit session".
- **Manual `mindwtr-sync` as the escape hatch.** It save-then-syncs by design, so it committed
  the in-progress capture itself.
- **The diff-based rebuild.** Reconcile replaces the buffer through
  `mindwtr-reconcile--replace-buffer-contents` (`mindwtr-reconcile.el:459`), a
  `replace-buffer-contents` diff that keeps markers in text it leaves unchanged. That rebuild
  landed in June (commit `353b301`), and the PR #57 repro above ran on a tree that already had
  it, so the diff does not protect a capture. The likely reason (inferred, not separately
  measured): the diff only preserves markers in text the render reproduces byte for byte, and
  the half-typed entry is exactly the text the rebuild rewrites, since it is canonicalized,
  reordered, or moved under `* Sync Failures` when it carries no `MW_TYPE`. The diff also
  degrades to a coarser replacement past its 2-second bound (`mindwtr-reconcile.el:485`). The
  docstring of `mindwtr--capture-in-progress-p` still says "`erase-buffer` + re-render", which is
  imprecise about the mechanism; the failure it describes holds under the diff. Do not read the diff rebuild as having made
  the capture gate redundant.

## Solution
One predicate, wired in at the two places that cannot be bypassed.

`mindwtr--capture-in-progress-p` (`mindwtr.el:339`) returns a live buffer with
`org-capture-mode` whose base buffer visits the tasks file or the archive file:

```elisp
(and (boundp 'org-capture-mode)
     (let ((targets (delq nil (mapcar #'find-buffer-visiting
                                      (delq nil (list mindwtr-file
                                                      (mindwtr-archive-path)))))))
       (seq-find (lambda (b)
                   (and (buffer-local-value 'org-capture-mode b)
                        (memq (or (buffer-base-buffer b) b) targets)))
                 (buffer-list))))
```

1. **The chokepoint.** It gates `mindwtr--sync-attempt` (`mindwtr.el:300`), which every launch
   path routes through: save debounce, periodic timer, focus change, and backoff retry. Gating
   `mindwtr--auto-sync` alone would have missed the retry timer and the manual command.
2. **The manual command refuses before its save.** `mindwtr-sync` signals a `user-error` naming
   the capture buffer (`mindwtr.el:398`) before its save-then-sync step, so an explicit sync
   cannot commit the capture either. This is the one exception to the rule that a manual sync
   never refuses.
3. **Deferred retries stay armed.** `mindwtr--retry-sync` clears its timer and then attempts. A
   gated attempt never launched, so the completion callback that would re-arm the backoff never
   ran and the retry chain ended silently. `mindwtr--sync-attempt` now returns non-nil only when
   it launched, and the retry re-arms at the same delay without advancing
   `mindwtr--retry-attempts` (`mindwtr.el:202`). An attempt that never left is not a failure, so
   the backoff does not advance and sync never gives up over a stand-down. Reusing
   `mindwtr--schedule-retry` was rejected because it gives up at the attempt ceiling and prints
   "server busy/unreachable" for a request that was never sent.

## Why This Works
The damage needs a rebuild of the base buffer while a capture's markers point into it. The
gate asks the question that matters, whether a capture buffer is live over a synced file,
instead of inferring it from the modified flag. Placing it in `mindwtr--sync-attempt` and ahead
of the manual save covers every path that can start a rebuild.

The gate has no staleness reclaim, unlike `mindwtr--sync-busy-p`: a forgotten `CAPTURE-*`
buffer stands sync down for as long as it lives. That is deliberate. A timeout would bring back
the corruption for any capture left open past it, and the refusal message names the buffer to
kill.

## Prevention
- Treat `buffer-modified-p` as "unsaved text", never as "edit in progress". Any mode that edits
  the synced file through markers held in another buffer (an indirect buffer, an edit-in-place
  session) needs its own stand-down predicate, because auto-savers and `C-x C-s` can clean the
  base buffer mid-session.
- Put a new stand-down guard in `mindwtr--sync-attempt`, not in one trigger. If the guard must
  also stop the manual command, check it before `mindwtr-sync` saves; a check after the save is
  too late.
- Any guard inside `mindwtr--sync-attempt` can stand down a backoff retry, so it relies on the
  retry re-arm. Keep `mindwtr--sync-attempt` returning nil on every stand-down path.
- Tests: `mindwtr-sync-stands-down-during-org-capture` (`test/mindwtr-test.el:255`) covers both
  entry points over a clean buffer and the false-positive direction (a capture on an unrelated
  file blocks nothing); `mindwtr-retry-rearms-when-a-capture-stands-it-down`
  (`test/mindwtr-test.el:299`) pins the re-arm and the unchanged counter. Both simulate capture
  with an indirect buffer plus a buffer-local `org-capture-mode`; the gate was checked against
  real `org-capture` by hand only, and the archive-file branch is untested.
- `mindwtr-bootstrap` has no capture guard. It is a confirmation-gated overwrite, not a
  background trigger, so the invariant does not depend on it.
- Clarify is not exposed to this: its queue holds `MW_ID`s re-resolved on each advance (see
  [clarify-queue-markers-collapse-on-write-back](clarify-queue-markers-collapse-on-write-back.md)).

## Related Issues
- PR #57 (merged 2026-09-20): the gate, the named refusal, the retry re-arm, and the trim.
  Landed commits `62d648e`, `b267770`, `221871f`, `7f54806`.
- [save-as-sync-commit-point](../design-patterns/save-as-sync-commit-point.md): the
  unsaved-edits gate and the manual save-then-sync escape hatch this learning makes an
  exception to.
- [sync-reentrancy-in-flight-guard](../design-patterns/sync-reentrancy-in-flight-guard.md): the
  other guard in `mindwtr--sync-attempt`, and the general rule that a stood-down retry re-arms.
- [reconcile-partial-update-reverts-remote-edits](reconcile-partial-update-reverts-remote-edits.md)
  and [clarify-queue-markers-collapse-on-write-back](clarify-queue-markers-collapse-on-write-back.md):
  other marker-collapse cases around buffer rewrites.
