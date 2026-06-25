;;; mindwtr-reconcile.el --- Apply merged appdata into the org buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Rebuilds the current buffer in full from a merged AppData via the canonical
;; renderer (`mindwtr-render-appdata').  Per-id org-only content (LOGBOOK/CLOCK
;; drawers, unknown PROPERTIES) is collected beforehand and grafted back so it
;; survives the rebuild; point is restored to the heading of the entity it was
;; on (column / in-body position is not preserved).  `mindwtr-reconcile-restore-entity'
;; still does an in-place single-heading rebuild for the conflict-restore action.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)
(require 'mindwtr-util)

(defun mindwtr-reconcile--id-markers ()
  "Return a hash MW_ID -> marker at heading start for every entity heading."
  (let ((h (make-hash-table :test 'equal)))
    (mindwtr-util--map-entries
     (lambda ()
       ;; Use the parser's own drawer scan rather than `org-entry-get': the
       ;; latter fails to associate a PROPERTIES drawer with its heading when
       ;; another drawer (e.g. a LOGBOOK placed above PROPERTIES) precedes it,
       ;; which would leave the entity unmatched and make reconcile append a
       ;; spurious duplicate instead of updating it in place.
       (let ((id (mindwtr-parse--prop "MW_ID")))
         (when id (puthash id (point-marker) h)))))
    h))

(defun mindwtr-reconcile--body-start ()
  "Return the position just after this entry's PROPERTIES drawer.
Point must be at the heading.  Falls back to the line after the heading
when there is no PROPERTIES drawer (so the body scan still has a start)."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (case-fold-search nil))
      (if (and (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
               (re-search-forward "^[ \t]*:END:[ \t]*$" end t))
          (min (1+ (point)) end)
        (progn (org-back-to-heading t) (forward-line 1) (point))))))

(defun mindwtr-reconcile--preserved-body (kind body-start end)
  "Return org-only body text between BODY-START and END to carry across a rebuild.
The renderer emits notes prose (+ checklist for tasks) for every kind that has
a notes field (`mindwtr-model-notes-field': task, project, section), so for
those the prose is regenerated from the merged entity and only genuinely
org-only lines are preserved: drawer blocks (LOGBOOK and CLOCK-in-drawer) and
bare CLOCK lines.  A kind with no notes field (`area') has its entire body
treated as org-only and preserved verbatim.  Returns nil when there is nothing
to preserve.

Note: for project/section this MUST narrow in lockstep with render starting to
emit the note -- if it kept carrying the whole body, render and preserved-body
would both claim the note bytes and it would appear twice (double-graft)."
  (if (not (mindwtr-model-notes-field kind))
      (let ((s (buffer-substring-no-properties body-start end)))
        (unless (string-empty-p (string-trim s)) s))
    (save-excursion
      (goto-char body-start)
      (let ((case-fold-search nil) parts)
        (while (< (point) end)
          (cond
           ((looking-at "^[ \t]*:\\([A-Za-z0-9_]+\\):[ \t]*$")
            (let ((name (match-string-no-properties 1)) (bbeg (point)))
              (forward-line 1)
              (unless (string= (upcase name) "END")
                (while (and (< (point) end)
                            (not (looking-at "^[ \t]*:END:[ \t]*$")))
                  (forward-line 1))
                (when (< (point) end) (forward-line 1)) ; consume the :END: line
                (push (buffer-substring-no-properties bbeg (min (point) end))
                      parts))))
           ((looking-at "^[ \t]*CLOCK:")
            (let ((cbeg (point)))
              (forward-line 1)
              (push (buffer-substring-no-properties cbeg (min (point) end)) parts)))
           (t (forward-line 1))))
        (when parts (mapconcat #'identity (nreverse parts) ""))))))

(defun mindwtr-reconcile--rebuild-entry (entity kind)
  "Replace the entry at point with a full render of ENTITY (kind KIND).
Point must be at the heading.  Rewrites the heading line, planning,
drawer, description and checklist from ENTITY by reusing the canonical
renderer -- so a remote change to ANY mapped field (dates, description,
checklist, drawer props, tags) reaches the buffer instead of silently
reverting on the next sync.  Preserves the heading's outline level,
unknown PROPERTIES, and org-only body content: LOGBOOK/CLOCK for any
note-bearing kind (task/project/section, whose prose is regenerated from the
merged entity), and the entire free-prose body only for `area' (which has no
notes field).  Child headings are outside the entry region and are left
untouched."
  (org-back-to-heading t)
  (let* ((level (org-current-level))
         (extra (mindwtr-parse--extra-props))
         ;; Capture the running clock's id before insert/delete-region detaches
         ;; org's clock markers (the CLOCK text is grafted back as preserved
         ;; body, but the in-memory markers must be re-pointed too).
         (clock-id (mindwtr-reconcile--running-clock-id))
         (beg (point))
         (end (save-excursion (outline-next-heading) (point)))
         (preserved (mindwtr-reconcile--preserved-body
                     kind (mindwtr-reconcile--body-start) end))
         ;; ENTITY doubles as the display-mirror source: it carries the
         ;; merged createdAt/updatedAt that render writes as MW_CREATED/UPDATED.
         (e (plist-put (plist-put (copy-sequence entity) :mw-kind kind)
                       :mw-extra-props extra))
         (rendered (mindwtr-render-heading e level e)))
    (when preserved
      ;; Graft preserved body right after the PROPERTIES :END: line so
      ;; LOGBOOK/CLOCK keep their conventional position above the body.  The
      ;; first ":END:" in the render output closes the (sole) PROPERTIES drawer.
      (let ((i (string-match "\n:END:\n" rendered)))
        (when i
          (let ((cut (+ i (length "\n:END:\n"))))
            (setq rendered (concat (substring rendered 0 cut)
                                   preserved
                                   (substring rendered cut)))))))
    ;; Replace the entry's region by diff, not insert+delete-region, so a marker
    ;; another buffer holds onto THIS entry -- an open `org-agenda' line -- stays
    ;; on it instead of drifting onto the next heading (insert+delete-region
    ;; carried an insertion-type-t marker off the rebuilt region).  Narrowing
    ;; scopes the whole-buffer `replace-buffer-contents' to just [beg,end];
    ;; headings after END are outside the restriction, so their markers shift
    ;; normally as the entry's length changes.
    (save-restriction
      (narrow-to-region beg end)
      (mindwtr-reconcile--replace-buffer-contents rendered))
    (mindwtr-reconcile--restore-running-clock clock-id)))

(defun mindwtr-reconcile--collect-org-only ()
  "Return a hash id -> (:body STR :extra PLIST) of preserved org-only content.
This is collected for every MW_ID heading in the current buffer, so a full
rebuild can carry it across."
  (let ((h (make-hash-table :test 'equal)))
    (mindwtr-util--map-entries
     (lambda ()
       (let ((id (mindwtr-parse--prop "MW_ID"))
             (kind (mindwtr-parse--prop "MW_TYPE")))
         (when (and id kind (not (string= kind "container")))
           (let* ((end (save-excursion (outline-next-heading) (point)))
                  (body (mindwtr-reconcile--preserved-body
                         (intern kind) (mindwtr-reconcile--body-start) end))
                  (extra (mindwtr-parse--extra-props)))
             (when (or body extra)
               (puthash id (list :body body :extra extra) h)))))))
    h))

(defun mindwtr-reconcile--id-at-point ()
  "Return a stable location key for the heading containing point.
The MW_ID of the nearest entity at or above point; failing that the MW_LIST
role of the heading point is on, so a cursor parked on a container (e.g.
`* Projects', which has no MW_ID) is also preserved across the rebuild.  Nil
when point is on a heading with neither property."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((own-list (mindwtr-parse--prop "MW_LIST"))
            (id (mindwtr-parse--prop "MW_ID")))
        (while (and (not id) (org-up-heading-safe))
          (setq id (mindwtr-parse--prop "MW_ID")))
        (or id own-list)))))

(defun mindwtr-reconcile--anchor-heading-pos ()
  "Return the buffer position of the heading `--goto-id (--id-at-point)' lands on.
The scroll anchor recenters on the heading point is restored to, so the
snapshot must measure that same heading's screen line.  This resolves it by the
SAME (or MW_ID MW_LIST) walk-up as `mindwtr-reconcile--id-at-point': the
heading bearing the nearest enclosing MW_ID (self or ancestor), or -- when no
MW_ID is found -- the heading point is on if it carries an MW_LIST (a
container).  Nil when point is on a heading with neither property (then
`--id-at-point' is nil too and `--goto-id' is a no-op, so there is no row to
anchor)."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((own-list (mindwtr-parse--prop "MW_LIST"))
            (start-pos (line-beginning-position))
            (id (mindwtr-parse--prop "MW_ID")))
        (if id
            start-pos
          (let (anc-pos)
            (while (and (not id) (org-up-heading-safe))
              (setq id (mindwtr-parse--prop "MW_ID"))
              (when id (setq anc-pos (line-beginning-position))))
            (or anc-pos (and own-list start-pos))))))))

(defun mindwtr-reconcile--goto-id (id)
  "Move point to the heading whose MW_ID or MW_LIST equals ID, if present.
Entity ids (UUIDs) and container roles share no values, so one search handles
both -- letting point and scroll anchors target containers, not just entities."
  (when id
    (goto-char (point-min))
    (let ((re (format ":MW_\\(?:ID\\|LIST\\): *%s *$" (regexp-quote id))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)))))

;; Cross-version fold operations.  The `org-fold-*' namespace only exists in
;; Org 9.6+ (Emacs 29); the project floor is Emacs 28.1 / Org 9.5, where the
;; legacy `outline-*' functions are the equivalents.  These are the only spots
;; that touch the 9.6+ namespace -- snapshot/detection uses `org-invisible-p',
;; which behaves consistently across 9.5-9.8.

(defun mindwtr-reconcile--hide-subtree ()
  "Fold the subtree at point (cross-version)."
  (if (fboundp 'org-fold-hide-subtree)
      (org-fold-hide-subtree)
    (outline-hide-subtree)))

(defun mindwtr-reconcile--show-entry ()
  "Reveal this entry's own body (cross-version), leaving descendants alone."
  (if (fboundp 'org-fold-show-entry)
      (org-fold-show-entry)
    (outline-show-entry)))

(defun mindwtr-reconcile--hide-entry ()
  "Fold only this entry's own body (cross-version), leaving child headings
visible -- the per-heading `contents' view: heading and sub-headings shown,
body text hidden."
  (if (fboundp 'org-fold-hide-entry)
      (org-fold-hide-entry)
    (outline-hide-entry)))

(defun mindwtr-reconcile--child-heading-shown-p ()
  "Non-nil when the heading at point has an immediate child heading whose own
line is currently visible.  This is the signature that distinguishes a
`contents' fold (body hidden, sub-headings shown) from a fully collapsed
subtree (sub-headings hidden) when the heading's own body is already hidden."
  (save-excursion
    (let ((lvl (org-current-level)))
      (and (outline-next-heading)
           (> (org-current-level) lvl)
           (not (org-invisible-p (line-beginning-position)))))))

(defun mindwtr-reconcile--snapshot-view ()
  "Capture user-visible view state before a full rebuild, as a plist.
Every field is optional; absent fields are simply not restored.  Uses only
cross-version-safe calls (`org-invisible-p', `org-current-level',
`window-start') so it cannot raise `void-function' on Org 9.5 -- it runs
before the rebuild, outside `mindwtr-reconcile--restore-view''s guard.

  :folds  -- hash KEY -> `open' / `contents' / `folded', recorded ONLY for
             headings whose own heading line is currently visible.  KEY is the
             MW_ID for entities and the MW_LIST role for containers (Inbox,
             Projects, ...), so every heading has a stable key and restore can
             reproduce fold state precisely -- there is no global backdrop.

             A heading hidden because an ancestor is collapsed is NOT recorded:
             when restore re-folds that ancestor it disappears again, so its own
             state is moot.  The three states are distinguished by what is
             hidden: `open' (body shown), `contents' (body hidden but a child
             heading still visible), `folded' (body and any children hidden).
  :top-id -- the MW_ID or MW_LIST at/after the live window's `window-start',
             as a fallback scroll anchor; nil when there is no live window.
             Used when :anchor-line is nil (the point anchor was off-screen),
             since it is truthful to the top of the viewport regardless of
             where point sits.
  :anchor-line -- the screen-line offset (per `count-screen-lines', measured
             against WIN) from `window-start' to the heading the point anchor
             (`mindwtr-reconcile--id-at-point') will be restored to, captured
             ONLY when that heading is within the live window's visible region.
             The preferred scroll anchor: restore reproduces it with `recenter'
             so the heading returns to its exact prior row, immune to drawer
             reflow at/below it.  Nil when there is no live window, the point
             anchor resolves to no heading, or that heading was off-screen --
             in which case restore falls back to :top-id."
  (let ((folds (make-hash-table :test 'equal))
        (win (get-buffer-window (current-buffer)))
        top-id anchor-line)
    (mindwtr-util--map-entries
     (lambda ()
       (let ((key (or (mindwtr-parse--prop "MW_ID")
                      (mindwtr-parse--prop "MW_LIST"))))
         (when (and key (not (org-invisible-p (line-beginning-position))))
           (puthash key
                    (cond ((not (org-invisible-p (line-end-position))) 'open)
                          ((mindwtr-reconcile--child-heading-shown-p) 'contents)
                          (t 'folded))
                    folds)))))
    (when win
      (save-excursion
        (goto-char (window-start win))
        (when (re-search-forward
               "^[ \t]*:MW_\\(?:ID\\|LIST\\):[ \t]*\\(.+?\\)[ \t]*$" nil t)
          (setq top-id (match-string-no-properties 1))))
      ;; :anchor-line -- locate the heading `--goto-id (--id-at-point)' will
      ;; land point on after the rebuild, resolved by the SAME (or MW_ID
      ;; MW_LIST) walk-up `--id-at-point' uses, so capture and reapply target
      ;; the same row.  Record its screen line only if it is on-screen now.
      (let ((heading-pos (mindwtr-reconcile--anchor-heading-pos)))
        (when (and heading-pos
                   (<= (window-start win) heading-pos)
                   (< heading-pos (window-end win)))
          (setq anchor-line
                (count-screen-lines (window-start win) heading-pos nil win)))))
    (list :folds folds
          :top-id top-id
          :anchor-line anchor-line)))

(defun mindwtr-reconcile--restore-view (view)
  "Reapply the view state captured by `mindwtr-reconcile--snapshot-view'.
VIEW is the snapshot plist.  Wrapped in `condition-case' so a fold/redisplay
hiccup can never abort a sync: reconcile runs after the server PUT has already
committed, so a throw here would surface as a spurious sync failure (R4).  Only
visual state is touched (fold overlays, `window-start'), never content, so
`buffer-modified-p' is left exactly as the rebuild left it (R5)."
  (condition-case nil
      (let ((folds (plist-get view :folds))
            (top-id (plist-get view :top-id))
            (anchor-line (plist-get view :anchor-line))
            (win (get-buffer-window (current-buffer))))
        ;; 1. Re-fold, top-down, keyed by MW_ID/MW_LIST not position (R6).  The
        ;;    rebuilt buffer is fully expanded, so we only ever HIDE -- never an
        ;;    `org-overview'/`org-content' backdrop, which would collapse more
        ;;    than the user had folded and degrade across syncs.  Going top-down
        ;;    with a "heading line visible" guard means a `folded' ancestor hides
        ;;    its descendants first, so their (now invisible) headings are
        ;;    skipped; a `contents' ancestor hides only its own body via
        ;;    `--hide-entry', leaving children visible for their own records.
        ;;
        ;;    Wrapped in `save-excursion' so point stays on the `at-id' heading
        ;;    that `mindwtr-reconcile-buffer' put it on just before calling here
        ;;    -- the recenter step below anchors on that point.
        (when folds
          (save-excursion
            (mindwtr-util--map-entries
             (lambda ()
               (let* ((key (or (mindwtr-parse--prop "MW_ID")
                               (mindwtr-parse--prop "MW_LIST")))
                      (st (and key (gethash key folds))))
                 (when (not (org-invisible-p (line-beginning-position)))
                   (pcase st
                     ('folded (mindwtr-reconcile--hide-subtree))
                     ('contents (mindwtr-reconcile--hide-entry)))))))))
        ;; 2. Scroll (LAST, after folds so screen geometry matches the snapshot).
        ;;    Preferred: point is on the `at-id' heading, whose screen line was
        ;;    captured pre-rebuild -- `recenter' returns it to that exact row,
        ;;    immune to drawer reflow at/below it.  `recenter'/`set-window-start'
        ;;    act on the selected window and `win' is often NOT selected on a
        ;;    background sync, so the recenter runs inside `with-selected-window'.
        ;;    Fallback (anchor heading was off-screen, so :anchor-line is nil):
        ;;    re-anchor `window-start' to :top-id, truthful to the prior viewport
        ;;    top.  No live window, or neither anchor resolves -> no-op.
        (when win
          (cond
           (anchor-line
            ;; Point is on the `at-id' heading (preserved by the fold loop's
            ;; `save-excursion').  Selecting WIN resets buffer point to WIN's
            ;; OWN stored window-point -- stale on a background sync, since
            ;; reconcile set buffer point while WIN was unselected -- so
            ;; re-assert the heading position before recentering on it.
            (let ((pt (point)))
              (with-selected-window win
                (goto-char pt)
                (recenter anchor-line))))
           (top-id
            (save-excursion
              ;; `--goto-id' returns non-nil (and leaves point on the heading)
              ;; only when the anchor entity still exists after the rebuild.
              (when (mindwtr-reconcile--goto-id top-id)
                (set-window-start win (line-beginning-position)))))))
        nil)
    (error nil)))

;; Quarantine guard.  `mindwtr-reconcile-buffer' rebuilds the whole file from
;; the merged server data, so a heading the parser does not turn into an entity
;; (no :MW_TYPE: and no inferable kind -- e.g. a stray top-level note) would be
;; silently erased.  Before the rebuild we collect those orphan subtrees and,
;; after the rebuild, re-emit them verbatim under a `* Sync Failures' container
;; instead of dropping them.

(defconst mindwtr-reconcile--quarantine-role "sync-failures"
  "The :MW_LIST: role of the * Sync Failures quarantine container.
Deliberately NOT a member of `mindwtr-model-list-roles' / the inference table,
so its children stay un-inferable and are re-collected (then re-emitted) on
every sync -- which is what keeps the container from nesting or growing.")

(defconst mindwtr-reconcile--quarantine-note
  "# mindwtr: couldn't determine type from context -- add a :MW_TYPE: or move this under a list container, then sync again.\n"
  "Annotation prefixed to each quarantined heading.  Regenerated every sync:
it lives in the container body, not in any orphan subtree, so it never
accumulates.")

(defun mindwtr-reconcile--orphan-heading-p ()
  "Non-nil if the heading at point is content reconcile would otherwise erase:
no (non-blank) :MW_TYPE: and no kind inferable from context.  A typed entity, a
container, and an inferable heading all return nil."
  (and (null (mindwtr-parse--mw-type))
       (null (mindwtr-parse--infer-kind))))

(defun mindwtr-reconcile--collect-orphans ()
  "Return raw strings for headings reconcile would otherwise erase.
Walks every heading in the current buffer (before any erase -- R7).  An orphan
heading (`--orphan-heading-p') is captured as just its own heading + body, NOT
its whole subtree: a typed or inferable DESCENDANT is a real entity that
`mindwtr-parse-buffer' independently parses, syncs, and re-renders in its
canonical bucket, so swallowing it into the quarantine text would duplicate it
and its MW_ID.  The walk therefore always descends; an untyped descendant is
visited and captured on its own.  An existing `* Sync Failures' container is a
recognized container (not an orphan), so the walk descends into it and
re-collects its children individually -- discarding the wrapper, which keeps
quarantine idempotent (regenerated fresh on re-emit, never nested)."
  (save-excursion
    (goto-char (point-min))
    (let (orphans)
      (when (or (org-at-heading-p) (outline-next-heading))
        (while (not (eobp))
          (when (mindwtr-reconcile--orphan-heading-p)
            (let ((beg (point))
                  (end (save-excursion (outline-next-heading) (point))))
              (push (buffer-substring-no-properties beg end) orphans)))
          (outline-next-heading)))
      (nreverse orphans))))

(defun mindwtr-reconcile--reroot-subtree (text target)
  "Shift every heading in subtree TEXT so its top heading sits at level TARGET.
Relative depths within the subtree are preserved.  Only heading lines (`^\\*+ ')
are touched, so body content is left byte-identical."
  (let* ((top (and (string-match "\\`\\(\\*+\\) " text)
                   (length (match-string 1 text))))
         (delta (and top (- target top))))
    (if (or (null delta) (= delta 0)) text
      (replace-regexp-in-string
       "^\\*+ "
       (lambda (stars+sp)
         (concat (make-string (max 1 (+ (1- (length stars+sp)) delta)) ?*) " "))
       text))))

