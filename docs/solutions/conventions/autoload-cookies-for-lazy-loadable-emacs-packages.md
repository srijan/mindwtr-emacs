---
title: "Lazy-loading an Emacs package: entry points need ;;;###autoload cookies (or use-package autoload keywords)"
date: 2026-06-19
category: conventions
module: mindwtr
problem_type: convention
component: tooling
severity: medium
applies_when:
  - "Adding a major mode wired through auto-mode-alist that should pull in its package on file open"
  - "Writing a use-package recipe to defer-load a package until a file opens or a key is pressed"
  - "Exposing a command or helper that must resolve before its package loads (capture template, hook fn)"
  - "A package eager-loads at startup (`:demand t`) and you want it deferred without losing functionality"
  - "Shipping a package for both bare `:load-path` checkouts and package.el/straight/elpaca installs"
tags: [emacs-lisp, autoload, lazy-loading, use-package, auto-mode-alist, deferred-loading, major-mode, packaging]
---

# Lazy-loading an Emacs package: entry points need ;;;###autoload cookies (or use-package autoload keywords)

## Context

A user wanted to lazy-load the `mindwtr` package: defer loading until the synced
`mindwtr.org` file is actually opened, keep global GTD keybindings working before
that, and crucially perform NO server sync at Emacs startup.

Their config did the opposite. They loaded with `use-package` and `:demand t`,
forcing an eager load at startup. As a side effect, `:config` ran
`(mindwtr-auto-sync-mode 1)`, which kicked off an immediate server sync the moment
the first frame got focus. Every launch paid the cost of loading the whole package
and hitting the network, whether or not the user ever touched their GTD file.

When they tried to defer, they hit a load-time deadlock. The README told them to
register the major mode by hand:

```elisp
(add-to-list 'auto-mode-alist '("/mindwtr\\.org\\'" . mindwtr-mode))
```

But opening `mindwtr.org` did not pull the package in. Neither `mindwtr-mode` (the
major mode, in `mindwtr.el`) nor `mindwtr-capture-template` (the capture helper, in
`mindwtr-capture.el`) carried a `;;;###autoload` cookie. Without a cookie on
`mindwtr-mode`, the `auto-mode-alist` association only fires if `mindwtr` is
*already* loaded — exactly the state deferral is trying to avoid. The user's config
compounded the problem by placing that `auto-mode-alist` line inside `use-package`'s
`:config` block, which only runs *after* the package loads: the trigger for loading
lived inside the block that only executes post-load, a circular dependency that
could never resolve.

## Guidance

Two things fix this: source-level autoload cookies, and a `use-package` recipe that
splits eager from deferred work correctly.

First, add `;;;###autoload` cookies to anything that needs to load the package on
demand — the major mode, and any non-interactive helper referenced before load:

```elisp
;;;###autoload
(define-derived-mode mindwtr-mode org-mode "Mindwtr" ...)

;;;###autoload
(defun mindwtr-capture-template () ...)
```

Second, structure the `use-package` declaration so the loading triggers live
*outside* `:config`, GTD essentials are available from a cold start, and the heavy
machinery stays deferred:

```elisp
(use-package mindwtr
  :ensure nil
  :load-path "/path/to/mindwtr-emacs"
  :mode ("/mindwtr\\.org\\'" . mindwtr-mode)          ; load on file open
  :bind (("C-c d e" . mindwtr-engage)                  ; global keys, work pre-load
         ("C-c d p" . mindwtr-projects)
         ("C-c d c" . mindwtr-capture)
         ("C-c d k" . mindwtr-clarify)
         ("C-c d s" . mindwtr-sync))
  :commands (mindwtr-capture-template)                 ; so C-c c i resolves pre-load
  :custom (mindwtr-server-url "...") (mindwtr-file "...")
          (mindwtr-sync-interval 600) (mindwtr-sync-idle-debounce 5)
  :init                                                 ; eager: agenda + capture from cold start
  (with-eval-after-load 'org
    (add-to-list 'org-agenda-files mindwtr-file))
  (with-eval-after-load 'org-capture
    (add-to-list 'org-capture-templates
                 `("i" "Mindwtr inbox" entry
                   (file+headline mindwtr-file "Inbox")
                   (function mindwtr-capture-template))))
  :config                                               ; deferred: sync engine on first load
  (mindwtr-auto-sync-mode 1)
  (mindwtr-agenda-setup))
```

The keyword roles:

- `:mode`, `:bind`, and `:commands` inject `(autoload ...)` forms at startup. These
  are the actual triggers that load the package — opening the file, pressing a key,
  or calling the named command.
- `:init` runs eagerly, before the package loads. Put GTD essentials here:
  registering the file in `org-agenda-files` and adding the `C-c c i` inbox capture
  template. Wrap each in `with-eval-after-load` so they attach to `org` /
  `org-capture` whenever those load, without forcing them.
- `:config` runs once, on first package load via any entry point. Put the heavy,
  side-effecting machinery here: the auto-sync engine and agenda-command
  registration. Nothing in here runs until the user first opens the file or hits a
  binding, so startup stays sync-free.

## Why This Matters

Lazy loading in Emacs hinges on a chain that is easy to break silently. An autoload
cookie is meaningless unless something builds it into a loaddefs file, and
`auto-mode-alist` is inert unless the target mode is autoloadable. Get one link
wrong and the package either loads eagerly (defeating the purpose) or never loads
when you open its file (breaking the feature) — usually with no error to point at.

Several non-obvious mechanics make or break this setup:

- **Autoload cookies need a loaddefs file to fire.** A bare `use-package :load-path`
  checkout (`:ensure nil`, pointing at a local directory) generates NO autoloads
  file. The source `;;;###autoload` cookies do nothing on their own in that mode.
  What actually makes deferral work there is that `use-package`'s `:mode` / `:bind`
  / `:commands` keywords inject their own `(autoload ...)` forms at startup. The
  source cookies still pay off for `package.el` / `straight` / `elpaca` installs,
  which build a loaddefs file — and they make a documented `auto-mode-alist`
  instruction actually lazy-load under those installs.

