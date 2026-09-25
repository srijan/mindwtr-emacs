---
title: "Agenda skip rules: the global skip hook composes with a block's, a view-wide org-agenda-skip-function is replaced"
date: 2026-09-25
category: design-patterns
module: mindwtr-agenda
problem_type: design_pattern
component: tooling
severity: medium
applies_when:
  - "Adding a filter that must hold across every block of a composite agenda view (Engage, Projects, any new view)"
  - "Adding a block-level org-agenda-skip-function to a view that already filters view-wide"
  - "Deciding whether a new availability rule is block-scoped or view-wide"
  - "Writing a test that claims a task is shown or hidden by an agenda view"
tags: [agenda, org-mode, org-agenda-skip, skip-function, skip-function-global, testing, mutation-testing, engage]
related_components:
  - mindwtr-agenda--engage-spec
  - mindwtr-agenda--skip-parked-project
  - mindwtr-agenda--skip-blocked-step
---

# Agenda skip rules: the global skip hook composes with a block's, a view-wide org-agenda-skip-function is replaced

## Context

The Engage view (`mindwtr-agenda--engage-spec`) filters with three rules that
mirror the three "unavailable" reasons of core's `getTaskFocusEligibility`:
future tickler, blocked sequential step, and task owned by a parked (SOMEDAY or
WAIT, unpinned) project. The first two live on the Next Actions block; the
parked rule must reach every block, the calendar included.

PR #65 first put the parked rule on a view-wide `org-agenda-skip-function`.
That worked for four blocks and silently failed on the fifth: Next Actions
already binds its own `org-agenda-skip-function` for the sequential rule, and a
block-level setting *replaces* the view-wide value of the same variable. The
first fix was to hand-merge both rules into one combined block skip function.
That hid the real design problem: any later block that installed a skip
function of its own would silently drop the parked rule again, and nothing
would fail.

Self-review in the same PR found the right hook. The fix landed on `main` with
PR #65 (merged 2026-09-22), after PR #61 (sequential blocked steps).

Two lessons came out of it: where a skip rule is bound (Guidance 1 and 2,
visible in the final code), and how a test proves a view hides something
(Guidance 3, visible nowhere in the production module).

## Guidance

### 1. A view-wide rule goes on `org-agenda-skip-function-global`

`org-agenda-skip` evaluates both hooks and skips when either returns a
position (Org 9.8.7 `org-agenda.el`, `org-agenda-skip`, around line 4265; PR #65
records the same behaviour on Org 9.6.15, which CI runs):

```elisp
(let ((to (or (org-agenda-skip-eval org-agenda-skip-function-global)
              (org-agenda-skip-eval org-agenda-skip-function))))
```

