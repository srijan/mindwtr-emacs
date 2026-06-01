# Mindwtr Live Smoke Suite — Design

**Date:** 2026-06-01
**Status:** Approved

## Goal

Consolidate the four throwaway `smoke-*.el` harnesses into one committed,
reusable live smoke suite that can be run against future Mindwtr server
versions and more complex instances, with read-only checks by default and an
opt-in self-cleaning write lifecycle.

## Motivation

During live debugging we accumulated four untracked harnesses:

- `smoke-test.el` — read-only: HEAD + GET, `validate-appdata`, render→parse→
  signature round-trip, PASS/DRIFT summary.
- `smoke-diag.el` — read-only: per-field canonical diff for drifting entities.
- `smoke-probe.el` — read-only: dumps raw entity shapes.
- `smoke-write.el` — guarded single-entity write, hardcoded to one task id.

They share heavily duplicated boilerplate (env/token setup, `keys`,
`find-by-id`, `index-by-id`, `plist-same-p`) and the write harness is pinned to
a hardcoded task id, so it cannot run against an arbitrary instance. We want a
single durable tool that exercises the full sync contract and surfaces server
schema drift the moment a new server version introduces it.

## Non-Goals

- Not part of `make test` (the offline ert suite): the live suite needs network
  and a real token.
- No golden schema snapshot file (YAGNI — the in-model known-fields registry
  diff is sufficient drift detection).
- No structured TAP/JSON output (human log + exit codes is enough for now).

## Architecture

```
smoke/
  mindwtr-smoke.el   ; shared library: config, reporting, helpers, phases
  run.el             ; thin entrypoint: selects + runs phases, exits
```

```
make smoke         ; read-only phases only (safe on any instance)
make smoke-write   ; read-only phases first, then the write lifecycle
```

Config from environment (unchanged from today):

- `MINDWTR_URL` — required, base URL.
- `MINDWTR_TOKEN` — bearer token; falls back to auth-source via
  `mindwtr--resolve-token` for the URL host when unset.

The token stays in the user's shell and is never echoed by the suite.
`smoke/` is committed; the four root `smoke-*.el` files are deleted.

### Design for isolation

- `mindwtr-smoke.el` holds all logic: config, reporting, pure helpers,
  diagnostics, and phase functions. Each phase is a function that takes the
  GET'd appdata (or the API client) and reports pass/fail/warn — independently
  understandable and independently testable against a mock transport.
- `run.el` is a thin orchestrator: decide which phases to run from the make
  target / env, run them in order, print the summary, exit with the right code.
- The known-fields registry lives in `mindwtr-model.el` (model knowledge,
  reused by the suite) rather than in the suite itself.

## Components

### Shared library: `smoke/mindwtr-smoke.el`

**Config**

- `mindwtr-smoke-configure` — resolve `MINDWTR_URL` (error if absent) and the
  token (env, then auth-source fallback), set `mindwtr-api-base-url` /
  `mindwtr-api-token`.

**Reporting + exit**

- A counters struct/plist tracking pass / fail / warn totals.
- `mindwtr-smoke-pass (label &rest details)` — print `[PASS] label`.
- `mindwtr-smoke-fail (label &rest details)` — print `[FAIL] label` plus
  details; increment fail counter.
- `mindwtr-smoke-warn (label &rest details)` — print `[WARN] label` plus
  details; never affects exit code.
- `mindwtr-smoke-summary` — print totals; return the intended exit code
  (non-zero iff any fail).

**Pure plist helpers** (dedup the copies from the four scripts)

- `mindwtr-smoke-plist-keys (pl)` — list of keys.
- `mindwtr-smoke-find-by-id (appdata id)` — entity across all collections.
- `mindwtr-smoke-index-by-id (appdata)` — hash id→entity over all collections.
- `mindwtr-smoke-plist-same-p (a b)` — order-insensitive key/value equality.

**Diagnostics** (invoked automatically by phases on failure)

