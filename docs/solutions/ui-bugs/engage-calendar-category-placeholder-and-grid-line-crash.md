---
title: Engage calendar block rendered "???" for its category, and routing it through the project/area prefix crashes on grid lines
date: 2026-06-22
category: ui-bugs
module: mindwtr-agenda
problem_type: ui_bug
component: tooling
symptoms:
  - "The Engage \"Today\" calendar block led each line with the bare \"???\" placeholder where a category column should be"
  - "When a category was resolvable it rendered the useless \"mindwtr:\" filename category instead of the task's owning project/area, unlike the four tags-todo blocks"
  - "Naively reusing the tags/todo project-area prefix on the calendar block crashed the agenda build on time-grid and now-marker lines"
root_cause: config_error
resolution_type: code_fix
severity: medium
related_components:
  - mindwtr-agenda--engage-spec
  - mindwtr-agenda--resolve-prefix
  - mindwtr-agenda--calendar-prefix-format
  - mindwtr-heading-map
tags: [agenda, org-mode, prefix-format, category, calendar-block, grid-lines, gtd]
---

# Engage calendar block rendered "???" for its category, and routing it through the project/area prefix crashes on grid lines

## Problem

The Engage view's four `tags-todo` blocks lead each line with the task's owning project (or area) via `mindwtr-agenda--prefix-format`, replacing org's default filename category. The fifth block -- the single-day `agenda` (calendar) block -- did not: it kept org's stock `org-agenda-prefix-format`, whose `%-12:c` category column rendered as a bare `???` placeholder. The day's scheduled items thus showed up with no project context and an ugly placeholder where every other block showed the owning project.

## Symptoms

- In the Engage agenda, a task scheduled for today (e.g. "Order supplies" under project "Atlas") appeared in the "Today" calendar block led by `???` instead of `Atlas`.
- The four `tags-todo` blocks directly above it correctly led their lines with the project/area column -- so the calendar block was visibly inconsistent with the rest of the view.
- The naive fix (reuse the same `%(mindwtr-agenda--resolve-prefix)` escape the other blocks use) crashed the entire agenda build: rendering the calendar block errored on the time-grid and `now`-marker lines.

## What Didn't Work

**The `???` itself is a category-resolution dead end, not a missing `#+CATEGORY`.** Org's `%-12:c` prefix asks for the entry's category. The Mindwtr buffer has no `#+CATEGORY`, so org falls back to the buffer's filename -- but the buffer's category cache can be primed during a filename-less scan: `mindwtr-heading-map` binds `buffer-file-name` to nil. With no `#+CATEGORY` and no filename, the category resolves to nil and org prints its `???` placeholder (otherwise the useless `mindwtr:` filename category). Setting a `#+CATEGORY` would paper over the symptom but still show the *same* category on every line, not the per-line owning project the other blocks show. The right move is to stop asking org for a category here at all and route the calendar block through the same project/area resolver the tags-todo blocks use.

**The subtler trap: you cannot just point the calendar block at the existing prefix.** The `tags-todo` blocks resolve their per-line column with a `%(mindwtr-agenda--resolve-prefix)` escape. Org evaluates a `%(...)` escape with point on the entry's *source* heading, in the Org buffer -- which is why `mindwtr-agenda--resolve-prefix` can call `org-back-to-heading` and walk the outline. But an `agenda` block also emits **auxiliary lines** that are not entries: the time grid and the `now` marker. On those lines org evaluates the same `%(...)` escape with point in the *agenda* buffer, where there is no heading and `org-back-to-heading` signals an error -- aborting the whole agenda build. The tags-todo blocks never hit this because every line they emit is a real heading; the calendar block is the first caller that evaluates the escape off a heading.

```elisp
;; Before: calendar block keeps org's default prefix -> "%-12:c" -> "???"
(agenda ""
        ((org-agenda-span 1)
         (org-agenda-overriding-header "Today")))

;; Naive fix that crashes -- the resolver body assumes point is on a heading:
(or (mindwtr-agenda--resolve-project)   ; calls org-back-to-heading -> error off-heading
    (mindwtr-agenda--resolve-area)
    mindwtr-agenda--prefix-empty)
```

## Solution

Two parts: give the calendar block its own prefix format, and make the resolver safe to call off a heading.

**Part 1 -- a calendar-specific prefix format** that leads with the project/area column but keeps org's own time/scheduling tail:

```elisp
(defconst mindwtr-agenda--calendar-prefix-format
  "  %(mindwtr-agenda--resolve-prefix) %?-12t% s"
  "`org-agenda-prefix-format' for the Engage view's `agenda' (calendar) block.")

;; In the Engage spec, override the prefix on the calendar block only:
(agenda ""
        ((org-agenda-span 1)
         (org-agenda-prefix-format ,mindwtr-agenda--calendar-prefix-format)
         (org-agenda-overriding-header "Today")))
```

