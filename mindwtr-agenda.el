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

(defvar mindwtr-agenda--stuck-cache nil
  "When non-nil (a hash (BUFFER . POS) -> boolean), memoizes stuck-project scans.
Bound to a fresh hash by `mindwtr-agenda--open' around one agenda build: the
Projects view runs `mindwtr-agenda--project-stuck-p' once per line via the
prefix format AND once per comparison in the sort (O(n log n) subtree scans
without the memo), all against an unchanging source buffer.  Nil outside a
build (e.g. an `org-agenda-redo'), where the uncached scan runs as before.")

(defun mindwtr-agenda--open (spec)
  "Open the agenda for the custom-command SPEC, scoped to the Mindwtr file.
Binds `org-agenda-files' to the Mindwtr file and `org-agenda-custom-commands' to
SPEC alone, then dispatches on SPEC's own key (its `car') -- so nothing leaks
into the user's global agenda configuration.  Shared by `mindwtr-engage' and
`mindwtr-projects'.  Also binds `mindwtr-agenda--stuck-cache' for the build."
  (let ((org-agenda-files (mindwtr-agenda--files))
        (org-agenda-custom-commands (list spec))
        (mindwtr-agenda--stuck-cache (make-hash-table :test 'equal)))
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
build (`mindwtr-agenda--stuck-cache')."
  (if (not mindwtr-agenda--stuck-cache)
      (mindwtr-agenda--project-stuck-p-1)
    (let* ((key (cons (current-buffer)
                      (save-excursion (org-back-to-heading t) (point))))
           (v (gethash key mindwtr-agenda--stuck-cache 'miss)))
      (if (eq v 'miss)
          (puthash key (mindwtr-agenda--project-stuck-p-1)
                   mindwtr-agenda--stuck-cache)
        v))))

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
primed during a filename-less scan (see `mindwtr-util--map-entries'), the bare
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
  (save-excursion
    (org-back-to-heading t)
    (catch 'found
      (while t
        (when (equal (org-entry-get (point) "MW_TYPE") "project")
          (throw 'found (point-marker)))
        (unless (org-up-heading-safe)
          (throw 'found nil))))))

(defun mindwtr-agenda--resolve-project ()
  "Return the clean title of point's owning project, or nil if standalone.
The title is stripped of TODO keyword, priority cookie, and tags."
  (let ((m (mindwtr-agenda--nearest-project-marker)))
    (when m
      (prog1 (org-with-point-at m (org-get-heading t t t t))
        (set-marker m nil)))))

(defun mindwtr-agenda--local-category ()
  "Return the heading at point's own literal `:CATEGORY:' drawer value, or nil.
Scans the physical PROPERTIES drawer line rather than calling
`org-entry-get'/`org-get-category', both of which route the special CATEGORY
property to the buffer/filename fallback -- the dead `???' / `mindwtr:' slot --
instead of nil when no drawer value exists (KTD5).  A blank value reads as nil
(the same blank-guard discipline the parser uses)."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (case-fold-search nil))
      (forward-line 1)
      (when (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
        (let ((drawer-end (save-excursion
                            (if (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
                                (point)
                              end))))
          (when (re-search-forward "^[ \t]*:CATEGORY:[ \t]*\\(.*?\\)[ \t]*$"
                                   drawer-end t)
            (let ((v (match-string-no-properties 1)))
              (unless (string-empty-p v) v))))))))

(defun mindwtr-agenda--resolve-area ()
  "Return point's area of focus (org `:CATEGORY:'), or nil.
Walks the outline ancestry (the heading itself counts) reading each heading's
own literal `:CATEGORY:' drawer line, returning the nearest one set -- so a
project task that carries no category of its own inherits its project's.
Returns nil when no ancestor carries a category, NEVER the filename-category
fallback `org-entry-get'/`org-get-category' would yield for the special
CATEGORY property (KTD5), so the prefix resolver still falls through to the
empty marker on an area-less line.  Mirrors the ancestry walk of
`mindwtr-agenda--nearest-project-marker', swapping its `org-entry-get' read for
the literal-drawer scan."
  (save-excursion
    (org-back-to-heading t)
    (catch 'found
      (while t
        (let ((cat (mindwtr-agenda--local-category)))
          (when cat (throw 'found cat)))
        (unless (org-up-heading-safe)
          (throw 'found nil))))))

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
                   (org-agenda-todo-ignore-scheduled 'future)))
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
