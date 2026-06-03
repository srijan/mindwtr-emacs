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
    (org-map-entries
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
The renderer emits a body (description + checklist) only for tasks, so for
a NON-task entity the entire body is org-only content and is preserved
verbatim.  For a task, description and checklist are regenerated from the
merged entity, so only org-only lines are preserved: drawer blocks
\(LOGBOOK and CLOCK-in-drawer) and bare CLOCK lines.  Returns nil when
there is nothing to preserve."
  (if (not (eq kind 'task))
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
unknown PROPERTIES, and org-only body content (LOGBOOK/CLOCK and, for
non-task entities, all free prose).  Child headings are outside the entry
region and are left untouched."
  (org-back-to-heading t)
  (let* ((level (org-current-level))
         (extra (mindwtr-parse--extra-props))
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
    ;; Insert the rebuilt entry BEFORE deleting the old one.  Deleting first
    ;; would collapse the next heading's marker onto the rebuild point; by
    ;; inserting ahead of the old region the following heading's marker simply
    ;; shifts and stays valid, so no O(n) marker rescan per update is needed.
    (goto-char beg)
    (insert rendered)
    (delete-region (point) (+ (point) (- end beg)))))

(defun mindwtr-reconcile--collect-org-only ()
  "Return a hash id -> (:body STR :extra PLIST) of preserved org-only content.
This is collected for every MW_ID heading in the current buffer, so a full
rebuild can carry it across."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
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
  "Return the MW_ID of the entity heading containing point, or nil."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((id (mindwtr-parse--prop "MW_ID")))
        (while (and (not id) (org-up-heading-safe))
          (setq id (mindwtr-parse--prop "MW_ID")))
        id))))

(defun mindwtr-reconcile--goto-id (id)
  "Move point to the heading whose MW_ID is ID, if present."
  (when id
    (goto-char (point-min))
    (let ((re (format ":MW_ID: *%s *$" (regexp-quote id))))
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

(defun mindwtr-reconcile--snapshot-view ()
  "Capture user-visible view state before a full rebuild, as a plist.
Every field is optional; absent fields are simply not restored.  Uses only
cross-version-safe calls (`org-invisible-p', `org-cycle-global-status',
`window-start') so it cannot raise `void-function' on Org 9.5 -- it runs
before the rebuild, outside `mindwtr-reconcile--restore-view''s guard.

  :folds  -- hash MW_ID -> `folded' or `open', recorded ONLY for entity
             headings whose own heading line is currently visible.  A heading
             hidden because an ancestor is collapsed is NOT recorded: its
             visibility is governed by that ancestor / the global backdrop, not
             by an explicit per-entity decision.  This three-way distinction
             (folded / open / unrecorded) is what lets restore reapply an
             `org-overview' backdrop AND still reopen the specific entities the
             user had expanded, without punching ancestor-folded children open.
  :global -- the buffer-local `org-cycle-global-status' (S-TAB level).
  :top-id -- the MW_ID at/after the live window's `window-start', as a scroll
             anchor; nil when there is no live window."
  (let ((folds (make-hash-table :test 'equal))
        (win (get-buffer-window (current-buffer)))
        top-id)
    (org-map-entries
     (lambda ()
       (let ((id (mindwtr-parse--prop "MW_ID")))
         (when (and id (not (org-invisible-p (line-beginning-position))))
           (puthash id
                    (if (org-invisible-p (line-end-position)) 'folded 'open)
                    folds)))))
    (when win
      (save-excursion
        (goto-char (window-start win))
        (when (re-search-forward "^[ \t]*:MW_ID:[ \t]*\\(.+?\\)[ \t]*$" nil t)
          (setq top-id (match-string-no-properties 1)))))
    (list :folds folds
          :global (bound-and-true-p org-cycle-global-status)
          :top-id top-id)))

(defun mindwtr-reconcile--restore-view (view)
  "Reapply the view state captured by `mindwtr-reconcile--snapshot-view'.
VIEW is the snapshot plist.  Wrapped in `condition-case' so a fold/redisplay
hiccup can never abort a sync: reconcile runs after the server PUT has already
committed, so a throw here would surface as a spurious sync failure (R4).  Only
visual state is touched (fold overlays, `window-start'), never content, so
`buffer-modified-p' is left exactly as the rebuild left it (R5)."
  (condition-case nil
      (let ((folds (plist-get view :folds))
            (global (plist-get view :global))
            (top-id (plist-get view :top-id)))
        ;; 1. Global backdrop first, so the per-entity pass below overrides it.
        ;;    Only the collapsing states need action: `all'/nil mean "fully
        ;;    shown", which the fresh erase/insert already is -- and the
        ;;    per-entity pass re-folds anything the user had folded -- so no
        ;;    show-all backdrop is needed (it would be a no-op).
        (pcase global
          ('overview (org-overview))
          ('contents (org-content)))
        ;; 2. Per-entity, top-down: re-fold the entities the user had folded and
        ;;    re-open the ones they had open, keyed by MW_ID not position (R6).
        ;;    Entities not recorded (ancestor-hidden at snapshot) are left to the
        ;;    backdrop -- so an `org-overview' backdrop keeps them collapsed.
        (when folds
          (org-map-entries
           (lambda ()
             (let* ((id (mindwtr-parse--prop "MW_ID"))
                    (st (and id (gethash id folds))))
               (cond ((eq st 'folded) (mindwtr-reconcile--hide-subtree))
                     ((eq st 'open) (mindwtr-reconcile--show-entry)))))))
        ;; 3. Scroll: anchor the window to the recorded top entity if it still
        ;;    resolves and there is a live window.
        (when top-id
          (let ((win (get-buffer-window (current-buffer))))
            (when win
              (save-excursion
                ;; `--goto-id' returns non-nil (and leaves point on the heading)
                ;; only when the anchor entity still exists after the rebuild.
                (when (mindwtr-reconcile--goto-id top-id)
                  (set-window-start win (line-beginning-position))))))))
    (error nil)))

(defun mindwtr-reconcile-buffer (merged)
  "Rebuild the current buffer to the canonical GTD-list layout of MERGED.
Org-only content (LOGBOOK/CLOCK, unknown PROPERTIES) is preserved per id,
point is restored to the entity it was on, and user-visible view state
\(folds) is snapshotted before the rebuild and reapplied after."
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
                (error nil))))
    (mindwtr-parse-ensure-keywords)
    (let* ((org-only (mindwtr-reconcile--collect-org-only))
           (at-id (mindwtr-reconcile--id-at-point))
           ;; Render BEFORE erasing: if rendering signals (e.g. an unexpected
           ;; status from the server), the buffer is left intact rather than
           ;; wiped between erase and insert.
           (rendered (mindwtr-render-appdata merged org-only)))
      (let ((inhibit-message t))
        (erase-buffer)
        (insert rendered))
      (goto-char (point-min))
      (mindwtr-reconcile--goto-id at-id)
      (mindwtr-reconcile--restore-view view))))

(defun mindwtr-reconcile--find-parsed (id)
  "Parse the buffer and return the entity whose id is ID, or nil."
  (let ((ad (mindwtr-parse-buffer)))
    (seq-find (lambda (e) (equal (plist-get e :id) id))
              (append (plist-get ad :tasks) (plist-get ad :projects)
                      (plist-get ad :sections) (plist-get ad :areas)))))

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
