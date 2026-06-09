---
title: "First PUT to a fresh namespace 500s: server null-derefs settings.syncPreferences"
date: 2026-06-09
category: integration-issues
module: mindwtr-sync / mindwtr-model
problem_type: integration_issue
component: tooling
symptoms:
  - "HTTP 500 on the very first PUT to a freshly provisioned (settings-less) namespace"
  - "First sync / bootstrap against a fresh self-hosted server fails"
  - "Dockerized integration smoke suite fails on the first write of the lifecycle"
  - "Client sends settings as JSON null and the server crashes instead of rejecting it"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags:
  - sync
  - settings
  - null-deref
  - fresh-namespace
  - integration-test
  - bootstrap
  - http-500
  - client-defense
---

# First PUT to a fresh namespace 500s: server null-derefs settings.syncPreferences

## Problem

A client's *first* `PUT /v1/data` against a freshly provisioned (settings-less) Mindwtr Cloud namespace crashed the server with HTTP 500. This was not hypothetical: it surfaced when the new dockerized integration test in PR #34 stood up a *real* cloud server (`ghcr.io/dongdongbh/mindwtr-cloud`) on an ephemeral, empty volume and ran the Emacs smoke write-lifecycle against it. The first write of the lifecycle 500'd.

The root cause is server-side: the Cloud server's settings merge (`mergeSettingsForSync`) dereferences the incoming `settings.syncPreferences` with no null guard. A brand-new namespace has no settings yet, so the client's outbound AppData carried an absent/null `settings`, the server walked into `settings.syncPreferences` on a null, and the request 500'd before anything was persisted.

This blocks the *first* sync for anyone bootstrapping against a fresh or self-hosted server — exactly the cold-start path, so it cannot be worked around by "just sync again." The fix is client-side: the client must never hand the server a null settings blob.

## Symptoms

- `PUT /v1/data` returns HTTP 500 on the first write to a namespace that has never held settings.
- The dockerized smoke suite (`make smoke-docker`) fails at the inbox→next→done→delete write lifecycle, on the first PUT.
- `mindwtr-bootstrap` against a fresh self-hosted server renders fine on GET but the first subsequent sync dies.
- The crashing payload is one where `settings` is JSON `null` (or absent) — every other field (`tasks`/`projects`/`sections`/`areas`) is well-formed.

## What Didn't Work

- **Treating it as a transient server error / retrying.** The namespace is still settings-less on the next attempt, so every PUT 500s identically. It is deterministic, not flaky.
- **Sending an empty object `settings: {}`.** This does not survive the Emacs JSON round-trip — the encoder collapses empty objects back to JSON `null`, so the server still receives null and still 500s. The default must carry at least one non-empty key.
- **Waiting for the server fix.** The dereference is in the server's `mergeSettingsForSync`; the Emacs client cannot patch it, and shipping a client that bricks first-sync against any fresh/self-hosted server is unacceptable. The client has to defend itself.

## Solution

Synthesize a minimal, non-null `settings` object on the client whenever the namespace has none, so every outbound PUT (and the bootstrap snapshot) carries a real settings blob. The default lives in `mindwtr-model.el`:

```elisp
(defun mindwtr-model-default-settings ()
  "Return a fresh, minimal non-null `settings' object for a new namespace."
  (list :syncPreferences (list :initialized t)))
```

It deliberately carries a single non-empty key, `:syncPreferences` → `(:initialized t)`. Two reasons: (1) `syncPreferences` is the exact field the server's merge reads first, so it is guaranteed present; and (2) a non-empty object survives the encoder (an empty object would collapse to JSON null again). It encodes to `{"syncPreferences":{"initialized":true}}`.

The synthesis was originally inlined at the two write/render sites (commit `77ec2da`, "fix(sync): create initial settings so a fresh namespace accepts writes"), then consolidated into one normalizer (commit `207bb5b`, "refactor(settings): consolidate non-null-settings guard into one helper"):

```elisp
(defun mindwtr-model-ensure-settings (appdata)
  "Return APPDATA with a guaranteed non-null `settings'."
  (if (plist-get appdata :settings) appdata
    (plist-put (copy-sequence appdata) :settings (mindwtr-model-default-settings))))