- `mindwtr-smoke-canonical-field-diff (orig re)` — per-key diff of the two
  canonical plists (from smoke-diag), printed for each drifting entity.
- `mindwtr-smoke-key-diff (wire server)` — per-key wire-vs-server diff, printed
  for each unexpected non-target change during the write lifecycle.

### Model addition: `mindwtr-model-known-fields`

```elisp
(defconst mindwtr-model-known-fields
  '((task    . (:id :title :status :priority :energyLevel :timeEstimate
                :assignedTo :location :taskMode :contexts :tags :description
                :checklist :attachments :recurrence :startTime :dueDate
                :completedAt :reviewAt :areaId :projectId :sectionId
                :order :orderNum :pushCount :showFutureRecurrence
                :isFocusedToday :textDirection
                :statusBeforeProjectArchive :completedAtBeforeProjectArchive
                :isFocusedTodayBeforeProjectArchive :projectArchivedAt
                :createdAt :updatedAt :deletedAt :purgedAt :rev :revBy))
    (project . (:id :title :color :order :status :areaId :areaTitle :tagIds
                :isSequential :isFocused
                :createdAt :updatedAt :deletedAt :rev :revBy))
    (section . (:id :title :projectId :order
                :createdAt :updatedAt :deletedAt :rev :revBy))
    (area    . (:id :name :color :order
                :createdAt :updatedAt :deletedAt :rev :revBy))
    (settings . (:theme :weekStart :keybindingStyle :appearance :gtd :ai
                 :syncPreferences :syncPreferencesUpdatedAt :savedFilters)))
  "Every server key we recognize, per entity type.
The smoke suite flags wire keys absent here as UNKNOWN (server drift) and
listed keys absent from the wire as MISSING. Doubles as living documentation
of the full known schema. Built from observed real payloads; extend it
deliberately when a new server field is intentionally adopted.")
```

The exact field lists are seeded from the real payloads already observed in
live runs (e.g. the lifecycle dump showing `recurrence`, `attachments`,
`*BeforeProjectArchive`, `purgedAt`, etc.) and refined during implementation by
running the coverage phase against the real server and reconciling.

### Entrypoint: `smoke/run.el`

- Require `mindwtr-smoke`.
- `mindwtr-smoke-configure`.
- Read whether to run the write lifecycle from the make target (env var, e.g.
  `MINDWTR_SMOKE_WRITE=1`).
- Run read-only phases in order; if write requested, run the lifecycle phase.
- Call `mindwtr-smoke-summary` and `kill-emacs` with its exit code.

## Phases

### Read-only (both `make smoke` and `make smoke-write`)

1. **connectivity** — `HEAD /v1/data`, report ETag. FAIL on auth/transport
   error (auth error message distinguished).
2. **snapshot + validate** — `GET /v1/data`, print counts
   (tasks/projects/sections/areas, settings present?), run
   `mindwtr-model-validate-appdata`. FAIL on validation error.
