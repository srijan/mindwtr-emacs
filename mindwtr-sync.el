;;; mindwtr-sync.el --- Sync engine -*- lexical-binding: t; -*-
;;; Commentary:
;; Change detection against the shadow and candidate-snapshot construction.
;;; Code:

(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-shadow)

(defconst mindwtr-sync--entity-keys '(:tasks :projects :sections :areas))

(defvar mindwtr--inhibit-save-sync nil
  "Non-nil while the engine writes the synced buffer itself.
Dynamically `let'-bound `t' (never `setq'-reset, so it auto-unwinds on any
exit) around an internal `save-buffer' so the `after-save-hook' debounce
\(`mindwtr--maybe-debounced-sync') does not re-arm a stray HEAD-only sync
~5s later for a save the engine performed.  Declared here -- the lower
layer that `mindwtr.el' requires -- so both files see it and `make compile'
stays clean under `error-on-warn'.  Mirrors the `mindwtr--sync-in-progress'
guard discipline.")

(defun mindwtr-sync--save-buffer-quietly (&optional protect-content)
  "Save the current buffer to disk without re-arming the auto-sync debounce.
Return `:skipped' when the buffer visits no file (a no-op), `t' on a
successful save, and nil when the underlying `save-buffer' signals -- the
error is caught, never thrown, because this also runs in the post-PUT
region where a throw would masquerade as a sync failure (AGENTS.md
invariant).  `save-buffer' itself no-ops when the buffer is unmodified.

Binds `mindwtr--inhibit-save-sync' to `t' so the `after-save-hook'
debounce stands down for this engine-driven save; other after-save
handlers (recentf, etc.) still run.  With PROTECT-CONTENT non-nil also
suppresses `before-save-hook' so a content-mutating hook (formatters,
trailing-whitespace cleanup) cannot churn engine-canonical reconciled
content out from under the just-passed concurrency guard."
  (if (not (buffer-file-name))
      :skipped
    (let ((mindwtr--inhibit-save-sync t))
      (condition-case err
          (progn
            (if protect-content
                (let ((before-save-hook nil)) (save-buffer))
              (save-buffer))
            t)
        (error
         (message "mindwtr: buffer save failed: %s" (error-message-string err))
         nil)))))

(defun mindwtr-sync--strip-device-local (entity)
  "Return ENTITY without device-local fields."
  (let (out (i 0))
    (while (< i (length entity))
      (unless (memq (nth i entity) mindwtr-model-device-local-fields)
        (setq out (plist-put out (nth i entity) (nth (1+ i) entity))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-sync--empty-p (v)
  "Non-nil if content value V counts as absent (nil, empty list/string)."
  (or (null v) (and (stringp v) (string-empty-p v))))

(defun mindwtr-sync--field-canonical (k v)
  "Canonical comparison form of content field K's value V, or nil if empty.
Uses the signature's own per-field normalization so the write-merge and
change detection agree on what \"the same content\" means."
  (if (mindwtr-sync--empty-p v) nil
    (mindwtr-signature-canonical-value k v)))

(defun mindwtr-sync--plist-remove (pl k)
  "Return PL without key K."
  (let (out (i 0))
    (while (< i (length pl))
      (unless (eq (nth i pl) k)
        (setq out (plist-put out (nth i pl) (nth (1+ i) pl))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-sync--merge-content (le se &optional protected-field)
  "Overlay LE's genuinely-changed content onto SE (the full shadow entity).
LE is the lossy org projection (no checklist item ids, minute-precision
timestamps); SE carries full fidelity plus server-managed and unmapped
fields.  For each editable field, the shadow value is kept whenever LE's
canonical projection matches SE's -- so fields the user did not change
retain their item ids and sub-minute precision -- while a genuine change
adopts LE's value (clearing the field when LE emptied it).  LE's identity
and internal keys are carried through (internal keys are stripped before
the wire).

PROTECTED-FIELD, when non-nil, is a single content field whose clearing is
suppressed when LE's value is empty but SE's is not.  Used for the first
post-upgrade sync: a buffer written by a renderer that did not emit
project/section note bodies parses to an empty notes value, which must not be
read as the user clearing a server-authored note.  The caller passes the
kind's notes field (project `:supportNotes', section `:description') only while
the migration latch is unset (see `mindwtr-shadow-notes-migrated-p'); once set,
this is nil and an empty note clears normally.  Note `:mw-kind' is stripped from
LE by `mindwtr-parse-buffer', so the kind cannot be recovered here -- the caller
resolves the field."
  (let ((out (copy-sequence (or se '()))))
    (dolist (k '(:id :mw-kind :mw-extra-props))
      (when (plist-member le k)
        (setq out (plist-put out k (plist-get le k)))))
    (dolist (k mindwtr-model-content-fields)
      (let ((lv (plist-get le k)) (sv (plist-get se k)))
        (unless (equal (mindwtr-sync--field-canonical k lv)
                       (mindwtr-sync--field-canonical k sv))
          (if (mindwtr-sync--empty-p lv)
              ;; `:status' is mandatory for task/project; an empty local value
              ;; means the parser could not determine it (a type-invalid or
              ;; missing keyword), never an intentional clear -- so keep SV.
              ;; PROTECTED-FIELD: a non-task notes field the buffer could not
              ;; yet render must likewise keep SV (pre-migration), never clear.
              (unless (or (eq k :status)
                          (and (eq k protected-field)
                               (not (mindwtr-sync--empty-p sv))))
                (setq out (mindwtr-sync--plist-remove out k)))
            (setq out (plist-put out k lv))))))
    out))