The leading `%(mindwtr-agenda--resolve-prefix)` reuses the shared project/area column. The trailing `%?-12t% s` is org's *own* default tail -- it preserves the time-of-day column and the scheduled/deadline leader (`Scheduled:`, `In N d.:`), so only the leading category is replaced and the calendar's date/time information is untouched.

**Part 2 -- guard the resolver for auxiliary lines** so the off-heading evaluation returns a blank column instead of erroring:

```elisp
(defun mindwtr-agenda--resolve-prefix ()
  (truncate-string-to-width
   (if (derived-mode-p 'org-mode)
       (or (mindwtr-agenda--resolve-project)
           (mindwtr-agenda--resolve-area)
           mindwtr-agenda--prefix-empty)
     "")
   mindwtr-agenda-prefix-width nil ?\s mindwtr-agenda-prefix-ellipsis))
```

`derived-mode-p 'org-mode` is the discriminator: when org evaluates the escape on a source heading, the current buffer is in `org-mode`; on a grid/now line, point is in the agenda buffer (`org-agenda-mode`, not derived from `org-mode`), so the guard returns `""`. `truncate-string-to-width` then pads that to `mindwtr-agenda-prefix-width`, so grid lines stay column-aligned under the project/area heading column instead of crashing.

## Why This Works

The fix separates the two things org's default prefix conflated. The *category* column was never meaningful for a filename-less, `#+CATEGORY`-less buffer -- so it is replaced wholesale with the project/area column that the rest of the view already uses, making all five Engage blocks consistent. The *time/scheduling* tail, which the calendar block genuinely needs, is preserved verbatim by reusing org's own `%?-12t% s` suffix rather than reinventing it. And because the shared resolver is now the entry point for lines that may or may not be headings, it is guarded to detect the off-heading case by buffer mode -- the one condition that distinguishes an entry line from an auxiliary one -- and degrade to an aligned blank rather than calling `org-back-to-heading` where there is no heading.

## Prevention

- **A `%(...)` prefix escape must survive being evaluated off a heading.** Org evaluates `org-agenda-prefix-format`'s `%(...)` on entry lines with point on the source heading, but on an `agenda` block's grid and `now`-marker lines it evaluates with point in the agenda buffer. Any helper that walks the outline (`org-back-to-heading`, `org-entry-get`, etc.) must gate on `(derived-mode-p 'org-mode)` and return a width-padded blank otherwise, or it will crash the agenda build. The `tags-todo` blocks hide this because every line they emit is a real heading -- the `agenda` block is where it bites.
- **Pad the off-heading fallback to the prefix width.** Returning `""` unpadded would misalign the grid under the heading column. Run the blank through the same `truncate-string-to-width ... mindwtr-agenda-prefix-width` path as the real column so auxiliary lines stay aligned.
- **Replace org's filename category rather than feeding it.** When a buffer has no `#+CATEGORY` and is scanned filename-less (`mindwtr-heading-map` binds `buffer-file-name` nil), org's `%-12:c` resolves to `???`. Setting a `#+CATEGORY` only swaps `???` for one constant string; if you want per-line context, override `org-agenda-prefix-format` to compute the column yourself and drop `%c` entirely.
- **Test the boundary, not just the headline.** Assert the project name *replaces* the category, and that neither `???` nor `mindwtr:` survives -- and separately, that the resolver returns an aligned blank off a heading. Isolate the calendar block's slice so a tags-todo line cannot satisfy the assertion by accident:

```elisp
;; Behavioral: calendar line leads with the project, no placeholder survives.
(let ((today (mindwtr-agenda-test--block-slice text "Today" "Today's Focus")))
  (should (string-match-p "Atlas +.*NEXT Order supplies" today))
  (should-not (string-match-p "\\?\\?\\?" today))
  (should-not (string-match-p "mindwtr:" today)))

;; Unit: resolver is blank (not an error) and width-padded off a heading.
(with-temp-buffer
  (fundamental-mode)
  (let ((prefix (mindwtr-agenda--resolve-prefix)))
    (should (string-match-p "\\`[ ]+\\'" prefix))
    (should (= (length prefix) mindwtr-agenda-prefix-width))))
```

## Related Issues

- [Future-dated ticklers leaked into the Engage Next Actions block because tags-todo ignores planning dates](../logic-errors/future-ticklers-leak-into-engage-next-actions.md) -- sibling Engage-view bug in the same `mindwtr-agenda--engage-spec`. That one is about *which* entries a block lists (planning-date semantics); this one is about *how* a block's lines are formatted (the prefix column). Both stem from the calendar block behaving differently from the `tags-todo` blocks around it.
- [Waiting projects leaked into the Engage Waiting For block via the shared WAIT keyword](../logic-errors/waiting-projects-leak-into-engage-waiting-for-block.md) -- another Engage-block correctness fix; a type-confusion membership bug rather than a formatting one.