So the two hooks are **different variables that are ORed**, and each block's
settings are bound over the view-wide ones (`org-agenda-run-series` binds
`(append gvars lvars)` with `cl-progv`, so a block's value wins). The consequences:

| Where the rule is bound | Effect on a block that binds its own `org-agenda-skip-function` |
|---|---|
| view-wide `org-agenda-skip-function` | Replaced. The rule silently stops applying in that block. |
| view-wide `org-agenda-skip-function-global` | Composes. Both rules apply. |
| block binds `org-agenda-skip-function-global` too | Replaced again. Composition is one level only: never bind the global hook per block. |

The current wiring (`mindwtr-agenda.el`, spec around lines 590-632):

```elisp
(tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""
           ((org-agenda-overriding-header "Next Actions")
            ...
            (org-agenda-skip-function 'mindwtr-agenda--skip-blocked-step)))
...
((org-agenda-skip-function-global 'mindwtr-agenda--skip-parked-project))
```

Each skip function carries **one** rule. There is no combined function to keep
in sync. The cost, documented in the spec docstring: a user's own
`org-agenda-skip-function-global` is shadowed while the Mindwtr view builds,
like every other setting these views bind.

### 2. Decide scope per rule, deliberately

The three rules are listed together in the comment block (`mindwtr-agenda.el`
around lines 440-472) but are deliberately **not** scoped alike:

- **Tickler (`deferred`) and sequential**: Next Actions block only. Today's
  Focus is an explicit user pick and must not be filtered by either.
- **Parked project**: view-wide, because upstream applies
  `isTaskInActiveProject` as base visibility for every list.

One consequence is tested and intended: a WAIT step inside an ACTIVE sequential
project shows under Waiting For while Next Actions treats it as blocked.
Upstream's Waiting list also filters on project status, not on the chain.
Before you move a rule to the global hook "for consistency", check upstream's
scope for it.

### 3. Behavioral tests must build the view

`mindwtr-agenda-engage-waiting-excludes-projects` used to put its delegated
task under the WAITING project and assert that the task belongs in Waiting For.
After the parked rule landed, the built view no longer showed that task. The
test still passed. It resolved the block's **match string** from the spec and
ran it through `org-map-entries`. That scan does call `org-agenda-skip` per
entry (via `org-scan-tags`), but with `org-agenda-skip-function` bound only from
its own empty SKIP args and `org-agenda-skip-function-global` never bound, so
no Mindwtr skip rule is active there, and it never sees the other block or view
settings (skip functions, `org-agenda-todo-ignore-*`,
`org-agenda-tags-todo-honor-ignore-options`). The test asserted behaviour the
view did not have.

Rules for agenda tests:

- A claim about what a user **sees** builds the view. Use
  `mindwtr-agenda-test--engage-text` (it calls `org-agenda` on the real spec
  and returns the buffer text). Use `mindwtr-agenda-test--block-slice` when a
  presence assertion must not be satisfied by a different block.
- A match-string test through `org-map-entries` proves only what the match
  string selects. Keep it for that narrow purpose, and keep its fixture free of
  anything a skip rule would drop. Otherwise it encodes a behaviour the view
  lacks.
- Mutation-check each new behavioral test. Move the global binding onto the
  non-global hook, or delete it, and confirm the test fails. PR #65's behavioral
  tests were checked this way. Run `rm -f *.elc` first (AGENTS.md): a stale
  `.elc` means the mutated source is never loaded, so the check proves nothing.
  The PR #65 fixture-rewrite check was run with `.elc` removed (session history).
- Bind `org-element-use-cache` to nil in any test that builds an agenda. Org
  9.6 (CI) drops planning data on cold batch scans otherwise. The helper
  already does this. (auto memory [claude])

## Why This Matters

A skip rule that falls off one block fails silently: the task shows up in a
list where it should not, no error is raised, and only a user who notices the
item can tell. The docstring of `org-agenda-skip-function-global` says it
applies to every match but never says it is ORed with the per-command hook,
and the natural first move (put the view-wide
rule on the view-wide `org-agenda-skip-function`) is the wrong one. A
match-string test gives no signal, because it never runs any skip function.

## When to Apply

- Adding a filter to an existing agenda view, or building a new composite view
  (Projects, a review view) that needs one rule across blocks plus per-block
  rules.
- Reviewing a spec where both hooks appear, or where one skip function applies
  more than one rule.
- Writing or reviewing any test named "... excludes ...", "... hides ..." or
  "... keeps ..." for an agenda view.

## Examples

Before (PR #65, first commit): one rule stated twice.

```elisp
;; view-wide
((org-agenda-skip-function 'mindwtr-agenda--skip-deferred-project)) ; since renamed -parked-
;; Next Actions block: must re-state the parked rule or lose it
(org-agenda-skip-function 'mindwtr-agenda--skip-unavailable) ; parked OR blocked
```

After: one rule per hook, composed by Org.

```elisp
;; view-wide
((org-agenda-skip-function-global 'mindwtr-agenda--skip-parked-project))
;; Next Actions block
(org-agenda-skip-function 'mindwtr-agenda--skip-blocked-step)
```

The test that pins the composition builds the view and asserts both rules in
the one block that installs its own hook
(`mindwtr-agenda-engage-next-actions-keeps-both-skip-rules` in
`test/mindwtr-agenda-test.el`):

```elisp
(should (string-match-p "SeqStepOne" text))    ; slot holder listed
(should-not (string-match-p "SeqStepTwo" text)) ; sequential rule fired
(should-not (string-match-p "ParkedStep" text)) ; global parked rule fired
```

## Related

- [Waiting projects leaked into the Engage Waiting For block](../logic-errors/waiting-projects-leak-into-engage-waiting-for-block.md): its Prevention section shows the `org-map-entries` match-string test pattern. That pattern cannot see skip rules; see Guidance section 3 above.
- [Future-dated ticklers leaked into Engage Next Actions](../logic-errors/future-ticklers-leak-into-engage-next-actions.md): the block-scoped tickler rule, another block setting a match-string test cannot see.
- PR #61 (sequential blocked steps) and PR #65 (parked projects), both merged.
