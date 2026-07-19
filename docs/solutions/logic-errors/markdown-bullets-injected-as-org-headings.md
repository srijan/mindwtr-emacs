---
title: "Markdown bullets in notes injected phantom org headings on render"
date: 2026-06-09
category: logic-errors
module: mindwtr-render / mindwtr-parse
problem_type: logic_error
component: tooling
symptoms:
  - "A note line starting with `*`/`+`+space rendered verbatim, then org reparsed it as a heading"
  - "Note body was truncated at the first bullet line on the next sync"
  - "A `*** ` note line fabricated a phantom task that was PUT to the server"
  - "Parsing one project yielded extra phantom sibling/child entities"
root_cause: logic_error
resolution_type: code_fix
severity: high
tags:
  - org-mode
  - markdown
  - round-trip
  - heading-injection
  - render
  - byte-stability
---

# Markdown bullets in notes injected phantom org headings on render

## Problem

Project notes (`:supportNotes`) and section/task notes (`:description`) arrive from Mindwtr Cloud as markdown and are rendered inline under an org heading. The render path (`mindwtr-render--mw->org-text`, called at `mindwtr-render.el:199`) converted markdown *links* to org links but passed everything else through verbatim.

Markdown and org disagree on one structural character: a line whose first non-blank content is a run of `*` followed by a space is an org **heading**. So a perfectly ordinary markdown note like:

```
Intro
* a
* b
more
```

rendered as literal `* a` / `* b` lines into the org buffer. On the *next* parse, org read those lines not as note text but as new headings — splitting the note at the first bullet and minting whatever entity that heading depth implied. A `*** ` line at the right depth produced a phantom task with no server identity, which the reconcile/sync path then dutifully PUT to the server as a real entity. This is the dangerous failure mode: it does not just corrupt local display, it fabricates writes back to the cloud.

The same latent injection existed for task/section descriptions, since they share the same converter pair.

## Symptoms

- A note line beginning with `*`/`+` + space (or any star-run + space, e.g. `*** `) was emitted literally into the org buffer.
- The note was truncated at that line — everything after the first bullet vanished from the note field on re-parse.
- Parsing a single project returned more than one entity: phantom sibling/child headings.
- A `*** ` note line produced a junk task that was PUT to the server (verified).
- Round-trip was not byte-stable: the rendered buffer was no longer a fixed point.

## What Didn't Work

The tempting "complete" fix is to teach the converter the full markdown↔org inline emphasis mapping — `**bold**` → `*bold*`, `*italic*` → `/italic/`, `_x_` → `_x_`, etc. That was rejected, and correctly so:

- Inline emphasis does **not** collide with org block structure. An org heading requires a star-run followed by a space *at column 0*; inline `*italic*` and `**bold**` never match that. So emphasis is not the bug.
- A naive regex that "converts emphasis" mauls ordinary prose. `snake_case_name` becomes `/case/`-style garbage, and arithmetic like `2 * 3 * 4` gets mangled into emphasis spans. There is no safe column-agnostic regex for inline `*`/`_`.

So the wrong move was to expand the transform. The right move was to narrow it to exactly the one construct that is structurally ambiguous — the leading bullet marker — and leave inline emphasis literal. This scope ("convert + normalize bullets only, leave emphasis literal") was an explicit decision made when the converter's scope was raised as an open design question during an earlier PR, after laying out the corruption risk of the regex-emphasis alternative. *(session history)*

## Solution

Both converters gained a single leading-bullet normalization pass that runs *before* the existing link conversion. The regex anchors at line start (`^`), preserves leading indentation, and matches a star-run **or** a `+`, each followed by a space, rewriting it to org's only body-safe bullet marker, `- `.

Render side, `mindwtr-render--mw->org-text` (`mindwtr-render.el:54`, regex at `:77`):

Before:
```elisp
(when text
  (replace-regexp-in-string
   "\\[\\([^]]*\\)\\](\\(\\(?:[^()]\\|([^()]*)\\)*\\))"
   (lambda (m) ...link conversion...)
   text t t)))
```

