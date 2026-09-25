---
title: Waiting projects leaked into the Engage Waiting For block via the shared WAIT keyword
date: 2026-06-17
category: logic-errors
module: mindwtr-agenda
problem_type: logic_error
component: tooling
symptoms:
  - "A project in the waiting state appeared under the Engage view's Waiting For block, interleaved with genuine waiting tasks"
  - "The Waiting For block matched TODO=\"WAIT\" on keyword alone, which does not distinguish a waiting project from a waiting task"
  - "After scoping the block to tasks, waiting projects appeared in no view at all (the Projects view matched ACTIVE only)"
root_cause: scope_issue
resolution_type: code_fix
severity: medium
related_components:
  - mindwtr-agenda--engage-spec
  - mindwtr-agenda--projects-spec
  - mindwtr-model--project-status-keywords
tags: [agenda, org-mode, gtd, tags-todo, mw-type, waiting-state, project-vs-task]
---

# Waiting projects leaked into the Engage Waiting For block via the shared WAIT keyword

## Problem

The Engage view's "Waiting For" block -- intended to list delegated *actions* you are waiting on someone else to complete -- also surfaced waiting *projects*. Because a waiting project carries the same `WAIT` org keyword as a waiting task, and the block matched on keyword alone (`TODO="WAIT"`), blocked projects were wrongly presented as if they were next actions you had delegated.

## Symptoms

- In the Engage agenda, a project heading in the waiting state (e.g. "Blocked proj") appeared under the "Waiting For" block, interleaved with genuine waiting tasks (e.g. "Awaiting reply").
- A blocked project is not something you delegated and are awaiting a reply on -- it belongs in the Projects view, not among delegated actions -- so its presence there was semantically misleading.

## What Didn't Work

The conceptual trap was matching an agenda block by TODO keyword alone, on the assumption that a keyword uniquely identifies an entity type. It does not. In this model, status maps to an org keyword *per entity type*, and the keyword space overlaps: `mindwtr-model--project-status-keywords` maps project `"waiting"` to `WAIT`, the very same keyword a waiting task uses.

```elisp
(defconst mindwtr-model--project-status-keywords
  '(("active" . "ACTIVE") ("someday" . "SOMEDAY")
    ("waiting" . "WAIT") ("archived" . "ARCH")))
```

So the original block encoded the wrong mental model -- "WAIT means a waiting task" -- when in fact `WAIT` means "a waiting task *or* a waiting project." The keyword is a status, not a type; only the `MW_TYPE` property distinguishes the two.

```elisp
;; Before: matches both waiting tasks and waiting projects
(tags-todo "TODO=\"WAIT\""
           ((org-agenda-overriding-header "Waiting For") ...))
```

## Solution

The complete fix is two-part -- narrow the over-broad query, then re-home what you excluded.

**Part 1 -- scope the Waiting For block to tasks** (commit `c67f23c`):

```elisp
(tags-todo "TODO=\"WAIT\"+MW_TYPE=\"task\""
           ((org-agenda-overriding-header "Waiting For") ...))
```

**Part 2 -- give waiting projects a home** (commit `e554c31`). The Projects view previously matched only `MW_TYPE="project"+TODO="ACTIVE"`, so the now-excluded waiting projects would have vanished from every view. A second Projects block was added:

```elisp
(tags-todo "MW_TYPE=\"project\"+TODO=\"WAIT\""
           ((org-agenda-overriding-header "Waiting Projects")
            (org-agenda-prefix-format ',project-pf)))
```

Both parts are essential: excluding without re-homing would have silently dropped waiting projects from all views.

## Why This Works

`MW_TYPE` is the only field that distinguishes a waiting task from a waiting project -- the `WAIT` TODO keyword is shared between them. Adding `+MW_TYPE="task"` to the match constrains it to the type the block actually means, restoring the intended GTD semantics (delegated actions in Engage, blocked projects in the Projects view).

Only the `WAIT` state needed the guard because it is the only keyword that collides across entity types in the views that matter here. The sibling blocks are safe by construction: projects are never in the `NEXT` or `INBOX` states, so `TODO="NEXT"` and `TODO="INBOX"` can only ever match tasks. The project keywords that *do* overlap -- `ACTIVE`, `SOMEDAY`, `ARCH` -- only appear in views already scoped to `MW_TYPE="project"`.

## Prevention

- **Constrain shared keywords by type.** When a status keyword is shared across entity types (here `WAIT` for both tasks and projects), any agenda block or query that targets that keyword must also constrain on `MW_TYPE`. Treat a bare `TODO="X"` match as suspect whenever `X` is reachable by more than one entity type.
- **Never orphan what you exclude.** When you narrow a query to remove a class of items, immediately verify those items still appear in some other view. Excluding without re-homing silently drops data -- confirm the destination view exists and matches them.
- **Test both directions.** Assert that the excluded type is *absent* from the narrowed block, and (separately) that it has a home elsewhere. The test added here resolves the block's match string from the live spec, runs `org-map-entries` over fixture appdata containing both a waiting task and a waiting project, then checks heading membership:

```elisp
(let ((hits (org-map-entries
             (lambda () (org-get-heading t t t t)) wait-match)))
  (should (member "Awaiting reply" hits))      ; task present
  (should-not (member "Blocked proj" hits)))   ; project excluded
```

## Related Issues

- [A new in-project task should default to NEXT, not INBOX](new-in-project-task-defaults-to-next.md) -- sibling learning rooted in the same GTD rule that project status and task status are distinct dimensions; that doc handles the sync-default angle, this one the agenda-query angle.
- [Entity identity: MW_ID and MW_LIST are the sync keys](../conventions/entity-identity-mw-id-mw-list.md) -- defines `MW_TYPE` as the entity-type discriminator that the `+MW_TYPE="task"` constraint keys on.
