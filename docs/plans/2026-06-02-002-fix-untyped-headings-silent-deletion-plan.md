---
title: "fix: stop silent deletion of untyped headings on sync (capture-safe ingest)"
type: fix
status: completed
date: 2026-06-02
issue: https://github.com/srijan/mindwtr-emacs/issues/2
depth: standard
---

# fix: stop silent deletion of untyped headings on sync (capture-safe ingest)

## Summary

A heading added without a `:MW_TYPE:` property — via `org-capture`, a raw edit, or a mobile
capture — is **silently deleted on the next sync**, with no error, warning, or sync-report
entry. The parser only collects headings that carry `MW_TYPE` (`mindwtr-parse.el:245`), so an
untyped heading never enters the parsed appdata; it is never pushed to the server; and
`mindwtr-reconcile-buffer`, which rebuilds the whole buffer from the merged server data
(`mindwtr-reconcile.el:3`), then erases it because it has no `MW_ID` anchor and no server
record. Confirmed from backups: `** INBOX Test new issue from emacs` present at
`mindwtr-20260602T203317.org`, gone at `…203347.org` (the next sync).

This plan closes the data-loss hole in two layers, **fallback first**:

1. **Layer 1 (correctness):** infer `MW_TYPE` from outline context so a captured/hand-typed
   heading becomes a first-class entity and round-trips; and a pre-reconcile **quarantine
   guard** that re-emits anything still un-inferable under a dedicated `* Sync Failures`
   container instead of deleting it.
2. **Layer 2 (convenience):** a mindwtr `org-capture` template that drops into Inbox and mints
   `MW_ID`, with the existing lazy minting (`mindwtr-sync.el:134`) staying as the universal
   fallback.

This serves the **Emacs-native editing** track in `STRATEGY.md`: the desk surface can only be
"a joy to edit" if content the user adds survives the sync that follows.

---

## Problem Frame

`mindwtr-sync-once` (`mindwtr-sync.el:273`) parses the buffer, builds a candidate from the
*parsed* entities only, PUTs, GETs the merged result, and calls `mindwtr-reconcile-buffer` —
which does `erase-buffer` + full re-render from the merged AppData. The parser is therefore
the sole gate deciding what survives a sync, and its gate is "has `MW_TYPE`"
(`mindwtr-parse.el:245-246`):

```elisp
(let ((kind (mindwtr-parse--prop "MW_TYPE")))
  (when (and kind (not (string= kind "container")))
```

Anything else is dropped from the parse, excluded from the candidate, and then erased by
reconcile. No warning fires because `mindwtr-parse--warnings` only records headings that *are*
parsed but carry a type-invalid keyword (`mindwtr-parse.el:179`).

The canonical layout the renderer produces (`mindwtr-render-appdata`, `mindwtr-render.el:299`)
is a fixed set of top-level `container` headings, each tagged `:MW_TYPE: container` with an
`:MW_LIST:` role:

| Container heading | `MW_LIST` role | Children |
|---|---|---|
| Inbox | `inbox` | standalone tasks (status `inbox`) |
| Single Actions | `single-actions` | standalone tasks (`next`/`waiting`/`done`) |
| Projects | `projects` | projects → sections → tasks |
| Someday | `someday` | the two sub-containers below |
| ↳ Someday Single Actions | `someday-single-actions` | standalone tasks |
| ↳ Someday Projects | `someday-projects` | projects → sections → tasks |
| Reference | `reference` | standalone tasks |
| Areas of Focus | `areas` | areas |

This fixed structure is exactly what makes context-based type inference tractable.

---

## Requirements

- **R1.** A heading without `:MW_TYPE:` is assigned a type inferred from its outline context
  (table in U1) and parsed as that kind, so it round-trips through the server like any typed
  entity. Status defaults follow the existing `mindwtr-sync--ensure-status` (task → `inbox`,
  project → `active`).
- **R2.** A heading that inference **cannot** place (no recognized container ancestor) is
  **never deleted**. Its full subtree (heading + body + drawers) is preserved verbatim under a
  dedicated top-level `* Sync Failures` container after reconcile, annotated with the reason.
