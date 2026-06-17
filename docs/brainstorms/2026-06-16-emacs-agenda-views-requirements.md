---
date: 2026-06-16
topic: emacs-agenda-views
---

# Mindwtr Emacs Agenda Views — Requirements

## Summary

Ship two opt-in `org-agenda` views for the mindwtr file — an **Engage** view
(today's calendar, focus, next actions, waiting, inbox) and a **Projects**
view (active projects with stuck ones surfaced) — registered through one
`mindwtr-agenda-setup` call and reached from the standard agenda dispatcher.
They are plain `org-agenda-custom-commands` entries, tested and shipped in the
package, so users stop hand-rolling them in personal config.

## Problem Frame

mindwtr owns a fixed keyword set (`INBOX NEXT WAIT SOMEDAY REF ACTIVE | DONE
ARCH`) and a focus field (`MW_FOCUS_TODAY`), but ships no way to *see* across
them. To get a daily working view today, a user reconstructs an
`org-agenda-custom-commands` block by hand and keeps it in sync with mindwtr's
keywords as they evolve — exactly the kind of friction the Emacs-native editing
track exists to remove ("if the desk surface isn't a joy to edit, the user
won't keep the org file as their source of truth"). The raw outline alone
can't answer "what should I do now" or "which projects have stalled."

## Key Decisions

- **No view-language DSL.** org-gtd compiles view specs through ~1100 lines of
  DSL (`org-gtd-view-language.el`) because it supports arbitrary user
  configuration. mindwtr owns one keyword set and (typically) one file, so the
  views are written directly as `org-agenda-custom-commands` entries. Carrying
  cost stays low.

- **Delivery is dispatcher-first, opt-in.** A one-time `mindwtr-agenda-setup`
  registers the entries; users reach them via `C-c a`. No view appears until
  the user opts in.

- **Each command scopes its own `org-agenda-files`.** The commands bind
  `org-agenda-files` to the mindwtr file(s) internally, so the views work
  whether or not the user has added the mindwtr file to their global agenda
  configuration.

- **Focus reuses the existing synced field.** "Today's Focus" is a property
  match on `MW_FOCUS_TODAY="t"` (already round-tripped, ticket #4) — no new
  field, no new sync work.

- **Plain text only, no emoji or icons.** Block headers and labels use plain
  text (`Today's Focus`, `Next Actions`, `Stuck (no next action)`).

## Requirements

**Engage view**

R1. The Engage view is a single multi-block `org-agenda` custom command whose
blocks appear in this order: calendar, Today's Focus, Next Actions, Waiting
For, Inbox.

R2. The calendar block shows today's `SCHEDULED` items and upcoming `DEADLINE`s
over a configurable look-ahead window.

R3. The Today's Focus block lists tasks matching `MW_FOCUS_TODAY="t"`.

R4. The Next Actions block lists `NEXT` tasks, excluding any already shown in
the Focus block (no task appears twice).

R5. The Waiting For block lists `WAIT` tasks.

R6. The Inbox block lists uncleared `INBOX` items and is the last block in the
view.

**Projects view**

R7. The Projects view lists `ACTIVE` projects (headings with
`MW_TYPE="project"`).

R8. Projects that are stuck — active, with no `NEXT` child task — are surfaced
distinctly at the top of the view.

R9. Project navigation uses native org-agenda behavior: `RET` jumps to the
project heading (and its subtree of actions), `TAB`/follow-mode preview without
leaving the agenda. No custom navigation code.

**Delivery and packaging**

R10. `mindwtr-agenda-setup` registers both views as `org-agenda-custom-commands`
entries reachable from the standard dispatcher (`C-c a`). Views are not active
until this is called.

R11. Both views are covered by `make test` (the offline correctness gate), so
their definitions ship verified rather than as documentation.

**Presentation**

R12. All block headers and labels are plain text — no emoji or icons.

R13. The archive surface (`mindwtr_archive.org`) is excluded from both views;
done and archived entities are not actionable.

## Acceptance Examples

AE1. **Covers R3, R4.** A `NEXT` task carrying `MW_FOCUS_TODAY="t"` appears in
the Today's Focus block and does **not** also appear in the Next Actions block.

AE2. **Covers R8.** An `ACTIVE` project with at least one `NEXT` child appears
in the normal project list; an `ACTIVE` project with zero `NEXT` children
appears under the stuck grouping at the top.

AE3. **Covers R2.** A task with `DEADLINE` inside the look-ahead window shows in
the calendar block today; the same task with a deadline beyond the window does
not.

AE4. **Covers R7, R13.** A project with status `ARCH` (or living in the archive
file) appears in neither view.

## Scope Boundaries

**Deferred for later**

- A context-grouped Next Actions view (mirroring the app's Focus screen, which
  groups next actions by `@agenda` / `@calls` / `@computer`).
- Person-scoped `@agenda/<name>` agenda lists — depends on ticket #46
  (Clarify producing those contexts) landing first.

**Outside this build**

- A view-language / DSL abstraction. Direct custom-command definitions only.
- Any change to how focus, keywords, or contexts are synced or rendered — this
  builds on the existing model untouched.

## Dependencies / Assumptions

- `MW_FOCUS_TODAY` round-trips already (ticket #4, closed) — Focus block depends
  on it.
- Projects carry `MW_TYPE="project"` and nest their task children, so a
  subtree scan can detect a missing `NEXT` child (assumption: project tasks are
  outline descendants of the project heading, consistent with the current
  render).
- Targets the package's minimum platform (Emacs 28.1 / Org 9.5); agenda
  construction must avoid Org 9.6+-only APIs, consistent with AGENTS.md.

## Outstanding Questions

**Deferred to planning**

- Default value for the calendar look-ahead window (R2) — a small number of
  days; exact default and defcustom name decided in planning.
- Dispatcher key assignments for the two entries (R10) — chosen to avoid
  clobbering common user bindings; possibly under a configurable prefix.
- Whether stuck projects render as a separate agenda block vs. a sorted/flagged
  group within one block (R8) — both satisfy the requirement; pick during
  implementation.

## Sources / Research

- `mindwtr-model.el:14` — canonical TODO keyword sequence.
- `mindwtr-model.el:156` — content allow-list including `:isFocusedToday`.
- `mindwtr-render.el:167` — `MW_FOCUS_TODAY` renders as `:MW_FOCUS_TODAY: t`
  (omitted when false), so the Focus block is a clean property match.
- `mindwtr-parse.el` — `MW_TYPE` discriminates `project` / `task` / `container`.
- `org-gtd.el:org-gtd-engage.el`,
  `org-gtd-view-language.el` — reference for engage-view composition and the
  DSL approach this brief deliberately does not copy.
- GitHub #8 (ship agenda/engage views), #4 (focus sync, closed), #46
  (`@agenda/<name>` contexts, related/deferred).
