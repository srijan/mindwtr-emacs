---
title: "feat: Mindwtr Emacs agenda views (Engage + Projects)"
date: 2026-06-16
type: feat
origin: docs/brainstorms/2026-06-16-emacs-agenda-views-requirements.md
---

# feat: Mindwtr Emacs Agenda Views (Engage + Projects)

## Summary

Add a new `mindwtr-agenda.el` module that ships two opt-in `org-agenda` views
for the mindwtr file: **Engage** (today's calendar, focus, next actions,
waiting, inbox) and **Projects** (active projects with stuck ones flagged
inline). A `mindwtr-agenda-setup` call binds a configurable `C-c d` prefix —
`C-c d e` for Engage, `C-c d p` for Projects. Both views build their agenda
dynamically and scope `org-agenda-files` to the mindwtr file internally, so they
work without any global agenda config. Shipped tested and byte-clean.

---

## Problem Frame

mindwtr owns a fixed keyword set (`INBOX NEXT WAIT SOMEDAY REF ACTIVE | DONE
ARCH`) and a synced focus field (`MW_FOCUS_TODAY`), but ships no way to see
across them. To get a daily working view today, a user hand-rolls an
`org-agenda-custom-commands` block and keeps it in sync with mindwtr's keywords
as they evolve — friction the Emacs-native editing track exists to remove. The
raw outline can't answer "what should I do now" or "which projects have
stalled."

---

## Requirements Traceability

Requirements and acceptance examples are carried from the origin
(`docs/brainstorms/2026-06-16-emacs-agenda-views-requirements.md`). One origin
requirement is overridden by an explicit user decision during planning:

- **R10 override** — origin R10 registered the views in `org-agenda-custom-commands`
  reachable from the standard dispatcher (`C-c a`). The user chose a dedicated
  `C-c d` prefix instead (`C-c d e` / `C-c d p`). The plan binds those keys to
  interactive commands; it does **not** pollute global `org-agenda-custom-commands`.
- **R2 refinement** — origin R2 called the window "configurable" and the origin
  Outstanding Questions deferred the defcustom name to planning. The user decided
  not to add a view-specific defcustom: the calendar block leaves
  `org-deadline-warning-days` untouched, so the window is configurable through org's
  own setting. "Configurable" is satisfied via the org default, not a new defcustom.

| Origin | Covered by |
|---|---|
| R1 (Engage block order) | U3 |
| R2 (calendar: today scheduled + upcoming deadlines) | U3 |
| R3 (focus block `MW_FOCUS_TODAY="t"`) | U3 |
| R4 (next actions exclude focused) | U3 |
| R5 (waiting block) | U3 |
| R6 (inbox block last) | U3 |
| R7 (projects: active, `MW_TYPE="project"`) | U4 |
| R8 (stuck projects surfaced) | U2, U4 |
| R9 (native RET/TAB/F navigation) | U6 (documented; no code) |
| R10 (delivery) — overridden to `C-c d` prefix | U5 |
| R11 (shipped tested) | U2, U3, U4, U5 test scenarios |
| R12 (plain text, no emoji/icons) | U3, U4 |
| R13 (archive excluded) | U1 |
| AE1 (focus dedup) | U3 |
| AE2 (stuck detection) | U2 |
| AE3 (deadline window) | U3 |
| AE4 (archive/done excluded) | U1, U4 |

---

## Key Technical Decisions

- **No global state; build agenda dynamically.** Each interactive command
  `let`-binds `org-agenda-files` to `(list mindwtr-file)` and `org-agenda-custom-commands`
  to a single freshly-built entry, then calls `org-agenda`. Nothing is written to
  the user's global `org-agenda-custom-commands`. This satisfies "scope agenda-files
  internally" (origin Key Decision) and keeps the views opt-in.

- **Delivery via a configurable prefix keymap.** `mindwtr-agenda-setup` installs a
  prefix keymap on `mindwtr-agenda-prefix-key` (default `"C-c d"`) with `e` → Engage,
  `p` → Projects (user decision). The commands are also plain `M-x`-invocable and
  autoloaded.

- **Deadline window uses org's own default.** The calendar block is a single-day
  agenda (`org-agenda-span` = 1) and does **not** override `org-deadline-warning-days`
  — upcoming deadlines surface via the user's existing org default (user decision).
  No new defcustom for the window.

