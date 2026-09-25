---
title: "org-element cache wedges org-scan-tags in the auto-sync timer"
date: 2026-09-25
category: runtime-errors
module: mindwtr-heading / auto-sync
problem_type: runtime_error
component: tooling
symptoms:
  - "Emacs pegged at 100% CPU for ~14 minutes, unresponsive to emacsclient"
  - "Recovered only with C-g; no error, no backtrace"
  - "sample(1) shows the main thread in one org-scan-tags call from mindwtr--auto-sync, inside org-element-cache-map / org-element--cache-find / org-element--parse-to"
  - "The same parse of the same file costs 0.06-0.09s cold"
root_cause: upstream_defect
resolution_type: code_fix
severity: high
framework_version: "org 9.8.7 (Emacs 31.1); Org 9.6 falls back differently"
tags:
  - org-mode
  - org-element-cache
  - org-scan-tags
  - auto-sync
  - timer
  - hang
  - mitigation
---

# org-element cache wedges org-scan-tags in the auto-sync timer

## Problem

A `mindwtr-auto-sync-mode` timer cycle froze Emacs at 100% CPU for about 14 minutes. The whole main thread sat in a single `org-scan-tags` call (reached through `org-map-entries`) inside Org's element cache. The fix is a mitigation, and the root cause in Org was never established: `mindwtr-heading-map` binds `org-element-use-cache` nil around every scan so the scan never walks the buffer's long-lived cache. This doc exists mainly to keep the investigation, which lives nowhere in the tracked repo except a one-line summary in a commit message, from being redone.

## Symptoms

- Emacs unresponsive for ~14 minutes, including to `emacsclient`; `C-g` recovered it.
- Two `sample(1)` runs 70 seconds apart both showed the main thread in one `org-scan-tags` call driven by `mindwtr--auto-sync` (`mindwtr.el:367`), entirely inside `org-element-cache-map` / `org-element--cache-find` / `org-element--parse-to`.
- The same file parses in 0.06-0.09s cold, so the scan itself is cheap. The cache had degraded.
- It happened once, in a long-lived session, and could not be reproduced on demand.

## What Didn't Work

