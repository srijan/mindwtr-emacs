---
title: Archive sync strict-absence safety gate for degraded parse
date: 2026-06-11
category: logic-errors
module: mindwtr-archive / mindwtr-sync
problem_type: logic_error
component: tooling
symptoms:
  - "Archived entities silently server-deleted after a sync cycle with no user deletion — triggered when the archive file contains a quarantined heading (MW_TYPE removed) or is empty/truncated"
  - "Refile to archive loses the heading from both source buffer and archive file if the paste step fails after the cut (heading stranded on kill ring)"
  - "Cycling a task to ARCH keyword relocates within the main file instead of refiling to the archive, diverging from set-status behavior"
  - "Duplicate MW_IDs across surfaces are only visible as a transient *Messages* line, not in the durable sync report"
root_cause: logic_error
resolution_type: code_fix
severity: critical
related_components:
  - mindwtr-sync--archive-strict-safe-p
  - mindwtr-sync--surface-has-unparsed-entity-p
  - mindwtr-archive-refile-best-effort
  - mindwtr-commands--route-after-keyword
tags:
  - archive-sync
  - strict-absence
  - data-loss
  - refile-atomicity
  - keyword-routing
  - parse-health
  - org-mode
  - emacs-lisp
---

# Archive sync strict-absence safety gate for degraded parse

## Problem

The strict-absence mechanism in `mindwtr-sync.el` tombstones archived entities when they are absent from the parsed local state — the inference being that the user deleted them. That inference is only sound when the archive file parsed completely. When the archive file is present on disk but degraded — a heading with `MW_TYPE` removed by a raw edit, a truncated save, or an empty file — the parse produces zero archived entities, and strict mode issued mass server tombstones against legitimately-archived items. The latch never fired on these seams because it was bound before the parse and could not see parse health. Three secondary issues were discovered in the same review: non-atomic refile (cut-before-paste could lose a heading from both buffers), divergent ARCH routing between `set-status` and `cycle`, and duplicate MW_ID drops visible only transiently.

## Symptoms

- Archived tasks or projects disappear from the server after a sync cycle with no corresponding user deletion.
- The deletion is silent: the cycle completes normally, no error, no sync-report warning — only a `deletedAt` tombstone on the server.
- The failure triggers specifically when the archive file is present and the migration latch is set, but the file is in one of these states:
  - A heading has `MW_ID` but its `MW_TYPE` property was removed or mistyped by a raw org edit.
  - The file is empty or contains only the `* Archive` container (truncated save, `rm`+recreate, failed write).
- Attempting to refile a task to the archive while the archive container is unavailable loses the heading — it is cut from the source buffer but never lands in the archive, stranded on the kill ring.
- Pressing the cycle key to advance a task to `ARCH` leaves it in the main file rather than filing it to the archive.

## What Didn't Work

**The existing file-existence guard appeared sufficient.**

The strict-mode latch before the fix:

```elisp
;; Bound BEFORE parse — never sees parse health
(mindwtr-sync--archive-strict
 (and archive-active
      (mindwtr-shadow-archive-migrated-p)
      (let ((p (mindwtr-archive-path))) (and p (file-exists-p p)))))
```

This guard correctly blocks strict mode when the archive file is missing from disk (`rm`ed file → echo, not delete). The assumption was that a present file implied a valid parse. It does not: a file that exists but is empty, or contains a heading whose `MW_TYPE` was removed, passes the guard and then produces zero archived entities from the parse.

**Keying `archive-warned` on `mindwtr-parse-warnings` didn't catch the quarantine case.**

The first attempted fix for P0 set `archive-warned` whenever `mindwtr-parse-warnings` was non-empty after parsing the archive surface. This channel fires for invalid *keyword* errors (a heading with an unrecognized TODO keyword). It does not fire for the real failure mode: when `MW_TYPE` is removed, `infer-kind` returns nil and the heading is silently skipped — the parser never emits a warning for it. So the gate passed even when entity absence was due to a silently-dropped unparsed heading. This approach was discarded before any tests were written, once the silent-skip path in `mindwtr-parse.el` was confirmed. (session history)

## Solution

### P0 — Post-parse strict-mode safety gate