- **Focus is a property match.** Today's Focus = `MW_FOCUS_TODAY="t"`; the Next
  Actions block excludes focused items via the same property in its match string,
  so no task appears twice (origin: focus already round-trips, ticket #4).

- **Stuck = inline flag in one list.** The Projects view is a single block listing
  active projects; a stuck project (active, no `NEXT` descendant) is marked inline
  with a plain-text flag. The block's `org-agenda-prefix-format` is a format string
  with a `%(...)` escape that calls a helper (`mindwtr-agenda--project-prefix`),
  which in turn uses the reusable `mindwtr-agenda--project-stuck-p` predicate. (Org's
  `org-agenda-prefix-format` is an alist of format strings, not a function slot — the
  helper is invoked from a `%(...)` escape, and being a named function keeps it unit
  testable.) User decision: one list, not two blocks. Stuck entries sort ahead of the
  rest.

- **Match-string and prefix-format specifics are directional.** Exact org match
  expressions and prefix-format strings are refined at implementation; the plan
  fixes the approach, not the literal strings.

---

## High-Level Technical Design

Both commands follow the same shape — build an entry, bind files, invoke:

```
mindwtr-engage / mindwtr-projects (interactive)
  └─ let org-agenda-files = (list mindwtr-file)       ; archive excluded
     let org-agenda-custom-commands = (list (build-spec))
     (org-agenda nil <key>)

Engage spec (composite, block order):       Projects spec (single block):
  1. agenda      today's schedule              tags-todo MW_TYPE="project"+ACTIVE
  2. tags-todo   MW_FOCUS_TODAY="t"              prefix-format %(...) flags stuck
  3. tags-todo   NEXT + MW_FOCUS_TODAY<>"t"      (mindwtr-agenda--project-stuck-p)
  4. tags-todo   WAIT                             sorted: stuck first
  5. tags-todo   INBOX  (last)
```

Block headers are plain text (`Today's Focus`, `Next Actions`, `Waiting For`,
`Inbox`, `Projects`). Directional; not implementation specification.

---

## Implementation Units

### U1. Module scaffold, file scoping, and wiring

**Goal:** Create `mindwtr-agenda.el` with its requires/provide, the
`mindwtr-agenda-prefix-key` defcustom, and the agenda-files scoping helper.

**Requirements:** R13, AE4.

**Dependencies:** none.

**Files:**
- `mindwtr-agenda.el` (new) — header, `(require 'org-agenda)`, `(require 'mindwtr-model)`, `(provide 'mindwtr-agenda)`.
- `mindwtr.el` (modify) — add `(require 'mindwtr-agenda)` alongside the other module requires.
- `test/mindwtr-agenda-test.el` (new) — test file (auto-discovered by `test/*-test.el`).

**Approach:**
- `mindwtr-agenda--files` returns `(list mindwtr-file)` and signals a clear error
  when `mindwtr-file` is unset (mirror the existing `mindwtr.el:119` pattern).
  Deliberately excludes `(mindwtr-archive-path)` — archived/done entities are not
  actionable.
- `mindwtr-agenda-prefix-key` defcustom, default `"C-c d"`, type string.

**Patterns to follow:** module header/`provide` style of `mindwtr-commands.el`;
`mindwtr-file` error guard at `mindwtr.el:119`.

**Test scenarios:**
- `mindwtr-agenda--files` returns exactly `(list mindwtr-file)` when set. **Covers AE4** (archive path is not included).
- `mindwtr-agenda--files` signals an error when `mindwtr-file` is nil.

**Verification:** module loads and byte-compiles warning-free under `make compile`;
the two helper tests pass.

### U2. Stuck-project predicate

**Goal:** A reusable predicate that decides whether the project heading at point
is stuck (active, with no `NEXT` descendant task).

**Requirements:** R8, AE2.

**Dependencies:** U1.

**Files:**
- `mindwtr-agenda.el` (modify) — add `mindwtr-agenda--project-stuck-p`.
- `test/mindwtr-agenda-test.el` (modify).

**Approach:**
- At a heading with `MW_TYPE="project"` and an active keyword, scan its subtree
  for a child task whose TODO keyword is `NEXT`. Stuck when none found. Scope the
  scan to the project's subtree (`org-narrow-to-subtree` or an end-of-subtree
  bound). Only `NEXT` counts — `WAIT`/`SOMEDAY`/`DONE` children do not clear stuck.

**Patterns to follow:** `mindwtr-commands--kind-at-point` and the ancestry/subtree
walking in `mindwtr-parse.el` (`mindwtr-parse--ancestor-id`); test rendering via
`mindwtr-commands-test--with-appdata`.

**Test scenarios:**
- Active project with a `NEXT` child → not stuck. **Covers AE2.**
- Active project with zero `NEXT` children → stuck. **Covers AE2.**
- Active project whose only children are `DONE` → stuck.
- Active project with a `WAIT` child but no `NEXT` → stuck.
- Nested: a `NEXT` task under a section within the project → not stuck (descendant, not just direct child).

**Verification:** predicate tests pass against rendered appdata buffers.

### U3. Engage view

