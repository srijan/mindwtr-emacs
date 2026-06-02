;;; mindwtr-sync.el --- Sync engine -*- lexical-binding: t; -*-
;;; Commentary:
;; Change detection against the shadow and candidate-snapshot construction.
;;; Code:

(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-shadow)

(defconst mindwtr-sync--entity-keys '(:tasks :projects :sections :areas))

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

(defun mindwtr-sync--merge-content (le se)
  "Overlay LE's genuinely-changed content onto SE (the full shadow entity).
LE is the lossy org projection (no checklist item ids, minute-precision
timestamps); SE carries full fidelity plus server-managed and unmapped
fields.  For each editable field, the shadow value is kept whenever LE's
canonical projection matches SE's -- so fields the user did not change
retain their item ids and sub-minute precision -- while a genuine change
adopts LE's value (clearing the field when LE emptied it).  LE's identity
and internal keys are carried through (internal keys are stripped before
the wire)."
  (let ((out (copy-sequence (or se '()))))
    (dolist (k '(:id :mw-kind :mw-extra-props))
      (when (plist-member le k)
        (setq out (plist-put out k (plist-get le k)))))
    (dolist (k mindwtr-model-content-fields)
      (let ((lv (plist-get le k)) (sv (plist-get se k)))
        (unless (equal (mindwtr-sync--field-canonical k lv)
                       (mindwtr-sync--field-canonical k sv))
          (if (mindwtr-sync--empty-p lv)
              (setq out (mindwtr-sync--plist-remove out k))
            (setq out (plist-put out k lv))))))
    out))

(defun mindwtr-sync--classify (local-entity shadow-entity)
  "Return one of `create' `update' `unchanged' for LOCAL vs SHADOW."
  (cond
   ((null shadow-entity) 'create)
   ((string= (mindwtr-signature local-entity) (mindwtr-signature shadow-entity))
    'unchanged)
   (t 'update)))

(defun mindwtr-sync-build-candidate (local shadow device-id now)
  "Build a candidate AppData from LOCAL parse and SHADOW, stamping DEVICE-ID/NOW."
  (let ((cand (list :settings (plist-get shadow :settings))))
    (dolist (key mindwtr-sync--entity-keys)
      (let* ((shadow-idx (mindwtr-shadow-index shadow key))
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
                     (let ((m (mindwtr-sync--merge-content le se)))
                       (setq m (plist-put m :rev 1))
                       (setq m (plist-put m :createdAt now))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id)))
                    ('update
                     (let ((m (mindwtr-sync--merge-content le se)))
                       (setq m (plist-put m :rev (1+ (or (plist-get se :rev) 0))))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id))))))
            (puthash id t seen)
            (push (mindwtr-sync--strip-device-local merged) out)))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (equal (plist-get se :status) "archived"))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (when (and (not (gethash id seen))
                       (not (plist-get se :deletedAt))
                       (equal (plist-get se :status) "archived"))
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
its shadow twin; a delete is a live shadow entity absent from LOCAL."
  (let ((created 0) (updated 0) (deleted 0))
    (dolist (key mindwtr-sync--entity-keys)
      (let ((idx (mindwtr-shadow-index shadow key))
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
                        (equal (plist-get se :status) "archived"))
              (setq deleted (1+ deleted)))))))
    (list :created created :updated updated :deleted deleted)))

(defun mindwtr-sync-once (buffer now)
  "Run one full sync cycle for org BUFFER, stamping changes with NOW.
Return (:ok t :conflicts LIST) or signals on hard error."
  (with-current-buffer buffer
    (let* ((shadow (mindwtr-shadow-load))
           (device (mindwtr-shadow-device-id))
           (local (mindwtr-parse-buffer))
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
          (list :ok t :noop t :conflicts nil :stats stats :skew nil)
        (let* ((candidate (mindwtr-sync-build-candidate local shadow device now))
               (wire (mindwtr-sync--strip-internal-keys candidate)))
          (mindwtr-model-validate-appdata wire)
          ;; The PUT response carries {ok, stats, clockSkewWarning}; surface
          ;; the skew warning so a misconfigured device clock is not silent.
          (let* ((put-resp (mindwtr-api-put-data wire))
                 (skew (plist-get put-resp :clockSkewWarning))
                 (got (mindwtr-api-get-data))
                 (merged (plist-get got :appdata))
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
                (setq backup-file bf)))
            (mindwtr-reconcile-buffer merged)
            (mindwtr-shadow-save merged)
            (mindwtr-shadow-set-etag (plist-get got :etag))
            (mindwtr-report-show stats conflicts skew backup-file (current-buffer))
            (list :ok t :conflicts conflicts :stats stats :skew skew)))))))

(provide 'mindwtr-sync)
;;; mindwtr-sync.el ends here
