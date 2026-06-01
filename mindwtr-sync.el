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

(defun mindwtr-sync--merge-shadow-fields (local-entity shadow-entity)
  "Overlay LOCAL-ENTITY (content) on SHADOW-ENTITY (full), local wins for content."
  (let ((out (copy-sequence (or shadow-entity '()))) (i 0))
    (while (< i (length local-entity))
      (let ((k (nth i local-entity)))
        (unless (eq k :mw-kind)
          (setq out (plist-put out k (nth (1+ i) local-entity)))))
      (setq i (+ i 2)))
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
                 (merged (mindwtr-sync--merge-shadow-fields le se)))
            (puthash id t seen)
            (pcase klass
              ('create
               (setq merged (plist-put merged :rev 1))
               (setq merged (plist-put merged :createdAt now))
               (setq merged (plist-put merged :updatedAt now))
               (setq merged (plist-put merged :revBy device-id)))
              ('update
               (setq merged (plist-put merged :rev (1+ (or (plist-get se :rev) 0))))
               (setq merged (plist-put merged :updatedAt now))
               (setq merged (plist-put merged :revBy device-id)))
              ('unchanged nil))
            (push (mindwtr-sync--strip-device-local merged) out)))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen) (plist-get se :deletedAt))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
        (setq cand (plist-put cand key (nreverse out)))))
    cand))

(defun mindwtr-sync--find (appdata id)
  "Find entity with ID in APPDATA across all entity lists."
  (catch 'hit
    (dolist (key mindwtr-sync--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (string= (plist-get e :id) id) (throw 'hit e))))
    nil))

(defun mindwtr-sync-detect-conflicts (candidate merged changed-ids)
  "Return lost-edit conflicts for CHANGED-IDS comparing CANDIDATE vs MERGED."
  (let (conflicts)
    (dolist (id changed-ids)
      (let ((mine (mindwtr-sync--find candidate id))
            (theirs (mindwtr-sync--find merged id)))
        (when (and mine theirs
                   (not (string= (mindwtr-signature mine)
                                 (mindwtr-signature theirs))))
          (push (list :id id :mine mine :theirs theirs) conflicts))))
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
                                                '(:mw-kind :mw-extra-props :mw-area-override))
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
           (candidate (mindwtr-sync-build-candidate local shadow device now))
           (wire (mindwtr-sync--strip-internal-keys candidate)))
      (mindwtr-model-validate-appdata wire)
      (mindwtr-api-put-data wire)
      (let* ((got (mindwtr-api-get-data))
             (merged (plist-get got :appdata))
             (conflicts (mindwtr-sync-detect-conflicts wire merged changed)))
        (unless (= tick (buffer-chars-modified-tick))
          (error "mindwtr: buffer changed during sync; aborting"))
        (when (buffer-file-name)
          (let ((bdir (expand-file-name "backups/" mindwtr-shadow-directory)))
            (make-directory bdir t)
            (write-region (point-min) (point-max)
                          (expand-file-name
                           (format "mindwtr-%s.org"
                                   (format-time-string "%Y%m%dT%H%M%S")) bdir))))
        (mindwtr-reconcile-buffer merged)
        (mindwtr-shadow-save merged)
        (mindwtr-shadow-set-etag (plist-get got :etag))
        (mindwtr-report-show
         (list :created (length changed) :updated 0 :deleted 0)
         conflicts nil)
        (list :ok t :conflicts conflicts)))))

(provide 'mindwtr-sync)
;;; mindwtr-sync.el ends here
