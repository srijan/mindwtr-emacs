---
title: Adding a task to an existing project in clarify left it stamped INBOX
date: 2026-06-19
category: logic-errors
module: mindwtr-clarify
problem_type: logic_error
component: tooling
symptoms:
  - "Clarify's [a] add-to-existing-project outcome refiled the task under the project but never set a TODO keyword, so it kept INBOX"
  - "The task kept surfacing as un-clarified inbox work even after being filed under a project"
  - "ensure-status did not self-heal it: an explicit INBOX keyword is a present :status, so the project-task NEXT default never fired"
  - "Keyword-less child sub-headings riding along under the task stayed un-stamped until a later sync"
root_cause: missing_workflow_step
resolution_type: code_fix
severity: medium
related_components:
  - mindwtr-clarify--apply-outcome
  - mindwtr-promote-to-project
  - mindwtr-commands--stamp-missing-child-keywords
  - mindwtr-sync--ensure-status
tags: [clarify, gtd, project-task, next, inbox, keyword-stamping, refile, child-headings]
---

# Adding a task to an existing project in clarify left it stamped INBOX

GitHub issue #35, an earlier PR (merged). Commits `650cb52` (parent keyword) and `9e22ef6` (child keywords).

## Problem
In the clarify workflow (`mindwtr-clarify.el`), the `[a]` "add to an existing project" outcome
refiled the inbox task under the chosen project but never changed its TODO keyword. A task triaged
out of the inbox into a project kept its **INBOX** state — so a clearly-processed task still read as
un-clarified inbox work.

## Symptoms
- A task filed under a project via `[a]` still carried the `INBOX` keyword and kept showing up as
  inbox work despite living under a project.
- Every other actionable outcome set a keyword — `[n]`/`[d]`/`[t]`/`[q]`/`[s]`/`[r]` route through
  `mindwtr-clarify--finalize`, and `[p]` routes through `mindwtr-promote-to-project` — but `[a]` went
  straight to `mindwtr-clarify--refile` with no keyword change.
- Sketched child sub-headings riding along under the task stayed keyword-less, so they did not render
  as project tasks in the local buffer until a sync round-trip.

## What Didn't Work
Two layers that "should" have caught this each had a blind spot:

- **The pre-existing test never observed the keyword.** `mindwtr-clarify-add-to-project-refiles`
  stubbed `org-refile` only to capture the verify function, then asserted the WIP buffer was gone.
  Because the real refile was replaced and the source heading was never inspected, the test was
  structurally incapable of seeing the (wrong) keyword — it passed while the bug shipped.
- **`mindwtr-sync--ensure-status` does not self-heal an explicit INBOX.** It only defaults a
  *missing* status; an explicit `INBOX` keyword is a populated `:status`, so the context-aware
  "task-under-a-project -> next" branch is skipped and sync never corrects the stale keyword. This is
  the crucial difference from the sibling bug (see Related Issues): that one was a *keyword-less* task
  that `ensure-status` defaults correctly; this one carries an explicit keyword that `ensure-status`
  leaves untouched, so it had to be fixed at the point of relocation.
- **Stale `.elc` masked the fix during verification.** After editing `mindwtr-clarify.el`, the test
  kept reporting `INBOX` because a compiled `mindwtr-clarify.elc` shadowed the edited `.el`
  (`load-prefer-newer` is nil by default). Recompiling made the fix visible. Same dead end documented
  in [stale-elc-shadows-updated-el-after-rebase](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md).

## Solution
The `[a]` clause in `mindwtr-clarify--apply-outcome` gained a keyword stamp (commit `650cb52`) and a
child-keyword pass (commit `9e22ef6`), both *before* the refile:

```elisp
;; BEFORE
(?a (mindwtr-clarify--post-prompts t)
    (mindwtr-clarify--refile))

;; AFTER
(?a (mindwtr-clarify--post-prompts t)
    (save-excursion (org-back-to-heading t) (org-todo "NEXT"))
    (mindwtr-commands--stamp-missing-child-keywords)
    (mindwtr-clarify--refile))
```