- **R3.** The `* Sync Failures` container is **idempotent across syncs**: an existing one is
  unwrapped (its children returned to the orphan pool) and a single fresh container is
  regenerated, so it never nests or accumulates duplicate wrappers.
- **R4.** Quarantine and inference must **not** corrupt or drop legitimately-typed entities:
  a normal sync with only typed headings produces byte-identical output to today (no spurious
  `* Sync Failures` heading when there are no orphans).
- **R5.** `MW_ID` remains the sync identity. Inference/quarantine never adopt org-native
  `:ID:` as identity. A stray `:ID:` on an adopted heading is preserved as an unknown property
  (existing `mw-extra-props` path) — it does not become the entity id.
- **R6.** A mindwtr `org-capture` template creates an Inbox task heading stamped with
  `:MW_TYPE: task` and a freshly-minted lowercase v4 `:MW_ID:`. The existing lazy minting at
  `mindwtr-sync.el:134` stays as the fallback for headings that bypass the template.
- **R7.** The quarantine collection runs **before** reconcile's `erase-buffer`, so no path can
  erase an orphan before it is stashed. The existing timestamped backup
  (`write-region`, `mindwtr-sync.el:329`) remains the ultimate recovery net.

---

## Key Technical Decisions

- **Inference lives in the parser, keyed on the nearest container's `MW_LIST` plus
  project/section ancestry.** The helpers already exist: `mindwtr-parse--ancestor-id`
  (nearest ancestor of a given `MW_TYPE`) and the container-role walk in
  `mindwtr-commands--parent-list-role`. Inference reuses that idiom rather than introducing a
  new traversal.
- **Sections stay explicit.** Under a project, a hand-added heading is inferred as a **task**,
  not a section — hand-creating a section is rare and a section needs an explicit
  `:MW_TYPE: section`. Documented as an accepted limitation.
- **Quarantine is a buffer-level concern in reconcile/sync, not in `mindwtr-render-appdata`.**
  `mindwtr-render-appdata` stays a pure AppData → org function. The orphan collection (pre-erase)
  and the `* Sync Failures` re-emission (post-render) live in the reconcile layer, where
  buffer text — not AppData — is the unit of work.
- **`* Sync Failures` is rendered as a recognized `container`** (`:MW_TYPE: container`,
  `:MW_LIST: sync-failures`). Consequences: the parser skips it like any container
  (`mindwtr-parse.el:246`); its `sync-failures` role is **deliberately absent** from the
  inference table, so its children stay un-inferable and are re-collected each sync (R3); and
  the collector special-cases this role to unwrap rather than re-quarantine the wrapper.
- **Keep `MW_ID`; do not adopt org-native `:ID:`.** mindwtr mints lowercase RFC-4122 v4 UUIDs
  (`mindwtr-util.el:17`); the capture template's `:ID:` was uppercase. Adopting org-id as
  identity would introduce cross-client case-sensitivity bugs and force reconcile to entangle
  with org-id's global machinery (`org-id-locations`, link DB, agenda) to keep `:ID:` stable.
  `MW_ID` is re-emitted on every render, so it is stable by construction.
- **The client mints the id (offline-first).** The only minting site is
  `mindwtr-sync.el:134`; the server accepts client UUIDs. Lazy minting stays as the universal
  fallback; the capture template makes the happy path eager.

---

## Implementation Units

### U1. Context-based `MW_TYPE` inference

**Goal:** A heading without `:MW_TYPE:` is parsed as the type its outline position implies, so
captured/hand-typed headings round-trip instead of being dropped. Delivers the high-value half
of the fix on its own (it rescues every heading that *has* a sane home).

**Requirements:** R1, R5.

**Dependencies:** none.

**Files:**
- `mindwtr-parse.el` — add `mindwtr-parse--infer-kind` (context → kind symbol or nil); change
  the `mindwtr-parse-buffer` gate (`:245`) to fall back to inference when `MW_TYPE` is absent;
  let `mindwtr-parse-heading` accept an inferred kind instead of erroring at `:156-158`.
