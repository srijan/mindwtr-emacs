;;; mindwtr-reconcile.el --- Apply merged appdata into the org buffer -*- lexical-binding: t; -*-
;;; Commentary:
;; Updates the current buffer to reflect a merged AppData by id, editing
;; recognized fields in place and preserving org-only drawers (LOGBOOK,
;; unknown PROPERTIES) and the user's point.
;;; Code:

(require 'org)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)
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

(defun mindwtr-reconcile-buffer (merged)
  "Reconcile the current buffer to reflect MERGED AppData."
  (mindwtr-parse-ensure-keywords)
  (save-excursion
    (let ((markers (mindwtr-reconcile--id-markers)))
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (e (plist-get merged key))
          (when (plist-get e :deletedAt)
            (let ((m (gethash (plist-get e :id) markers)))
              (when m (goto-char m) (org-back-to-heading t)
                    (org-cut-subtree) (remhash (plist-get e :id) markers))))))
      (dolist (key '(:areas :projects :sections :tasks))
        (let ((kind (intern (substring (symbol-name key) 1
                                       (1- (length (symbol-name key)))))))
          (dolist (e (plist-get merged key))
            (unless (plist-get e :deletedAt)
              (let ((m (gethash (plist-get e :id) markers)))
                (if m
                    ;; Update in place: `--rebuild-entry' inserts-before-deletes,
                    ;; so existing markers stay valid -- no rescan needed.
                    (progn (goto-char m)
                           (mindwtr-reconcile--rebuild-entry e kind))
                  ;; A new heading's id is not yet in the map and a later entity
                  ;; may need it as a container; rescan so it is resolvable.
                  (mindwtr-reconcile--insert-entity e kind markers)
                  (setq markers (mindwtr-reconcile--id-markers)))))))))))

(provide 'mindwtr-reconcile)
;;; mindwtr-reconcile.el ends here
