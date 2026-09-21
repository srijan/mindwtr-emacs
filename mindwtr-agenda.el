;;; mindwtr-agenda.el --- Opt-in org-agenda views for the Mindwtr file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Two opt-in `org-agenda' views over the Mindwtr file:
;;   `mindwtr-engage'   -- today's calendar, Today's Focus, Next Actions,
;;                         Waiting For, and the Inbox (in that order).
;;   `mindwtr-projects' -- active projects, with stuck ones (no NEXT action)
;;                         flagged inline and floated to the top.
;;
;; Each command builds its agenda dynamically and scopes `org-agenda-files' to
;; the Mindwtr file alone (the archive file is excluded -- archived/done
;; entities are not actionable), so the views work whether or not the user has
;; added the Mindwtr file to their global agenda configuration.  Nothing is
;; written to the user's global `org-agenda-custom-commands'.
;;
;; `mindwtr-agenda-setup' binds both commands under a configurable prefix
;; (default "C-c d": `e' -> Engage, `p' -> Projects).  The commands are also
;; plain `M-x'-invocable.
;;
;; This module deliberately never `require's `mindwtr.el' (which requires this
;; one): `mindwtr-file' is reached through a forward `defvar', mirroring
;; `mindwtr-archive.el'.
;;; Code:

(require 'org)
(require 'org-agenda)
(require 'mindwtr-model)
(require 'mindwtr-heading)
(require 'mindwtr-util)

(defvar mindwtr-file)

(defcustom mindwtr-agenda-prefix-key "C-c d"
  "Key prefix `mindwtr-agenda-setup' binds the Mindwtr agenda commands under.
Beneath this prefix, `e' is bound to `mindwtr-engage' and `p' to
`mindwtr-projects'.  A key description string as understood by `kbd'."
  :type 'string :group 'mindwtr)

(defcustom mindwtr-agenda-prefix-width 30
  "Column width of the Engage view's owning-project/area prefix.
Each Next Action (and Focus/Waiting/Inbox) line leads with the task's owning
project, falling back to its area of focus -- see
`mindwtr-agenda--resolve-prefix'.  Longer values are truncated to this width
with `mindwtr-agenda-prefix-ellipsis'."
  :type 'integer :group 'mindwtr)

(defcustom mindwtr-agenda-prefix-ellipsis "..."
  "String appended when an Engage prefix is truncated to fit its column.
See `mindwtr-agenda-prefix-width'."
  :type 'string :group 'mindwtr)

(defun mindwtr-agenda--files ()
  "Return the agenda file list scoped to the Mindwtr task file.
Signals a clear error when `mindwtr-file' is unset (mirrors the guard in
`mindwtr--prepare').  Deliberately excludes the archive file: archived and
done entities are not actionable and must not appear in these views."
  (unless mindwtr-file (error "mindwtr-agenda: set `mindwtr-file'"))
  (list mindwtr-file))