- `test/mindwtr-parse-test.el` — tests.

**Approach:**
- `mindwtr-parse--infer-kind` (called with point on a heading that has no `MW_TYPE`):
  - Resolve the nearest container ancestor's `MW_LIST` (reuse the `mindwtr-commands--parent-list-role`
    walk: climb headings, first whose `MW_TYPE` is `container` wins).
  - Resolve `(mindwtr-parse--ancestor-id 'section)` and `(mindwtr-parse--ancestor-id 'project)`.
  - Map per the table below; return nil when no container ancestor is found.

  | Nearest container `MW_LIST` | Ancestry | Inferred kind |
  |---|---|---|
  | `inbox`, `single-actions`, `someday-single-actions`, `reference` | — | `task` |
  | `projects`, `someday-projects` | has section or project ancestor | `task` |
  | `projects`, `someday-projects` | direct child of the container (no project/section ancestor) | `project` |
  | `areas` | — | `area` |
  | `someday` (bare parent), `sync-failures`, or none | — | `nil` (un-inferable) |

- `mindwtr-parse-buffer` gate: when `MW_TYPE` is nil, call `mindwtr-parse--infer-kind`; if it
  returns a kind, parse the heading as that kind; if nil, leave it unparsed (U2 quarantines it).
- `mindwtr-parse-heading`: take the resolved kind as an argument (or read a dynamically-bound
  inferred kind) rather than hard-`error`-ing when `MW_TYPE` is absent. Identity/`:id` still
  comes from `MW_ID` only (R5); a present `:ID:` flows into `mw-extra-props` via the existing
  `mindwtr-parse--extra-props` (it is not in `mindwtr-parse--known-props`).
- Containment plumbing already handled downstream: `mindwtr-parse-buffer` sets `:sectionId` /
  `:projectId` from ancestry (`:252-259`); an inferred task/section inherits the same.

**Patterns to follow:**
- `mindwtr-commands--parent-list-role` (`mindwtr-commands.el:67`) for the container-role walk.
- `mindwtr-parse--ancestor-id` (`mindwtr-parse.el:228`) for project/section ancestry.

**Execution note:** Start with a failing test: a heading `** INBOX Buy milk` (no `MW_TYPE`)
directly under the Inbox container parses to a task with `:status "inbox"`.

**Test scenarios** (ERT + `with-temp-buffer`/`org-mode`, matching existing parse tests):
- R1. Untyped `INBOX` heading under Inbox → task, status `inbox`.
- R1. Untyped heading directly under the Projects container → project.
- R1. Untyped heading under a typed project → task with that project's `:projectId`.
- R1. Untyped heading under a section → task with the section's `:sectionId`.
- R1. Untyped heading under Areas of Focus → area.
- R5. Untyped heading carrying an org `:ID:` → adopted with `:id` nil (so the sync mints
  `MW_ID`), and the `:ID:` preserved in `mw-extra-props`.
- Negative. Untyped heading at top level / under `* Sync Failures` → `infer-kind` returns nil
  (heading left unparsed). Asserts the boundary U2 depends on.
- Regression. A buffer of only typed headings parses identically to before (inference is a
  pure fallback, never overriding an explicit `MW_TYPE`).

