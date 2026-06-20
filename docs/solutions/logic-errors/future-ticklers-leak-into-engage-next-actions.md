---
title: Future-dated ticklers leaked into the Engage Next Actions block because tags-todo ignores planning dates
date: 2026-06-19
category: logic-errors
module: mindwtr-agenda
problem_type: logic_error
component: tooling
symptoms:
  - "A NEXT task scheduled for a future date appeared in the Engage view's Next Actions block immediately, instead of staying hidden until its start date"
  - "The task showed in no calendar block (span-1 today only, future SCHEDULED lands on its own day) yet still surfaced under Next Actions"
  - "Clarify's tickler outcome (NEXT + future SCHEDULED) was defeated -- deferring an item to a date did not remove it from today's actionable list"
root_cause: missing_constraint
resolution_type: code_fix
severity: medium
related_components:
  - mindwtr-agenda--engage-spec
  - mindwtr-clarify
tags: [agenda, org-mode, gtd, tags-todo, tickler, scheduled, deferred, ignore-options]
---

# Future-dated ticklers leaked into the Engage Next Actions block because tags-todo ignores planning dates

## Problem

The Engage view's "Next Actions" block -- meant to list what you can act on *now* -- also surfaced ticklers deferred to a future date. In this model a tickler is `NEXT` + a future `SCHEDULED` date (Clarify's defer-to-a-date outcome, `mindwtr-clarify.el`), whose entire purpose is "don't show me this until the date arrives." But the block listed it the moment it was created, so every deferred item immediately cluttered the list it was supposed to stay out of.

## Symptoms

- A NEXT task scheduled a week out (e.g. "Deferred") appeared under Next Actions today, alongside genuinely-actionable items.
- The same task appeared in *no* calendar block: the Engage calendar is `org-agenda-span 1` (today only), and a future `SCHEDULED` item lands on its own day, not before. So the task was invisible where it should have been visible (the future calendar) and visible where it should have been hidden (Next Actions).
- Deferring an Inbox item to a date during Clarify did not get it out of your face -- defeating the tickler's reason to exist.

## What Didn't Work

The conceptual trap was assuming an org `tags-todo` search respects planning dates the way the `agenda` (calendar) block does. It does not. A `tags-todo` block lists *every* heading matching its tag/keyword criterion regardless of any `SCHEDULED` or `DEADLINE` on it -- planning dates are simply not consulted. So the original block encoded the wrong mental model -- "a future-scheduled NEXT isn't actionable yet, so it won't show" -- when in fact the date had no effect at all.

```elisp
;; Before: lists every NEXT task, future-scheduled ticklers included
(tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""
           ((org-agenda-overriding-header "Next Actions")
            (org-agenda-prefix-format ',pf)))
```

A second, subtler trap follows once you reach for the fix: org has `org-agenda-todo-ignore-scheduled` for exactly this, but setting it alone does nothing in a `tags-todo` block. The ignore options are honored in tag searches *only* when `org-agenda-tags-todo-honor-ignore-options` is also non-nil -- two bindings are required, not one. (The check lives in `org-scan-tags` in `org.el`, gated on that flag; `org-agenda-todo-ignore-scheduled 'future` on its own is silently inert for `tags-todo`.)

## Solution

Add both bindings to the Next Actions block's local settings:

```elisp
(tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""
           ((org-agenda-overriding-header "Next Actions")
            (org-agenda-prefix-format ',pf)
            (org-agenda-tags-todo-honor-ignore-options t)
            (org-agenda-todo-ignore-scheduled 'future)))
```

`'future` is the deliberate choice over `'all`: it hides only items scheduled *strictly* in the future. A tickler whose date is today (now actionable) or in the past (an overdue tickler that should still nag) stays listed. Deadlines are left untouched -- a due-but-not-yet-started task is actionable now, and its `DEADLINE` already surfaces in the calendar block within `org-deadline-warning-days`.

The guard is scoped to Next Actions only. Today's Focus is explicit (if you starred it, you want it regardless of date); Waiting For uses a check-in `DEADLINE`, not a start date; Inbox items should not carry dates.

## Why This Works

The org-side distinction matches the GTD one the model already encodes: `SCHEDULED` (`startTime`) is a *start date* / tickler -- not actionable until then -- while `DEADLINE` (`dueDate`) is a *due date*, still actionable before it. `org-agenda-todo-ignore-scheduled 'future` defers exactly the first class and leaves the second alone, so a future tickler drops out of Next Actions and resurfaces in the calendar on the day it lands.

## Prevention

- **A `tags-todo` block ignores planning dates by default.** If a block should respect `SCHEDULED`/`DEADLINE`, you must opt in with `org-agenda-tags-todo-honor-ignore-options t` *plus* the relevant `org-agenda-todo-ignore-*` option. Setting the ignore option alone is a no-op in tag searches -- a quiet failure mode worth remembering.
- **Recompile before trusting a local agenda test.** `.elc` is gitignored and `make test` does not depend on `make compile`, so a stale byte-compiled file silently shadows edited `.el` source (Emacs warns "using older file" but still loads it). CI runs `make compile` first; locally, pair them or the test exercises old code. This cost real debugging time here -- the fix looked broken when only the build was stale.
- **Test the boundary, not just the headline case.** Assert the future tickler is *absent* from the block, and (separately) that a today-scheduled, an overdue, and an undated NEXT task all remain -- otherwise a regression to `'all` (hide every scheduled item) would pass a too-weak test. Isolate the block's slice from the full agenda buffer so a calendar entry can't satisfy a presence assertion by accident:

```elisp
(let ((next (mindwtr-agenda-test--block-slice text "Next Actions" "Waiting For")))
  (should-not (string-match-p "Deferred" next))     ; future tickler hidden
  (should (string-match-p "Anytime" next))          ; undated stays
  (should (string-match-p "StartsToday" next))      ; today stays
  (should (string-match-p "Overdue" next)))         ; overdue stays
```

## Related Issues

- [Waiting projects leaked into the Engage Waiting For block via the shared WAIT keyword](waiting-projects-leak-into-engage-waiting-for-block.md) -- sibling agenda-query bug in the same `mindwtr-agenda--engage-spec`. That one is a *type* confusion (a keyword shared across entity types); this one is a *date* confusion (a block that ignores planning dates). Both are cases of a `tags-todo` match being broader than the block's intended meaning.
