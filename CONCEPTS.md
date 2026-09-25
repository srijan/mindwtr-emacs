# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Relationships

The Shadow is the baseline the Content signature is computed against; a signature that differs from the Shadow's is what marks an entity changed. The Allow-list defines exactly which fields the signature covers. Reconcile is the only step that rewrites the buffer from merged server data. The engine's save of the reconciled buffers is the durable commit point: the Shadow is committed after it, and a Migration latch flips only if that save succeeded. Round-trip byte-stability is the invariant that keeps the signature honest — without it, signatures churn even when nothing changed.

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
A one-way, per-client persisted flag that records "this client has rendered a newly-signed field (or a new render surface) at least once." It guards the deploy seam created when a previously-unsynced field is promoted onto the Allow-list, or when a surface such as the Archive surface starts taking part: until the flag is set, an empty parse of that field is treated as "not yet migrated" (keep the server value) rather than "user cleared it" (push the empty value).

The latch must flip only *after* a confirmed durable save of the re-rendered buffer — flipping it on intent (before the save confirms) would drop the protection while the on-disk buffer is still stale, re-exposing the very clobber it prevents on the next reload.

## Sync process

### Sync cycle
One round trip of the sync engine: parse every surface into a Candidate, check whether anything changed locally or remotely, PUT the Candidate, GET the server's merged AppData, Reconcile each surface to it, save, and commit the Shadow. A cycle runs asynchronously across network callbacks, so everything a later stage needs is carried on the cycle itself rather than in a local binding. Only one cycle may be in flight at a time: a trigger that arrives while one is running (a timer, a retry, a manual sync) stands down, and a cycle aborts before its PUT if the user edits the buffer while it waits on the network.

### Reconcile
The step that rebuilds the buffer from merged server data: it replaces the buffer's contents with a fresh canonical render of the AppData and restores view state (folds, point). The replacement is a diff, so positions other buffers hold (an open agenda's lines) stay on their headings, but anything the render does not reproduce is still removed. Reconcile must therefore collect whatever it cannot represent *before* the rebuild and set it aside in Quarantine.

Reconcile is followed by the engine's own save of each rebuilt buffer, and that save, not the rebuild, is what durable post-sync side effects are sequenced after: the Shadow is committed once the saves have run, and a Migration latch flips only when every save succeeded.

### Quarantine
The holding area, a `Sync Failures` container heading, where Reconcile re-emits verbatim any heading it could not place, so an unplaceable heading is set aside instead of being dropped by the rebuild. A heading lands there when it has no entity type and none can be inferred from its position, or when it has a blank title and matches nothing the server returned. Quarantined content does not sync; the user gives it a type or moves it under a list container, and the next sync picks it up.

### Archive surface
A second synced render surface — its own org file (`mindwtr_archive.org`) — that holds exactly the entities the main render drops for being archived. "Archived" becomes a status whose render surface is a *different file*, not an entity that vanishes: one sync cycle iterates a list of surfaces (main first, archive appended when active), parse-merging them by id with the earlier surface winning collisions, and Reconciling each with its own renderer. Because the archive file is regenerated from merged data every full cycle (never an append log), dedup is automatic, cloud-side archives appear on Reconcile, and un-archiving or deleting are ordinary parse-side changes — no pending-push ledger or dedup tracking is needed.

Containment crosses the file split via explicit `MW_PROJECT_ID`/`MW_SECTION_ID` drawer properties: an archived task whose project still lives in the main file cannot nest under it, so the archive render emits the parent id and the parser honors it over outline ancestry. These are not new content fields (no signature migration); they only relocate where ancestry is read from.

The archive surface has its own Migration latch (`archive-migrated`): an archived entity absent from local state means deletion (Tombstone) only *after* the surface has been durably rendered once. Before that — and whenever the archive file is missing from disk — a missing archived entity is echoed verbatim instead, so the first post-upgrade sync can never read the not-yet-created archive file as a mass deletion. This strict-vs-echo behavior is a dynamic mode, off by default, so legacy single-file behavior is byte-identical when the surface is inactive.

The latch guards the deploy seam; a second gate guards the steady-state seam. Even with the latch set and the file present, strict deletion semantics are withheld for a cycle when the archive buffer parsed with a degraded heading (an `MW_ID` heading that produced no entity — e.g. a hand-edit that removed `MW_TYPE`) or when the file came back empty while the Shadow still holds archived entities. In both cases an absent archived entity is more likely a parse or truncation fault than a deletion, so the cycle echoes (and re-backfills) instead of tombstoning. The one accepted cost: deleting the *last* archived item by emptying the file is deferred to the next cycle that carries another archived heading.