**Verification:** `make test` green; manually capturing a task into Inbox then syncing pushes
it to the server (appears in the sync report's `created` count) and it survives reconcile.

---

### U2. Pre-reconcile quarantine guard (`* Sync Failures`)

**Goal:** Anything inference still can't place is preserved verbatim under a dedicated
`* Sync Failures` container instead of being erased. Closes the residual hole U1 leaves.

**Requirements:** R2, R3, R4, R7.

**Dependencies:** U1 (orphans are "headings that survive the inference fallback unparsed").

**Files:**
- `mindwtr-reconcile.el` — add `mindwtr-reconcile--collect-orphans` (pre-erase) and
  `mindwtr-reconcile--emit-quarantine` (post-render); wire both into `mindwtr-reconcile-buffer`
  straddling the `erase-buffer`/render.
- `mindwtr-model.el` (or wherever `mindwtr-model-list-title` lives) — register the
  `sync-failures` role's display title so `mindwtr-render--container` can name it; **or** emit
  the container directly in reconcile without going through the model map (decide during
  implementation — prefer the model map for consistency).
- `test/mindwtr-reconcile-test.el` — tests.

**Approach:**
- **Collect (before `erase-buffer`):** walk top-level/`org-map-entries`, identify "orphan"
  subtrees = headings that (a) have no `MW_TYPE` and `mindwtr-parse--infer-kind` returns nil,
  **or** (b) are the children of an existing `:MW_LIST: sync-failures` container. For each,
  capture the raw subtree text (`org-back-to-heading` → `org-end-of-subtree`,
  `buffer-substring-no-properties`). Unwrap an existing `* Sync Failures` container: take its
  children as orphans, discard the wrapper (R3). Return the list of raw subtree strings.
- **Emit (after the canonical render, before view-state restore):** if the orphan list is
  non-empty, append one `* Sync Failures` container
  (`:MW_TYPE: container`, `:MW_LIST: sync-failures`) followed by each orphan subtree verbatim,
  each prefixed with a one-line annotation noting why it was parked (e.g. a `# mindwtr: couldn't
  determine type — no container context` comment line, or a `:MW_NOTE:` drawer property — pick
  the form that survives a re-parse cleanly). When the list is empty, emit nothing (R4).
- **Demote orphan heading levels** if needed so they sit at level 2 under the level-1
  container (a captured heading may have been `**` already; normalize so the subtree nests
  correctly). Preserve relative sub-levels within each orphan subtree.
- **Wire into `mindwtr-reconcile-buffer`:** bind `(orphans (mindwtr-reconcile--collect-orphans))`
  in the same let-group as the existing pre-erase snapshots (alongside `at-id` and the U1/U2
  view snapshot from the buffer-view plan), then call `(mindwtr-reconcile--emit-quarantine
  orphans)` after the render insert and before `--restore-view`.

**Patterns to follow:**
- `mindwtr-reconcile--collect-org-only` / `--id-markers` (`mindwtr-reconcile.el:17`) for the
  pre-erase `org-map-entries` + subtree-bounds idiom.
- `mindwtr-render--container` (`mindwtr-render.el:180`) for the container heading format.

**Execution note:** Start with a failing test: reconcile a buffer containing one untyped
top-level heading (no container context) and assert the heading text still appears, now under
a `* Sync Failures` container, after reconcile.

**Test scenarios:**
- R2. A top-level untyped heading with a body survives reconcile under `* Sync Failures`, body
  intact.
- R2. The annotation/reason line is present on the quarantined heading.
- R3. Two consecutive reconciles with the same persistent orphan produce **one** `* Sync
  Failures` container with **one** copy of the orphan — no nesting, no duplication.
- R3. An orphan that becomes inferable on the second pass (user moved it under Inbox or added
  `MW_TYPE`) leaves `* Sync Failures` and is no longer quarantined; an empty container is not
  left behind.
- R4. A buffer with only typed entities reconciles with **no** `* Sync Failures` heading and
  output identical to pre-change behavior.
- R7. The orphan is captured before erase: a reconcile whose render throws mid-way (simulate)
  still has the orphan available (guards the ordering invariant).

**Verification:** `make test` green; manually add a stray `* random note` at top level, sync,
confirm it lands under `* Sync Failures` rather than vanishing, and that a second sync doesn't
duplicate it.

---

### U3. `org-capture` template + capture command

**Goal:** A first-class capture path that stamps `:MW_TYPE: task` and a minted `:MW_ID:`,
dropping into Inbox — so the happy path doesn't rely on inference, while inference + quarantine
remain the defense for headings that bypass the template.

**Requirements:** R6.

**Dependencies:** U1, U2 (so the template is a convenience over a correct fallback, not the
sole correctness mechanism).

**Files:**
- `mindwtr.el` (or a new `mindwtr-capture.el` — decide during implementation based on where
  user-facing commands live) — a capture template definition and/or an
  `org-capture`-compatible template function that finds the Inbox container and inserts a task
  heading stamped with `:MW_TYPE: task` and `(mindwtr-util-uuid)` as `:MW_ID:`.
- `README.md` — replace the "Capture workflow" future-work bullet (`README.md:260`) with the
  shipped command, and correct the graceful-degradation paragraph (`README.md:106-111`) to
  describe inference + quarantine.
- `test/` — a test asserting the template output parses back to a task with the minted id.

**Approach:**
- Provide a template target that locates the Inbox container (`:MW_LIST: inbox`) — reuse
  `mindwtr-commands--container-marker` (`mindwtr-commands.el:77`) — and inserts:
  ```org
  ** TODO %?
  :PROPERTIES:
  :MW_TYPE: task
  :MW_ID: <minted lowercase v4 uuid>
  :END:
  ```
  (Keyword `INBOX`/`TODO` per the mindwtr task keyword set — use
  `mindwtr-model-status->keyword` for `inbox` rather than hard-coding.)
- Document wiring `org-capture-templates` (and optionally `org-protocol`) in the README.
- Lazy minting at `mindwtr-sync.el:134` is untouched (fallback for non-template captures).

**Patterns to follow:**
- `mindwtr-commands--container-marker` for locating a container by role.
- `mindwtr-model-status->keyword` for the keyword string.

**Test scenarios:**
- R6. The template body, inserted into a buffer and parsed, yields a task with `:status
  "inbox"` and the exact minted `:id`.
- R6. The minted id is a lowercase RFC-4122 v4 UUID (format assertion).

**Verification:** `make test` green; `M-x org-capture` with the mindwtr template creates an
Inbox task; the next sync reports it as `created` and it survives reconcile.

---

## Scope Boundaries

**In scope:** inference for the four contexts in U1; quarantine for everything else; a capture
template; README correction.

**Known limitations (accepted):**
- A hand-added heading under a project is inferred as a **task**, never a **section**; sections
  require explicit `:MW_TYPE: section`.
- Inference uses only outline context, not heading content; an untyped heading deliberately
  meant as a plain org note inside a container will be adopted as a task. Mitigated by the
  `* Sync Failures` path being available for anything placed outside containers.
- The quarantine annotation is informational; mindwtr does not attempt to auto-repair the
  orphan — the user fixes it (adds `MW_TYPE` or moves it) and re-syncs.

**Deferred / not in scope:**
- `org-protocol` browser capture (mention in README as a follow-on; not built here).
- Inferring section vs task by sibling shape.

---

## Risks & Dependencies

- **Inference adopting a heading the user meant as plain prose.** A note typed as a heading
  inside Inbox becomes a task. Mitigated by: inference only fires when `MW_TYPE` is absent
  *and* there is a recognized container context; anything outside containers goes to
  `* Sync Failures` rather than being silently typed. Accepted as the lesser evil vs. deletion.
- **Quarantine container growth / nesting.** The central correctness risk for U2 — mitigated by
  R3's unwrap-and-regenerate and its dedicated idempotency tests. A bug here degrades to
  duplicated (not lost) content, and the timestamped backup still holds the original.
- **Ordering: orphan collection must precede `erase-buffer`.** R7. Enforced by binding the
  orphan list in the pre-erase let-group, with a test asserting capture-before-erase.
- **Interaction with the buffer-view-state restore (`docs/plans/2026-06-02-001-…`).** Both add
  pre-erase snapshots and post-render steps to `mindwtr-reconcile-buffer`. Sequence
  post-render: render → emit quarantine → restore view state, so quarantined headings exist
  before fold/scroll restore runs over them. Verify the two snapshot passes compose without
  one shadowing the other.
- **`make test` is the gate.** Each unit lands test-first; run the full suite after each.
