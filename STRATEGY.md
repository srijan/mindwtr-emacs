---
name: mindwtr.el
last_updated: 2026-06-02
---

# mindwtr.el Strategy

## Target problem

An org-mode GTD user has nowhere good to capture and triage on the go — org-mode is unbeatable for deep work at the desk, but there's no native mobile experience. The usual fix, keeping GTD data in two systems, makes them drift out of sync, and no tool keeps a single GTD source of truth coherent across both surfaces.

## Our approach

Lossless round-trip is the non-negotiable: no data loss in either direction, with the org file holding a superset of what Mindwtr models — so anything Mindwtr doesn't understand survives the trip rather than being flattened to the server's schema. The user can move between Emacs and the mobile app without fear that something was dropped.

## Who it's for

**Primary:** An org-mode power user already running GTD in Emacs who wants Mindwtr as their mobile/native arm. They're hiring `mindwtr.el` to keep one GTD source of truth coherent across the desk and on the go — capturing and triaging on mobile while keeping the Emacs editing power for deep work.

## Key metrics

- **Round-trip fidelity** — a model survives parse → render → parse unchanged. Measured as a pass/fail invariant in the test suite (`test/mindwtr-roundtrip-test.el`), backed by the signature/canonical-comparison machinery.
- **Dropped entities / updates** — headings whose status was left unchanged (invalid-keyword warnings) plus the proposed-change counts and overridden-edit conflicts. Surfaced live every sync in the *Mindwtr Sync Report*.
- **Sync failures** — runtime-observed via API error classification (401/429) and the backoff/give-up state machine. No aggregate counter yet; watched one run at a time.

## Tracks

### Fidelity engine

The org↔model translation that *is* the lossless guarantee: parse, render, content signatures, canonical comparison, and preserving unknown properties.

_Why it serves the approach:_ This track is the approach made concrete — lossless round-trip lives or dies here.

### Sync & conflict reconciliation

Server-authoritative merge, the shadow snapshot for change detection, the sync report, and one-key restore of edits the server overrode.

_Why it serves the approach:_ Guarantees that "no data loss" survives a real merge — and makes any override visible and recoverable rather than silent.

### Emacs-native editing

`mindwtr-mode`, type-aware status commands, and immediate bucket relocation that make the synced file pleasant to actually work in.

_Why it serves the approach:_ If the desk surface isn't a joy to edit, the user won't keep the org file as their source of truth — which the whole approach depends on.

### Transport & reliability

The HTTP/API layer, auth, retry/backoff, and auto-sync.

_Why it serves the approach:_ A round-trip that fails to complete is still data left stranded; reliable transport is what lets fidelity reach the server.
