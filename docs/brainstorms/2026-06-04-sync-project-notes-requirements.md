---
date: 2026-06-04
topic: sync-project-notes
issue: 31
ideation: docs/ideation/2026-06-04-sync-project-notes-ideation.md
---

# Sync Project & Section Notes

## Summary

Make project and section notes first-class, round-tripped content in the org
file: rendered inline under the entity heading like task descriptions, editable
at the desk, and synced back to the server. This brings the org file to parity
as the source of truth for notes that today exist only on mobile.

---

## Problem Frame

mindwtr treats the single org file as the source of truth for a user working at
their desk — Emacs proposes changes, the server reconciles. But note-bearing
content on non-task entities never reaches the buffer. Projects carry notes in
`:supportNotes`, kept only in the local shadow snapshot, so they are invisible
and uneditable in Emacs. Sections carry `:description`, which is already a synced
content field but is never rendered. Both are blocked because body-prose
rendering is gated to tasks only.

The cost lands on the one workflow the product is built around: a user who keeps
the org file as their source of truth literally cannot see or edit a project's
notes at the desk. They have to switch to mobile to read or change them, which
contradicts "the org file is the source of truth." This is also the first synced
field where a lost edit is a paragraph of real prose rather than a flipped
scalar — raising the stakes on getting round-trip and conflict behavior right.

---

## Key Decisions

- **Full read + write round-trip, not a phased read-only step.** Notes are both
  rendered into the buffer and parsed back out so desk edits sync. Shipping
  read-only visibility first was considered and rejected — the complete feature
  is the goal.

- **Notes render inline as body prose, not as a dedicated `** Notes` subtree.**
  They read the same way task descriptions already do. The subtree alternative
  would have sidestepped the prose-vs-checklist/drawer parse boundary, but
  diverging the read experience from tasks wasn't worth it; the parse-boundary
  work stays in scope instead.

- **Conflicts reuse the existing server-authoritative model.** Revision-aware
  last-write-wins with server-wins on ties; any local note edit the server
  overrode is surfaced in the sync report. No prose-specific diff, recovery, or
  merge — a clobbered note is reported like any other overridden field, not
  recovered.

