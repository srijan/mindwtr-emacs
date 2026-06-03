# mindwtr.el

Bidirectional sync between a single org-mode GTD file and a self-hosted
[Mindwtr Cloud](https://mindwtr.com) server.

`mindwtr.el` parses one org file into the Mindwtr AppData model, `PUT`s a
candidate snapshot to `/v1/data`, then `GET`s the server's merged result and
reconciles it back into your buffer. **The server owns conflict resolution**
(revision-aware last-write-wins, server-wins on ties); Emacs only proposes
changes and reports any local edits the server overrode. A local *shadow*
JSON file holds the last-synced full snapshot (including tombstones, settings,
and sync metadata) so changes can be detected without re-fetching.

## Requirements

- Emacs 28.1 or newer.
- [`plz`](https://github.com/alphapapa/plz.el) is used for HTTP when present;
  if it is not installed, `mindwtr.el` falls back to the built-in `url.el`.

## Installation

Put the `.el` files on your load path and require the package:

```elisp
(add-to-list 'load-path "/path/to/mindwtr-emacs")
(require 'mindwtr)
```

## Configuration

```elisp
(setq mindwtr-server-url "https://mw.example")     ; your server base URL
(setq mindwtr-file "~/org/mindwtr.org")            ; the synced org file
```

### Authentication

The bearer token can be set directly:

```elisp
(setq mindwtr-auth-token "YOUR_TOKEN")
```

Or, preferably, left out and stored in an auth-source backend such as
`~/.authinfo.gpg`. The token is read via `auth-source-search` on the **host**
of `mindwtr-server-url`, so add a line like:

```
machine mw.example login apikey password YOUR_TOKEN
```

(The `login` field is not checked; the secret is taken from `password`.)

### Major mode (optional)

The synced file uses a custom TODO keyword sequence and `[#A]`..`[#D]`
priorities. To have it open in `mindwtr-mode` automatically, either add it to
`auto-mode-alist`:

```elisp
(add-to-list 'auto-mode-alist '("/mindwtr\\.org\\'" . mindwtr-mode))
```

or put a file-local line at the top of the file:

```org
# -*- mode: mindwtr -*-
```

Using the mode is recommended for correct priority display, but **sync works
without it**. The rendered file leads with an in-buffer `#+TODO:` line, so org
registers the Mindwtr keywords for this file even when your global
`org-todo-keywords` differs (e.g. a personal GTD config that defines `NEXT` but
not `SOMEDAY`/`REF`). The parser also re-installs the full sequence before
reading the buffer if any keyword is missing.

### Working the file

`mindwtr-mode` binds type-aware status commands that replace the default org
equivalents for Mindwtr headings:

| Key | Command | Behaviour |
|---|---|---|
| `C-c C-t` | `mindwtr-set-status` | Prompt for a status; offers **only** the keywords valid for the entity type at point (task vs project). |
| `S-<right>` | `mindwtr-cycle-status-forward` | Cycle forward through type-valid keywords. |
| `S-<left>` | `mindwtr-cycle-status-backward` | Cycle backward through type-valid keywords. |

Tasks and projects have **disjoint** valid keyword sets:

- **Task statuses**: `INBOX` `NEXT` `WAIT` `SOMEDAY` `REF` `DONE` `ARCH`
- **Project statuses**: `ACTIVE` `WAIT` `SOMEDAY` `ARCH`

This means you can never accidentally apply a task-only keyword (`INBOX`, `NEXT`,
`REF`, `DONE`) to a project, or a project-only keyword (`ACTIVE`) to a task.

**Immediate relocation.** After a status change, a standalone task or a project
is moved to the bucket matching its new status right away — no need to wait for
the next sync. A task inside a project, a section heading, and an archived entity
are left in place (they have no independent bucket to relocate to).

**Re-parenting.** Moving a task into or out of a project is done with standard
`C-c C-w` (`org-refile`). Containment is encoded by outline nesting, so nesting a
task under a project heading makes it a project task; lifting it out makes it
standalone.

**Graceful degradation.** Content that reaches the file through a raw text edit,
org-capture, or editing outside `mindwtr-mode` is never silently lost:

- **A type-invalid keyword** (e.g. `NEXT` on a project) does not abort the sync.
  The parser retains the entity's previous status, or assigns a type-appropriate
  default for a brand-new entity (task → `inbox`, project → `active`), and emits
  a warning.
- **A heading missing its `:MW_TYPE:`** (the common org-capture / raw-edit case)
  has its type **inferred from outline context** — under `* Inbox`, `* Single
  Actions`, `* Someday`'s single-action list, or `* Reference` it becomes a
  **task**; directly under `* Projects` a **project**; under a project or section
  a **task**; under `* Areas of Focus` an **area** — so it round-trips like any
  typed entity (and the sync mints its `MW_ID`).
- **A heading that fits nowhere** (no recognized container ancestor, so its type
  cannot be inferred) is **not deleted**. It is preserved verbatim under a
  `* Sync Failures` heading after each sync, annotated with what to fix — add a
  `:MW_TYPE:` or move it under a list container, then sync again. A pre-sync
  backup of the whole file is also written to `backups/` under the data
  directory on every sync as a final safety net.

**Fallback.** Off a Mindwtr task or project heading these keys fall back to
standard org behaviour (`org-todo`, `org-shiftright` / `org-shiftleft`).

## Usage

1. **`M-x mindwtr-bootstrap`** (run once) — fetch the current server snapshot
   and render it into `mindwtr-file`. This **overwrites** the file (you are
   prompted to confirm if it already exists).
2. **`M-x mindwtr-sync`** — run one sync cycle: push your local changes, pull
   the merged result, reconcile the buffer, and update the shadow.
3. **`M-x mindwtr-auto-sync-mode`** — a global minor mode that syncs
   automatically via three triggers:
   - **On save** — debounced; fires after `mindwtr-sync-idle-debounce` seconds
     (default 5) of idle following a save of `mindwtr-file`.
   - **Periodically** — every `mindwtr-sync-interval` seconds (default 600;
     set to `nil` to disable), gated on a cheap `HEAD` ETag check so it only
     does work when the remote actually changed.
   - **On frame focus** — when Emacs regains focus (throttled to 30s).

### Capture

`mindwtr-capture-template` is an `org-capture` template function that drops a new
task into the `* Inbox` bucket, stamped with `:MW_TYPE: task` and a freshly
minted `:MW_ID:`. Register it once:

```elisp
(add-to-list 'org-capture-templates
  `("m" "Mindwtr inbox" entry
    (file+headline mindwtr-file "Inbox")
    (function mindwtr-capture-template)))
```

`C-c c m` then captures straight into the inbox. The stamping is belt-and-
suspenders: even a hand-written inbox heading is recognized as a task by context
inference and gets an `MW_ID` on the next sync (see **Graceful degradation**), so
the template is ergonomics, not a correctness requirement.

### Customization summary

| Variable | Default | Meaning |
|---|---|---|
| `mindwtr-server-url` | `nil` | Base URL of the Mindwtr Cloud server. |
| `mindwtr-auth-token` | `nil` | Bearer token; if `nil`, looked up via auth-source. |
| `mindwtr-file` | `nil` | Path to the synced org file. |
| `mindwtr-sync-idle-debounce` | `5` | Idle seconds after save before auto-sync. |
| `mindwtr-sync-interval` | `600` | Seconds between periodic syncs (`nil` disables). |

## Org schema

### v3 file layout

The rendered file is structured into six top-level buckets (in order), one of
which — `* Someday` — is a container holding two nested sub-buckets:

| Heading | Contents |
|---|---|
| `* Inbox` | Standalone tasks with status `inbox` |
| `* Single Actions` | Standalone tasks with status `next`, `waiting`, or `done` |
| `* Projects` | Active and waiting projects, each with their sections and tasks nested beneath; projects are further grouped by area |
| `* Someday` | Container — holds `** Single Actions` (someday standalone tasks) and `** Projects` (someday projects) |
| `* Reference` | Standalone tasks with status `reference` |
| `* Areas of Focus` | Your areas, for reference |

Tasks and projects have **disjoint** valid statuses. Task statuses are `inbox`,
`next`, `waiting`, `someday`, `reference`, `done`, and `archived`. Project
statuses are `active`, `waiting`, `someday`, and `archived`. Archived entities
are not rendered into the file — see "Archived projects preserve their tasks"
below.

### Entity schema

Each synced heading carries a `:PROPERTIES:` drawer with at least:

- `MW_TYPE` — one of `area`, `project`, `section`, `task`.
- `MW_ID` — the entity's stable id (assigned automatically for new headings).

**Nesting encodes containment**: an area contains projects, a project contains
sections, and sections/projects/areas contain tasks. Parent ids are derived
from the surrounding outline structure, so just nest headings normally.

```org
* My Area
  :PROPERTIES:
  :MW_TYPE: area
  :MW_ID: a-1
  :END:
** ACTIVE My Project
   :PROPERTIES:
   :MW_TYPE: project
   :MW_ID: p-1
   :END:
*** NEXT [#A] Buy supplies                          :@errand:shopping:
    SCHEDULED: <2026-06-02 Tue> DEADLINE: <2026-06-05 Fri>
    :PROPERTIES:
    :MW_TYPE: task
    :MW_ID: t-1
    :END:
    Pick up paint and brushes.
    - [ ] paint
    - [X] brushes
```

Field mapping:

| Org element | Mindwtr field |
|---|---|
| Heading text | task/project/section `title`; area `name` |
| TODO keyword (tasks/projects) | `status` |
| Priority cookie `[#A]`..`[#D]` (tasks) | `priority` = urgent / high / medium / low |
| Tags starting with `@` | `contexts` |
| Other tags | hashtags (`#tag`) |
| Body prose (minus planning/drawers/checklist) | `description` |
| Org links `[[url][label]]` / `[[url]]` in the body | markdown links `[label](url)` / `[url](url)` in `description` (converted both ways) |
| `- [ ]` / `- [X]` lines | `checklist` items |
| `SCHEDULED:` | `startTime` |
| `DEADLINE:` | `dueDate` |
| `CLOSED:` | `completedAt` |

**TODO keywords**: `INBOX` `NEXT` `WAIT` `SOMEDAY` `REF` `ACTIVE` (active
states) and `DONE` `ARCH` (done states). Not all keywords are valid for every
entity type — see "Working the file" above for the per-type breakdown.

Additional task properties with no native org form are stored in the drawer.
The drawer fields synced **read-write** from org in v1 are exactly:
`MW_ENERGY`, `MW_TIME_ESTIMATE`, `MW_ASSIGNED_TO`, `MW_LOCATION`, and
`MW_TASK_MODE` — edits to these in org are parsed back and pushed to the server.

`MW_RECURRENCE`, `MW_FOCUS_TODAY`, `MW_REVIEW_AT`, `MW_SEQUENTIAL`,
`MW_FOCUSED`, and `MW_ATTACH` (link attachments) are **displayed from server
data but are effectively read-only in v1** — they are rendered into the drawer
for your reference, but editing them in org does **not** push back to the
server. Full read-write for these (along with recurrence-object fidelity and
file-byte attachment transfer) is deferred to Phase 2.

`MW_CREATED` and `MW_UPDATED` are **read-only display mirrors** — they are
written into the drawer for your reference but are authoritative in the shadow
and never parsed back as edits. Any **other** drawer or property (`LOGBOOK`,
`CLOCK`, custom properties you add) is **preserved verbatim but never synced**.

## Conflict report

After every sync a `*Mindwtr Sync Report*` buffer shows created/updated/deleted
counts. When a local edit is overridden by a newer remote edit (server-wins,
revision-aware last-write-wins), the lost edits are listed there with your
value and the server's value side by side — so no local change is ever silently
discarded.

## Status and scope

**v1** syncs tasks, projects, sections, and areas read-write for their core
org-native fields plus the drawer fields `MW_ENERGY`, `MW_TIME_ESTIMATE`,
`MW_ASSIGNED_TO`, `MW_LOCATION`, and `MW_TASK_MODE`. The reserved drawer keys
`MW_RECURRENCE`, `MW_FOCUS_TODAY`, `MW_REVIEW_AT`, `MW_SEQUENTIAL`,
`MW_FOCUSED`, and `MW_ATTACH` (link attachments) are rendered from server data
but are **read-only in v1** — editing them in org does not push to the server.
Server `settings` are carried through verbatim (opaque pass-through; never
edited).

**Deferred to Phase 2:**

- Full read-write for `MW_RECURRENCE`, `MW_FOCUS_TODAY`, `MW_REVIEW_AT`,
  `MW_SEQUENTIAL`, `MW_FOCUSED`, and `MW_ATTACH` (parsing org edits back to the
  server).
- File-byte attachment transfer (upload/download of attachment contents).
- A one-time importer from an existing `org-gtd` file into the schema.
- Recurrence-object fidelity beyond serialized round-trip.
- **`org-protocol` capture** — a browser-triggered front door on top of the
  shipped `org-capture` template (see [Capture](#capture)). (Emacs-native
  editing track.)
- **Clarify workflow** — a guided triage flow over `* Inbox` items to replace
  org-gtd's clarify/organize wizard: set type-valid status (`mindwtr-set-status`),
  add contexts/area, optionally refile under a project (`org-refile`), and move
  to the next inbox item. Built on the existing type-aware commands rather than a
  new state machine. (Emacs-native editing track.)
- **org-edna local automation (spike)** — evaluate using `org-edna` inside
  `mindwtr-mode` for desk-only task automation. Mechanically it composes (edna
  fires on `org-todo`, which `mindwtr-set-status` calls). Constraints to design
  around: edna's `TRIGGER`/`BLOCKER` properties are non-`MW_` drawer keys, so
  they are **preserved but never synced** — any cascade is Emacs-only and must
  produce a *synced end-state* to stay coherent across surfaces. Skip cascades
  that duplicate server semantics (project completion → tasks Done is already
  handled by server-side archive; projects have no `DONE`, only `ARCH`). The
  promising case is sequential next-action triggering as a local stand-in for
  `MW_SEQUENTIAL` until that field is read-write. Deliverable: a documented list
  of safe vs. unsafe edna patterns, not a blanket enablement.
- **Incremental reconciliation (preserve buffer state)** — today
  `mindwtr-reconcile-buffer` rebuilds the whole file (`erase-buffer` + `insert`)
  on every sync and only restores point to the current entity's heading. That
  discards fold/visibility state, scroll position (`window-start`), and the exact
  cursor column — a sync mid-edit visibly resets the buffer. Goal: rewrite only
  the entities that actually changed, leaving untouched headings byte-identical
  so their folds and overlays survive. The building blocks already exist:
  `mindwtr-reconcile--id-markers` (locate an entity), `--rebuild-entry` (in-place
  per-entity rewrite, used by the restore action), `--collect-org-only`
  (preserve unknown drawers), and `mindwtr-signature` (change detection). The
  reconcile loop would diff each merged entity's signature against the buffer's
  parsed copy and only `--rebuild-entry` the changed ones, then handle structural
  deltas (new entities, deletions, and **bucket relocation on status change** —
  the tricky case, since a moved subtree must keep its fold state across the
  move). Note org folds are overlays/invisibility, not text, so even an in-place
  entry rewrite needs an explicit save/restore of visibility around it. Cheaper
  stopgap if full incremental is deferred: snapshot folded headings (keyed by
  `MW_ID` for entities / `MW_LIST` for containers) + `window-start` before the
  existing full rebuild and reapply them precisely per heading after — less
  correct on moves, but restores the user-visible state.
- **Configurable bucket→file routing** — today `mindwtr-render-appdata` emits all
  six buckets into one string written to the single `mindwtr-file`. Let the user
  route buckets to separate files (e.g. `Inbox` → `inbox.org`, `Reference` →
  `reference.org`, the rest in a main file) or keep everything in one file. The
  server model is a single AppData, so this is purely a *local presentation*
  split — the **bucket is the routing unit**; a project subtree stays whole in
  whichever file holds the `Projects` bucket, since containment is encoded by
  outline nesting and cannot span files. Design notes:
  - **Config shape**: an alist mapping bucket/role → file path, plus a default
    file for unmapped buckets. The default config routes everything to
    `mindwtr-file`, so current single-file behavior is preserved.
  - **Render** emits per-file strings instead of one concatenation.
  - **Parse** reads all configured files and merges into one AppData (merge by
    globally-unique `MW_ID`; each file contributes its buckets).
  - **Reconcile** runs per-file — this compounds with the incremental
    reconciliation item above (whole-buffer rebuild × N files is worse).
  - **Shadow / change detection** must span the set of files, not one buffer.
  - **`auto-mode-alist` / `mindwtr-mode` / auto-sync save trigger** must cover
    every routed file, not just `mindwtr-file`.
- **Surface mobile-captured inbox items after sync** — the sync report shows a
  *created* count but does not take the user to the new entities. Closes the core
  loop (capture/triage on mobile, work on the desk): a post-sync command or
  automatic jump/highlight of newly-arrived `INBOX` tasks so mobile captures are
  felt on the desk side without hunting. (Sync & conflict reconciliation track.)
- **Verify (and fix) the pre-sync buffer backup** — the restore path and report
  reference a "pre-sync buffer backup" (`mindwtr-report--backup-file`,
  mindwtr-report.el:17) and the shadow keeps `shadow.bak.json`
  (mindwtr-shadow.el:31), but it is unconfirmed that the *buffer* file is actually
  snapshotted before reconcile. If the report points users to a backup that is
  never created, the promised safety net is missing. Verify; write the buffer
  backup before each reconcile if absent. (Sync & conflict reconciliation track.)
- **Show incoming remote changes, not just overrides** — the sync report lists
  conflicts (edits the server overrode) but not the benign remote edits the merge
  brings *in*. Add a "remote changes since last sync" summary so the user sees
  what mobile changed without diffing manually. (Sync & conflict reconciliation
  track.)
- **Ship the agenda / engage views in the package** — any agenda view (engage =
  today + `NEXT` + `WAIT` + `INBOX`) is currently hand-rolled in user config.
  Since mindwtr owns its keyword set, ship a tested `org-agenda-custom-commands`
  block / a `mindwtr-engage` command so users don't reconstruct it. (Emacs-native
  editing track.)
- **Refile-target wiring** — the clarify flow and re-parenting both lean on
  `org-refile`, but nothing sets `org-refile-targets` to mindwtr projects, so
  `C-c C-w` won't offer the right destinations out of the box. Small; a
  prerequisite that makes the clarify workflow land cleanly. (Emacs-native editing
  track.)
- **`mindwtr-lint` / pre-sync validation command** — an on-demand command that
  flags type-invalid keywords, orphaned tasks, and malformed drawers *before*
  sync, turning the existing graceful-degradation warnings into something the user
  can run deliberately. Supports the dropped-entities metric. (Emacs-native
  editing / fidelity tracks.)
- **Property-based round-trip fuzzing** — round-trip fidelity is the headline
  invariant but is tested on hand-written fixtures. Add a generator that produces
  random valid AppData (varied statuses, nesting, unicode titles, checklist/drawer
  combinations) and asserts parse→render→parse stability, hardening the guarantee
  against unconsidered cases. Highest-leverage test investment, since the
  invariant *is* the product. (Fidelity engine track.)
- **Aggregate counter for dropped / invalid entities** — STRATEGY notes there is
  "no aggregate counter yet" for invalid-keyword warnings and sync failures; they
  are watched one run at a time. Add a small persisted tally (per sync, appended
  to a log) so the metric is trackable over time instead of glance-and-forget.
  (Fidelity engine track.)

## Behavior notes

### Archived projects preserve their tasks

When a project is archived, Mindwtr moves the project's incomplete tasks to
Done and keeps them inside the (now hidden) project. mindwtr-emacs hides an
archived project's entire subtree from the org file — the project, its
sections, and its tasks are not rendered — and **preserves those entities on
the server**: they are echoed back verbatim on each sync (never tombstoned)
rather than having their status rewritten. An entity whose absence from org is
expected — because it is archived, its parent container does not render, or
(for a standalone task) its status maps to no list — is therefore never
mistaken for a user deletion. This is decided by
`mindwtr-sync--rendered-absent-p`.

**TODO / to verify manually:** the end-to-end behavior of archiving a project
that has live/done child tasks against a real server has not yet been
exercised. Confirm that the children are preserved (not deleted) across a sync,
and that they reappear correctly if the project is un-archived. The path is
guarded by `mindwtr-sync--rendered-absent-p` and covered by unit tests, but has
not been run against the live server.