## Task status

### Status
The GTD-style resting keyword that names a task's or project's workflow state — for a task, drawn from the next-action vocabulary (inbox, next, active, someday, waiting, and the like) and carried by the org TODO keyword, so the keyword *is* the status; for a project it names the project's own state (active, someday, waiting, archived).

The two vocabularies overlap — a waiting task and a waiting project carry the same TODO keyword, as do someday and archived — so the keyword names the *status* but not the *entity type*. Whether a heading is a task or a project is a separate dimension; a query that selects on a shared keyword (e.g. waiting) without also constraining on entity type will mix tasks and projects together.

A task's status is independent of its parent's: a project's deferral (someday, waiting) is carried by the task's container placement, never cascaded onto the task's own keyword. So a keyword-less task created inside a project rests at next — actionable — whatever the project's status, while a keyword-less task with no container parent rests at inbox. This independence matches upstream, which leaves a task's status untouched when its project becomes someday.

### Tickler
A next action deferred to a future start date so it stays out of actionable views until that date arrives — the result of the defer-to-a-date Outcome during Clarify. It is a next-status task carrying a start date (not a due date): the start date gates *when it becomes actionable*, distinct from a deadline, which gates *when it is due* and leaves the task actionable before then.

A future tickler is suppressed from the actionable next-actions surface until its start date and resurfaces on the day it lands; a tickler dated today is actionable now, and one whose start date has passed (an overdue tickler) stays listed rather than disappearing. Only a strictly-future start date defers — this is why a surface that lists next actions must consult planning dates explicitly, since a plain keyword query ignores them.

## Agenda views

### Engage
The daily "what do I act on now" agenda surface, gathering today's focused items, next actions, the items you have delegated and are waiting on, the inbox, and the day's calendar into one view. Named for GTD's engage phase — choosing what to do in the moment. Its delegated-items block lists waiting *tasks* only; a waiting project is not a delegated action and belongs to the Projects view. Every block hides tasks owned by a Parked project, and the next-actions block also hides future Ticklers and the blocked steps of a Sequential project.

### Parked project
A project the user has set aside, by giving it someday or waiting status, so that none of its tasks appear in any actionable list until it becomes active again or is explicitly pinned as focused. The nearest project ancestor decides, so an active project nested under a parked one keeps its own steps actionable. The project itself still lists in the Projects view.

### Sequential project
A project whose steps are done one at a time: exactly one open step holds the project's slot and is actionable, and every other step is a blocked step, hidden from next actions. The slot goes to the step ranked first on focus and timing (a focus pick, a due or overdue review, a date), with outline order breaking ties, so it is not simply the first step in the outline. Waiting and focus lists are not filtered by the sequence.

### Projects
The project-review agenda surface, listing the multi-step outcomes themselves rather than individual actions: active projects (stuck ones flagged for attention) and the projects you are waiting on, each under its own block. Complements Engage, which is scoped to actions.

## Inbox triage

### Inbox
The capture bucket holding items that have not yet been clarified — the un-triaged entries that Clarify drains. An item leaves the Inbox when an Outcome relocates it (under a project, onto a someday list, into the calendar, or — for trash with the Archive surface active — into the archive file; with the surface inactive, trash leaves it in place to be dropped on the next sync).

### Clarify
The guided session that walks the Inbox one item at a time, loading each into a working buffer so the user can decide and apply a single Outcome before the session advances to the next item.

Each item receives exactly one Outcome per pass. The session tracks its remaining queue by stable entity identity, not by buffer position, so an Outcome still advances correctly whether it relocates the item (including a trash that refiles it into the Archive surface, so the heading vanishes from the source) or leaves it in place, and an item that has left the Inbox by other means is skipped rather than re-presented.

### Outcome
The decision applied to one Inbox item during Clarify, drawn from a fixed set that mirrors the GTD next-action question — mark it already done (a two-minute quick action), make it a next action, file it under a project, defer it to someday, schedule it onto the calendar, mark it reference, delegate it, or trash it. Every Outcome relocates the item out of the Inbox — trash into the Archive surface when active (or in place when inactive, to be dropped on the next sync).

An Outcome both relocates the item and assigns it the resting Status its destination implies — the two are one operation, not relocation alone. Filing an item under a project makes it a next action; leaving it at inbox would contradict the destination. Because the inbox keyword is an explicit Status (not an absent one), nothing downstream re-derives it from the new location, so the Outcome itself must set it.