(defun mindwtr-sync--classify (local-entity shadow-entity)
  "Return one of `create' `update' `unchanged' for LOCAL vs SHADOW."
  (cond
   ((null shadow-entity) 'create)
   ((string= (mindwtr-signature local-entity) (mindwtr-signature shadow-entity))
    'unchanged)
   (t 'update)))

(defun mindwtr-sync--live-container-ids (shadow)
  "Return (PROJECTS . SECTIONS): hashes of SHADOW container ids that render.
A project renders unless it is archived or tombstoned.  A section renders
only when it is not tombstoned and its parent project renders.  Used to
decide whether a shadow entity's absence from org is EXPECTED (its parent
is hidden) rather than a user deletion."
  (let ((projs (make-hash-table :test 'equal))
        (secs (make-hash-table :test 'equal)))
    (dolist (p (plist-get shadow :projects))
      (let ((id (plist-get p :id)))
        (when (and id (not (plist-get p :deletedAt))
                   (not (equal (plist-get p :status) "archived")))
          (puthash id t projs))))
    (dolist (s (plist-get shadow :sections))
      (let ((id (plist-get s :id)) (pid (plist-get s :projectId)))
        (when (and id (not (plist-get s :deletedAt)) pid (gethash pid projs))
          (puthash id t secs))))
    (cons projs secs)))

(defun mindwtr-sync--rendered-absent-p (se kind live)
  "Non-nil if shadow entity SE of KIND is EXPECTED to be absent from org.
True when SE is archived, or its parent container does not render, or (for a
standalone task) its status maps to no list.  Such an entity must not be
tombstoned for being missing from the buffer; it is echoed verbatim instead.
LIVE is (PROJECTS . SECTIONS) from `mindwtr-sync--live-container-ids'."
  (or (equal (plist-get se :status) "archived")
      (pcase kind
        ('task
         (let ((sid (plist-get se :sectionId)) (pid (plist-get se :projectId)))
           (cond (sid (not (gethash sid (cdr live))))
                 (pid (not (gethash pid (car live))))
                 (t (null (mindwtr-model-status->list (plist-get se :status)))))))
        ('section
         (let ((pid (plist-get se :projectId)))
           (not (and pid (gethash pid (car live))))))
        (_ nil))))

(defun mindwtr-sync--ensure-status (entity kind)
  "Default a missing status on a newly created ENTITY of KIND.
A type-invalid or missing keyword left the parser omitting :status; for a
brand-new entity there is no shadow status to inherit, so fall back to the
kind's default (task -> inbox, project -> active) so validation does not abort."
  (if (or (not (memq kind '(task project))) (plist-get entity :status))
      entity
    (plist-put (copy-sequence entity)
               :status (if (eq kind 'task) "inbox" "active"))))

(defun mindwtr-sync-build-candidate (local shadow device-id now &optional protect-empty-notes)
  "Build a candidate AppData from LOCAL parse and SHADOW, stamping DEVICE-ID/NOW.
PROTECT-EMPTY-NOTES is forwarded to `mindwtr-sync--merge-content' so the
first post-upgrade sync does not clear a server-authored project/section
note the old renderer never wrote into the buffer (see
`mindwtr-shadow-notes-migrated-p')."
  ;; Guarantee non-null settings up front: a fresh namespace has none in its
  ;; shadow yet, and the server's settings merge 500s on a null blob.
  (setq shadow (mindwtr-model-ensure-settings shadow))
  (let ((cand (list :settings (plist-get shadow :settings)))
        (live (mindwtr-sync--live-container-ids shadow)))
    (dolist (key mindwtr-sync--entity-keys)
      (let* ((shadow-idx (mindwtr-shadow-index shadow key))
             (kind (mindwtr-sync--key->kind key))
             ;; Pre-migration, protect this kind's notes field from being read
             ;; as a clear (project :supportNotes, section :description); task
             ;; notes always rendered, so they are never protected.
             (protected-field (and protect-empty-notes
                                   (not (eq kind 'task))
                                   (mindwtr-model-notes-field kind)))
             (seen (make-hash-table :test 'equal))
             out)
        (dolist (le (plist-get local key))
          (let* ((id (or (plist-get le :id) (mindwtr-util-uuid)))
                 (le (plist-put (copy-sequence le) :id id))
                 (se (gethash id shadow-idx))
                 (klass (mindwtr-sync--classify le se))
                 (merged
                  (pcase klass
                    ;; Unchanged: echo the shadow verbatim.  Overlaying the
                    ;; lossy parse here would silently strip checklist item
                    ;; ids and truncate sub-minute timestamps on every sync.
                    ('unchanged (copy-sequence se))
                    ('create
                     (let ((m (mindwtr-sync--ensure-status
                               (mindwtr-sync--merge-content le se protected-field) kind)))
                       (setq m (plist-put m :rev 1))
                       (setq m (plist-put m :createdAt now))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id)))
                    ('update
                     (let ((m (mindwtr-sync--merge-content le se protected-field)))
                       (setq m (plist-put m :rev (1+ (or (plist-get se :rev) 0))))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id))))))
            (puthash id t seen)
            (push (mindwtr-sync--strip-device-local merged) out)))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (mindwtr-sync--rendered-absent-p se kind live))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
        ;; Shadow entities whose absence from org is EXPECTED -- archived, or
        ;; their parent container is hidden, or (for a standalone task) their
        ;; status maps to no list -- are echoed verbatim (not tombstoned): a
        ;; missing org heading there is not a user deletion.
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (when (and (not (gethash id seen))
                       (not (plist-get se :deletedAt))
                       (mindwtr-sync--rendered-absent-p se kind live))
              (push (mindwtr-sync--strip-device-local (copy-sequence se)) out))))
        (setq cand (plist-put cand key (nreverse out)))))
    cand))

(defun mindwtr-sync--key->kind (key)
  "Map an entity-list KEY like `:tasks' to its singular kind symbol `task'."
  (intern (substring (symbol-name key) 1 (1- (length (symbol-name key))))))

(defun mindwtr-sync--find-entry (appdata id)
  "Return (KIND . ENTITY) for ID in APPDATA across all entity lists, or nil.
KIND is the singular symbol (task/project/section/area)."
  (catch 'hit
    (dolist (key mindwtr-sync--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (string= (plist-get e :id) id)
          (throw 'hit (cons (mindwtr-sync--key->kind key) e)))))
    nil))

(defun mindwtr-sync-detect-conflicts (candidate merged changed-ids)
  "Return lost-edit conflicts for CHANGED-IDS comparing CANDIDATE vs MERGED.
Each conflict is (:id ID :kind KIND :mine OURS :theirs SERVERS); KIND lets
the report's restore action rebuild the entity in the buffer."
  (let (conflicts)
    (dolist (id changed-ids)
      (let* ((mine-e (mindwtr-sync--find-entry candidate id))
             (theirs-e (mindwtr-sync--find-entry merged id))
             (mine (cdr mine-e))
             (theirs (cdr theirs-e)))
        (when (and mine theirs
                   (not (string= (mindwtr-signature mine)
                                 (mindwtr-signature theirs))))
          (push (list :id id :kind (car mine-e) :mine mine :theirs theirs)
                conflicts))))
    (nreverse conflicts)))

(require 'mindwtr-parse)
(require 'mindwtr-api)
(require 'mindwtr-reconcile)
(require 'mindwtr-report)

(defun mindwtr-sync--strip-internal-keys (appdata)
  "Remove internal :mw-* keys from every entity in APPDATA (for the wire)."
  (let ((out (list :settings (plist-get appdata :settings))))
    (dolist (key mindwtr-sync--entity-keys)
      (setq out (plist-put out key
                           (mapcar
                            (lambda (e)
                              (let (clean (i 0))
                                (while (< i (length e))
                                  (unless (memq (nth i e)
                                                '(:mw-kind :mw-extra-props))
                                    (setq clean (plist-put clean (nth i e) (nth (1+ i) e))))
                                  (setq i (+ i 2)))
                                clean))
                            (plist-get appdata key)))))
    out))

(defun mindwtr-sync--changed-ids (local shadow)
  "Return ids of entities that are create/update vs SHADOW."
  (let (ids)
    (dolist (key mindwtr-sync--entity-keys)
      (let ((idx (mindwtr-shadow-index shadow key)))
        (dolist (le (plist-get local key))
          (let* ((id (plist-get le :id))
                 (se (and id (gethash id idx))))
            (when (and id (not (eq (mindwtr-sync--classify le se) 'unchanged)))
              (push id ids))))))
    ids))

(defun mindwtr-sync--stats (local shadow)
  "Return (:created C :updated U :deleted D) for LOCAL parse vs SHADOW.
A create is a local entity not in the shadow (including a new heading that
has no id yet); an update is a local entity whose signature differs from
its shadow twin; a delete is a live shadow entity absent from LOCAL whose
absence is not explained by archival or a hidden parent."
  (let ((created 0) (updated 0) (deleted 0)
        (live (mindwtr-sync--live-container-ids shadow)))
    (dolist (key mindwtr-sync--entity-keys)
      (let ((idx (mindwtr-shadow-index shadow key))
            (kind (mindwtr-sync--key->kind key))
            (seen (make-hash-table :test 'equal)))
        (dolist (le (plist-get local key))
          (let* ((id (plist-get le :id))
                 (se (and id (gethash id idx))))
            (when id (puthash id t seen))
            (pcase (mindwtr-sync--classify le se)
              ('create (setq created (1+ created)))
              ('update (setq updated (1+ updated))))))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (mindwtr-sync--rendered-absent-p se kind live))
              (setq deleted (1+ deleted)))))))
    (list :created created :updated updated :deleted deleted)))

(defun mindwtr-sync-once (buffer now)
  "Run one full sync cycle for org BUFFER, stamping changes with NOW.
Return (:ok t :conflicts LIST) or signals on hard error."
  (with-current-buffer buffer
    (let* ((shadow (mindwtr-shadow-load))
           (device (mindwtr-shadow-device-id))
           (local (mindwtr-parse-buffer))
           (parse-warnings (mindwtr-parse-warnings))
           ;; Capture the tick AFTER parsing: `mindwtr-parse-buffer' may call
           ;; `mindwtr-parse-ensure-keywords' which re-inits `org-mode', and a
           ;; mode re-init can bump `buffer-chars-modified-tick' without the
           ;; user editing.  Parsing is a read of the user's buffer state, so
           ;; the post-parse tick is the correct baseline for the concurrency
           ;; guard; capturing before parse would make the guard fire spuriously.
           (tick (buffer-chars-modified-tick))
           (changed (mindwtr-sync--changed-ids local shadow))
           (stats (mindwtr-sync--stats local shadow))
           (local-dirty (> (+ (plist-get stats :created)
                              (plist-get stats :updated)
                              (plist-get stats :deleted))
                           0))
           (shadow-etag (mindwtr-shadow-get-etag)))
      ;; Step 1 of the cycle: with nothing local to push, HEAD the server; if
      ;; its ETag still matches the shadow, neither side changed -- skip the
      ;; PUT/GET round-trip.  (When local IS dirty we must PUT regardless, so a
      ;; HEAD would not change the decision; we go straight to the full cycle,
      ;; whose follow-up GET also pulls any concurrent remote changes.)
      (if (and (not local-dirty)
               shadow-etag (not (string-empty-p shadow-etag))
               (equal (mindwtr-api-head-etag) shadow-etag))
          (progn
            ;; Even when nothing needs pushing, a stray keyword should not be
            ;; silently swallowed -- surface it in the report.
            (when parse-warnings
              (mindwtr-report-show stats nil nil nil (current-buffer) parse-warnings))
            ;; The notes-migration latch is intentionally NOT set here: a noop
            ;; skips reconcile, so the buffer still holds the old pre-notes
            ;; render.  Empty-notes protection must stay on until a full cycle
            ;; actually rewrites the buffer (the latch is set in that branch
            ;; below, after a confirmed save).
            (list :ok t :noop t :conflicts nil :stats stats :skew nil
                  :warnings parse-warnings))
        (let* ((protect-empty-notes (not (mindwtr-shadow-notes-migrated-p)))
               (candidate (mindwtr-sync-build-candidate local shadow device now
                                                        protect-empty-notes))
               (wire (mindwtr-sync--strip-internal-keys candidate)))
          (mindwtr-model-validate-appdata wire)
          ;; The PUT response carries {ok, stats, clockSkewWarning}; surface
          ;; the skew warning so a misconfigured device clock is not silent.
          (let* ((put-resp (mindwtr-api-put-data wire))
                 (skew (plist-get put-resp :clockSkewWarning))
                 (got (mindwtr-api-get-data))
                 ;; Normalize settings on the way in too: should the server ever
                 ;; return a null/absent blob, keep the shadow consistent now
                 ;; rather than relying on build-candidate to re-synthesize next
                 ;; cycle.
                 (merged (mindwtr-model-ensure-settings (plist-get got :appdata)))
                 (conflicts (mindwtr-sync-detect-conflicts wire merged changed))
                 (backup-file nil))
            (unless (= tick (buffer-chars-modified-tick))
              (error "mindwtr: buffer changed during sync; aborting"))
            (when (buffer-file-name)
              (let* ((bdir (expand-file-name "backups/" mindwtr-shadow-directory))
                     (bf (expand-file-name
                          (format "mindwtr-%s.org"
                                  (format-time-string "%Y%m%dT%H%M%S")) bdir)))
                (make-directory bdir t)
                (write-region (point-min) (point-max) bf)
                (setq backup-file bf)
                (condition-case err
                    (mindwtr-shadow-prune-backups)
                  (error (message "mindwtr: backup cleanup skipped: %s"
                                  (error-message-string err))))))
            (mindwtr-reconcile-buffer merged)
            ;; Return the buffer to clean on disk after the rebuild (an
            ;; erase+insert always marks it modified, so this always writes on
            ;; a full cycle -- never on the :noop branch above).  This closes
            ;; the loop that keeps the unsaved-edits gate from self-wedging.
            ;; Content-protected (KTD-7) and condition-case-guarded inside the
            ;; helper: a write failure here must NOT throw (post-PUT; the
            ;; server already committed).  Instead it is reported via
            ;; :save-failed so the caller can raise a visible, recoverable
            ;; error state rather than stall the gate silently (KTD-5).  A
            ;; non-file (temp-buffer) save returns :skipped, which is not a
            ;; failure.
            (let ((save-failed (null (mindwtr-sync--save-buffer-quietly t))))
              (mindwtr-shadow-save merged)
              (mindwtr-shadow-set-etag (plist-get got :etag))
              ;; Latch the notes migration ONLY once the notes-capable render is
              ;; durably on disk.  The buffer now carries project/section note
              ;; bodies, so a future empty notes value is a genuine clear -- but
              ;; only if the file actually persisted.  If the save failed, the
              ;; .org on disk may still hold the old note-less render; latching
              ;; now would drop empty-notes protection, and a later reload from
              ;; that stale file would clear a server note via LWW.  Guarded so
              ;; a latch-write failure cannot throw (post-PUT; server committed).
              (unless save-failed
                (condition-case err
                    (mindwtr-shadow-set-notes-migrated)
                  (error (message "mindwtr: notes-migrated latch write failed: %s"
                                  (error-message-string err)))))
              (mindwtr-report-show stats conflicts skew backup-file (current-buffer) parse-warnings)
              (list :ok t :conflicts conflicts :stats stats :skew skew
                    :warnings parse-warnings :save-failed save-failed))))))))

(provide 'mindwtr-sync)
;;; mindwtr-sync.el ends here