**Goal:** `mindwtr-engage` interactive command and its composite agenda spec
builder.

**Requirements:** R1, R2, R3, R4, R5, R6, R12, AE1, AE3.

**Dependencies:** U1.

**Files:**
- `mindwtr-agenda.el` (modify) — `mindwtr-agenda--engage-spec` (returns the
  custom-command entry) and `;;;###autoload (defun mindwtr-engage ...)`.
- `test/mindwtr-agenda-test.el` (modify).

**Approach:**
- `mindwtr-engage` `let`-binds `org-agenda-files` to `(mindwtr-agenda--files)` and
  `org-agenda-custom-commands` to `(list (mindwtr-agenda--engage-spec))`, then calls
  `org-agenda` with the spec's key.
- Spec is a composite command with blocks in order: `agenda` (span 1, no override
  of `org-deadline-warning-days`), `tags-todo "MW_FOCUS_TODAY=\"t\""`,
  `tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""` (directional), `tags-todo "TODO=\"WAIT\""`,
  `tags-todo "TODO=\"INBOX\""` last.
- The focus-exclusion uses **property inequality** `MW_FOCUS_TODAY<>"t"`, not tag
  negation `-MW_FOCUS_TODAY`: `MW_FOCUS_TODAY` is a drawer property (renders as
  `:MW_FOCUS_TODAY: t`), so `-MW_FOCUS_TODAY` would negate a non-existent tag and
  fail to dedup. The inequality form also correctly includes tasks where the property
  is absent (the normal render for non-focused items).
- Each block sets `org-agenda-overriding-header` to a plain-text label (R12).

**Technical design (directional):** see High-Level Technical Design block layout.
Exact match strings are refined at implementation.

**Patterns to follow:** `org-agenda-custom-commands` composite-command form;
`mindwtr-model.el` keyword names for match strings.

**Test scenarios:**
- `mindwtr-agenda--engage-spec` returns five blocks in the order calendar, focus,
  next, waiting, inbox. **Covers R1.**
- Behavioral (not just structural): render an appdata buffer (via
  `mindwtr-commands-test--with-appdata`) with a focused `NEXT` task and an unfocused
  `NEXT` task, then run each block's match string against the buffer with
  `org-map-entries` (the same matcher org-agenda uses). Assert the focus block's match
  selects the focused task, and the next block's match selects the unfocused task and
  **excludes** the focused one. **Covers AE1.** This catches a wrong-but-plausible
  match string that a structure-only assertion would miss.
- The agenda/calendar block does not set `org-deadline-warning-days` in its settings
  (window follows the org default). For behavior, render tasks with a near deadline
  (inside the org default warning window) and a far one (beyond it) and assert the
  near one is surfaced by the agenda block and the far one is not. **Covers AE3.**
- The inbox block is the last element. **Covers R6.**
- Every block carries a plain-text `org-agenda-overriding-header` with no emoji or
  non-ASCII icon characters. **Covers R12.**

**Verification:** spec-structure tests pass; `mindwtr-engage` opens an agenda
scoped to the mindwtr file (manual confirmation).

### U4. Projects view

**Goal:** `mindwtr-projects` interactive command and its agenda spec, with stuck
projects flagged inline.

**Requirements:** R7, R8, R12, AE4.

**Dependencies:** U1, U2.

**Files:**
- `mindwtr-agenda.el` (modify) — `mindwtr-agenda--projects-spec`,
  `mindwtr-agenda--project-prefix` (prefix-format function), and
  `;;;###autoload (defun mindwtr-projects ...)`.
- `test/mindwtr-agenda-test.el` (modify).

**Approach:**
- Single `tags-todo` block matching `MW_TYPE="project"` restricted to the active
  keyword.
- `org-agenda-prefix-format` uses `mindwtr-agenda--project-prefix`, which returns a
  plain-text `STUCK` marker (padded) when `mindwtr-agenda--project-stuck-p` is true
  at the entry, blank otherwise (R12 — plain text).
- Sort so stuck entries lead (e.g., a user-defined sort that keys on the predicate),
  realizing "surfaced" within one list.
- Same `let`-bind-and-invoke shape as `mindwtr-engage`.

**Patterns to follow:** U3 command shape; U2 predicate; org prefix-format function
convention.

**Test scenarios:**
- `mindwtr-agenda--projects-spec` is a single block matching `MW_TYPE="project"` and
  the active keyword. **Covers R7.**
- `mindwtr-agenda--project-prefix` returns the `STUCK` marker at a stuck project and
  a blank/space-padded string at a non-stuck project. **Covers R8.**
- The prefix marker contains only plain ASCII text (no emoji/icons). **Covers R12.**
- A project with status `ARCH` is not matched by the spec. **Covers AE4.**

