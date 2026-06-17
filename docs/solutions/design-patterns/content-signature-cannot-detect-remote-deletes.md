---
title: "Content signature cannot detect remote deletes: test the tombstone before the signature gate"
date: 2026-06-09
category: design-patterns
module: mindwtr-sync / mindwtr-signature
problem_type: design_pattern
component: tooling
severity: high
applies_when:
  - "Using mindwtr-signature equality as an unchanged / own-edit gate in change detection"
  - "Classifying an incoming entity as a delete, update, or no-op during sync"
  - "Adding a field to mindwtr-model-shadow-only-fields rather than mindwtr-model-content-fields"
  - "Writing tests for delete handling (tombstone fixtures must retain content fields)"
tags: [change-detection, signature, content-signature, tombstone, delete-detection, shadow-only, sync]
---

# Content signature cannot detect remote deletes: test the tombstone before the signature gate

## Context

Mindwtr's change detection is built on **content signatures** — `mindwtr-signature`
(`mindwtr-signature.el`) returns a SHA-256 over only an entity's editable content
fields. The hashed surface is deliberately narrow: `mindwtr-signature--canonical-plist`
iterates the **allow-list** `mindwtr-model-content-fields` and nothing else, so unmapped
and server-managed fields can neither drift the signature nor leak into change detection
(see [[content-signature-allow-list-not-deny-list]]).

The sync engine leans on this signature in two places that decide *intent*, not just
"did bytes change":

- `mindwtr-sync--classify` (local-vs-shadow) returns only `create` / `update` /
  `unchanged`. It **never returns a delete** — deletes are handled separately in
  `mindwtr-sync-build-candidate`, where a live shadow entity absent from the buffer is
  tombstoned.
- `mindwtr-sync--incoming-changes` (wire-vs-merged-vs-shadow) reports the remote
  `created` / `updated` / `deleted` changes the user did not push, and uses an
  **own-edit gate** — `(string= (mindwtr-signature m) (mindwtr-signature w))` — to filter
  out this device's own accepted edits.

A remote delete turns a live entity into a **tombstone**. On the real Mindwtr server a
tombstone *retains its content fields* and merely adds `:deletedAt`. But `:deletedAt` is in
`mindwtr-model-shadow-only-fields`, not in `mindwtr-model-content-fields` — so it is
**excluded from the signature by construction**. The consequence: the content signature of
a live entity and its tombstone are **byte-identical**. The only field that changed is the
one field the signature cannot see.

This is visible in the fixtures: the reconcile tombstone at
`test/mindwtr-reconcile-test.el` (the `mindwtr-reconcile-removes-tombstoned` test) —
`(:id "t1" :title "gone" :status "next" :areaId "a1" :deletedAt "2026-06-01T00:00:00Z" :rev 2)` —
keeps every content field; only `:deletedAt`/`:rev` are added, and neither is signed.

## Guidance

When classifying entity changes by signature, **test for deletion before any
signature-equality gate.**

1. **Delete first.** Check for a tombstone (`:deletedAt` set in the merged/server view) or
   the entity being absent entirely *before* you consult `mindwtr-signature`. A delete must
   never be inferred from a signature diff — the signature cannot represent it.
2. **Distinguish own vs remote deletes by provenance, not by signature.** A delete this
   device pushed carries `:deletedAt` in the candidate/`wire`; a remote delete does not.
   Decide ownership with `(and w (plist-get w :deletedAt))`, never by comparing signatures
   (which are equal on both sides of any delete).
3. **Only then run the signature gate** to filter out the device's own accepted
   creates/updates, and the merged-vs-shadow comparison to separate remote creates from
   remote updates.

This is exactly the ordering encoded in `mindwtr-sync--incoming-changes` and documented in
its docstring: *"This delete test runs BEFORE the signature gate below: a server tombstone
keeps its content fields and `:deletedAt` is shadow-only, so a remote delete has an
unchanged content signature and the own-edit gate would otherwise mis-skip it."*

## Why This Matters

If the signature gate runs first, a remote delete reads as **"unchanged" / "own accepted
edit"** — its signature matches the wire entity's — and is silently dropped. In the
incoming-changes feature this would mean remote deletes (e.g. the mobile app deleting a
project) **never appearing in the sync report**, directly violating the "no surprises"
guarantee that feature exists to uphold.

The trap is sharpened by a **fixture/reality mismatch**: it is tempting to write unit tests
where the tombstone has its content stripped (so `sig(live) != sig(tombstone)` and a naive
signature-diff *appears* to detect the delete). Those tests pass while the *real* server
path silently fails, because the real server **retains tombstone content**. A correct test
must use a content-bearing tombstone — see
`mindwtr-sync-incoming-reports-remote-delete-with-content-tombstone` in
`test/mindwtr-sync-test.el`, whose `merged` keeps `:title "doomed" :status "next" :areaId "a1"`
and only adds `:deletedAt`, asserting the change is still reported `deleted`.

