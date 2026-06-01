# Mindwtr ⇄ Org-mode Sync — Design

**Date:** 2026-06-01
**Status:** Approved design, pre-implementation
**Repo:** `mindwtr-emacs` (greenfield)

## Goal

An Emacs package that keeps a GTD system maintained in a single org-mode file in
**bidirectional, lossless** sync with a self-hosted **Mindwtr Cloud** server.

**Fidelity rule (revised after review):** every Mindwtr field round-trips losslessly,
but the representation is split across two stores — the **org file** holds the
human-editable content, and a local **shadow JSON** holds sync metadata and opaque
app-display fields keyed by `id`. *(org content + shadow)* is the exact projection of
`AppData`. The org file alone is a clean projection of the editable content; it **may
additionally carry org-only content** (extra `:PROPERTIES:`, `LOGBOOK`, `CLOCK`
entries) that is preserved across syncs but **not** sent to Mindwtr.

**Display-mirror fields:** `createdAt` and `updatedAt` are *also* rendered into the
org drawer (as org inactive timestamps) so they're usable in agenda/column views and
sorting — but they are **read-only mirrors**: authoritative in the shadow, excluded
from the content signature, and rewritten from the merged result on every reconcile.
Editing them in org has no effect and never triggers a sync.

## Background: the Mindwtr sync contract

Established from the Mindwtr wiki (Cloud-API, Core-API, Sync-Algorithm,
Architecture, Data-and-Sync, Performance-Guide):

- **Transport to self-hosted cloud** is a simple `GET`/`PUT /v1/data` REST API with
  `Authorization: Bearer <token>`. The cloud server performs the merge **server-side**
  on `PUT` (unlike the WebDAV/File backends, where the client merges).
- **Merge is revision-aware Last-Write-Wins** per entity: higher `rev` wins → newer
  `updatedAt` → deterministic content-signature tiebreak.
- Every syncable entity (`Task`, `Project`, `Section`, `Area`) carries
  `id`, `rev`, `revBy`, `createdAt`, `updatedAt`, `deletedAt`.
- **Soft deletes via tombstones** that must be preserved (never purged by a client).
  Delete-vs-live uses `max(updatedAt, deletedAt)` with a 30-second ambiguity window.
- `AppData = { tasks[], projects[], sections[], areas[], settings }`.
- **Snapshot transport is intentional**; revisit only if snapshots exceed 5 MB or
  round-trips exceed 5 s. Merge scales linearly with entity count.
- **Device-local fields** (`lastSyncStats`, `lastSyncHistory`, `localStatus`,
  pending-write recovery) must be stripped from remote payloads.
- `createdAt` is immutable; `updatedAt` bumps on change; `deletedAt` on delete.
- `PUT` returns `{ ok, stats, clockSkewWarning }` (not the merged body), so the
  authoritative merged snapshot is fetched with a follow-up `GET`.
- HTTP allowed for localhost/private targets; HTTPS required for public URLs.

### Third-party client compliance rules (from Architecture wiki)

1. Respect revision ordering. 2. Never purge tombstones. 3. Deterministic
tiebreaks. 4. Honor soft deletes. 5. Respect FK semantics. 6. Coalesce overlapping
writes. 7. 30-s delete ambiguity. 8. Full-snapshot merge (no delta assumption).
9. Manage sync-state markers locally. 10. Exponential backoff (5s→5m).
11. Strip device-local fields. 12. Report conflicts transparently — **no silent
discards**.

## Chosen approach

**Approach A — Cloud snapshot sync.** Emacs is a first-class, well-behaved sync peer.
It maintains a local *shadow* (last-synced `AppData`) for local-change detection,
builds a candidate snapshot, and lets the **server own conflict resolution**. Emacs
never reimplements the merge algorithm.

Rejected alternatives:
- **B — REST CRUD** (`/v1/tasks` etc.): no cross-set server merge; would force us to
  reimplement LWW/cascade/ordering in elisp. Rejected.
- **C — Local API via desktop app**: zero merge code, but projects/areas appear
  read-only there and it requires the desktop app running. Fails the full-write
  scope. Rejected (possible future task-only fast-path).

### Core principle

`parse(buffer) → AppData` and `render(AppData) → buffer` are inverses. The org file
is a deterministic, lossless rendering of `AppData`.

## Architecture & data flow

### Persistent local state (state dir, e.g. `~/.emacs.d/mindwtr/`)

