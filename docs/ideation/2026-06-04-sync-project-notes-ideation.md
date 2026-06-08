---
date: 2026-06-04
topic: sync-project-notes
focus: issue #31 ("Sync project notes")
mode: repo-grounded
---

# Ideation: Sync Project Notes

## Grounding Context

**The gap.** `mindwtr-render.el:177` gates body-prose rendering to `kind = task`. The two note-bearing
fields on other entities never reach the org buffer:

* **Projects** carry notes in `:supportNotes` — *not* in the content-field allow-list
  (`mindwtr-model-content-fields`, model.el:150-164), preserved verbatim in the shadow snapshot only,
  so it is invisible and uneditable in Emacs.

* **Sections** carry `:description` — already in the allow-list, but blocked by the same render gate.

These are **two different fix paths**: sections need only a render-gate widening; projects need
render + parse + a shadow→content reclassification. Today a user who keeps the org file as their
source of truth literally cannot see or edit a project's notes at the desk — they exist only on mobile,
which cuts against the product's "org file is the source of truth" approach.

**Scope.** Areas have no notes/description field in the synced schema (`mindwtr-model.el` area known-fields are `:id :name :color :icon :order` plus timestamps), so this work is project + section only.

**Load-bearing learnings (docs/solutions/):**

* Add a field to the allow-list **last**, only after byte-stable parse↔render is proven — a prior
  deny-list bug drove 30/32 entities to false-drift on every sync.

* Reuse the existing `mw->org-text` / `org->mw-text` converters and the round-trip suite; every text
  transform must be its own inverse or it phantom-churns the content signature (Emacs then wins every merge).

* `mindwtr-reconcile--preserved-body` already keeps non-task free-prose verbatim — so `render-heading`
  must become the **sole** serializer or notes double-graft.

* Safe-by-default: the erase-buffer+rebuild reconcile must never silently drop content; anything
  unplaceable is quarantined under `* Sync Failures`.