```

Note it `copy-sequence`s rather than mutating the caller's structure, and returns present settings unchanged.

**Three injection sites**, all now routed through `mindwtr-model-ensure-settings`:

1. **`mindwtr-sync-build-candidate` (`mindwtr-sync.el`)** — every outbound candidate is normalized up front:

   ```elisp
   ;; Guarantee non-null settings up front: a fresh namespace has none in its
   ;; shadow yet, and the server's settings merge 500s on a null blob.
   (setq shadow (mindwtr-model-ensure-settings shadow))
   ```

2. **`mindwtr-bootstrap` (`mindwtr.el`)** — the bootstrap snapshot stamps initial settings so the shadow/local reflect them immediately:

   ```elisp
   (appdata (mindwtr-model-ensure-settings (plist-get got :appdata)))
   ```

3. **`mindwtr-sync-once` GET path (`mindwtr-sync.el`)** — normalize on the way *in* too, so that if the server ever returns a null/absent settings, the shadow stays consistent now instead of relying on the next cycle to re-synthesize:

   ```elisp
   (merged (mindwtr-model-ensure-settings (plist-get got :appdata)))
   ```

**Before**: an inlined `or` form in `build-candidate`, a *separate* `if`/`plist-put` form in `mindwtr-bootstrap`, and **no guard at all** on the `mindwtr-sync-once` GET path — which meant a server-returned null could propagate straight into the shadow. **After**: one helper, three call sites, identical semantics, and the previously-unguarded GET path now covered.

## Why This Works

The defect is a server-side missing-validation gap: `mergeSettingsForSync` dereferences `settings.syncPreferences` without first checking that `settings` is non-null. The server *should* reject (4xx) or default a null settings blob; instead it crashes (5xx).

The client cannot fix the server, so it removes the only input that triggers the crash. By guaranteeing that every PUT and every bootstrap snapshot carries a non-null `settings` whose `syncPreferences` is a real object, the server's unguarded dereference always lands on a valid value. The minimal `{"syncPreferences":{"initialized":true}}` is the smallest payload that (a) is non-null after JSON encoding and (b) populates the exact field the merge reads first.

This is a robust client-side fix for a server-side gap, and it is the right layering even setting the bug aside: a fresh namespace legitimately *should* be initialized with default settings on first contact, rather than left in a null state for the server to interpret. The client is now well-behaved regardless of whether the server ever adds its own null guard.

## Prevention

- **The integration test that catches it.** PR #34's dockerized smoke (`test/integration/run.sh`, `make smoke-docker`) provisions a real cloud server on an **ephemeral named volume so every run starts from an empty namespace**, then runs the full write lifecycle against it. This is what surfaced the 500 in the first place — a unit test with a mocked server would never have, because the crash lives in the server's merge. *Cold-start against a real server is the only thing that exercises the fresh-namespace path.*
- **Second independent client.** `run.sh`'s curl cross-check now also PUTs non-null settings (`settings: { syncPreferences: { initialized: true } }`) with an inline comment pointing back to this same server gap — so the curl client mirrors the Emacs client's defense rather than re-triggering the 500.
- **Unit pins on the synthesis.** `test/mindwtr-sync-test.el` pins that a settings-less shadow yields `mindwtr-model-default-settings` in the candidate (`mindwtr-sync-candidate-creates-initial-settings-when-absent`), and `test/mindwtr-test.el` pins that `mindwtr-bootstrap` synthesizes a non-null `syncPreferences` blob when the server GET returns no `settings` key (`mindwtr-bootstrap-synthesizes-initial-settings-when-server-has-none`, confirmed non-vacuous: it fails when the synthesis is removed).
- **General rule.** When a remote endpoint may crash on a degenerate input you control, defend at the client boundary by normalizing to a valid, minimal value — and verify the fix against a *real* server on a *fresh* namespace, not a mock. Mocks encode your assumptions about the server; the bug was in the server's assumptions about you.

## Related Issues

- GitHub PR #34 — dockerized integration smoke + curl cross-check, which surfaced this 500.
- Follow-up commits: `77ec2da` (initial client-side fix), `032b2fe` (test pins for the synthesis), `207bb5b` (consolidation into `mindwtr-model-ensure-settings`).
- [[json-encoding-gotchas-emacs-server-boundary]] — same Emacs↔server sync boundary; directly relevant here, since the "empty object collapses to JSON null through the encoder" gotcha is *why* the default must carry a non-empty key.