- **For projects and sections, checkbox lines are prose.** These kinds have no
  checklist field, so a `- [ ]` line in their notes is preserved as literal text
  and round-trips unchanged — it never becomes a tracked checklist. (Tasks keep
  their existing checklist behavior; the task-side checkbox-vs-description
  earmark is a separate concern tracked in issue #33.)

- **Scope is projects and sections only.** Areas have no notes or description
  field in the synced schema, so they are out by construction.

The note-bearing fields by entity kind:

| Kind | Notes field | Synced today? | Rendered today? |
|---|---|---|---|
| Task | `:description` | yes | yes |
| Section | `:description` | yes | no (render-gated) |
| Project | `:supportNotes` | no (shadow only) | no |
| Area | — | — | — |

---

## Requirements

**Visibility & editing**

- R1. A project's notes render as inline body prose under the project heading,
  in the same position and shape as a task description.
- R2. A section's notes render as inline body prose under the section heading,
  in the same shape as R1.
- R3. Edits a user makes to project or section notes in the buffer are parsed
  back out and proposed to the server on the normal save-then-sync cycle — no
  new sync trigger or gesture.
- R4. Project notes participate in change detection as synced content (promoted
  from shadow-only), so an edit is detected and an unchanged note produces no
  spurious change.

**Round-trip fidelity**

- R5. Note text is byte-stable across render → parse → render: an unedited note
  never phantom-churns the content signature on a sync.
- R6. Non-ASCII note content round-trips unchanged.
- R7. Markdown↔org link conversion in notes reuses the existing converters and
  is its own inverse, so links don't churn the signature.
- R8. An empty or absent note and an empty-string note are treated equivalently,
  producing no body and no phantom change.

**Parse boundaries**

- R9. For projects and sections, a `- [ ]` line within notes is preserved as
  literal prose and round-trips unchanged; it is not reclassified as a checklist.
- R10. Drawers, planning lines, and clock entries on a project or section
  heading are preserved across a sync and are not absorbed into or displaced by
  the notes prose.

**Conflict & safety**

- R11. When the server overrides a local note edit, the override is surfaced in
  the sync report the same way other overridden fields are — named, not silently
  dropped, and not specially diffed or recovered.
- R12. Any note content the parser cannot place is quarantined under
  `* Sync Failures`, never dropped — the existing safe-by-default reconcile
  guarantee holds for the new body content.

---

## Acceptance Examples

- AE1. **Covers R5, R6.** Given a project with a note containing a non-ASCII
  paragraph, when the user syncs without editing it, then the content signature
  is unchanged and no override or change is reported.
- AE2. **Covers R9.** Given a user types `- [ ]` followed by text into a
  project's notes and syncs, when the note round-trips, then the line is still
  present as literal text and no checklist item was created on the project.
- AE3. **Covers R10.** Given a project heading has a LOGBOOK drawer and notes,
  when the user edits the notes and syncs, then the drawer survives intact and
  the notes update.
- AE4. **Covers R11.** Given a user edits a project note in Emacs while the same
  note was changed on mobile, when the sync resolves server-wins, then the org
  buffer shows the server's note and the sync report names the overridden local
  edit.

---

## Scope Boundaries

**Deferred for later**

- Three-way prose merge using the shadow as a common ancestor (so non-overlapping
  desk and mobile edits both survive) — valuable but a follow-up to basic
  round-trip.
- Read-only-first rollout as an intermediate shipping mode — collapsed into the
  full round-trip feature.

**Out of scope**

- Area notes — no synced notes/description field exists.
- Task-side checkbox-vs-checklist earmark convention — tracked in issue #33.
- Prose-aware override reporting (showing the overwritten text for paste-back) —
  the existing override report is sufficient.

---

## Success Criteria

- A user can read and edit any project's or section's notes entirely at the desk,
  with no need to switch to mobile to see or change them.
- The offline correctness gate (`make test`) and byte-compile pass, including new
  round-trip and symmetry coverage for project/section notes across the kind ×
  prose-field matrix.
- At least one non-ASCII note is exercised through a write-path smoke run before
  shipping (equality-based round-trip tests can mask a symmetric encoder bug).
- No regression in existing task-description round-trip, view-state restore, or
  the false-drift guard.

---

## Dependencies / Assumptions

- Promoting `:supportNotes` from shadow-only to a synced content field must
  happen only after byte-stable round-trip is proven — a prior premature
  allow-list addition drove 30/32 entities to false-drift on every sync.
- The reconcile path that currently returns the entire non-task body verbatim
  must stop owning notes prose before render starts emitting it, or both paths
  claim the same bytes and notes double-graft. This sequencing is load-bearing
  and belongs to planning.
- View-state anchoring must survive a body whose length changes when notes are
  added or edited.

---

## Sources / Research

- Ideation: `docs/ideation/2026-06-04-sync-project-notes-ideation.md` — ranked
  ideas, rejected alternatives, and the per-kind prose-field framing this doc
  inherits.
- The render gate, parse checklist regex, and the verbatim non-task
  preserved-body path are the three sites a planner will touch; see
  `mindwtr-render.el`, `mindwtr-parse.el`, `mindwtr-reconcile.el`, and the
  content-field definitions in `mindwtr-model.el`.
- `docs/solutions/` — load-bearing learnings on allow-list-last ordering,
  self-inverse text transforms, sole-serializer reconcile, and safe-by-default
  quarantine.
- Prior art (item-level LWW in org-caldav/Joplin/Obsidian; Zotero three-pointer
  merge; CalDAV `If-Match`) is relevant only if the deferred three-way merge is
  later picked up.
- Related: issue #33 (task description vs checklist earmark).
