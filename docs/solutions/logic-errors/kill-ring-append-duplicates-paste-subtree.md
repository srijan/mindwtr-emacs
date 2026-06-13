---
title: Relocate/refile duplicate entities because org-paste-subtree pastes an appended kill-ring head
date: 2026-06-12
category: logic-errors
module: mindwtr-commands / mindwtr-archive
problem_type: logic_error
component: tooling
symptoms:
  - "Sync report warns: N id(s) present in more than one file; the archive-file copy was dropped"
  - "After a heavy clarify session the main buffer has many duplicate headings (same MW_ID repeated back-to-back)"
  - "Duplicate counts form a staircase in decision order (13, 12, 11, ... 1) — earlier-moved items have more copies"
  - "The archive file independently accumulates duplicate ARCH headings"
  - "The very next sync repairs it (erase + re-render from deduped appdata), so it looks transient"
  - "Batch ERT tests of --relocate / archive-refile pass even though interactive use duplicates"
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags: [org-paste-subtree, org-cut-subtree, kill-ring, last-command, relocate, archive, clarify, duplicate, mw-id]
---

# Relocate/refile duplicate entities because org-paste-subtree pastes an appended kill-ring head

## Problem
`mindwtr-commands--relocate`, `mindwtr-commands--move-subtree-under`, and
`mindwtr-archive-refile-at-point` moved a subtree by cutting/copying it and then
calling `org-paste-subtree` with **no explicit `tree` argument**. With no tree,
`org-paste-subtree` pastes `(current-kill 0)` — the kill-ring head — and both
`org-cut-subtree` (→ `kill-region`) and `org-copy-subtree` (→
`copy-region-as-kill`) **append** to that head when `last-command` is
`kill-region`.

In the interactive command loop `last-command` carries `kill-region` from one
command into the next, so when a user relocates/archives several entities in a
row (a clarify session filing many inbox items, repeated status cycling, bulk
archiving) every cut/copied subtree accumulates into one growing kill-ring
entry. Each paste then re-inserts the whole accumulated blob, duplicating every
previously-moved entity. The duplication count follows a staircase in decision
order — the first-moved item is re-pasted on every subsequent move.

## Symptoms
- Sync report: `N id(s) present in more than one file; the archive-file copy was dropped`.
- Main buffer transiently balloons (e.g. 325 `MW_ID` headings, 158 unique; one id ×18).
- Duplicate counts staircase in decision order (13, 12, … 1); the archive file gains duplicate ARCH headings too.
- The next sync cleans it up (`mindwtr-reconcile-buffer` does `erase-buffer` + re-render from the deduped `merged` appdata), so it reads as transient — but the buffer was genuinely corrupted in between.

## Root Cause
`org-paste-subtree`'s `tree` argument defaults to `(current-kill 0)`:

```elisp
(setq tree (or tree (current-kill 0)))   ; org.el
```

and `org-cut-subtree`/`org-copy-subtree` append to that kill on consecutive
kills (standard Emacs `kill-append` behaviour, gated on
`(eq last-command 'kill-region)`). The move helpers relied on the kill ring
holding *only* the just-cut subtree, which is false after a prior relocation in
the same command-loop session.

## Solution
Capture the text returned by `org-cut-subtree` / `org-copy-subtree` (both return
the subtree string) and pass it as the explicit `tree` argument to
`org-paste-subtree`, making the move independent of kill-ring state:

```elisp
;; mindwtr-commands--relocate / --move-subtree-under
(let* ((level (1+ (save-excursion (goto-char target) (org-current-level))))
       (text (org-cut-subtree)))
  (goto-char target)
  (org-end-of-subtree t t)
  (org-paste-subtree level text))

;; mindwtr-archive-refile-at-point
(let ((text (org-copy-subtree)))
  (with-current-buffer abuf
    (let ((c (mindwtr-archive--ensure-container)))
      (goto-char c) (org-end-of-subtree t t)
      (org-paste-subtree 2 text))))
```

`mindwtr-clarify.el`'s write-back already passed an explicit `text` to
`org-paste-subtree`, which is why the clarify write-back path was never affected
— it was the template for the fix.

## Why This Works
The explicit `text` is exactly the one subtree that was just cut/copied, so the
paste no longer reads the (possibly appended) kill-ring head. Any leftover
kill-ring accumulation is then harmless because nothing pastes from it.

## What Didn't Work
- A plain batch ERT test of `--relocate` over several items passed against the
  buggy code: `last-command` is not `kill-region` in batch, so no append
  happened. Reproducing the bug **requires setting `last-command` to
  `kill-region` between moves** to mimic the command loop. The regression tests
  (`mindwtr-commands-relocate-does-not-duplicate-on-consecutive-kills`,
  `mindwtr-archive-refile-no-duplicate-on-consecutive-kills`) do exactly that.

## Prevention
- Never call `org-paste-subtree` without an explicit `tree` when the matching
  cut/copy might run consecutively with another kill. Pass the cut/copied text.
- When reproducing kill-ring / `org-cut-subtree` behaviour in ERT, set
  `last-command` deliberately — batch defaults hide append bugs.
- Note: verifying this fix required `make compile` first; a stale `.elc` shadowed
  the edited `.el`. See [stale .elc shadows updated .el](../developer-experience/stale-elc-shadows-updated-el-after-rebase.md).

## Related Issues
- [Clarify queue markers collapse on write-back](clarify-queue-markers-collapse-on-write-back.md) — same clarify flow, different position-vs-identity hazard.
- GitHub issue #51.