- **Shadow** — last-synced full `AppData` JSON, **including tombstones and settings**.
  The visible org file holds *live entities only*; the shadow carries the bookkeeping.
  The shadow is also the **store of record for fields not authoritative in org** —
  `rev`, `revBy`, `deletedAt`, `createdAt`/`updatedAt` (mirrored read-only into org),
  and opaque app-display fields (`color`, `icon`, `textDirection`, `order`,
  `pushCount`, `showFutureRecurrence`) — keyed by
  `id`. It is a *cache*: if lost, a fresh `GET` rebuilds it from the server (the
  authority for those fields). A candidate entity is reconstructed as
  `parse(org-heading) ⊕ shadow[id]`.
- **ETag / Last-Modified** — for cheap `HEAD` change-checks.
- **Device ID** — stable `revBy` (e.g. `emacs-<hostname>` or a persisted UUID).

### One sync cycle

```
1. HEAD /v1/data         → compare ETag. (Unchanged remote + no local edits ⇒ done.)
2. GET  /v1/data         → authoritative remote AppData + ETag.
3. Parse org buffer      → per-entity content keyed by MW_ID; reconstruct full
                           entities as parse(heading) ⊕ shadow[id] (sync metadata +
                           opaque fields come from the shadow, not org).
4. Diff local vs shadow  → classify create / update / delete / unchanged.
5. Build candidate:
     - changed/new entities: bump rev (= shadow.rev + 1), updatedAt = now, revBy.
     - unchanged entities: echo shadow rev/updatedAt verbatim.
     - deletions: emit deletedAt = now (tombstone), retained in candidate + shadow.
     - settings: carry remote settings VERBATIM (opaque pass-through; never edited).
     - strip all device-local fields.
6. Validate candidate shape.
7. PUT /v1/data { candidate }   → server merges server-side; returns stats.
8. GET /v1/data                 → authoritative merged AppData.
9. Conflict-compare: for each locally-changed entity, compare our candidate value
   vs merged result. Diverged + higher remote rev ⇒ our edit lost.
10. Backup pre-sync buffer; reconcile merged AppData into the buffer by id
    (update recognized fields in place, preserving org-only drawers/LOGBOOK /
    insert remote-new / drop tombstoned); regenerate ordering.
11. Save shadow = merged AppData; save new ETag.
12. Surface *Mindwtr Sync Report* (conflicts, discarded edits + diffs, clock skew,
    create/update/delete counts).
```

**Why a shadow:** bumping `rev` on every entity every sync would always "win" and
silently clobber phone/desktop edits. The shadow lets us bump `rev` only for entities
that genuinely changed in org.

## The org ⇄ AppData bijection

### File and tree

A single `mindwtr.org`, live entities only. Tree mirrors Mindwtr containment:
**Area → Project → Section → Task**. Area-less projects and project-less/inbox tasks
live under a synthetic, non-syncing `* Inbox` container.

The org drawer is intentionally minimal: identity + discriminator + content-only
fields with no native org form. Sync metadata and opaque display fields live in the
shadow, not here.

```org
* Work                              ← Area
  :PROPERTIES:
  :MW_TYPE: area  :MW_ID: 6f3a…
  :END:
** ACTIVE Storefront v2.4        ← Project (status = TODO keyword)
  :PROPERTIES:
  :MW_TYPE: project  :MW_ID: …  :MW_SEQUENTIAL: t
  :END:
*** Planning                        ← Section (optional level)
  :PROPERTIES: :MW_TYPE: section :MW_ID: … :END:
**** [#B] NEXT Create stories  :@computer:focused:    ← Task (priority = cookie)
  SCHEDULED: <2026-02-09>  DEADLINE: <2026-02-15>
  :PROPERTIES:
  :MW_TYPE: task  :MW_ID: …
  :MW_ENERGY: medium  :MW_TIME_ESTIMATE: 1hr
  :MW_CREATED: [2026-01-01 Mon 10:00]  :MW_UPDATED: [2026-05-30 Sat 15:30]  ← read-only mirror
  :END:
  :LOGBOOK:
  - org-only content like this drawer is preserved, never synced
  :END:
  Notes here are the task's description (body prose minus planning/drawers/checklist).
  - [ ] a checklist item
```

### Discriminator

`:MW_TYPE:` (`area|project|section|task`) is authoritative — parsing never guesses
entity type from depth. **Both tasks and projects carry a TODO keyword** for their
status; `:MW_TYPE:` disambiguates the (deliberately overlapping) keyword set:

- **Task status:** `INBOX NEXT WAIT SOMEDAY REF` (open) / `DONE ARCH` (closed).
- **Project status:** `ACTIVE SOMEDAY WAIT ARCH` (`active/someday/waiting/archived`).