This mirrors `mindwtr-promote-to-project` (`mindwtr-commands.el`), which does the same
`(org-todo "NEXT")` then `(mindwtr-commands--stamp-missing-child-keywords)` pair before moving the
subtree.

## Why This Works
- **Root cause:** `[a]` was the only task-relocation path in the clarify menu that moved a task
  without setting its keyword. Relocating a heading into a project changes its *role*; the keyword
  has to reflect that role. Treat "relocate" and "restamp" as one operation.
- **NEXT is the codebase-wide resting state for a project task.** `mindwtr-promote-to-project` stamps
  NEXT, `mindwtr-commands--stamp-missing-child-keywords` stamps NEXT, and `mindwtr-sync--ensure-status`
  defaults a parented keyword-less task to `next`. Using NEXT here keeps `[a]` in lockstep with all
  three. (`mindwtr-commands--target-role` returns nil for an in-project task, so the relocate machinery
  deliberately will not move it back out — the keyword is the only thing left to set.)
- **Ordering matters.** The stamp runs before `mindwtr-clarify--refile`, because the refile moves the
  heading out from under point. Setting the keyword first (inside `save-excursion` /
  `org-back-to-heading`) guarantees the heading is still under point when `org-todo` runs.

## Prevention
- **Any task-relocation / refile path must also set the resting keyword.** Moving a heading into a new
  container is not enough — there are now three consumers of the project-task NEXT rule
  (`mindwtr-sync--ensure-status`, `mindwtr-promote-to-project`, and this clarify `[a]` outcome); a
  fourth relocation path must restamp too.
- **`ensure-status` only covers a MISSING keyword, never a wrong one.** Do not rely on sync as a safety
  net for an incorrect-but-present keyword; the source of truth must be right at the point of
  relocation.
- **Tests for refile outcomes must observe the resulting keyword, not stub the refile blind.** Stub
  `org-refile` to a *no-op* so the heading stays in place and its keyword stays observable, then assert
  on it:

  ```elisp
  (cl-letf (((symbol-function 'org-refile) (lambda (&rest _) nil))
            ((symbol-function 'completing-read-multiple) (lambda (&rest _) nil)))
    (mindwtr-clarify)
    (mindwtr-clarify-test--press ?a))
  (with-current-buffer src
    (should (string= (mindwtr-clarify-test--keyword-of "One") "NEXT")))
  ```

  `mindwtr-clarify-add-to-project-sets-next` checks the task itself;
  `mindwtr-clarify-add-to-project-stamps-child-keywords` checks a riding-along child also becomes NEXT.
  The old `mindwtr-clarify-add-to-project-refiles` test is kept for the refile wiring but is no longer
  the only coverage.
- After editing `.el` that has a compiled `.elc`, clear stale `.elc` before running tests.

## Related Issues
- [new-in-project-task-defaults-to-next](new-in-project-task-defaults-to-next.md) — the canonical
  companion. Same "a task under a project rests at NEXT" rule, but on the **sync build path**
  (`mindwtr-sync--ensure-status`) for a *keyword-less* task. This doc is the clarify-interactive
  counterpart, and the distinction is load-bearing: there the keyword is missing (so `ensure-status`
  fixes it); here it is an explicit INBOX (so `ensure-status` does not, and the fix lives in
  `mindwtr-clarify.el`).
- [clarify-queue-markers-collapse-on-write-back](clarify-queue-markers-collapse-on-write-back.md) —
  same module and the same clarify outcome-dispatch machinery (see-also).
- [kill-ring-append-duplicates-paste-subtree](kill-ring-append-duplicates-paste-subtree.md) — concerns
  the clarify relocate/refile step that this outcome's keyword stamp runs ahead of (see-also).
- [stale-elc-shadows-updated-el-after-rebase](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md)
  — the stale-`.elc` dead end hit while verifying this fix.
- In-code precedent: `mindwtr-promote-to-project` (the NEXT + child-stamp pair this outcome now mirrors).
