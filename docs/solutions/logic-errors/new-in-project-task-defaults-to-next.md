---
title: A new in-project task should default to NEXT, not INBOX
date: 2026-06-16
category: logic-errors
module: mindwtr-sync
problem_type: logic_error
component: tooling
symptoms:
  - "A keyword-less task hand-created directly inside a project lands in INBOX instead of NEXT"
  - "mindwtr-sync--ensure-status falls back to a blanket \"inbox\" default for any keyword-less task"
  - "The sync default disagrees with the promote-to-project path, which already stamps project children NEXT"
  - "A task under a someday/waiting project would be a candidate to wrongly inherit a deferred resting state"
root_cause: logic_error
resolution_type: code_fix
severity: medium
related_components:
  - mindwtr-commands--stamp-missing-child-keywords
  - mindwtr-sync--build-candidate
  - mindwtr-parse
tags: [sync, status-default, project-task, next, inbox, parent-presence, status-agnostic]
---

# A new in-project task should default to NEXT, not INBOX

## Problem
A task hand-created directly under a project heading in the Org buffer — but with no TODO keyword
written on it — would sync to the cloud landing in **INBOX** rather than the project's actionable
queue (**NEXT**). The user signalled actionable project work by placing it under a project, yet it
silently fell into the catch-all inbox.

## Symptoms
- A keyword-less heading under a project parses with `:projectId` (and/or `:sectionId`) from outline
  ancestry, but with **no `:status`** (no keyword was written).
- On the next sync, that brand-new task is pushed with `:status "inbox"`.
- The task shows in the global Inbox instead of under its project's NEXT actions, despite its
  outline placement.
- Only hand-typed tasks hit this: the interactive `mindwtr-promote-to-project` path already stamped
  children NEXT, so the inconsistency was invisible to anyone who went through that command.

## What Didn't Work
- **Leaving the blanket `inbox` default.** The original `task -> "inbox"` is the bug itself: it
  ignores the strongest available signal — the task already has a container parent.
- **Cascading the parent project's status onto the task** (task under a `someday` project becomes
  `someday`, etc.). Rejected: it diverges from upstream Mindwtr, where a project flipping to
  `someday` leaves its tasks' status untouched — the project's *container placement* carries the
  deferral, not each task's keyword. Cascading would be lossy and surprising.
- **Keying the default on the parent project entity's status** (read the project's `:status` and
  branch on it). Same divergence as above, and it couples the task default to whether the parent
  project entity happens to be parsed in the same cycle. The fix deliberately keys on *parent
  presence only*, never parent status.
- **Investigation dead ends (session history):**
  - The capture flow (`mindwtr-capture.el`) was traced first and ruled out — capture always targets
    the Inbox explicitly and is not the path that shapes hand-edited headings. The default lives in
    the sync build path, not capture.
  - After the fix was written, two test runs still returned `"inbox"`. The cause was a **stale
    `mindwtr-sync.elc`** (compiled June 12) shadowing the edited `.el`; removing the `.elc` files
    made the fix visible. See
    [stale-elc-shadows-updated-el-after-rebase](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md).

## Solution
`mindwtr-sync--ensure-status` (in `mindwtr-sync.el`) now branches on whether the new entity carries
a container parent:

```elisp
;; BEFORE
(plist-put (copy-sequence entity)
           :status (if (eq kind 'task) "inbox" "active"))

;; AFTER
(plist-put (copy-sequence entity)
           :status (cond
                    ((eq kind 'project) "active")
                    ((or (plist-get entity :projectId)
                         (plist-get entity :sectionId))
                     "next")
                    (t "inbox")))
```

Resulting defaults:
- `project` -> `"active"`
- `task` with a `:projectId` or `:sectionId` parent -> `"next"`
- `task` with no container parent (the Inbox container) -> `"inbox"`

The guard clause is unchanged — it only fires for `task`/`project` kinds that have **no `:status`**
already, so existing tasks that carry a keyword keep it.

