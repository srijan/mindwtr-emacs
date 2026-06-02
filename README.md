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

### Customization summary

| Variable | Default | Meaning |
|---|---|---|
| `mindwtr-server-url` | `nil` | Base URL of the Mindwtr Cloud server. |
| `mindwtr-auth-token` | `nil` | Bearer token; if `nil`, looked up via auth-source. |
| `mindwtr-file` | `nil` | Path to the synced org file. |
| `mindwtr-sync-idle-debounce` | `5` | Idle seconds after save before auto-sync. |
| `mindwtr-sync-interval` | `600` | Seconds between periodic syncs (`nil` disables). |

## Org schema

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
| `- [ ]` / `- [X]` lines | `checklist` items |
| `SCHEDULED:` | `startTime` |
| `DEADLINE:` | `dueDate` |
| `CLOSED:` | `completedAt` |

**TODO keywords**: `INBOX` `NEXT` `WAIT` `SOMEDAY` `REF` `ACTIVE` (active
states) and `DONE` `ARCH` (done states).

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
- A retry/backoff loop for transient `429`/`5xx` server errors.

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
