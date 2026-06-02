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

(defun mindwtr-reconcile--container-marker (markers entity)
  "Return marker of ENTITY's container heading, or nil for top-level."
  (let ((parent (or (plist-get entity :sectionId)
                    (plist-get entity :projectId)
                    (plist-get entity :areaId))))
    (and parent (gethash parent markers))))

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

(defun mindwtr-reconcile--insert-entity (entity kind markers)
  "Insert ENTITY (kind KIND) as a new heading under its container."
  (let* ((cmark (mindwtr-reconcile--container-marker markers entity))
         (level (if cmark
                    (1+ (save-excursion (goto-char cmark) (org-current-level)))
                  1)))
    (if cmark
        (progn (goto-char cmark)
               (org-end-of-subtree t t)
               (unless (bolp) (insert "\n")))
      (goto-char (point-max)) (unless (bolp) (insert "\n")))
    (let ((e (plist-put (copy-sequence entity) :mw-kind kind)))
      (insert (mindwtr-render-heading e level
                                      (list :createdAt (plist-get entity :createdAt)
                                            :updatedAt (plist-get entity :updatedAt)))))))

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

(defun mindwtr-reconcile-buffer (merged)
  "Rebuild the current buffer to the canonical GTD-list layout of MERGED.
Org-only content (LOGBOOK/CLOCK, unknown PROPERTIES) is preserved per id,
and point is restored to the entity it was on."
  (mindwtr-parse-ensure-keywords)
  (let ((org-only (mindwtr-reconcile--collect-org-only))
        (at-id (mindwtr-reconcile--id-at-point)))
    (let ((inhibit-message t))
      (erase-buffer)
      (insert (mindwtr-render-appdata merged org-only)))
    (goto-char (point-min))
    (mindwtr-reconcile--goto-id at-id)))

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