(defun mindwtr-reconcile--emit-quarantine (orphans)
  "Append a `* Sync Failures' container holding ORPHANS at point-max.
ORPHANS is the list of raw subtree strings from `--collect-orphans'.  A no-op
when ORPHANS is empty, so a clean sync produces no quarantine heading (R4).
Each orphan is re-rooted to level 2 under the level-1 container and prefixed
with `mindwtr-reconcile--quarantine-note'."
  (when orphans
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "* %s\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: %s\n:END:\n"
                    "Sync Failures" mindwtr-reconcile--quarantine-role))
    (dolist (o orphans)
      (insert mindwtr-reconcile--quarantine-note)
      (let ((s (mindwtr-reconcile--reroot-subtree o 2)))
        (insert s)
        (unless (string-suffix-p "\n" s) (insert "\n"))))))

(defun mindwtr-reconcile--running-clock-id ()
  "Return the MW_ID of the entry holding the running clock in this buffer.
Org tracks the active clock with `org-clock-hd-marker'/`org-clock-marker'.  A
full buffer rebuild (`erase-buffer') detaches those markers -- the CLOCK text is
preserved as org-only body, but the in-memory clock state collapses to
`point-min', so a later clock-out lands on the wrong line.  Returns the id so
the markers can be re-pointed after the rebuild; nil when no clock runs here."
  (when (and (fboundp 'org-clocking-p) (org-clocking-p)
             (markerp org-clock-hd-marker)
             (eq (marker-buffer org-clock-hd-marker) (current-buffer)))
    (save-excursion
      (goto-char org-clock-hd-marker)
      (mindwtr-parse--prop "MW_ID"))))

(defun mindwtr-reconcile--restore-running-clock (id)
  "Re-point the org clock markers at the open CLOCK line under MW_ID heading.
ID is from `mindwtr-reconcile--running-clock-id', captured before the rebuild.
A no-op when ID is nil or its heading no longer exists (a remote delete of the
clocked entry).  Targets the open clock -- a `CLOCK:' line with a start stamp
and no `--' end -- so the markers match org's own clock-in placement."
  (when id
    (let ((m (gethash id (mindwtr-reconcile--id-markers))))
      (when m
        (save-excursion
          (goto-char m)
          (org-back-to-heading t)
          (move-marker org-clock-hd-marker (point) (current-buffer))
          (let ((end (save-excursion (outline-next-heading) (point))))
            (when (re-search-forward "^[ \t]*CLOCK: \\[[^]]*\\][ \t]*$" end t)
              (move-marker org-clock-marker (point) (current-buffer)))))))))

(defun mindwtr-reconcile--replace-buffer-contents (string)
  "Replace the current buffer's contents with STRING, preserving markers.
Unlike `erase-buffer'+`insert' -- which moves every live marker in the buffer to
point-max -- `replace-buffer-contents' diffs the new text against the old and
makes only the minimal edits, so markers OTHER buffers hold into this one keep
pointing at their original headings.  This matters for an open `org-agenda' over
the Mindwtr file: each agenda line holds a marker into this buffer, and a sync
that rebuilds it must not collapse those markers to point-max (the file's
trailing `Areas of Focus' heading) -- otherwise the next agenda clock-in or
schedule lands on that last area instead of the task the user is on.
`replace-buffer-contents' takes its replacement from a buffer, so STRING is
staged in a temporary one."
  (let ((dest (current-buffer)))
    (with-temp-buffer
      (insert string)
      (let ((source (current-buffer)))
        (with-current-buffer dest
          ;; `replace-buffer-contents' is the right call on the Org/Emacs CI
          ;; baseline (29.3); it was marked obsolete in 31.1 (in favour of a
          ;; reworked `replace-region-contents' with an incompatible signature),
          ;; so suppress that newer-Emacs warning rather than branch on version.
          (with-suppressed-warnings ((obsolete replace-buffer-contents))
            (replace-buffer-contents source)))))))

(defun mindwtr-reconcile-buffer (merged &optional render-fn)
  "Rebuild the current buffer to the canonical layout of MERGED via RENDER-FN.
RENDER-FN is the (APPDATA &optional ORG-ONLY) -> string renderer, defaulting to
`mindwtr-render-appdata' (the main GTD-list surface); the archive surface
passes `mindwtr-render-archive-appdata'.  Everything else here -- org-only
preservation, quarantine, point/view restore -- is buffer-generic and works for
any surface.
Org-only content (LOGBOOK/CLOCK, unknown PROPERTIES) is preserved per id,
point is restored to the entity it was on, and user-visible view state
\(folds) is snapshotted before the rebuild and reapplied after.  Headings the
parser cannot place (no :MW_TYPE:, no inferable kind) are collected before the
rebuild and re-emitted under a `* Sync Failures' container so they are never
silently erased."
  ;; Snapshot view state FIRST: `mindwtr-parse-ensure-keywords' may re-init
  ;; org-mode (when the buffer's TODO keywords aren't registered), which resets
  ;; all fold state and `org-cycle-global-status'.  Capturing before that runs
  ;; reads the user's real visibility, not a wiped one.
  ;;
  ;; Guarded like the restore: reconcile runs AFTER the server PUT has already
  ;; committed, and the snapshot sits before the restore's own `condition-case',
  ;; so a signal here (e.g. `org-map-entries' on a degenerate buffer) would turn
  ;; an already-committed sync into a spurious failure.  A nil view degrades to
  ;; "restore nothing", strictly safer than aborting (R4).
  (let ((view (condition-case nil (mindwtr-reconcile--snapshot-view)
                (error nil)))
        ;; Capture the running clock's entry id before `erase-buffer' detaches
        ;; org's clock markers, so they can be re-pointed at the rebuilt entry.
        (clock-id (mindwtr-reconcile--running-clock-id)))
    (mindwtr-parse-ensure-keywords)
    (let* ((org-only (mindwtr-reconcile--collect-org-only))
           (at-id (mindwtr-reconcile--id-at-point))
           ;; Collect orphans from the LIVE buffer, before the rebuild below (R7).
           (orphans (mindwtr-reconcile--collect-orphans))
           ;; Render BEFORE replacing: if rendering signals (e.g. an unexpected
           ;; status from the server), the buffer is left intact rather than
           ;; wiped mid-rebuild.
           (rendered (funcall (or render-fn #'mindwtr-render-appdata)
                              merged org-only)))
      ;; Replace via diff (not erase+insert) so markers other buffers hold into
      ;; this one -- an open `org-agenda's per-line markers especially -- survive
      ;; the rebuild instead of collapsing to point-max.
      (let ((inhibit-message t))
        (mindwtr-reconcile--replace-buffer-contents rendered))
      ;; Re-emit orphans before view restore, so fold/scroll restore runs over a
      ;; buffer that already includes the quarantined headings.
      (mindwtr-reconcile--emit-quarantine orphans)
      (goto-char (point-min))
      ;; Position point on the anchor entity for the scroll restore.  If it no
      ;; longer resolves -- the entity the cursor was on was deleted by THIS
      ;; sync -- `--goto-id' leaves point at `point-min'.  The snapshot recorded
      ;; an `:anchor-line' for it (it was on-screen pre-rebuild), so drop that
      ;; field: recentering on the stranded point-min would yank the viewport to
      ;; the buffer top.  Restore then falls back to the viewport-truthful
      ;; `:top-id' window-start anchor instead.
      (unless (mindwtr-reconcile--goto-id at-id)
        (setq view (and view (plist-put view :anchor-line nil))))
      (mindwtr-reconcile--restore-view view)
      (mindwtr-reconcile--restore-running-clock clock-id))))

(defun mindwtr-reconcile--find-parsed (id)
  "Parse the buffer and return the entity whose id is ID, or nil."
  (let ((ad (mindwtr-parse-buffer)))
    (seq-find (lambda (e) (equal (plist-get e :id) id))
              (append (plist-get ad :tasks) (plist-get ad :projects)
                      (plist-get ad :sections) (plist-get ad :areas)
                      (plist-get ad :people)))))

(defun mindwtr-reconcile-restore-entity (entity kind)
  "Re-apply ENTITY (kind KIND) onto its existing heading in the current buffer.
Used by the sync report's restore action: after the server overrode a
local edit, this puts the local (ENTITY) version back into the buffer so
the next sync proposes it again.  Returns:
  `restored' - the rebuilt heading re-parses to ENTITY's content, so the
               next sync will detect the change and propose it;
  `partial'  - a heading with ENTITY's id exists but could not be
               reproduced exactly.  The in-place rebuild rewrites the
               heading's own fields but does NOT move it, so a containment
               (refile) edit -- whose parent is derived from outline
               ancestry, not a field -- cannot be reapplied here;
  nil        - no heading with ENTITY's id is present (e.g. it was removed
               by a remote deletion).
The caller surfaces `partial'/nil so a lost edit is never silently
reported as restored; the user falls back to the pre-sync backup."
  (let ((m (gethash (plist-get entity :id) (mindwtr-reconcile--id-markers)))
        (mindwtr-render-area-names (mindwtr-render--area-name-map (mindwtr-parse-buffer))))
    (if (not m)
        nil
      (save-excursion
        (goto-char m)
        (mindwtr-reconcile--rebuild-entry entity kind))
      (let ((re (mindwtr-reconcile--find-parsed (plist-get entity :id))))
        (if (and re (string= (mindwtr-signature re) (mindwtr-signature entity)))
            'restored
          'partial)))))

(provide 'mindwtr-reconcile)
;;; mindwtr-reconcile.el ends here
