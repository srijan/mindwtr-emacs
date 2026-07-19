---
title: "Stale .elc shadows the updated .el after a branch switch or rebase"
date: 2026-06-09
category: developer-experience
module: build / test
problem_type: developer_experience
component: development_workflow
symptoms:
  - "A function or variable reported void/undefined even though its definition is present in the .el"
  - "Byte-compile or ERT run fails referencing a symbol that visibly exists in source"
  - "The failure appears right after a rebase, branch switch, or pull that added a definition"
  - "`make compile && make test` passes for a colleague but fails locally on the same commit"
applies_when:
  - "Running `make compile` then switching branches / rebasing / pulling"
  - "A definition was added or moved on the branch you switched to"
  - "Test or compile errors name a symbol that is clearly defined in the current source"
tags:
  - emacs-lisp
  - byte-compile
  - stale-cache
  - rebase
  - elc
  - build
  - gitignore
---

# Stale .elc shadows the updated .el after a branch switch or rebase

## Context

`make compile` byte-compiles `mindwtr*.el` into `.elc` files, and those `.elc` files are git-ignored (`.gitignore` line 1: `*.elc`). Because they are ignored, a `git checkout`, `git rebase`, or `git pull` **never touches them** — they sit on disk exactly as the last `make compile` left them, even after the underlying `.el` sources have changed out from under them.

Emacs `load` prefers a `.elc` over its `.el` sibling by default (`load-prefer-newer` is nil), *regardless of which file is newer on disk*. So once a stale `.elc` exists, it shadows the updated `.el`: code added or moved on the branch you just switched to is invisible, and you get a void-function / undefined-symbol error for a definition you can plainly see in the source.

This surfaced concretely while rebasing an earlier PR onto a `main` that had just added `mindwtr-model-ensure-settings` (`mindwtr-model.el:227`): the first compile failed reporting that function undefined, even though the defun was right there. The `.elc` had been compiled before `main` introduced it.

## Guidance

**When a symbol is reported void/undefined but is visibly defined in the current `.el`, suspect a stale `.elc` first — before re-reading the source for a typo.** Clear the byte-compiled cache and rebuild:

```sh
rm -f *.elc && make compile
```

Treat this as the reflex after any branch switch / rebase / pull that changed definitions, not just when an error appears. `make test` loads the package files and will pick up a stale `.elc` the same way `make compile` does, so the same `rm -f *.elc` clears spurious test failures too.

## Why This Matters

The failure mode is actively misleading: the error names a symbol you can see in the source, so the natural reaction is to doubt the source (typo? wrong file? bad require order?) and burn minutes there — when the real problem is a cache the VCS can't manage for you. Because `.elc` is git-ignored, the usual "rebase gives me a clean tree" intuition is wrong for these files: the working tree looks clean while a stale artifact silently overrides it. Knowing the one-line reflex turns a confusing dead end into a five-second fix.

## When to Apply

- Right after `git checkout` / `git rebase` / `git pull` when the incoming changes added, moved, or renamed top-level definitions.
- Whenever a compile or ERT run reports a void-function, void-variable, or "reference to free variable" for a symbol that exists in the current `.el`.
- Before filing a "this doesn't compile on my machine" report — rule out the stale cache first.

## Examples

**The trap:** `main` adds `mindwtr-model-ensure-settings`; you rebase your branch onto it; you still have a `mindwtr-model.elc` from before the rebase. `make compile` loads the old `.elc`, never sees the new defun, and fails with the function reported undefined — despite `grep` finding it at `mindwtr-model.el:227`.

**The fix:**

```sh
$ rm -f *.elc && make compile   # cache cleared, fresh byte-compile sees the new defun
```

**Why not just rely on `load-prefer-newer`?** Setting it would prefer whichever sibling is newer by mtime, but a rebase rewrites `.el` mtimes unpredictably and `.elc` is ignored, so timestamps are not a reliable signal. Deleting the cache is unambiguous and cheap, so it is the recommended reflex rather than a config tweak.

## Related

- `AGENTS.md` already carries a terse form of this reflex under "Building & testing" ("Remove stale `*.elc` before batch ERT runs if results look off (`rm -f *.elc`)"); this doc is the full rationale behind that one-liner.
- [[fresh-namespace-null-settings-500]] — the rebase during which this trap surfaced (the incoming `mindwtr-model-ensure-settings` was the shadowed symbol).