Move the `mindwtr-sync--archive-strict` binding below `mindwtr-sync--parse-surfaces` so it can inspect actual parse results. Introduce `mindwtr-sync--archive-strict-safe-p` to gate the final latch:

```elisp
(defun mindwtr-sync--archive-strict-safe-p (local shadow archive-warned)
  "Non-nil if strict absence semantics are safe to apply this cycle."
  (and (not archive-warned)
       (not (and (> (mindwtr-sync--archived-count shadow) 0)
                 (= (mindwtr-sync--archived-count local) 0)))))
```

Two conditions each withhold strict mode, falling back to echo-for-the-cycle (identical to the missing-file fallback):

1. `archive-warned` — the archive surface has an `MW_ID` heading that produced no entity. Detected by `mindwtr-sync--surface-has-unparsed-entity-p`, which walks the archive buffer after parsing, collects all `MW_ID` property values present in the buffer, and checks whether each appears in the parsed appdata. An `MW_ID` in the buffer but absent from the appdata means kind inference returned nil (MW_TYPE missing/mistyped) — a parse reason for absence, not a user deletion.

2. **Empty-shortfall** — the shadow holds archived entities but local parsed zero. An empty or truncated archive file must not read as mass deletion of the entire archived backlog.

The binding now reads:

```elisp
;; Step 1: eligibility (same file-level guard as before)
(archive-strict-eligible
 (and archive-active
      (mindwtr-shadow-archive-migrated-p)
      (let ((p (mindwtr-archive-path))) (and p (file-exists-p p)))))
;; Step 2: parse-health gate (post-parse, can see what the parse actually returned)
(mindwtr-sync--archive-strict
 (and archive-strict-eligible
      (mindwtr-sync--archive-strict-safe-p
       local shadow (plist-get parsed :archive-warned))))
```

The `archive-warned` flag is computed inside `mindwtr-sync--parse-surfaces` immediately after parsing the archive surface's buffer and returned in the plist as `:archive-warned`. When eligibility passes but the gate withholds, a loud message fires:

```
mindwtr: archive file degraded or empty this cycle; archived deletions NOT applied (echoing instead)
```

### P1 — Refile atomicity (copy → paste → cut)

Before the fix, `mindwtr-archive-refile-at-point` cut the subtree before pasting into the archive buffer. A failure during paste (or `mindwtr-archive--ensure-container` signaling) left the subtree on the kill ring — gone from both the source buffer and the archive file, violating the R7 "leaves heading in place" contract.

```elisp
;; Before: cut first, paste second -- paste failure loses the heading
(org-cut-subtree)
(with-current-buffer abuf
  (let ((c (mindwtr-archive--ensure-container)))
    (goto-char c)
    (org-end-of-subtree t t)
    (org-paste-subtree 2)))
```

```elisp
;; After: copy first, paste second, cut only on paste success
(org-copy-subtree)
;; If this signals, control unwinds with the source subtree intact.
(with-current-buffer abuf
  (let ((c (mindwtr-archive--ensure-container)))
    (goto-char c)
    (org-end-of-subtree t t)
    (org-paste-subtree 2)))
;; Paste succeeded -- safe to remove the original.
(org-back-to-heading t)
(org-cut-subtree)
```

Additionally, `mindwtr-archive-item-at-point` (the user-facing command) was calling the bare `mindwtr-archive-refile-at-point` directly. It now routes through `mindwtr-archive-refile-best-effort`, so a runtime failure leaves the heading in place with its `ARCH` keyword for the next sync to handle.

### P2 — Centralized ARCH routing

`mindwtr-commands--cycle` was calling `mindwtr-commands--relocate` unconditionally after setting the ARCH keyword, keeping the heading in the main file. `mindwtr-set-status` correctly called `mindwtr-archive-refile-best-effort` on ARCH. The routing was extracted into a shared helper:

```elisp
(defun mindwtr-commands--route-after-keyword (kind keyword)
  "ARCH with the archive surface active refiles; any other keyword relocates."
  (if (and (string= keyword "ARCH") (mindwtr-archive-path))
      (mindwtr-archive-refile-best-effort)
    (mindwtr-commands--relocate kind)))
```