A `mindwtr-mode` (derived from `org-mode`) sets `org-todo-keywords` buffer-locally to
the union. Areas and sections are plain headings (no keyword).

### Containment

`projectId` / `sectionId` / `areaId` (task) and `areaId` (project) are derived from
**ancestor headings**. Refiling a heading in org = re-parenting in Mindwtr. When
Mindwtr sets a task's `areaId` independently of its project's area, the explicit
value is preserved via an `:MW_AREA_ID:` override property (rare path).

### Field mapping — native org where faithful, drawer for the rest

| Native org | Mindwtr field |
|---|---|
| heading text | `title` |
| TODO keyword | task/project `status` (see Discriminator) |
| priority cookie `[#A]/[#B]/[#C]/[#D]`, unset = none | `priority` `urgent/high/medium/low` |
| `SCHEDULED` / `DEADLINE` / `CLOSED` | `startTime` / `dueDate` / `completedAt` |
| org tags `:@home:` (leading `@`) | `contexts` |
| org tags `:focused:` (no `@`) | `tags` (re-prefixed `#`) |
| body prose (minus planning/drawers/checklist) | `description` |
| `- [ ]` / `- [X]` list in body | `checklist[]` (parsed out of, and stripped from, description) |
| sibling order in file | `orderNum` / `order` (numeric value cached in shadow) |

**Org drawer (persisted in org):** `MW_ID` + `MW_TYPE` (always), plus content-only
fields with no native org form: `MW_ENERGY`, `MW_TIME_ESTIMATE`, `MW_RECURRENCE`
(serialized), `MW_ASSIGNED_TO`, `MW_FOCUS_TODAY`, `MW_REVIEW_AT`, `MW_LOCATION`,
`MW_TASK_MODE`, `MW_SEQUENTIAL` (project), `MW_FOCUSED` (project), `MW_AREA_ID`
(override, rare), `MW_ATTACH` (link attachments).

**Display-mirror in org (read-only, authoritative in shadow, excluded from
signature):** `MW_CREATED` / `MW_UPDATED`, rendered as org inactive timestamps and
rewritten from the merged result every reconcile.

**Shadow-only fields (NOT in org):** `rev`, `revBy`, `deletedAt`, `color`, `icon`,
`textDirection`, `order`/`orderNum` (numeric), `pushCount`, `showFutureRecurrence`,
recurrence `completedOccurrences`. New org entities default these; remote-set values
are preserved via the shadow and echoed back untouched.

**Org-only content (preserved, never synced):** any drawer other than the recognized
`MW_*` keys (e.g. `LOGBOOK`, `CLOCK`, user properties) and is left untouched by
reconcile. `description` deliberately excludes these.

**Tags fallback:** if a Mindwtr tag/context contains characters org tags can't hold
(spaces, etc.), that entity's tags/contexts move wholesale to `:MW_TAGS:` /
`:MW_CONTEXTS:` properties to preserve exactness.

### Canonical form / idempotency — the linchpin

`render(parse(buffer))` must equal `buffer` for unchanged content, or every sync
bumps `rev` on phantom edits and the client always wins. We define **one canonical
rendering** (fixed property order, ISO-8601 UTC timestamps, sorted tags, normalized
body) and a **content signature** computed over *only the editable mapped fields* —
explicitly **excluding** `createdAt`/`updatedAt` (display mirrors), `rev`/`revBy`, and
shadow-only fields. Change detection compares signatures, never raw text. This mirrors
Mindwtr's own normalized content-signature used in its tiebreak.

### Views, not structure

GTD views (Next Actions, Waiting, Someday, Inbox) are **org-agenda queries over the
TODO keyword / status**, never separate files or top-level buckets. Structure encodes
containment only.

## Change detection (parsed org vs shadow, per `id`)

- In org, not in shadow → **create**: assign UUID, `rev=1`, `createdAt=now`.
- In both, signature differs → **update**: `rev = shadow.rev+1`, `updatedAt=now`, `revBy`.
- In both, signature equal → **unchanged**: echo shadow `rev`/`updatedAt`.
- In shadow (live), absent in org → **delete**: `deletedAt=now`; tombstone kept in
  candidate + shadow, not rendered.
- Tombstone in shadow → carried forward untouched.

## Conflict surfacing — no silent loss

After the authoritative re-`GET`, for every locally-changed entity, compare our
candidate against the merged result. If the server kept a higher-`rev` remote edit,
**our local edit lost**. Before reconciling:

1. Snapshot the pre-sync buffer to `mindwtr/backups/mindwtr-<timestamp>.org`.
2. Pop `*Mindwtr Sync Report*` listing conflicts + IDs (from `PUT` stats),
   locally-discarded edits **with a field-level diff and a one-key "restore my edit"
   action**, clock-skew warnings, and create/update/delete counts.

## Concurrency & safety

- **Mid-sync edit:** if the buffer's modification tick changes between parse and
  reconcile-write, **abort and re-queue** (mirrors Mindwtr's own rule). No hard lock.
- **Failure isolation:** on any failure (network, `401`, `429`, `5xx`, parse/validate
  error), leave org and shadow **untouched** — org is always a safe local state.
- **Backoff:** `429`/`5xx` → exponential `5s → 5m`; after 12 attempts, a persistent
  error state is surfaced.
- **Atomic shadow writes:** temp-file + rename, with a retained last-good copy.

## Triggers

All funnel into one debounced, `HEAD`-guarded engine; `mindwtr-sync` is the primitive.

- **Manual:** `M-x mindwtr-sync`.
- **Debounced on save/idle:** ~5 s after editing `mindwtr.org` (debounced).
- **Periodic timer:** every N minutes (default 10) via `HEAD` pre-check; throttled.
- **Focus/startup:** shortly after Emacs starts and on frame focus (throttled ~30 s).

## Module decomposition

| File | Responsibility | Depends on |
|---|---|---|
| `mindwtr-model.el` | Entity structs (`cl-defstruct`), `AppData`, enums, shape validation. Pure data. | — |
| `mindwtr-api.el` | HTTP: `GET`/`HEAD`/`PUT /v1/data`, attachments endpoints. Auth, ETag, error classification, backoff. | model |
| `mindwtr-parse.el` | org buffer → `AppData`. | model |
| `mindwtr-render.el` | `AppData` → canonical org text. | model |
| `mindwtr-signature.el` | Content signature over mapped fields (idempotency oracle). | model |
| `mindwtr-shadow.el` | Shadow + ETag + device-id persistence; atomic write, last-good backup. | model |
| `mindwtr-sync.el` | The engine (orchestrates the cycle, change detection, conflict compare). | all above |
| `mindwtr-reconcile.el` | Apply merged `AppData` into the live buffer by `id`, updating only recognized fields and **preserving org-only drawers/LOGBOOK** and point. | render |
| `mindwtr-report.el` | `*Mindwtr Sync Report*` buffer; conflict diffs; restore action. | model |
| `mindwtr.el` | Entry point: custom vars, `auth-source` token, commands, trigger wiring, minor mode. | sync |

**Secrets:** token via `auth-source` (`~/.authinfo.gpg`), never plaintext.
**HTTP:** `plz.el` preferred; fall back to built-in `url.el`.

## Testing strategy (`ert`, golden files)

- **Round-trip properties (core):** `render(parse(x)) ≡ x` over a corpus;
  `parse(render(d)) ≡ d`. Signature stability (cosmetic reformat → same signature;
  field change → different).
- **Change detection:** create/update/delete/unchanged vs a shadow fixture.
- **Reconcile:** merged snapshot → expected buffer; tombstone removal; remote-insert;
  point preservation.
- **API** against a stub server: ETag short-circuit, `429` backoff, `401`.
- **Conflict path:** server keeps a remote edit → report lists discarded edit +
  backup written (no silent loss).
- **Invariants:** settings pass-through untouched; tombstone retention.
- **Reference merge (optional):** a small elisp reimplementation of the documented
  LWW to drive end-to-end tests without a live server, plus a manual integration test
  against a real self-hosted instance.

## Scope

**v1:** full bidirectional round-trip of tasks, projects, sections, areas, and
`link` attachments (URLs); all four triggers; conflict report with restore.

**Phase 2 (deferred):**
- File-attachment **byte** upload/download via `PUT/GET /v1/attachments/:path` and
  orphan cleanup.
- One-time importer from the existing `org-gtd-tasks.org` into the new schema.
- Recurrence-object edge fidelity beyond serialized round-trip; richer checklist UX.
- Optional Local-API fast-path for task-only edits when the desktop app is running.

## Open risks

- **Description ⇄ body fidelity:** `description` = body prose *minus* planning lines,
  drawers (`PROPERTIES`/`LOGBOOK`/etc.), and the checklist. Mindwtr renders it raw.
  The split must be unambiguous and reversible so reconcile never disturbs org-only
  drawers or the checklist while updating the prose.
- **Recurrence** objects are serialized into a property; native org repeaters are not
  used in v1 to avoid a lossy mapping.
- **Canonical-form drift** is the highest-risk area — covered by the round-trip
  property tests, which must pass before any sync logic is trusted.