After:
```elisp
(when text
  (let ((s (replace-regexp-in-string
            "^\\([ \t]*\\)\\(?:\\*+\\|\\+\\) " "\\1- " text)))
    (replace-regexp-in-string
     "\\[\\([^]]*\\)\\](\\(\\(?:[^()]\\|([^()]*)\\)*\\))"
     (lambda (m) ...link conversion...)
     s t t)))
```

Parse side, `mindwtr-parse--org->mw-text` (`mindwtr-parse.el:92`, regex at `:112`), gets the identical leading-bullet pass before the org→markdown link conversion. Because both directions normalize to `- `, a hand-typed `+ ` or `* ` bullet in the buffer converges to `- ` in a single sync cycle (the markdown re-baselines once) rather than churning the content signature forever. This is a deliberate **convert + normalize** design, not a lossless round-trip.

Inline emphasis (`**bold**`, `*italic*`, `_x_`, `` `code` ``) is left untouched in both directions.

## Why This Works

The fix targets the precise structural collision and nothing else. Org's heading grammar only triggers on a star-run + space at column 0, so neutralizing exactly that leading construct removes 100% of the injection surface. `- ` is the one bullet marker org carries safely inside a body — `*` at column 0 is always a heading, so it could never have been the target.

Leaving inline emphasis literal is what keeps the transform byte-safe: `snake_case`, `file_path_here`, and `2 * 3 * 4` survive unchanged because no regex touches mid-line `*`/`_`. The normalize-both-directions choice guarantees a fixed point: after the first sync, the markdown is `- `-canonical and `render == render(parse(render(x)))` holds.

## Prevention

The fix ships a byte-stability test matrix in `test/mindwtr-roundtrip-test.el`, driven by the helper `mindwtr-roundtrip--project-note-cycle` (`:299`), which renders a project whose `:supportNotes` is the adversarial note, parses it back, and re-renders for fixed-point comparison:

- `mindwtr-roundtrip-notes-no-heading-injection` (`:318`) — for each adversarial note (`"* foo\nbar"`, `"Intro\n* a\n* b\nmore"`, `"+ plus bullet"`, `"- dash bullet"`, `"** bold ** text"`, `"*** triple star"`) asserts exactly one parsed project, **zero** phantom tasks/projects, no rendered body line matching `"\n\\*+ "`, and the note content preserved with bullets normalized to `- `.
- `mindwtr-roundtrip-notes-literal-emphasis-not-corrupted` (`:344`) — asserts `snake_case_name`, `2 * 3 * 4`, `**bold** *italic* \`code\``, and `a*b*c` round-trip byte-identically (no emphasis conversion applied).
- `mindwtr-roundtrip-notes-render-byte-stable-across-structures` (`:358`) — asserts `render == render(parse(render(x)))` across bullets, literal emphasis, and links.

Guardrail to keep: any new inline transform added to the shared converter pair must be proven against the literal-emphasis cases (identifiers, arithmetic) before merge — the test matrix is the contract, and the "phantom-entity count == expected" assertion is the load-bearing check that distinguishes display corruption from server-write corruption.

## Related Issues

- GitHub an earlier PR — introduced this fix as "Finding B".
- Issue #35 — a pre-existing `mindwtr-parse--body` bug (a bare `:word:` line in note prose is read as a drawer and drops following content). The bullet-normalization work here widened its blast radius; the recorded fix direction is to restrict structural stripping (drawers + planning lines) to real org structure rather than matching anywhere in prose. Accepted as out of scope for #36. *(session history)*
- [[org-markdown-link-conversion-roundtrip]] — the link-truncation sibling; same round-trip byte-stability theme, a different transform (links rather than bullets) in the same converter pair.
- [[silent-deletion-untyped-org-headings]] — adjacent phantom/untyped heading handling; the downstream consequence of unintended headings reaching the parser.
- [[content-signature-allow-list-not-deny-list]] — the broader principle: normalize only the constructs you can prove safe, rather than transforming everything.
