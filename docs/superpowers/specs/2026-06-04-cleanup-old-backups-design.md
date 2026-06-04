# Cleanup old pre-sync backups automatically

**Issue:** [#30 — Cleanup old backups automatically](https://github.com/srijan/mindwtr-emacs/issues/30)
**Date:** 2026-06-04
**Scope:** Age-based pruning of the pre-sync backup directory. Nothing else in the
sync/backup pipeline changes.

## Problem

Every full sync cycle writes a pre-sync snapshot of the buffer to
`<mindwtr-shadow-directory>/backups/mindwtr-<timestamp>.org` (`mindwtr-sync.el`,
in the post-PUT path). These files are a recovery aid: "the sync I just ran went
wrong, let me get the previous buffer contents back." Nothing ever deletes them,
so the directory grows without bound — one file per full sync, forever.

## Goal

After each sync writes its new backup, delete pre-sync backups older than a
configurable age (default 3 days). The value of a pre-sync snapshot decays fast —
it is almost entirely "recover from the sync I just did" — so a short age window
keeps recent recovery points while bounding the directory.

## Non-goals

- Count-based retention ("keep the last N"). Age-based only.
- Compressing or archiving old backups. They are deleted outright.
- Touching the shadow snapshot or its single `shadow.bak.json` last-good backup
  (`mindwtr-shadow-save`) — that is a separate, already-bounded mechanism.
- Pruning on any trigger other than a successful sync's backup write. There is no
  timer and no interactive cleanup command.

## Design

### Configuration

```elisp
(defcustom mindwtr-backup-retention-days 3
  "Delete pre-sync backups older than this many days after each sync.
Age is measured from the timestamp encoded in the backup filename.
nil or 0 disables cleanup (backups are kept forever)."
  :type '(choice (const :tag "Keep forever" nil) integer)
  :group 'mindwtr)
```

### New helper — `mindwtr-shadow-prune-backups`

Lives in `mindwtr-shadow.el`: the backups directory derives from
`mindwtr-shadow-directory`, so shadow.el is its natural home, alongside the other
on-disk state helpers.

```elisp
(defun mindwtr-shadow-prune-backups (&optional now)
  "Delete pre-sync backups older than `mindwtr-backup-retention-days'.
NOW defaults to `current-time' (injectable for tests). No-op when retention
is nil or 0, or when the backups directory does not exist."
  ...)
```

Behavior:

1. Return immediately when `mindwtr-backup-retention-days` is `nil` or `<= 0`, or
   when the `backups/` directory does not exist.
2. Compute a cutoff time: `now` minus `retention-days`.
3. List the `backups/` directory. For each entry whose name matches the backup
   naming pattern `mindwtr-<YYYYMMDDTHHMMSS>.org`:
   - Parse the timestamp **from the filename** (true backup-creation time; immune
     to mtime drift from copies/touches).
   - Delete the file when its parsed time is strictly before the cutoff.
4. Files that do **not** match the pattern are left untouched — we never delete
   anything we did not create.

The filename timestamp is produced by `(format-time-string "%Y%m%dT%H%M%S")`, so
parsing is the inverse: read the 15-char `YYYYMMDDTHHMMSS` field and convert with
`encode-time` / `parse-time-string`. Timestamps are in local time on both write
and read, so the round-trip is consistent.

### Call site

In `mindwtr-sync.el`, immediately after the existing backup `write-region`
(currently around line 366), call `mindwtr-shadow-prune-backups`.

This is the **post-PUT path**, where AGENTS.md is emphatic that nothing may throw
(the server write has already committed; a hiccup must not surface as a spurious
sync failure). The prune is therefore wrapped so it can never abort the cycle:

```elisp
(write-region (point-min) (point-max) bf)
(setq backup-file bf)
(condition-case err
    (mindwtr-shadow-prune-backups)
  (error (message "mindwtr: backup cleanup skipped: %s"
                  (error-message-string err))))
```

A permission error, an unparsable name, or any other surprise degrades to a
logged message, never a failed sync.

## Invariants

- **Must not throw.** Runs post-PUT; wrapped in `condition-case` at the call site.
- **Deletes only our own backups.** Only files matching `mindwtr-*.org` with a
  parseable embedded timestamp in the `backups/` dir are candidates.
- **Disable-able.** `nil`/`0` retention is a first-class "keep forever" mode.
- **Boundary is strict-older-than.** A backup exactly at the cutoff is kept; only
  files strictly older than `now - retention-days` are deleted. (Edge precision is
  not important here, but the test pins one behavior.)

## Testing

New ERT tests in `test/mindwtr-shadow-test.el` (create if absent), each operating
on a temp `mindwtr-shadow-directory` with fabricated backup filenames and an
injected `now`:

1. A backup older than the cutoff (e.g. 5 days old, retention 3) is deleted.
2. A backup newer than the cutoff (e.g. 1 day old) is kept.
3. `mindwtr-backup-retention-days` = `nil` deletes nothing; `0` deletes nothing.
4. A non-matching file in `backups/` (e.g. `notes.txt`, or `mindwtr-garbage.org`
   with an unparseable stamp) is never deleted.
5. Missing `backups/` directory is a no-op, not an error.
6. Mixed directory: old + new + foreign files together → only the old `mindwtr-*`
   backups go.