* View-state anchor (PR #28/#29) must survive a body whose length changes.

**External prior art:** org-caldav / Joplin / Obsidian all do *item-level* last-write-wins with no
field-level prose merge (Joplin dumps the loser into a "Conflicts" notebook). Closest good analogy:
Zotero's three-pointer snapshot merge — and the shadow snapshot already *is* a stored common ancestor,
so `diff3(shadow, buffer, server)` is cheap. CalDAV `If-Match` is the optimistic-concurrency primitive.
Markdown↔org link conversion is a known fidelity risk.

## Topic Axes

1. Render side — placing project/section notes as body prose in the buffer
2. Parse side — extracting edited notes; separating prose from checklist/planning/drawers/children
3. Allow-list & schema governance — content-fields membership, shadow→content reclassification, drift guards
4. Conflict & recovery for prose — LWW vs three-way merge, surfacing/recovering overridden edits
5. Round-trip fidelity & formatting — link conversion reuse, byte-stability, non-ASCII

## Ranked Ideas

### 1. Per-kind prose-field registry (single source of truth)

**Description:** One declarative table — `task→:description`, `section→:description`,
`project→:supportNotes` — that render, parse, signature, and preserved-body all read from, replacing
the three hardcoded `(eq kind 'task)` sites. `render-heading` becomes the sole prose serializer for
every kind; the two field names become the only per-kind difference, expressed as data.
**Axis:** 3 (governance)
**Basis:** `direct:` render.el:177 and parse.el:217 both re-gate on `(eq kind 'task)`; `:description`
vs `:supportNotes` are the only real divergence.
**Rationale:** Collapses the "two different code paths" warning into one and makes every future
non-round-tripping field (`:reviewAt`, `:isSequential`, area fields) a one-row addition rather than a new PR.
**Downsides:** A refactor before the feature; touches four files at once.
**Confidence:** 90%
**Complexity:** Medium
**Status:** Unexplored

### 2. Kind-aware parse partition — don't eat `- [ ]` lines as checklists on non-tasks

**Description:** `parse--body` pulls any `- [ ]` line into `:checklist`, but projects/sections have no
`:checklist` field — a literal checkbox typed into project notes would be silently amputated on the
next sync. Branch so only tasks reclassify checkboxes; for project/section, everything that isn't
planning/drawer is prose.
**Axis:** 2 (parse)
**Basis:** `direct:` parse.el:129-132 (checklist regex) + model.el:182-188 (no `:checklist` on project/section).
**Rationale:** Exactly the silent prose loss the safe-by-default rule forbids, and cheap to prevent.
**Downsides:** None material; a small branch.
**Confidence:** 88%
**Complexity:** Low
**Status:** Unexplored

**Review note (resolved):** Split out as a task-only follow-up — see issue #33. Projects/sections have no `:checklist` field, so for them all `- [ ]` lines stay in notes prose (this issue, #31). The task-side earmark convention (let descriptions contain checkboxes while a real checklist stays distinct) and its round-trip design are tracked separately in #33.

### 3. De-opaque `preserved-body` first (the ordering landmine)

**Description:** `reconcile--preserved-body` returns the entire non-task body verbatim today — correct
only while render emits nothing. The moment render emits notes, both paths claim the same bytes →
double-graft / silent divergence. Narrow preserved-body to drawers/CLOCK for all kinds *before* render
starts emitting prose.
**Axis:** 2 (parse/reconcile)
**Basis:** `direct:` reconcile.el:53-55; learnings flag this as the sole-serializer precondition.
**Rationale:** Highest-probability silent-corruption bug in the feature; a sequencing decision that
must ship atomically with idea #1.
**Downsides:** Must be coordinated with #1; wrong order corrupts content.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

### 4. Test-gated shadow→content promotion + parameterized round-trip & symmetry guards

**Description:** Encode "allow-list LAST" as machinery: a parameterized round-trip property suite over
kind×prose (with empty/nil≡, non-ASCII, links, and a code-block/extreme-content corpus) plus a
render⇄parse symmetry drift-guard; allow-list membership is asserted only when those are green.
**Axis:** 3 (governance) / 5 (fidelity)
**Basis:** `direct:` premature allow-listing once drove 30/32 entities to false-drift; extends the
existing `infer-kind-covers-every-entity-role` guard.
**Rationale:** Turns a tribal rule into a structural gate — disarms the false-drift footgun permanently,
for this field and the next.
**Downsides:** Up-front test scaffolding; no user-facing output on its own.
**Confidence:** 90%
**Complexity:** Medium
**Status:** Unexplored

### 5. Three-way prose merge with the shadow as common ancestor

**Description:** Notes are the first field where blind LWW destroys real human work (a lost paragraph
vs a flipped checkbox). The shadow already stores the last-synced value — a free merge base. Run
`diff3(shadow, buffer, server)`; non-overlapping edits both survive, true conflicts quarantine under
`* Sync Failures`. Conservative variant: detect-and-quarantine via `If-Match`, or an append-only
"loser" ledger, instead of real merge.
**Axis:** 4 (conflict)
**Basis:** `external:` Zotero three-pointer / git diff3; `reasoned:` the ancestor is already on disk.
**Rationale:** The "raise the bar" idea — every competitor only does item-level LWW. The machinery
generalizes to task descriptions too.
**Downsides:** Real complexity; arguably a follow-up to shipping basic round-trip.
**Confidence:** 60%
**Complexity:** High
**Status:** Unexplored

### 6. Notes placement: inline body (decided) — axis 1

**Description:** Notes render as inline body prose under the entity heading (same shape as task descriptions), **not** as a dedicated `** Notes` subtree. The subtree alternative was considered — it would have dissolved the prose-vs-checklist/drawer/children boundary problem — but rejected in review: notes should read inline like task descriptions. Consequence: the parse-boundary work in #2/#3 must be solved directly rather than sidestepped.
**Axis:** 1 (render)
**Basis:** `reasoned:` inline keeps notes consistent with how task descriptions already render; the structural separation of a subtree is not worth diverging the read experience.
**Rationale:** Resolves the placement fork so downstream brainstorm/planning targets a single shape.
**Downsides:** Keeps the prose/checklist/drawer parse-boundary problem (#2/#3) in scope rather than avoiding it.
**Confidence:** 95%
**Complexity:** —
**Status:** Explored (decided)

### 7. Phased rollout: read-only render first, edit-back later

**Description:** Ship rendering of notes as read-only body (no allow-list entry, no parse-back) to
deliver the core win — notes finally visible in Emacs — on day one with zero round-trip risk. Add
editability once idea #4's oracle is green.
**Axis:** 1 (render)
**Basis:** `reasoned:` the "allow-list LAST" rule means a read-only render needs neither allow-list
nor parse, so it is safe immediately.
**Rationale:** Decouples the high-value visibility win from the high-risk round-trip; a natural increment.
**Downsides:** Read-only notes are a partial feature; needs a clear visual "read-only" affordance.
**Confidence:** 75%
**Complexity:** Low
**Status:** Unexplored

## Rejection Summary

| #  | Idea                                                                | Reason Rejected                                                    |
| :- | :------------------------------------------------------------------ | :----------------------------------------------------------------- |
| 1  | Alias `:supportNotes`→`:description` at model boundary              | Duplicates #1 (folded in)                                          |
| 2  | "Trust the existing parser unchanged"                               | Contradicted by #2 — parser is not safe unchanged for non-tasks    |
| 3  | Body-as-typed-segment-stream (preserve interleave)                  | Real fidelity feature but scope overrun for notes; separate effort |
| 4  | Semantic-idempotence-not-byte-stability reframe                     | Reopens a settled contract; better as a brainstorm variant         |
| 5  | Local-wins `#+MW_PIN` / continuous prose flush                      | Speculative; conflicts with the server-authoritative model         |
| 6  | OT on a prose lane / CRDT (Yjs, Loro, Automerge)                    | Too expensive vs diff3 for a two-endpoint sync                     |
| 7  | Genome annotation tracks / BGP prose-zone fence / sentinel comments | Exotic restatements of #3/#6                                       |
| 8  | Schema migration ledger                                             | Heavier restatement of #4                                          |
| 9  | Verbatim escrow for code/LaTeX spans                                | Valid edge-case hardening; folded into #4's fuzzer corpus          |
| 10 | Empty/nil normalization; link self-inverse fixpoint test            | Folded into #4 as required test cases                              |
