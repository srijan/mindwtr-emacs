# AGENTS.md

Guidance for coding agents working in `mindwtr.el` — bidirectional sync between a single
org-mode GTD file and a self-hosted [Mindwtr Cloud](https://mindwtr.com) server. The server
owns conflict resolution (revision-aware last-write-wins, server-wins on ties); Emacs proposes
changes and reports any local edits the server overrode.

## Sync pipeline

`mindwtr-sync-once` drives one cycle: parse the org buffer → PUT a candidate snapshot to
`/v1/data` → GET the server's merged result → reconcile it back into the buffer. A local shadow
JSON snapshot lets changes be detected without re-fetching.

| File | Role |
|------|------|
| `mindwtr.el` | Entry point; wires the package together |
| `mindwtr-sync.el` | Sync engine (the parse→PUT→GET→reconcile cycle) |
| `mindwtr-api.el` | Mindwtr Cloud REST client (`plz`, falls back to `url.el`) |
| `mindwtr-model.el` | Data model & validation (content-field definitions) |
| `mindwtr-heading.el` | Read access to org headings: drawer props, MW_ID/MW_LIST lookup, ancestry, extent, safe iteration. Every module reads headings through it |
| `mindwtr-parse.el` | org buffer → appdata content (incl. MW_TYPE inference) |
| `mindwtr-render.el` | appdata → canonical org text |
| `mindwtr-reconcile.el` | Apply merged appdata into the buffer (per surface, via a render fn); view-state + quarantine |
| `mindwtr-archive.el` | Archive-file surface: path/buffer resolution, archive renderer entry, immediate refile (`mindwtr-archive-item-at-point`) |
| `mindwtr-signature.el` | Content signatures (drives change detection) |
| `mindwtr-shadow.el` | Durable sync state: Shadow, ETag, device id, Migration latches, pre-sync backups. Sync reads it as one baseline and writes it with one commit; an internal store seam has a file adapter (default) and an in-memory one for tests |
| `mindwtr-commands.el` | Interactive type-aware status commands |
| `mindwtr-clarify.el` | Guided inbox triage (`mindwtr-clarify`, the clarify workflow) |
| `mindwtr-capture.el` | Inbox capture (`mindwtr-capture` + org-capture template; stamps MW_TYPE + MW_ID) |
| `mindwtr-report.el` | Sync report buffer |
| `mindwtr-util.el` | Utilities (UUID, etc.) |

## Conventions & invariants

- **Minimum platform: Emacs 28.1 / Org 9.5.** The `org-fold-*` namespace (Org 9.6+) is absent
  there — `fboundp`-dispatch fold operations to legacy `outline-*`, and use version-safe
  detection (`org-invisible-p`, not `org-fold-folded-p`).
- **Round-trip byte-stability.** Any description/text transform must be its own inverse across
  render→parse→render. A non-stable transform phantom-churns the content signature on every
  sync. Add a round-trip test for every new transform. **This obligation applies to the archive
  file too:** `mindwtr-render-archive-appdata` is a second render surface and must round-trip
  byte-stably exactly like the main render (its injected `MW_PROJECT_ID`/`MW_SECTION_ID`
  containment props land at a fixed drawer position for that reason).
- **Safe-by-default on reconcile.** Reconcile does a full `erase-buffer`+rebuild; it must never
  silently destroy user content. Anything the parser can't place is quarantined under
  `* Sync Failures`, not dropped.
- **Post-PUT path must never throw.** Reconcile runs *after* the server write commits, so
  view-state restore and similar cosmetic steps are wrapped in `condition-case` — a hiccup must
  not surface as a spurious sync failure.

## Building & testing

- `make test` — the **offline** correctness gate: ERT unit tests, no server needed. This plus
  `make compile` (byte-compile) is the ship gate; run them before every commit.
- `make parity` — **offline** synced-field parity: diffs `mindwtr-model-known-fields` against
  the Mindwtr core's own sync-schema fixtures (`packages/core/src/<entity>-sync-schema.fixture.json`).
  Set `MINDWTR_CORE_PATH` to an upstream checkout (monorepo root or `packages/core/src`); skips
  cleanly when unset. The same comparison runs as an ERT gate inside `make test` and as the first
  phase of `make smoke`. Prefer this over the live schema-coverage phase when adopting a new
  server version: schema coverage only sees fields some entity on that instance actually carries,
  so it is blind to a field the server has learned but nobody has set yet.
  **Severities are asymmetric on purpose.** A field the fixture declares that the model lacks
  fails (exit 1) — the server can send it and nothing recognizes it. A field the model knows that
  the fixture omits is only *noted*: CI reads the fixtures at the pinned server version, which
  normally lags upstream, so recognizing a newer field is forward compatibility, not drift.
  CI checks out `dongdongbh/Mindwtr` at `v$DEFAULT_CLOUD_TAG` — the same version token
  `make smoke-docker` pins — so both gates describe one server and Renovate's existing bump of
  that token upgrades this too. Adopting a field the check finds is *recognition only*: add it to
  `mindwtr-model-known-fields`, never straight to `mindwtr-model-content-fields` (allow-list-LAST).
- `make smoke` / `make smoke-write` — **online** integration tests that require a live
  `MINDWTR_URL` (and credentials); they exit early with a connection error when no server is
  reachable, so run *directly* they're manual/staging-only, not a CI gate. Always exercise at
  least one non-ASCII title through smoke — a symmetric encoder bug passes equality-based
  round-trip tests.
- `make smoke-docker` — the **CI gate** version: it provisions its own throwaway cloud server
  in Docker, runs the smoke suite against it, cross-checks the wire with curl, and tears down.
  Because it self-provisions (no external `MINDWTR_URL` dependency) it *is* wired into CI; see
  `test/integration/README.md`. SKIPs cleanly without Docker/Emacs unless `MINDWTR_DOCKER_REQUIRE=1`.
- `test/mindwtr-test-helpers.el` holds the shared fakes: `mindwtr-test-server` (an in-memory
  Mindwtr Cloud at the HTTP seam, tags advance v1, v2, ... on PUT; inspect `-last-put` and
  `-requests`) and `mindwtr-test-with-sync-env`, which binds that server plus the in-memory
  shadow store so a full `mindwtr-sync-once` runs with no temp directory and no files. Prefer
  it over an inline `pcase` fake unless the test needs fault injection or a specific ETag
  sequence.
- Remove stale `*.elc` before batch ERT runs if results look off (`rm -f *.elc`).

## Documented solutions

`docs/solutions/` — documented solutions to past problems (bugs, design patterns), organized by
category with YAML frontmatter (`module`, `tags`, `problem_type`, `component`). Relevant when
implementing or debugging in documented areas (e.g. reconcile view-state, untyped-heading data
loss, org↔markdown link conversion). `docs/plans/` and `docs/superpowers/specs/` hold the
implementation plans and design specs those solutions came from.

`CONCEPTS.md` (repo root) — shared domain vocabulary (Shadow, Content signature, Reconcile,
Migration latch, …); relevant when orienting to the sync engine or discussing domain concepts.