## Why This Works
`mindwtr-sync--ensure-status` exists to prevent a cloud **validation-abort**: the server rejects an
entity with a missing/invalid status, so the sync build path must synthesize a default for
brand-new entities before posting. It is called only on the `create` branch of
`mindwtr-sync-build-candidate` — reached only when classification returns `create`, i.e. there is no
`shadow` entity. That is what the docstring's "no shadow status to inherit" means: a brand-new
entity has no prior server-side record whose status could carry forward, so a default must be made
up. Existing entities take the `unchanged`/`update` branches and never reach `ensure-status`.

The root cause was that this default was a single blanket value (`task -> inbox`) that ignored the
entity's own `:projectId`/`:sectionId`. Those fields are the parser's encoding of outline ancestry,
and their *presence* is precisely the signal "this is project work." Branching the default on that
presence puts the task in the project's actionable queue, which is what the placement meant.

Keying on **presence, not the parent's status**, keeps the default deterministic and matches
upstream Mindwtr's rule that a project's deferred status never propagates to its tasks. (Consulted
during the fix: upstream `store-tasks.ts` defaults every new task to `inbox` with no project-context
awareness — so the NEXT default is a deliberate mindwtr-emacs workflow choice, not inherited
upstream semantics, suited to the Org context where the TODO keyword *is* the status. (session
history))

The fix also makes the sync default **consistent with the interactive command path**:
`mindwtr-commands--stamp-missing-child-keywords` (called from `mindwtr-promote-to-project`) already
stamps keyword-less descendants `NEXT` on promote, and its docstring explicitly names the `inbox`
default as "the wrong resting state for a project task." Before this fix only the command path
corrected it; now hand-typed and command-promoted tasks land identically.

## Prevention
- **Guardrail rule: key a child entity's default on parent _presence_, never parent _status_.** A
  task under a `someday`/`waiting` project must still default to `next`; never cascade a container's
  deferral onto its members. Preserve this on any future change to `ensure-status`.
- **Keep the two default paths in sync.** Any change to the sync-side default
  (`mindwtr-sync--ensure-status`) and the command-side stamp
  (`mindwtr-commands--stamp-missing-child-keywords`) must move together; their docstrings
  cross-reference each other for exactly this reason.
- **Regression tests** (in `test/mindwtr-sync-test.el`):
  - `ensure-status` of a standalone task `(:id "t" :title "x")` -> `"inbox"`.
  - `ensure-status` of a task with `:projectId "p1"` -> `"next"`.
  - `ensure-status` of a task with `:sectionId "s1"` -> `"next"`.
  - End-to-end `build-candidate`: a keyword-less task parsed under a project syncs as `"next"`.
  - End-to-end: a keyword-less task under a **someday** project still syncs as `"next"` — the
    load-bearing guard that pins the "presence not status" rule, so a future refactor that reads the
    parent project's status fails loudly.
- After editing `.el` that has a compiled `.elc`, clear stale `.elc` before running tests (a stale
  compile masked this fix during development).

## Related Issues
- [parser-single-most-specific-container-id](parser-single-most-specific-container-id.md) — establishes
  that `:projectId`/`:sectionId` come from outline ancestry and the parser stores the single
  most-specific container. This fix consumes the *presence* of those parsed fields without changing
  them; it complements, not contradicts, that doc.
- [entity-identity-mw-id-mw-list](../conventions/entity-identity-mw-id-mw-list.md) — candidate-build
  entity provisioning in `mindwtr-sync.el`; `ensure-status` runs in the same candidate pipeline.
- [clarify-queue-markers-collapse-on-write-back](clarify-queue-markers-collapse-on-write-back.md) —
  related GTD status-routing logic (see-also).
- [stale-elc-shadows-updated-el-after-rebase](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md)
  — the stale-`.elc` dead end hit while verifying this fix.
- In-code precedent: `mindwtr-commands--stamp-missing-child-keywords` (the promote-to-project NEXT
  stamp the sync default now mirrors).