**Verification:** spec/prefix tests pass; `mindwtr-projects` lists active projects
with stuck ones flagged and leading (manual confirmation).

### U5. Setup / keybinding entry point

**Goal:** `mindwtr-agenda-setup` binds the configurable prefix to the two commands.

**Requirements:** R10 (overridden to `C-c d`).

**Dependencies:** U1, U3, U4.

**Files:**
- `mindwtr-agenda.el` (modify) — `;;;###autoload (defun mindwtr-agenda-setup ...)`.
- `test/mindwtr-agenda-test.el` (modify).

**Approach:**
- Build a prefix keymap binding `e` → `mindwtr-engage`, `p` → `mindwtr-projects`,
  and install it globally under `(kbd mindwtr-agenda-prefix-key)` (default `C-c d`).
- Idempotent: calling setup twice leaves a single consistent binding.

**Patterns to follow:** `;;;###autoload` entry points in `mindwtr.el`.

**Test scenarios:**
- After `mindwtr-agenda-setup`, `C-c d e` resolves to `mindwtr-engage` and `C-c d p`
  to `mindwtr-projects` (via `key-binding`/`lookup-key`).
- A custom `mindwtr-agenda-prefix-key` (e.g., `"C-c m"`) binds the commands under
  that prefix instead.

**Verification:** keybinding tests pass; manual `C-c d e` / `C-c d p` open the views.

### U6. Documentation

**Goal:** Document setup, the two views, the keybindings, and native navigation in
the README.

**Requirements:** R9.

**Dependencies:** U3, U4, U5.

**Files:**
- `README.md` (modify) — replace the placeholder agenda bullet (around `README.md:485`)
  with a real section: `(mindwtr-agenda-setup)`, `C-c d e` / `C-c d p`, what each
  view shows, and that `RET`/`TAB`/`F` drill into a project's actions natively (R9).

**Approach:** Plain-text labels throughout (R12). Keep the section concise and
consistent with the README's existing voice.

**Test scenarios:** Test expectation: none — documentation only.

**Verification:** README renders; setup instructions match the shipped command and
defcustom names.

---

## Scope Boundaries

**In scope:** the two views, the stuck predicate, the setup/keybinding entry point,
and README docs — full origin coverage.

**Deferred for later (origin):**
- A context-grouped Next Actions view (app's `@agenda`/`@calls`/`@computer` grouping).
- Person-scoped `@agenda/<name>` lists — depends on ticket #46.

**Outside this build (origin):**
- A view-language / DSL abstraction — direct definitions only.
- Any change to how focus, keywords, or contexts sync or render.

**Deferred to Follow-Up Work:** none identified.

---

## Open Questions (Deferred to Implementation)

- Exact org match-expression strings for the focus-exclusion in the Next Actions
  block and the `MW_TYPE`/keyword combination — refined when running against a real
  buffer.
- Exact prefix-format string and the sort hook used to float stuck projects to the
  top within the single Projects list.

---

## Dependencies / Assumptions

- `MW_FOCUS_TODAY` already round-trips (ticket #4, closed).
- Project task children are outline descendants of the project heading (consistent
  with the current render), so a subtree scan finds them.
- Target floor Emacs 28.1 / Org 9.5: composite `org-agenda-custom-commands`,
  per-command `org-agenda-files`, property match syntax, prefix-format functions,
  and `org-agenda` invocation are all available there. No Org 9.6+ APIs.
- `make compile` byte-compiles `mindwtr*.el` with `byte-compile-error-on-warn`, so
  `mindwtr-agenda.el` must be warning-clean; `test/*-test.el` is auto-discovered.

---

## Sources & Research

- `mindwtr.el:34` (`mindwtr-file` defcustom), `mindwtr.el:119` (unset-file error
  pattern), `mindwtr.el:14-22` (module require block + autoload convention).
- `mindwtr-model.el:14` (keyword sequence), `:156` (content allow-list incl.
  `:isFocusedToday`).
- `mindwtr-render.el:167` (`MW_FOCUS_TODAY` renders as `:MW_FOCUS_TODAY: t`,
  omitted when false).
- `mindwtr-parse.el` (`MW_TYPE` discriminates project/task/container;
  subtree/ancestry walking).
- `test/mindwtr-commands-test.el` (`mindwtr-commands-test--with-appdata` rendering
  harness to reuse).
- `Makefile` (`test/*-test.el` wildcard discovery; `compile` error-on-warn).
- `org-gtd.el: org-gtd-engage.el` — reference for engage-view
  composition (the DSL approach is deliberately not copied).
- GitHub #8 (ship agenda/engage views), #4 (focus sync, closed), #46
  (`@agenda/<name>`, deferred).