(defvar mindwtr-agenda--cache nil
  "When non-nil (a hash), memoizes per-heading subtree scans for one build.
Bound to a fresh hash by `mindwtr-agenda--open' around one agenda build, which
scans the same unchanging source buffer many times: the Projects view runs
`mindwtr-agenda--project-stuck-p' once per line via the prefix format AND once
per comparison in the sort (O(n log n) subtree scans without the memo), and the
Engage view runs `mindwtr-agenda--sequential-slot' once per candidate step of
the same project.  Nil outside a build (e.g. an `org-agenda-redo'), where the
uncached scan runs as before.")

(defun mindwtr-agenda--memo (key thunk)
  "Return (funcall THUNK), memoized under KEY in `mindwtr-agenda--cache'.
Calls THUNK directly when no build cache is bound.  KEY must name the scan as
well as its heading, since one cache serves every memoized scan."
  (if (not mindwtr-agenda--cache)
      (funcall thunk)
    (let ((v (gethash key mindwtr-agenda--cache 'miss)))
      (if (eq v 'miss) (puthash key (funcall thunk) mindwtr-agenda--cache) v))))

(defun mindwtr-agenda--open (spec)
  "Open the agenda for the custom-command SPEC, scoped to the Mindwtr file.
Binds `org-agenda-files' to the Mindwtr file and `org-agenda-custom-commands' to
SPEC alone, then dispatches on SPEC's own key (its `car') -- so nothing leaks
into the user's global agenda configuration.  Shared by `mindwtr-engage' and
`mindwtr-projects'.  Also binds `mindwtr-agenda--cache' for the build."
  (let ((org-agenda-files (mindwtr-agenda--files))
        (org-agenda-custom-commands (list spec))
        (mindwtr-agenda--cache (make-hash-table :test 'equal)))
    (org-agenda nil (car spec))))

(defun mindwtr-agenda--project-stuck-p-1 ()
  "Uncached subtree scan behind `mindwtr-agenda--project-stuck-p'."
  (save-excursion
    (org-back-to-heading t)
    (and (equal (org-get-todo-state) "ACTIVE")
         (let ((end (save-excursion (org-end-of-subtree t t) (point)))
               (found nil))
           (save-excursion
             (while (and (not found)
                         (outline-next-heading)
                         (< (point) end))
               (when (equal (org-get-todo-state) "NEXT")
                 (setq found t))))
           (not found)))))

(defun mindwtr-agenda--project-stuck-p ()
  "Non-nil when the project heading at point is stuck.
A project is stuck when it is active (TODO keyword ACTIVE) and has no
descendant carrying the NEXT keyword.  Only NEXT clears stuck: WAIT, SOMEDAY,
and DONE children do not.  The scan covers the whole subtree, so a NEXT task
nested under a section still counts.  Returns nil off an active project
heading.  Used both as the Projects view's inline stuck flag and its sort key,
so the definition lives in one place; memoized per heading during one agenda
build (`mindwtr-agenda--cache')."
  (mindwtr-agenda--memo (list 'stuck (current-buffer)
                              (save-excursion (org-back-to-heading t) (point)))
                        #'mindwtr-agenda--project-stuck-p-1))

;;; Engage prefix: owning project / area ---------------------------------------

(defconst mindwtr-agenda--prefix-empty "-"
  "Marker shown in the Engage prefix when a task has no owning project or area.
A plain hyphen: a task that is neither under a project nor filed to an area
(e.g. a raw Inbox item) reads as a clean blank slot rather than a dead filename.")

(defconst mindwtr-agenda--prefix-format "  %(mindwtr-agenda--resolve-prefix) "
  "`org-agenda-prefix-format' value for the Engage view's TODO/tags blocks.
The `%(...)' escape org evaluates with point on the source heading (the same
mechanism the Projects view uses for its STUCK flag), so the per-line prefix is
resolved by `mindwtr-agenda--resolve-prefix'.")

(defconst mindwtr-agenda--calendar-prefix-format
  "  %(mindwtr-agenda--resolve-prefix) %?-12t% s"
  "`org-agenda-prefix-format' for the Engage view's `agenda' (calendar) block.
Leads each line with the task's owning project/area via the same
`mindwtr-agenda--resolve-prefix' column the TODO/tags blocks use, in place of
org's default filename category.  Area-bearing lines now carry a real per-item
`:CATEGORY:' drawer value (the area name), which fills what was otherwise the
dead filename-category slot; area-less lines still fall back to org's filename
category -- the useless `mindwtr:' or, when the buffer's category cache was
primed during a filename-less scan (see `mindwtr-heading-map'), the bare
`???' placeholder -- so this column replaces it for every line.  The trailing
`%?-12t% s' is org's own default tail: it keeps the time-of-day column and the
scheduled/deadline leader (`Scheduled:', `In N d.:'), so only the leading
category is replaced -- the calendar's date/time information is unchanged.")

(defun mindwtr-agenda--nearest-project-marker ()
  "Return a marker on the nearest `MW_TYPE=project' ancestor of point, or nil.
Walks up the outline from the heading at point (the heading itself counts).
Mindwtr links a task to its project by outline nesting in the main file -- there
is no MW_PROJECT_ID there -- so the owning project is found by ancestry, the
inverse of the subtree walk in `mindwtr-agenda--project-stuck-p'."
  (let ((pos (mindwtr-heading-ancestor-pos 'project t)))
    (and pos (copy-marker pos))))

(defun mindwtr-agenda--resolve-project ()
  "Return the clean title of point's owning project, or nil if standalone.
The title is stripped of TODO keyword, priority cookie, and tags."
  (let ((m (mindwtr-agenda--nearest-project-marker)))
    (when m
      (prog1 (org-with-point-at m (org-get-heading t t t t))
        (set-marker m nil)))))

(defun mindwtr-agenda--resolve-area ()
  "Return point's area of focus (org `:CATEGORY:'), or nil.
Walks the outline ancestry (the heading itself counts) reading each heading's
own literal `:CATEGORY:' drawer line, returning the nearest one set -- so a
project task that carries no category of its own inherits its project's.
Returns nil when no ancestor carries a category, NEVER the filename-category
fallback `org-entry-get'/`org-get-category' would yield for the special
CATEGORY property (KTD5), so the prefix resolver still falls through to the
empty marker on an area-less line.  A blank value reads as nil."
  (mindwtr-heading-inherited-prop "CATEGORY"))

(defun mindwtr-agenda--resolve-prefix ()
  "Return the Engage prefix string for the heading at point.
Fallback chain (R: most decision-relevant first): owning project title, else
area of focus, else `mindwtr-agenda--prefix-empty'.  Padded with spaces to, and
truncated with `mindwtr-agenda-prefix-ellipsis' at,
`mindwtr-agenda-prefix-width' so titles stay column-aligned.

Guarded for the calendar block, whose `org-agenda-prefix-format' also routes
through here (`mindwtr-agenda--calendar-prefix-format').  Org evaluates a
`%(...)' escape on a heading line with point in the Org source buffer, but on an
auxiliary line (the time grid, the `now' marker) with point in the agenda buffer
itself -- where `org-back-to-heading' would error.  `derived-mode-p' detects
that case (`org-agenda-mode' is not derived from `org-mode') and returns a
blank, width-padded column so grid lines stay aligned under the project/area
heading column instead of crashing the agenda build."
  (truncate-string-to-width
   (if (derived-mode-p 'org-mode)
       (or (mindwtr-agenda--resolve-project)
           (mindwtr-agenda--resolve-area)
           mindwtr-agenda--prefix-empty)
     "")
   mindwtr-agenda-prefix-width nil ?\s mindwtr-agenda-prefix-ellipsis))

;;; Sequential projects: the blocked-step filter -------------------------------
;;
;; Mirrors upstream's `getFocusSequentialFirstTaskIds' /
;; `getFocusSequentialScheduleKey' (Mindwtr core `task-utils.ts'): every
;; candidate step of a sequential project is scored (RANK . TIME) and the
;; lowest score holds the project's one slot, with document order breaking
;; ties.  It is NOT "the first step, unless a later one is due" -- that
;; order-first reading is the bug upstream fixed in its own widgets.

(defconst mindwtr-agenda--sequence-keywords '("NEXT" "WAIT")
  "TODO keywords that put a task in a sequential project's chain.
Upstream's `isSequentialChainStatus': next or waiting.  WAIT is in because a
delegated step is committed and genuinely blocks the ones after it.  A step
outside the chain can still compete, but only by being focused or review-due
-- which pool it is drawn from is `mindwtr-agenda--eligible-keywords' rule,
not this one.

Known gap: a task the server cancelled keeps whatever keyword it had, because
`:cancelledAt' is recognized-only and never rendered, so a cancelled NEXT step
still holds the slot.  Fixable only by surfacing that field.")

(defconst mindwtr-agenda--eligible-keywords '("INBOX" "NEXT" "WAIT" "SOMEDAY")
  "TODO keywords a task must carry to compete for a sequential project's slot.
Upstream `FOCUS_ELIGIBILITY_ACTIVE_STATUSES' (core `task-utils.ts'), which
filters the candidate pool BEFORE anything is scored.  DONE/ARCH are finished
and REF is not an action, so none of them can hold a slot -- not even carrying
a stale MW_REVIEW_AT or MW_FOCUS_TODAY, which would otherwise hand a completed
step the slot and freeze the project for good.")

(defconst mindwtr-agenda--iso-re
  (concat "\\`[0-9]\\{4\\}\\(?:-[0-9]\\{2\\}\\(?:-[0-9]\\{2\\}"
          "\\(?:T[0-9]\\{2\\}:[0-9]\\{2\\}\\(?::[0-9]\\{2\\}\\(?:\\.[0-9]+\\)?\\)?"
          "\\(?:Z\\|[-+]\\(?:0[0-9]\\|1[0-4]\\):[0-5][0-9]\\)?\\)?\\)?\\)?\\'")
  "The ISO 8601 shapes MW_REVIEW_AT may take: a closed ALLOW-list.
Deliberately narrower than the standard.  The server writes exactly one form
\(`YYYY-MM-DDTHH:MM:SS.mmmZ'), the drawer is hand-editable, and
`iso8601-parse' NORMALIZES whatever it is handed rather than signalling -- so
anything outside what the server writes or a human plausibly types is a typo,
and guessing at it is how a typo becomes a real overdue review that steals a
sequential project's slot.  Reduced precision (`2026-02', `2026') is in
because upstream resolves it too.

An allow-list rather than a list of things to reject: checking fields one at a
time sprang a new leak on each review round -- an impossible day, then hour 25,
then offset minute 99, then a fractional hour read as the whole hour.  What is
not written here cannot parse, so the set of leaks is closed.

Sub-second precision IS accepted and then discarded: `iso8601-parse' truncates
to the second, so two reviews within the same second tie and document order
decides where upstream would order them by the fraction.  Left alone on
purpose -- preserving it means changing `mindwtr-util-iso->time', which three
sync-path callers share and which `mindwtr-util-iso-coarsen-minute' exists to
coarsen further for signature stability.  Sub-second ordering of two reviews
is not something a reader of the agenda can perceive.")

(defun mindwtr-agenda--iso-sane-p (iso dec)
  "Non-nil when ISO, parsed as DEC, is a review timestamp worth believing.
Shape first (`mindwtr-agenda--iso-re'), then the values: a real calendar date,
and a clock within range -- allowing ISO's one legitimate overflow, the
end-of-day form `T24:00:00', and a leap second."
  (let ((day (decoded-time-day dec))
        (month (decoded-time-month dec))
        (hour (decoded-time-hour dec))
        (minute (decoded-time-minute dec))
        (second (decoded-time-second dec)))
    (and (string-match-p mindwtr-agenda--iso-re iso)
         (<= 1 month 12)
         (<= 0 minute 59)
         (<= 0 second 60)
         (or (<= 0 hour 23)
             ;; `T24:00:00' only, and only bare: a fraction on it ("T24:00:00.5")
             ;; is not the end-of-day form, and the fraction is truncated away
             ;; before it could be seen in DEC.
             (and (= hour 24) (= minute 0) (= second 0)
                  (not (string-match-p "T24:00:00\\." iso))))
         ;; Re-encode the DATE at midday, where no zone or DST edge can shift
         ;; it, and require day and month to survive the trip -- Feb 30 lands
         ;; on Mar 2 rather than signalling.
         (let ((back (decode-time
                      (encode-time (list 0 0 12 day month
                                         (decoded-time-year dec) nil -1 nil)))))
           (and (eq day (decoded-time-day back))
                (eq month (decoded-time-month back)))))))

(defun mindwtr-agenda--review-time ()
  "Time value of the entry's MW_REVIEW_AT, or nil when absent or malformed.
The property holds a raw ISO timestamp, so it goes through
`mindwtr-util-iso->time' rather than org's timestamp reader.  That value is
hand-editable, so a malformed one reads as \"no review\" instead of aborting
the agenda build."
  (let ((iso (mindwtr-heading-prop-nonblank "MW_REVIEW_AT")))
    (and iso
         (ignore-errors
           ;; `iso8601-parse' + `encode-time' NORMALIZE an impossible calendar
           ;; date instead of signalling (Feb 30 -> Mar 2, month 13 -> next
           ;; January and hour 25 becomes 01:00 the next day), so a hand-typo
           ;; would become a real -- usually past -- review that takes the
           ;; slot.  `decoded-time-set-defaults' first, so a legitimately
           ;; reduced-precision value ("2026-02") keeps working.
           (let ((dec (decoded-time-set-defaults (iso8601-parse iso))))
             (and (mindwtr-agenda--iso-sane-p iso dec)
                  (mindwtr-util-iso->time iso)))))))

(defun mindwtr-agenda--deadline-rank-time (time)
  "Return the ranking instant for a DEADLINE parsed as TIME.
A DATE-ONLY deadline ranks at the END of its day, matching upstream
`safeParseDueDate': an all-day item due today is less urgent than one due at
09:00 the same day, not more.  Org parses it as midnight, which inverts that.

Ranking ONLY.  Whether the deadline falls today is decided on the raw date --
see `mindwtr-agenda--slot-score' -- because on a day whose final hour does not
exist (a midnight DST jump, e.g. America/Nuuk in March) the end-of-day instant
lands after midnight, and testing THAT against today would read a deadline due
today as future for the whole of its own day."
  (if (string-match-p "[0-9][0-9]:[0-9][0-9]"
                      (org-entry-get (point) "DEADLINE"))
      time
    ;; Rebuild from the date fields with an UNKNOWN DST flag and no zone, so
    ;; `encode-time' resolves 23:59:59 in local time.  Carrying midnight's own
    ;; offset instead pins the pre-transition zone.
    (let ((d (decode-time time)))
      (encode-time (list 59 59 23 (decoded-time-day d) (decoded-time-month d)
                         (decoded-time-year d) nil -1 nil)))))

(defun mindwtr-agenda--slot-score (now today)
  "Score the step at point for its sequential project's one slot as (RANK . TIME).
Lower wins.  NOW is epoch seconds, TODAY an `org-today' day number.

Rank 0 is a step the user put in Today's Focus; it always holds the slot.
Rank 1 is a step whose deadline falls today or earlier, or whose review has
come due, TIME being the earlier of the two -- so between two due steps the
more urgent one wins, not the earlier one in the buffer.  Rank 2 is everything
else, ordered by position alone.

A WAIT step's deadline earns nothing (upstream: it is not actionable, and
letting it outrank an earlier actionable step would hide real work); a WAIT
step holds its slot by order alone.  Its review date still counts, since
review surfaces regardless of status."
  (if (equal "t" (mindwtr-heading-prop "MW_FOCUS_TODAY"))
      (cons 0 0)
    (let ((due (org-get-deadline-time (point)))
          (review (mindwtr-agenda--review-time))
          (best 1.0e+INF))
      (when (and due (<= (time-to-days due) today)
                 (not (equal (org-get-todo-state) "WAIT")))
        (setq best (float-time (mindwtr-agenda--deadline-rank-time due))))
      (when (and review (<= (float-time review) now))
        (setq best (min best (float-time review))))
      (cons (if (< best 1.0e+INF) 1 2) best))))

(defun mindwtr-agenda--sequence-candidate-p (now)
  "Non-nil when the step at point competes for its project's slot at NOW.
Upstream `isFocusSequentialCandidate', over the eligible pool: focused-today,
or in the chain (`mindwtr-agenda--sequence-keywords'), or review-due whatever
its status.  Review is compared as an INSTANT (upstream `isDueForReview'): one
set for 23:59 must not pull the slot at 00:01, which a day-granular test would.

The kind test is an ALLOW-list of task-or-untyped, not a list of structure
kinds to reject.  Untyped must pass: a hand-typed action under a project
carries no `:MW_TYPE:' until the next sync stamps one, and demanding one made
a freshly typed action invisible to the walk.  But the keyword alone cannot
stand in for the type -- a SECTION whose title merely begins with a keyword
word renders as `*** WAIT Vendor', which Org reads as a WAIT heading, and it
would take the slot from the section's own task."
  (let ((kw (org-get-todo-state)))
    (and (memq (mindwtr-heading-kind) '(nil task))
         (member kw mindwtr-agenda--eligible-keywords)
         (or (equal "t" (mindwtr-heading-prop "MW_FOCUS_TODAY"))
             (member kw mindwtr-agenda--sequence-keywords)
             (let ((review (mindwtr-agenda--review-time)))
               (and review (<= (float-time review) now)))))))

(defun mindwtr-agenda--sequential-slot (ppos)
  "Position of the step holding the sequential project at PPOS's one slot.
An uncached scan; `mindwtr-agenda--blocked-step-p' memoizes it per project.
PPOS is the start of a project heading.  Walks its subtree in document order,
which IS upstream 1.3.0's sequence for a sequential project -- sections in
`:order', tasks in `:order' within each section, then the no-section tasks in
`:order' -- because `mindwtr-render--project-subtree' emits exactly that layout
and (since bb67d2d) document order round-trips back as `:order'.  No display
sort enters the calculation; project `:taskSortBy' is presentation-only.

Returns the position of the best-scoring candidate
\(`mindwtr-agenda--slot-score'), or nil when the project has no candidate at
all.  Document order breaks a tie, so an equal score keeps the earlier step."
  (org-with-point-at ppos
    (let ((end (save-excursion (org-end-of-subtree t t) (point)))
          (now (float-time))
          (today (org-today))
          (best (cons 1.0e+INF 1.0e+INF))
          (nested-end 0)
          slot)
      (while (and (outline-next-heading) (< (point) end))
        (cond
         ;; Inside a project demoted under this one: it owns its own sequence,
         ;; so its steps must not compete here (upstream groups by projectId).
         ((< (point) nested-end))
         ((eq (mindwtr-heading-kind) 'project)
          (setq nested-end (save-excursion (org-end-of-subtree t t) (point))))
         ((mindwtr-agenda--sequence-candidate-p now)
          (let ((score (mindwtr-agenda--slot-score now today)))
            (when (or (< (car score) (car best))
                      (and (= (car score) (car best))
                           (< (cdr score) (cdr best))))
              (setq slot (point) best score))))))
      slot)))

(defun mindwtr-agenda--blocked-step-p ()
  "Non-nil when the task at point is a blocked step of a sequential project.
Blocked means another step holds the project's slot -- the state the apps
expose as `view: blocked'.  Nil for a standalone task, for a task in a project
without `:MW_SEQUENTIAL: t', and for the slot holder itself.

Nil too when the project has NO slot holder: an empty slot must fail OPEN.
Blocking on a nil slot hid every action of a project the walk could not read,
with nothing in Emacs able to clear it.

ponytail: treats every sequential project as `sequentialScope: project' (one
slot for the whole project).  The server's `section' scope (one slot per
section) is invisible here -- `:sequentialScope' is recognized-only and never
rendered to org -- so a section-scoped project hides steps the apps would show.
Upgrade path: render it as a drawer property, or read it from the shadow."
  ;; Widened: an agenda restriction (`org-agenda-restrict' to a section, say)
  ;; narrows the source buffer before the skip function runs, which hides the
  ;; project ancestor and made every step inside it read as standalone -- so a
  ;; restricted view showed blocked steps an unrestricted one hid.
  (save-restriction
    (widen)
    (let ((ppos (mindwtr-heading-ancestor-pos 'project)))
      (and ppos
           (equal "t" (org-with-point-at ppos (mindwtr-heading-prop "MW_SEQUENTIAL")))
           (let ((slot (mindwtr-agenda--memo
                        (list 'slot (current-buffer) ppos)
                        (lambda () (mindwtr-agenda--sequential-slot ppos)))))
             (and slot
                  (not (eq slot (save-excursion (org-back-to-heading t) (point))))))))))

(defun mindwtr-agenda--skip-blocked-step ()
  "`org-agenda-skip-function' dropping blocked steps of sequential projects.
Returns the end of THIS ENTRY (org's signal to skip it) or nil to keep it.
Deliberately not the end of the subtree: a step nested under another step is
its own candidate and may be the very one holding the slot, so skipping the
parent must not skip past it."
  (when (mindwtr-agenda--blocked-step-p)
    (org-entry-end-position)))

;;; Engage view ----------------------------------------------------------------

(defun mindwtr-agenda--engage-spec ()
  "Return the composite `org-agenda-custom-commands' entry for the Engage view.
Blocks, in order (R1): today's calendar, Today's Focus, Next Actions, Waiting
For, and the Inbox last.

The Next Actions block excludes focused tasks with the property INEQUALITY
`MW_FOCUS_TODAY<>\"t\"', not tag negation `-MW_FOCUS_TODAY': MW_FOCUS_TODAY is
a drawer property (it renders as `:MW_FOCUS_TODAY: t'), so `-MW_FOCUS_TODAY'
would negate a non-existent tag and fail to dedup.  The inequality form also
correctly matches the common case where the property is absent (every
non-focused task), so those still appear under Next Actions.

The Next Actions block also defers ticklers: a NEXT task with a SCHEDULED date
in the future is not yet actionable, so it is dropped from this block until its
start date (`org-agenda-todo-ignore-scheduled' `future', enabled for the
tags-todo search by `org-agenda-tags-todo-honor-ignore-options').  Today's and
overdue scheduled tasks stay; deadlines are not ignored.

It also drops blocked steps of sequential projects
(`mindwtr-agenda--skip-blocked-step'): such a project grants one slot at a
time, so listing steps 2..N here made the desk disagree with the apps about
what is actionable.  Today's Focus is deliberately NOT filtered -- it is an
explicit user pick.

The Waiting For block is scoped `+MW_TYPE=\"task\"': a project in the waiting
state shares the WAIT keyword (`mindwtr-model--project-status-keywords'), but a
waiting project is not a delegated action and belongs to the Projects view, so
it must not surface here.  Next Actions and Inbox need no such guard -- projects
are never NEXT or INBOX.

The calendar block is a single day (`org-agenda-span' 1) and deliberately does
NOT override `org-deadline-warning-days': upcoming deadlines surface through the
user's own org default (R2).

All five blocks lead each line with the task's owning project (or area),
replacing org's default filename category: the four `tags-todo' blocks via
`mindwtr-agenda--prefix-format', and the calendar block via
`mindwtr-agenda--calendar-prefix-format', which additionally retains org's
time-of-day and scheduled/deadline columns so the calendar's date/time
information is preserved."
  (let ((pf `((tags . ,mindwtr-agenda--prefix-format)
              (todo . ,mindwtr-agenda--prefix-format))))
    `("e" "Mindwtr Engage"
      ((agenda ""
               ((org-agenda-span 1)
                (org-agenda-prefix-format ,mindwtr-agenda--calendar-prefix-format)
                (org-agenda-overriding-header "Today")))
       (tags-todo "MW_FOCUS_TODAY=\"t\""
                  ((org-agenda-overriding-header "Today's Focus")
                   (org-agenda-prefix-format ',pf)))
       (tags-todo "TODO=\"NEXT\"+MW_FOCUS_TODAY<>\"t\""
                  ((org-agenda-overriding-header "Next Actions")
                   (org-agenda-prefix-format ',pf)
                   ;; A future SCHEDULED date marks a tickler (Clarify's defer
                   ;; outcome: NEXT + SCHEDULED) -- not actionable until its
                   ;; start date, so drop it from Next Actions until then; it
                   ;; resurfaces in the calendar block on the day it lands.
                   ;; `tags-todo' searches ignore planning dates unless
                   ;; `org-agenda-tags-todo-honor-ignore-options' is set, so
                   ;; both bindings are required.  `future' keeps today's and
                   ;; overdue ticklers visible (still actionable / nagging) --
                   ;; only strictly-future ones are deferred.  Deadlines are
                   ;; left untouched: a due-but-not-started task is actionable
                   ;; now, and its deadline surfaces in the calendar block.
                   (org-agenda-tags-todo-honor-ignore-options t)
                   (org-agenda-todo-ignore-scheduled 'future)
                   ;; A later step of a sequential project is blocked until the
                   ;; steps before it are done -- the apps hide it, so the desk
                   ;; must too (see `mindwtr-agenda--skip-blocked-step').
                   (org-agenda-skip-function
                    'mindwtr-agenda--skip-blocked-step)))
       (tags-todo "TODO=\"WAIT\"+MW_TYPE=\"task\""
                  ((org-agenda-overriding-header "Waiting For")
                   (org-agenda-prefix-format ',pf)))
       (tags-todo "TODO=\"INBOX\""
                  ((org-agenda-overriding-header "Inbox")
                   (org-agenda-prefix-format ',pf)))))))

;;;###autoload
(defun mindwtr-engage ()
  "Open the Mindwtr Engage agenda: today, focus, next actions, waiting, inbox.
Scopes `org-agenda-files' to the Mindwtr file and builds the view dynamically,
so it works with no global agenda configuration."
  (interactive)
  (mindwtr-agenda--open (mindwtr-agenda--engage-spec)))

;;; Projects view --------------------------------------------------------------

(defconst mindwtr-agenda--stuck-flag "STUCK"
  "Plain-text marker shown before a stuck project in the Projects view (R12).")

(defun mindwtr-agenda--project-prefix ()
  "Agenda prefix for the project heading at point: a STUCK marker or blanks.
Invoked from the Projects view `org-agenda-prefix-format' via its `%(...)'
escape, which org evaluates with point on the source heading.  Returns a
plain-text `STUCK ' for a stuck project and an equal-width blank string
otherwise, so the project titles stay column-aligned (R8, R12)."
  (if (mindwtr-agenda--project-stuck-p)
      (concat mindwtr-agenda--stuck-flag " ")
    (make-string (1+ (length mindwtr-agenda--stuck-flag)) ?\s)))

(defun mindwtr-agenda--entry-stuck-p (line)
  "Non-nil when agenda LINE's project (via its `org-hd-marker') is stuck."
  (let ((m (get-text-property 0 'org-hd-marker line)))
    (and m (org-with-point-at m (mindwtr-agenda--project-stuck-p)))))

(defun mindwtr-agenda--project-cmp (a b)
  "Sort comparator floating stuck projects ahead of the rest.
Returns -1/+1/nil for agenda lines A and B; paired with the
`user-defined-up' sorting strategy so stuck projects lead the single list."
  (let ((sa (mindwtr-agenda--entry-stuck-p a))
        (sb (mindwtr-agenda--entry-stuck-p b)))
    (cond ((and sa (not sb)) -1)
          ((and sb (not sa)) +1)
          (t nil))))

(defun mindwtr-agenda--projects-spec ()
  "Return the `org-agenda-custom-commands' entry for the Projects view.
Two blocks: active projects (`MW_TYPE=\"project\"' with the ACTIVE keyword, R7),
where stuck ones are flagged inline by `mindwtr-agenda--project-prefix' and
floated to the top by `mindwtr-agenda--project-cmp' (R8); then waiting projects
(the WAIT keyword) under their own header.  Both blocks use
`mindwtr-agenda--project-prefix', which suppresses org's default filename
category.  A waiting project is intentionally blocked, not stalled: it is never
ACTIVE, so the prefix yields blank padding (no STUCK flag) aligned with the
active block."
  (let ((project-pf '((tags . " %(mindwtr-agenda--project-prefix)"))))
    `("p" "Mindwtr Projects"
      ((tags-todo "MW_TYPE=\"project\"+TODO=\"ACTIVE\""
                  ((org-agenda-overriding-header "Projects")
                   (org-agenda-prefix-format ',project-pf)
                   (org-agenda-cmp-user-defined #'mindwtr-agenda--project-cmp)
                   (org-agenda-sorting-strategy '(user-defined-up))))
       (tags-todo "MW_TYPE=\"project\"+TODO=\"WAIT\""
                  ((org-agenda-overriding-header "Waiting Projects")
                   (org-agenda-prefix-format ',project-pf)))))))

;;;###autoload
(defun mindwtr-projects ()
  "Open the Mindwtr Projects agenda: active projects (stuck ones flagged first),
then waiting projects.  Scopes `org-agenda-files' to the Mindwtr file and builds
the view dynamically, so it works with no global agenda configuration."
  (interactive)
  (mindwtr-agenda--open (mindwtr-agenda--projects-spec)))

;;; Setup ----------------------------------------------------------------------

;;;###autoload
(defun mindwtr-agenda-setup ()
  "Bind the Mindwtr agenda commands under `mindwtr-agenda-prefix-key'.
Installs a global prefix keymap (default \"C-c d\") with `e' -> `mindwtr-engage'
and `p' -> `mindwtr-projects'.  Idempotent: a fresh prefix keymap is built and
re-installed each call, so calling it twice leaves a single consistent binding."
  (interactive)
  (let ((map (make-sparse-keymap)))
    (define-key map "e" #'mindwtr-engage)
    (define-key map "p" #'mindwtr-projects)
    (global-set-key (kbd mindwtr-agenda-prefix-key) map)))

(provide 'mindwtr-agenda)
;;; mindwtr-agenda.el ends here
