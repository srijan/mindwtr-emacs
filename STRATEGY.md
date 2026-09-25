---
name: mindwtr.el
last_updated: 2026-09-25
---

# mindwtr.el Strategy

## Purpose

An org-mode GTD user has nowhere good to capture and triage on the go — org-mode is unbeatable for deep work at the desk, but there's no native mobile experience. The usual fix, keeping GTD data in two systems, makes them drift out of sync, and no tool keeps a single GTD source of truth coherent across both surfaces.

## Positioning

Lossless round-trip is the non-negotiable: no data loss in either direction, with the org files holding a superset of what Mindwtr models — so anything Mindwtr doesn't understand survives the trip rather than being flattened to the server's schema. Conflict resolution is always Mindwtr's own merge logic, on the server or run locally from upstream's code, never reimplemented in Emacs. The user can move between Emacs and the mobile app without fear that something was dropped.

## Users

**Primary:** An org-mode power user already running GTD in Emacs who wants Mindwtr as their mobile/native arm. They're hiring `mindwtr.el` to keep one GTD source of truth coherent across the desk and on the go — capturing and triaging on mobile while keeping the Emacs editing power for deep work.

## Boundaries

- Don't route through a server endpoint what org already does; call the server only for processing Emacs shouldn't replicate (e.g. audio transcription).
- Don't diverge from upstream's GTD rules on the desk. An urge to diverge means we've missed upstream's reasoning or found an upstream bug — take it upstream.

_Resist a change when:_ it makes Emacs decide something upstream Mindwtr already decides — merge, GTD rules, or server-side parsing — instead of reusing upstream's own logic.

## Key metrics

- **No push without a local edit** - a sync that follows no local edits proposes zero changes. Checked by `make smoke-docker` (a change pulled from another client, then an idle sync) and flagged in the sync report when a real cycle does it; both to be added.
- **Every pushed change traces to a local edit** - the pushed diff for an edit carries only the fields that edit touches. Checked per kind of edit (archive, refile, clarify outcome, status change) in the test suite; to be added.
- **Round-trip fidelity** - a model survives parse → render → parse unchanged. A pass/fail invariant in the test suite (`test/mindwtr-roundtrip-test.el`), backed by the signature/canonical-comparison machinery.
- **Sync failures** - runtime-observed via API error classification and the backoff/give-up state machine. No aggregate counter yet; watched one run at a time.

## Tracks

### Fidelity engine

The org↔model translation that *is* the lossless guarantee: parse, render, content signatures, preserving unknown properties, and keeping the model in step with each upstream Mindwtr release.

_Why it serves the approach:_ Lossless round-trip lives or dies here — and a field upstream adds that Emacs doesn't recognize is data waiting to be lost.

### Sync & reliability

Server-authoritative merge, the shadow snapshot, transport, retry and auto-sync, and the sync report that makes every override visible and recoverable — including backends lighter to host than a full Mindwtr server.

_Why it serves the approach:_ "No data loss" has to survive a real merge over an unreliable network; a cycle that fails, or an override nobody can see or undo, is data left stranded.

### Desk GTD client

The user's org files, organized however they choose, act as a first-class GTD surface: pleasant to edit in, and making the same decisions the app makes about what's actionable.

_Why it serves the approach:_ If the desk isn't where the user wants to work, org stops being the source of truth; if it decides differently from the app, the two surfaces disagree about what to do next.
