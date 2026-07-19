---
title: Org/markdown link conversion truncated parens-URLs and broke description round-trip stability
date: 2026-06-03
category: logic-errors
module: mindwtr-render / mindwtr-parse
problem_type: logic_error
component: tooling
symptoms:
  - "URLs containing parentheses are truncated at the first inner `)`, corrupting the link"
  - "Description signature phantom-churns on every sync even when nothing changed"
  - "Empty-label org link [[url][]] mis-parses or nil-crashes instead of falling back to the URL"
  - "Label-less links do not round-trip byte-stably between org and markdown"
  - "Markdown [](url) renders to invalid org [[url][]]"
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags: [org-mode, markdown, link-conversion, round-trip, byte-stability, regex, sync]
---

# Org/markdown link conversion truncated parens-URLs and broke description round-trip stability

## Problem
The bidirectional org⇄markdown link converter for description fields used a naive
URL-capture regex (`[^)]*`) that stopped at the first inner `)`, truncating URLs
that legitimately contain balanced parens (e.g. `https://en.wikipedia.org/wiki/Foo_(bar)`).
Empty labels were also mishandled in both directions, producing invalid org or a nil crash.

## Symptoms
- A description URL like `https://en.wikipedia.org/wiki/Foo_(bar)` was rewritten to
  `https://en.wikipedia.org/wiki/Foo_(bar` — truncated at the first `)` — corrupting the
  link as it crossed the serialization boundary.
- Because the converted form differed from the original on every pass, the description
  signature **phantom-churned**: change detection saw a "change" on every sync even when
  the user edited nothing.
- An empty markdown label `[](url)` rendered to the invalid org form `[[url][]]`; an empty
  org label `[[url][]]` did not safely fall back and risked a nil/empty-string mishandle.
- Label-less links were not guaranteed byte-stable across a render→parse→render trip.

## What Didn't Work
The first implementation (`205bdf0`) captured the markdown URL with a naive negated-char
class that ends at the first `)`:

```elisp
;; effective pattern — URL group stops at the first ')'
"\\[\\([^]]*\\)\\](\\([^)]*\\))"
```

For `[Foo](https://en.wikipedia.org/wiki/Foo_(bar))` the `[^)]*` group matched only up to
`Foo_(bar`, dropping the trailing `bar)`. This both corrupted the link and broke the
round-trip byte-stability invariant.

During PR review (session history), **three independent reviewers converged on this as a
P1 bug at confidence 100** and explicitly connected it to the *idempotency linchpin* in the
sync design: a non-byte-stable description phantom-churns its signature on every sync, so the
Emacs client perpetually "wins" the last-writer-wins merge. That framing elevated the regex
from a cosmetic nit to a must-fix blocker. *(session history)*

## Solution
**Render (markdown→org), `mindwtr-render--mw->org-text`** — the URL group now tolerates one
level of balanced parens, and an empty/equal label collapses to the canonical `[[url]]`:

```elisp
;; before:  "\\[\\([^]]*\\)\\](\\([^)]*\\))"
;; after:
(replace-regexp-in-string
 "\\[\\([^]]*\\)\\](\\(\\(?:[^()]\\|([^()]*)\\)*\\))"
 (lambda (m)
   (let ((label (match-string 1 m))
         (url   (match-string 2 m)))
     (if (or (string= label url) (string-empty-p label))
         (format "[[%s]]" url)
       (format "[[%s][%s]]" url label))))
 text t t)
```

The URL subexpression `\(?:[^()]\|([^()]*)\)*` accepts either a non-paren char or a fully
balanced `(...)` group, so `Foo_(bar)` survives intact. The `string=`/`string-empty-p`
branch renders the canonical label-less `[[url]]`, so `[](url)` no longer yields invalid
`[[url][]]` and a label-less link is byte-stable.

**Parse (org→markdown), `mindwtr-parse--org->mw-text`** — nil-safe, empty-label fallback,
documented `]`-in-url limitation:

```elisp
(when text                                   ; nil-safe
  (replace-regexp-in-string
   "\\[\\[\\([^]]*\\)\\]\\(?:\\[\\([^]]*\\)\\]\\)?\\]"
   (lambda (m)
     (let ((url   (match-string 1 m))
           (label (match-string 2 m)))
       (format "[%s](%s)"
               (if (and label (not (string-empty-p label))) label url)
               url)))
   text t t))
```

`[[url][label]]` → `[label](url)`; `[[url]]` and `[[url][]]` both → `[url](url)`. A literal
`]` inside an org link path is explicitly documented as unsupported — org uses `]` as a
delimiter and cannot unambiguously represent a bare `]` in its path — and is pinned by a
test rather than silently producing a corrupted link.

## Why This Works
The sync pipeline relies on a **round-trip byte-stability invariant**: rendering a mindwtr
description into the org buffer and parsing it back must reproduce the exact same markdown,
and re-rendering must reproduce the exact same org text. Change detection compares description
signatures, so any conversion that is not its own inverse makes the description differ from
itself on every pass — a phantom change that re-syncs/reconciles needlessly and lets the
Emacs side win every LWW merge. The truncating URL regex violated this (corrupted URL ≠
original), as did the non-canonical label-less handling. The balanced-parens group preserves
the URL exactly, and collapsing `label==url`/empty-label to the canonical `[[url]]` makes the
label-less form the unique fixed point of the round trip — restoring byte-stability and
silencing the churn.

## Prevention
- **Round-trip property test** (`mindwtr-roundtrip-test.el`) drives the full trip and asserts
  byte-identity across a labelled link, a label-less link, a parens-URL link, and link-free
  prose:
  ```elisp
  (let* ((org  (mindwtr-render--mw->org-text desc))  ; md → org
         (back (mindwtr-parse--org->mw-text org)))   ; org → md
    (should (string= back desc)))
  ```
- **Parens-URL regression** explicitly pins the truncation bug:
  ```elisp
  (should (string= (mindwtr-render--mw->org-text
                    "[Foo](https://en.wikipedia.org/wiki/Foo_(bar))")
                   "[[https://en.wikipedia.org/wiki/Foo_(bar)][Foo]]"))
  ```
- **Empty-label coverage** in both directions, and a **documented-limitation pin** asserting
  the `]`-in-url case is left verbatim rather than corrupted.
- Treat byte-stable round-tripping as a hard invariant for any new description transform: if a
  transform isn't its own inverse, it will phantom-churn the signature. Add a round-trip test
  for every new conversion before shipping it.
- Test count went 204 → 208, all passing.

## Related Issues
- Closes GitHub issue #21 (link syntax synced verbatim between org and mindwtr).
- Anchored on the round-trip byte-stability / signature-idempotency invariant that underpins
  change detection across the sync layer — see
  [[preserving-buffer-view-state-across-reconcile]] and
  [[silent-deletion-untyped-org-headings]] for adjacent reconcile/sync-integrity work.
- Checklist-item link conversion was intentionally deferred per issue scope (follow-up).