Seven hypotheses about the cause were each tested and falsified (investigation notes for PR #53, kept in the untracked `.blackboard/todo.org`):

1. **`buffer-file-name` bound nil (by the existing scan guard) corrupts the cache.** The cache records `:path` but never uses it for validation.
2. **Many indirect buffers make `org-element--cache-active-p` O(n).** The session had 41 buffers, none indirect.
3. **`replace-buffer-contents` churn from reconcile degrades the cache.** Ten heavy sync cycles stayed at 0.06s.
4. **`org-element--cache-self-verify` left on.** It was nil.
5. **A stuck `org-element--cache-change-warning`.** It *was* set on the archive buffer, yet `org-element-at-point` there took 0.01ms.
6. **Auto-revert, reproduced in batch.** No slowdown.
7. **Auto-revert on the real live buffer.** A controlled test dirtied the archive buffer with 30k edits and reverted it from disk. The scan measured 0.06s afterwards.

Conclusion at the time: the pathology needs some transient interleaving that could not be triggered deliberately. Treat any new theory as needing to explain why none of the above reproduces it.

Also ruled out as the *trigger*: a sync from the phone's older mindwtr-emacs client a few minutes before the freeze. Data was verified intact across the event (unique MW_IDs unchanged, no duplicates). That sync's clock-skew report is a separate finding with its own TODO.

## Solution

Bind `org-element-use-cache` nil in the one scan guard every heading scan already routes through, alongside the existing `buffer-file-name` binding (`mindwtr-heading.el:294-296`):

```elisp
(defun mindwtr-heading-map (func &rest args)
  "Run `org-map-entries' with FUNC and ARGS under two scan bindings. ..."
  (let ((buffer-file-name nil)
        (org-element-use-cache nil))
    (apply #'org-map-entries func args)))
```

The binding first landed in PR #53 (commit `2a1b3fc`, in the since-deleted `mindwtr-util--map-entries`). PR #54 moved it into `mindwtr-heading-map` (`27a1f32`) and corrected the explanation of what it does. The measured cost when this was first added was about 30ms per sync cycle on a 110KB archive (0.06s to 0.09s).

## Why This Works

The two commits disagree about the mechanism, and the later one is right for current Org:

- **`2a1b3fc` (PR #53) claimed** that with the cache disabled `org-scan-tags` takes a plain regexp outline walk, avoiding the cache code path entirely. Per the PR #54 session, which ran the suite on Emacs 29.3 / Org 9.6.15 in Docker, that holds only for **Org 9.6**, where `org-scan-tags` checks `org-element--cache-active-p` before choosing the cache path. (The docstring also records Org 9.5 as never using the cache; not re-verified here.)
- **`27a1f32` (PR #54) corrected it for Org 9.7+.** Verified against the installed Org 9.8.7: `org-scan-tags` always calls `org-element-cache-map` (`org.el:11651`), which wraps the walk in `org-element-with-enabled-cache` (`org-element.el:8030`). When the cache is disabled, that macro saves the buffer's cache variables, binds `org-element-use-cache` t, calls `org-element-cache-reset` to build a fresh throwaway cache for the scan, and restores the saved state afterwards (`org-element.el:7948-7970`).

So on the Org most users run, the scan still goes through the cache, just a brand-new one. It pays a full parse every time, bounded by buffer size, and it never touches the long-lived cache that had been mutating for days. That is the property that matters: whatever state wedged the old cache cannot reach a scan. The `mindwtr-heading-map` docstring (`mindwtr-heading.el:266-289`) carries this per-version table; the commit message of `2a1b3fc` does not, so do not take its explanation from `git log`.

Skipping the live cache during the scan is safe because every caller is a structural read that inserts or deletes no characters. The fold-restore scan in `mindwtr-reconcile--restore-view` changes only visibility. The buffer's cache therefore stays consistent across the scan.

This matters more for a timer than for a command: the scan runs from `mindwtr-auto-sync-mode`'s timer, so a slow scan presents as a wedged Emacs rather than a slow command the user chose to run.

## Prevention

- **Route every heading scan through `mindwtr-heading-map`.** No production code calls `org-map-entries` directly (only tests do), so the binding covers all scans. A new scan that bypasses the guard reopens the hang on the timer path.
- **Do not remove the binding as dead weight.** It looks inert on Org 9.7+ because `org-scan-tags` re-enables a cache internally, and the regression test cannot observe it: `mindwtr-heading-map-hides-file-name` (`test/mindwtr-heading-test.el:259`) asserts only the `buffer-file-name` half, and its docstring explains why the cache half is unobservable from inside the callback. Nothing in the test suite will fail if it is deleted; this doc and the docstring are the only guard.
- **Scope of the mitigation.** It covers `org-map-entries` scans only. Other cache users in the same session (agenda builds, `org-element-at-point` from user commands) still use the long-lived cache. If a freeze recurs, first check with `sample(1)` (or `M-x profiler-start`) whether the stack is inside `mindwtr-heading-map` at all before assuming the mitigation failed.
- **If it recurs, start from the falsified list above** rather than re-testing those seven theories. The useful new evidence would be what changed in the buffer (edits, reverts, indirect buffers, narrowing) in the minutes before the freeze.
- **Distinct from the Org 9.6 cold-scan bug.** Agenda tests bind `org-element-use-cache` nil for a different reason (Org 9.6 drops deadlines on cold batch agenda scans; see `test/mindwtr-agenda-test.el:167`). Same variable, unrelated defect.

## Related Issues

- `docs/solutions/runtime-errors/org-map-entries-nil-scope-batch-hang.md` covers the other half of the same guard: the `buffer-file-name` binding that stops `org-map-entries` prompting about a non-existent agenda file under `--batch`.
- PR #53 (`fix(sync): keep the auto-sync scan out of org-element's cache`) introduced the binding; PR #54 (the `mindwtr-heading.el` refactor) moved it and corrected the mechanism.
