# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Relationships

The Shadow is the baseline the Content signature is computed against; a signature that differs from the Shadow's is what marks an entity changed. The Allow-list defines exactly which fields the signature covers. Reconcile is the only step that rewrites the buffer from merged server data, and it is the durable commit point a sync's side effects (Shadow update, Migration latch) are gated on. Round-trip byte-stability is the invariant that keeps the signature honest — without it, signatures churn even when nothing changed.

## Sync data model

### AppData
The full document synced between the local org buffer and the cloud over the `/v1/data` wire — the user's tasks, projects, sections, areas, and settings as a single structure. A sync GETs the server's AppData, merges, and PUTs a candidate AppData back.

### Namespace
A cloud-side data partition keyed to a user/account that holds exactly one AppData plus its settings. A freshly provisioned namespace has no settings yet, which is why first-contact (cold-start) behavior is a distinct case worth testing.

### Shadow
The client's locally persisted copy of the last-known-server AppData. It is the baseline for change detection (the buffer is compared against it, not against the server directly) and the holding place for server-only fields that the org buffer cannot represent — those are preserved verbatim in the Shadow and merged back on write rather than being dropped.

### Candidate
The AppData this client proposes to the server on a sync: the local buffer's parsed state merged with the server-only fields preserved from the Shadow, then stamped and PUT as the client's bid. It is distinct from the Shadow it is built from (the last-known-server baseline) and from the merged AppData the server returns, which the buffer is then Reconciled to. The stripped-for-transport form of the Candidate — internal-only keys removed before the PUT — is sometimes called the wire form.

### Tombstone
A deleted entity that still travels in AppData — a soft-delete marker carrying a deletion timestamp rather than an absent record — so every client learns of the deletion on its next sync instead of having to infer it from absence.

A tombstone retains its content fields and adds only the deletion marker, and that marker is a server-only field outside the Allow-list — so a tombstoned entity has the same Content signature as its live form. Deletion is therefore invisible to signature comparison and must be detected from the tombstone marker directly, never inferred from a signature difference. A delete this client pushed is told apart from one pulled from the server by whether the deletion marker is present in the Candidate it sent.

## Change detection

### Content signature
A hash over an entity's content used to decide whether it changed: the client compares the signature of the parsed buffer entity against the signature of its Shadow copy, and a difference means "user edited this." Set-valued and lossy fields are normalized before hashing (e.g. order-insensitive sets are sorted, timestamps coarsened) so the signature reflects meaning, not incidental formatting.

### Allow-list (content fields)
The explicit set of fields that round-trip through the org representation and therefore define the Content signature — deliberately an allow-list, never a deny-list. A field not on it is invisible to change detection by construction: it can neither drift a signature nor be clobbered, because it is preserved in the Shadow and merged back unchanged. A field is added to the allow-list only after it is proven to round-trip byte-stably (allow-list-LAST).

### Round-trip byte-stability
The invariant that rendering a value into the buffer and parsing it back (and re-rendering) reproduces identical bytes — the rendered form is a fixed point. A transform that is not its own inverse makes a value differ from itself on every sync, so its signature phantom-churns and the local side wins every last-write-wins merge even when the user changed nothing.

### Migration latch
A one-way, per-client persisted flag that records "this client has rendered a newly-signed field at least once." It guards the deploy seam created when a previously-unsynced field is promoted onto the Allow-list: until the flag is set, an empty parse of that field is treated as "not yet migrated" (keep the server value) rather than "user cleared it" (push the empty value).

The latch must flip only *after* a confirmed durable save of the re-rendered buffer — flipping it on intent (before the save confirms) would drop the protection while the on-disk buffer is still stale, re-exposing the very clobber it prevents on the next reload.

## Sync process

### Reconcile
The step that rebuilds the buffer from merged server data: it erases the buffer, re-renders the canonical AppData, and restores view state (folds, point). Because it is destructive-then-rebuild, it must collect anything it cannot represent *before* erasing, and it is the commit point that durable post-sync side effects (Shadow save, Migration latch) are sequenced after.

## Inbox triage

### Inbox
The capture bucket holding items that have not yet been clarified — the un-triaged entries that Clarify drains. An item leaves the Inbox when an Outcome relocates it (under a project, onto a someday list, into the calendar); trashing instead archives it in place, so it stays in the buffer but is no longer an Inbox item.

### Clarify
The guided session that walks the Inbox one item at a time, loading each into a working buffer so the user can decide and apply a single Outcome before the session advances to the next item.

Each item receives exactly one Outcome per pass. The session tracks its remaining queue by stable entity identity, not by buffer position, so an Outcome that leaves an item in place (trash) still advances correctly, and an item that has left the Inbox by other means is skipped rather than re-presented.

### Outcome
The decision applied to one Inbox item during Clarify, drawn from a fixed set that mirrors the GTD next-action question — make it a next action, file it under a project, defer it to someday, schedule it onto the calendar, mark it reference, delegate it, or trash it. Most Outcomes relocate the item out of the Inbox; trash is the one that leaves it in place.