3. **schema coverage** — for each entity type, diff live keys (union across all
   entities of that type) against `mindwtr-model-known-fields`. WARN (non-fatal,
   exit 0) on UNKNOWN keys (new server field we don't model) and MISSING
   expected keys.
4. **round-trip signature** — render the snapshot into an org buffer, parse it
   back, compare each entity's content signature to the original. On any drift,
   FAIL and automatically print the per-field canonical diff
   (`canonical-field-diff`) for each drifting entity so the failure is
   self-diagnosing.

### Write lifecycle (`make smoke-write` only)

Drives one throwaway task through the real GTD state machine, re-GETting and
asserting after every PUT. Title is recognizable: `"[mw-smoke] lifecycle
<run-id>"` (run-id derived from a timestamp passed in, since `Date.now` style
calls are fine in a batch script via `format-time-string`). The whole sequence
is wrapped in `unwind-protect` whose cleanup deletes (tombstones) the test task,
so a mid-lifecycle failure never leaves litter and reruns stay clean.

```
create task in INBOX, with fields            -> PUT -> verify rev1, status=inbox, fields landed
  (contexts @computer, tags #smoke, checklist 2 items, dueDate, priority, energyLevel)
mutate: edit title + flip a checklist item   -> PUT -> verify rev2, change landed, others intact
transition INBOX -> NEXT                      -> PUT -> verify status=next, fields survive
transition NEXT  -> DONE                       -> PUT -> verify status=done, completedAt set
delete (tombstone)                            -> PUT -> verify gone from live set
final assert: every pre-existing entity byte-identical throughout (0 non-target drift)
```

**Per-PUT safety gate** (reused from `smoke-write.el`): before each PUT, assert
that only the test entity differs from the prior server state — every
pre-existing live entity must be byte-identical and no other tombstone may
appear. On any anomaly, print the offending entity's `key-diff` and FAIL the
phase (still running cleanup).

The candidate payloads are built through the real sync path
(`mindwtr-sync-build-candidate` + `mindwtr-sync--strip-internal-keys`), so the
lifecycle tests the actual code, not a bypass. Field mutations are applied by
editing the rendered org buffer where possible (so the org→parse→merge path is
exercised), and directly on the candidate where a state has no org affordance.

## Data Flow

1. `run.el` configures the API client from env.
2. Read-only phases each call `mindwtr-api-get-data` (or `head-etag`) and report.
3. Write lifecycle: GET (server truth) → render→edit→parse→build-candidate →
   safety gate → PUT → re-GET → assert. Repeat per transition. Cleanup deletes.
4. `run.el` prints the summary and exits non-zero iff any phase failed.

## Error Handling

- Transport/auth errors in any phase → FAIL with the classified error; the run
  continues to the summary where possible, but connectivity failure aborts
  early (nothing else can run).
- Validation errors → FAIL the validate phase.
- Round-trip drift → FAIL with automatic per-field diagnostics.
- Write anomalies → FAIL with per-key wire-vs-server diagnostics; cleanup always
  runs via `unwind-protect`.
- Non-fatal observations (unknown/missing schema keys) → WARN only.

## Testing

`test/mindwtr-smoke-test.el`, run under `make test` (no network):

- Pure helpers (`plist-keys`, `find-by-id`, `index-by-id`, `plist-same-p`,
  `canonical-field-diff`, `key-diff`) get direct unit tests.
- Schema-coverage computation gets a test: a fabricated appdata with one
  injected unknown key and one missing expected key asserts the WARN set.
- The **full write lifecycle** runs against an in-memory mock server installed
  via `mindwtr-api-http-function` (the same injection point used in
  `mindwtr-sync-test`): the mock holds an appdata table and actually applies
  PUTs, so the test exercises create → field-set → next → done → delete and the
  safety gate end to end, asserting the final state has zero trace and zero
  non-target drift.
- Reporting/exit: a test asserts the summary returns non-zero exactly when a
  fail was recorded.

This keeps the suite's own logic honest offline; `make smoke` is then the same
code pointed at a real server.

## Migration

Delete `smoke-test.el`, `smoke-diag.el`, `smoke-probe.el`, `smoke-write.el` from
the repo root; their behavior is subsumed:

- smoke-test → read-only phases 1, 2, 4.
- smoke-diag → automatic diagnostics on round-trip drift (phase 4).
- smoke-probe → superseded by the schema-coverage phase (3); raw-shape dumping
  is no longer a separate mode.
- smoke-write → the write lifecycle phase, generalized (no hardcoded id,
  self-cleaning).

## Decisions (resolved during brainstorming)

- Write strategy: self-cleaning lifecycle through the GTD state machine
  (inbox → next → done → delete), with field round-trip checks.
- Packaging: committed `smoke/` dir with `make smoke` / `make smoke-write`.
- Schema drift: in-model `known-fields` registry, coverage report as WARN.
- Output: human log + exit codes, with automatic diagnostics on any failure.
- Out of scope: golden snapshot file, TAP/JSON output.