- **`:config` runs on first load via ANY entry point, not just file-open.**
  `use-package` wraps a deferred `:config` in `(with-eval-after-load 'mindwtr ...)`.
  So pressing any `:bind` key (say `C-c d e`) loads the package and runs `:config`.
  The autoload loads the file and runs `:config` *before* invoking the command body,
  which means `mindwtr-agenda-setup` has already run by the time `mindwtr-engage`'s
  body executes. You do not need to open the file to "warm up" the package.

- **Keyword ordering matters.** `use-package` processes `:custom` before `:init`, so
  `mindwtr-file` (set via `:custom`) is already bound when `:init` references it in
  the agenda and capture registrations.

The eager-vs-deferred split is the heart of the fix. GTD essentials —
agenda-file registration and the inbox capture template — must work from a cold
start without opening the file, so they go in `:init`. The heavy sync engine and
agenda-command registration must NOT run at startup, so they go in `:config` behind
the load trigger. Putting a load trigger inside `:config` (the original bug) is
self-defeating: the thing meant to cause loading can only run after loading has
already happened.

## When to Apply

Apply this pattern when:

- You are packaging or configuring an Emacs package that should defer loading until
  a specific file is opened or a command is invoked, rather than at startup.
- The package has startup-expensive side effects (network sync, timers, large
  agenda scans) that must not run until the user actually engages the feature.
- You want some lightweight capabilities (keybindings, agenda-file registration,
  capture templates) available from a cold start, while the bulk stays unloaded.
- You are writing a package others install: add `;;;###autoload` cookies to the
  major mode and any helper referenced before load, so `auto-mode-alist`-style
  instructions work under `package.el` / `straight` / `elpaca`.

Add `;;;###autoload` to any function that is a legitimate entry point — interactive
commands the user binds, the major mode named in `auto-mode-alist`, and
non-interactive helpers referenced by name before the package loads (capture
template functions, hook functions). On Emacs 29.1+, prefer the semantically tidier
`:autoload` keyword over `:commands` for non-interactive helpers like
`mindwtr-capture-template`.

Do NOT scatter load-triggering forms inside `:config`. If a form's purpose is to
cause the package to load, it belongs in `:init`, `:mode`, `:bind`, or `:commands` —
never in the block that only runs post-load.

## Examples

**Before — eager load, sync at startup, deadlock-prone deferral**

Source: no autoload cookies.

```elisp
(define-derived-mode mindwtr-mode org-mode "Mindwtr" ...)   ; no cookie
(defun mindwtr-capture-template () ...)                      ; no cookie
```

User config:

```elisp
(use-package mindwtr
  :ensure nil
  :load-path "/path/to/mindwtr-emacs"
  :demand t                                ; loads eagerly at startup
  :config
  (mindwtr-auto-sync-mode 1)               ; immediate sync on first frame focus
  (add-to-list 'auto-mode-alist            ; load trigger trapped post-load
               '("/mindwtr\\.org\\'" . mindwtr-mode))
  (mindwtr-agenda-setup))
```

Result: the package loads on every launch and syncs to the server at startup.
Removing `:demand t` does not help — the only deferral trigger lives inside
`:config`, which never runs because nothing loads the package, so opening
`mindwtr.org` does not pull it in either.

**After — deferred load, no startup sync, GTD keys work cold**

Source: cookies added.

```elisp
;;;###autoload
(define-derived-mode mindwtr-mode org-mode "Mindwtr" ...)

;;;###autoload
(defun mindwtr-capture-template () ...)
```

User config: the full deferred recipe shown under Guidance — load triggers in
`:mode` / `:bind` / `:commands`, GTD essentials in `:init`, heavy machinery in
`:config`.

Result: at startup, `org-agenda-files` includes the GTD file and `C-c c i` captures
to the inbox — no package load, no sync. Opening `mindwtr.org`, or pressing any
`C-c d` binding, loads the package once and runs `:config` (turning on auto-sync and
agenda setup) before handing control to the command. Sync happens only after the
user first engages, never at startup.

Verified: `make compile` clean, `make test` 483/483 passing.

## Related

- `../developer-experience/stale-elc-shadows-updated-el-after-rebase.md` — adjacent
  Emacs Lisp load-mechanics gotcha (stale `.elc` shadowing `.el`); orthogonal cause,
  same "the load chain bit me silently" family.
- `../design-patterns/save-as-sync-commit-point.md` — why an unprompted sync at
  startup is undesirable in the first place (the symptom this deferral removes).
- Issue #63 ("Ability to make mindwtr-emacs load async on file open") and PR #65
  ("feat(autoload): defer loading until file open / first command") — the origin.