This is the delete-shaped corollary of the allow-list invariant: that doc explains *what*
the signature signs; this one documents a non-obvious operational hazard the invariant
*creates* — deletes live entirely in the shadow-only field set, so signature equality
cannot see them. It is the same family of signature-equality misfire as
[[reconcile-partial-update-reverts-remote-edits]], with a twist: a delete is **not**
solvable by rebuild-through-renderer (a tombstone has no heading to rebuild), so the
signature gate must be *bypassed before* it runs, not corrected after.

## When to Apply

- Writing any **new change-detection, diff, or reconciliation logic** over signed entities
  in this codebase. (Issue #5 — full incremental reconciliation via signature-diffed
  in-place rewrite — would inherit this blind spot and must special-case tombstones outside
  the diff.)
- Reviewing any code that treats `mindwtr-signature` equality as **"nothing changed"** —
  confirm a delete branch precedes it.
- Authoring **tests** for delete handling — ensure tombstone fixtures retain content
  fields, mirroring the server, not a stripped contrivance.
- Any future field that, like `:deletedAt`, lives in `mindwtr-model-shadow-only-fields`: a
  change to it is invisible to the signature and needs its own explicit detection path.

## Examples

**The realistic tombstone proving `sig(live) == sig(tombstone)`** (the two entities differ
only in unsigned fields):

```elisp
;; live entity (in WIRE / SHADOW)
(:id "t1" :title "doomed" :status "next" :areaId "a1")
;; server tombstone (in MERGED) — same content, only :deletedAt/:rev added
(:id "t1" :title "doomed" :status "next" :areaId "a1"
     :deletedAt "2026-06-01T00:00:00Z" :rev 2)
;; :deletedAt and :rev are shadow-only, excluded from mindwtr-model-content-fields
;; => (mindwtr-signature live) == (mindwtr-signature tombstone)
```

**WRONG — signature gate before the tombstone test (remote delete silently skipped):**

```elisp
(cond
 ((and w (string= (mindwtr-signature m) (mindwtr-signature w)))
  nil)                                  ; <- tombstone matches WIRE's sig, treated
                                        ;    as "own accepted edit" and DROPPED
 ((plist-get m :deletedAt)             ; <- never reached for a content-bearing
  ...report 'deleted...))              ;    tombstone
```

**RIGHT — tombstone test first, ownership by `:deletedAt` in `wire`** (the actual shape in
`mindwtr-sync--incoming-changes`):

```elisp
(let* ((s (gethash id s-idx))
       (w (gethash id w-idx))
       (s-live (and s (not (plist-get s :deletedAt)))))
  (cond
   ((plist-get m :deletedAt)                      ; delete test FIRST
    (when (and s-live (not (and w (plist-get w :deletedAt))))
      (push (list :id id :kind kind               ; remote delete -> report it
                  :title (mindwtr-model-entity-title s)
                  :change 'deleted)
            out)))
   ((and w (string= (mindwtr-signature m)         ; THEN own-edit signature gate
                    (mindwtr-signature w)))
    nil)
   ((null s) ...remote 'created...)
   ((not (string= (mindwtr-signature m)           ; merged-vs-shadow -> 'updated
                  (mindwtr-signature s)))
    ...remote 'updated...)))
```

Note the own/remote distinction: `(and w (plist-get w :deletedAt))` asks *"did this device
push the tombstone?"* — provenance — never a signature comparison, since signatures are
equal on both sides of any delete.

Since PR #49 the `'updated` branch additionally carries `:before s :after m` on its plist
(only `updated`, not `created`/`deleted`), so the report can render a per-field diff; the
delete path shown above is unchanged. See
[[single-classifier-feeds-summary-and-detail]].

## Related

- [[single-classifier-feeds-summary-and-detail]] — the symmetric proposed/incoming report
  built on this classifier: its `mindwtr-sync--local-changes` reuses the same `--classify`
  and the same three-part delete guard documented here.
- [[content-signature-allow-list-not-deny-list]] — the field-set invariant this is the
  delete-blindness corollary of; the signature signs only `mindwtr-model-content-fields`.
- [[reconcile-partial-update-reverts-remote-edits]] — same signature-equality-misfire
  family (a stale local value re-PUT reverts a remote change); the delete case is the one
  that rebuild-through-renderer cannot fix.
- [[save-as-sync-commit-point]] — the post-PUT must-not-throw region the incoming-changes
  computation and report render sit in.
- Surfaced implementing the incoming-remote-changes feature (issue 11, PR #41). Constrains
  any future signature-diffed reconciliation (issue #5).
