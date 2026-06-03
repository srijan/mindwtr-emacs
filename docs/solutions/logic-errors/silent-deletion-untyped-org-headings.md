---
title: Silent deletion of untyped org headings on sync
date: 2026-06-03
category: logic-errors
module: mindwtr-parse / mindwtr-reconcile
problem_type: logic_error
component: tooling
symptoms:
  - "Headings added without :MW_TYPE: vanish on the next sync"
  - "org-capture and mobile-captured tasks silently disappear"
  - "Data loss with no error, warning, or sync-report entry"
  - "Duplicate MW_ID PUT to the server when a typed entity nests under an untyped heading"
  - 'Blank ":MW_TYPE:" value silently erases the heading'
root_cause: missing_validation
resolution_type: code_fix
severity: critical
tags: [data-loss, org-mode, sync-reconcile, type-inference, quarantine, safe-by-default, org-capture]
---

# Silent deletion of untyped org headings on sync

## Problem
A sync runs `mindwtr-sync-once` → parse buffer → PUT entities → GET merged →
`mindwtr-reconcile-buffer`, which `erase-buffer`s and re-renders the whole file from server
data. The parser only collected headings carrying a non-`container` `:MW_TYPE:`, so any
heading added without that property (via org-capture, a raw edit, or mobile) never entered
the parsed appdata, was never pushed to the server, and was therefore **erased by the full
rebuild — silently, with no warning.**

## Symptoms
- Headings authored without `:MW_TYPE:` disappear entirely on the next sync. An
  `** INBOX Test new issue from emacs` heading was confirmed present in one timestamped backup
  and gone in the next-sync backup.
- No error, warning, or sync-report entry fires — `mindwtr-parse--warnings` only records
  headings that *are* parsed but carry a type-invalid keyword, so an unparsed heading produces
  zero signal.
- Two adjacent gaps in the same data-loss class (found in code review):
  - A typed entity nested *under* an untyped heading could be swallowed into quarantine text
    while `mindwtr-parse-buffer` *also* synced and re-rendered it → duplicated heading and a
    duplicate `MW_ID` PUT that never self-healed.
  - A blank `:MW_TYPE:` value (a raw edit that left the property empty) interned to the truthy
    empty symbol, so it was treated as explicitly typed — dropped by parse, skipped by
    quarantine, and silently erased.

## What Didn't Work
**Prior behavior — destructive-by-default.** The parser's gate was
`(when (and kind (not (string= kind "container"))) …)`. Anything failing that test was dropped
from the parse, excluded from the PUT candidate set, then erased by reconcile's full rebuild.
The parser was the *sole* gate deciding what survives a sync:

```elisp
;; before — heading silently dropped if MW_TYPE absent/blank
(let ((kind (mindwtr-parse--prop "MW_TYPE")))
  (when (and kind (not (string= kind "container")))
    ...))
```

Rejected alternatives (from the plan doc and session history):
- **Adopt org-native `:ID:` as identity** — declined. A stray org `:ID:` is preserved as an
  unknown property but never becomes the entity id; `MW_ID` stays the sole sync identity.
- **Infer sections under projects** — declined as an accepted limitation. A hand-added heading
  under a project is inferred as a *task*, not a section; a section needs explicit
  `:MW_TYPE: section`.
- **Put quarantine in the renderer** — declined. `mindwtr-render-appdata` stays a pure
  AppData→org function; orphan collection and `* Sync Failures` re-emission live in the
  reconcile layer where buffer *text* is the unit of work.

## Solution
Close the hole fallback-first, in two layers, plus a convenience capture template.

**U1 — infer MW_TYPE from outline context (parser).** When `:MW_TYPE:` is absent or blank,
infer the entity kind from the nearest container's `:MW_LIST:` role plus project/section
ancestry:

```elisp
(defun mindwtr-parse--infer-kind ()
  (pcase (mindwtr-parse--ancestor-list-role)
    ((or "inbox" "single-actions" "someday-single-actions" "reference") 'task)
    ((or "projects" "someday-projects")
     (if (or (mindwtr-parse--ancestor-id 'section)
             (mindwtr-parse--ancestor-id 'project))
         'task 'project))
    ("areas" 'area)
    (_ nil)))
```

An explicit `:MW_TYPE:` always wins (inference is a pure fallback), and a **blank** value is
treated as absent so it routes through inference/quarantine instead of interning to the truthy
empty symbol:

```elisp
(defun mindwtr-parse--mw-type ()
  (let ((v (mindwtr-parse--prop "MW_TYPE")))
    (and v (not (string-empty-p v)) v)))

(let* ((mt   (mindwtr-parse--mw-type))
       (kind (cond ((null mt)               (mindwtr-parse--infer-kind))
                   ((string= mt "container") nil)
                   (t                        (intern mt)))))
  (when kind ...))
```

**U2 — quarantine un-inferable headings instead of erasing (reconcile).** Before the
`erase-buffer`, collect every heading that has no (non-blank) MW_TYPE and no inferable kind,
and re-emit it verbatim under a `* Sync Failures` container after the canonical render:

```elisp
(defun mindwtr-reconcile--orphan-heading-p ()
  (and (null (mindwtr-parse--mw-type))
       (null (mindwtr-parse--infer-kind))))

;; in mindwtr-reconcile-buffer — collect from the LIVE buffer BEFORE erase
(let ((orphans (mindwtr-reconcile--collect-orphans)))
  (erase-buffer)
  (insert rendered)
  (mindwtr-reconcile--emit-quarantine orphans))
```

`--collect-orphans` captures only an orphan's **own** heading + body (not its whole subtree)
and always descends, so a typed/inferable descendant is left to its canonical bucket — this is
the duplicate-MW_ID fix. An existing `* Sync Failures` container is itself recognized, so the
walk descends into it and re-collects its children individually, discarding the wrapper and
keeping quarantine **idempotent**. Emitting nothing when `orphans` is empty means a clean sync
produces no `* Sync Failures` heading.

**U3 — org-capture template (convenience).** New `mindwtr-capture.el` returns a template that
stamps `:MW_TYPE: task` and a freshly minted lowercase v4 `:MW_ID:`:

```elisp
(format "* %s %%?\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: %s\n:END:\n"
        (mindwtr-model-status->keyword 'task "inbox")
        (mindwtr-util-uuid))
```

This is belt-and-suspenders ergonomics — U1 inference and the existing lazy MW_ID minting at
sync remain the fallback for any heading that bypasses the template.

## Why This Works
The fix inverts the default from **destructive-by-default** to **safe-by-default**. Previously
the parser's gate was the single point deciding survival, and failing it meant silent erasure.
Now there are two safety nets before any data can be lost: inference reclassifies most untyped
headings into real entities that round-trip, and anything still un-inferable is preserved
verbatim under a visible, annotated `* Sync Failures` container. The guiding principle:
**a sync must never silently destroy user-authored content.** Quarantine + inference make loss
impossible-by-construction on the common paths and visible-and-recoverable on the residual
ones, with the timestamped backup as the ultimate net. Idempotent unwrap-and-regenerate of the
container means the safety net never accumulates cruft.

## Prevention
- **Drift guard test** — `mindwtr-parse-infer-kind-covers-every-entity-role` asserts every
  entity-bearing model list-role infers a kind, so adding a render-layer role without teaching
  the inference table **fails loudly here** instead of silently quarantining everything under
  the new bucket. The `sync-failures` role is asserted to stay *un*-inferable.
- **Reconcile coverage** — quarantine creation, idempotence (`= 1 "Sync Failures"` after two
  reconciles), no-quarantine-when-clean, unwrap-existing-container, the duplicate-MW_ID guard
  (`quarantine-excludes-typed-descendants` asserts `(= 1 (count ":MW_ID: t1"))`), and the
  blank-MW_TYPE orphan case.
- **Capture coverage** — `template-mints-lowercase-v4-id` (anchored RFC-4122 v4 regex) and
  `template-parses-as-inbox-task`.
- The durable guardrail: the reconcile layer treats "the parser couldn't place this" as a
  **preservation event, not a deletion event.** Any future destructive rebuild must collect
  what it cannot represent *before* erasing.

## Related Issues
- GitHub issue **#2** (the originating bug). The two review-surfaced gaps (duplicate MW_ID,
  blank MW_TYPE) were folded into this same PR as the same data-loss class.
- Part of the broader reconcile/sync data-integrity track (STRATEGY.md "Emacs-native editing":
  the desk surface can only be "a joy to edit" if added content survives the next sync).
- Adjacent to [[preserving-buffer-view-state-across-reconcile]] (render-before-erase safety,
  view-state restoration) and the signature-stability invariant in
  [[org-markdown-link-conversion-roundtrip]].
- Related gap noted but out of scope: `MW_FOCUS_TODAY` (`isFocusedToday`) is deliberately
  excluded from `mindwtr-model-content-fields`, so focus-status edits are silently dropped on
  sync — filed separately as issue #4. *(session history)*