Both `mindwtr-set-status` and `mindwtr-commands--cycle` now call this function.

### P3 — Durable duplicate-ID warnings

Cross-surface duplicate `MW_ID`s were logged only to `*Messages*` (a ring buffer). Dropped IDs are now folded into the sync report's warnings channel as `(:id ID :duplicate t)` entries so the loss is visible in the durable report after the cycle.

## Why This Works

The root cause was a temporal ordering error: the strict-mode latch evaluated file presence as a proxy for parse correctness, but was bound *before* the parse ran. Parse health — specifically whether every `MW_ID` heading in the archive buffer produced a parsed entity — is only knowable after parsing.

Moving the binding post-parse gives the gate access to actual parse results. The two conditions in `mindwtr-sync--archive-strict-safe-p` are conservative by design: they produce false negatives (withhold strict when it might have been safe) rather than false positives (apply strict when it might tombstone valid data). The cost of a false negative is one deferred deletion cycle; the cost of a false positive is irreversible server data loss. The fallback behavior — echo-for-the-cycle — means the cycle is never a no-op: it still renders and syncs, just without treating absence as deletion.

The `mindwtr-sync--surface-has-unparsed-entity-p` function closes the quarantine seam specifically. The parse warnings channel was the natural first candidate but does not fire for the `infer-kind`-returns-nil case (MW_TYPE removed → heading silently skipped without a warning). The `MW_ID`-in-buffer-but-absent-from-appdata signal is the correct discriminant.

For P1, Elisp's condition system unwinds the stack on a signal, so if `org-paste-subtree` throws before the cut executes, the source buffer is untouched. The heading remains where it was with its existing keyword; the next sync refiles it identically.

## Prevention

- **Bind strict/destructive flags post-parse, not pre-parse.** Any latch that gates irreversible operations (server tombstones, buffer deletions) on the state of a file must be evaluated *after* parsing that file. File presence is necessary but not sufficient for parse health.

- **Use `surface-has-unparsed-entity-p` as the degraded-parse signal, not `parse-warnings`.** The warnings channel covers invalid keyword errors. It does not fire for silently-skipped headings (MW_TYPE removed → `infer-kind` returns nil). Detecting parse degradation requires comparing `MW_ID` properties in the buffer against `MW_ID`s in the parsed appdata.

- **Test the degraded-parse seam explicitly.** For every deletion mechanism, write a test that passes the file-existence check but produces a degraded parse, and assert no destructive operation fires. The `mindwtr-sync-once-empty-archive-does-not-mass-delete` and the quarantine variant are the reference shapes.

- **Use copy-before-cut for any two-buffer move.** When moving content between Emacs buffers: (1) copy to the destination, (2) let any signal from the paste propagate, (3) only then cut the source. The kill ring is not a safe intermediate state — it is outside the condition system's unwind path.

- **Route user-facing archive commands through the best-effort wrapper.** Commands that trigger refile operations should call `mindwtr-archive-refile-best-effort`, not the bare `refile-at-point`. Bypassing the wrapper defeats the R7 contract that absorbs runtime failures and leaves a recoverable state.

- **Single-source routing decisions.** Any conditional that depends on external state (archive surface active/inactive) and is duplicated across two commands will diverge. Extract it into a named function and call it from both sites.

- **Fold operational warnings into the durable sync report.** `*Messages*` is a ring buffer — warnings about data events (duplicate IDs, degraded parses, withheld deletions) must be written to the sync report so users see them after the fact.

## Related

- [silent-deletion-untyped-org-headings.md](./silent-deletion-untyped-org-headings.md) — Same class of failure: parse incompleteness (missing MW_TYPE) drives a destructive downstream step. That doc fixes the parse-level quarantine gate; this doc adds the sync-level safety gate that catches degraded archive parses the parser may not warn about.
- [content-signature-cannot-detect-remote-deletes.md](../design-patterns/content-signature-cannot-detect-remote-deletes.md) — Adjacent tombstone concern: that doc guards against tombstones arriving from the server being misclassified; this doc guards against tombstones being generated locally from a degraded parse. Different guard points in the same tombstone pipeline.
