;;; mindwtr-parity.el --- Synced-field parity against upstream fixtures -*- lexical-binding: t; -*-
;;; Commentary:
;; Compares `mindwtr-model-known-fields' against the Mindwtr core's own
;; machine-readable sync-field fixtures
;; (`packages/core/src/<entity>-sync-schema.fixture.json'), which upstream
;; generates and gates in CI via `scripts/check-synced-field-parity.ts'.
;;
;; Why this exists: `mindwtr-smoke-schema-coverage' diffs the model against the
;; keys actually present on a live instance, so a field the server has learned
;; but no entity uses yet is invisible to it.  That is exactly how
;; `Project.startDate' and `Task.viewSectionIds' reached the model unnoticed.
;; The fixtures declare every synced field whether or not any row carries one,
;; so this check catches a new field the day upstream adds it.
;;
;; **No server is required** -- this is a pure file comparison, so it runs in
;; the offline `make test' gate (skipped when no checkout is configured) as
;; well as from `make parity' and the live smoke run.
;;
;; Point it at an upstream checkout with MINDWTR_CORE_PATH: either the monorepo
;; root or the `packages/core/src' directory itself.
;;
;;   MINDWTR_CORE_PATH=~/src/Mindwtr make parity
;;
;; Two fixture generations are in the wild and both are read:
;;
;;   v1 (area, person, project, section) -- each field carries `cloudSynced'.
;;   v2 (task) -- each field carries a `sync' category (identity, content,
;;       order, revision-metadata, archive-metadata, tombstone, legacy-alias)
;;       and a `signature' membership.
;;
;; `legacy-alias' fields (e.g. task `orderNum') are deprecated upstream spellings:
;; the model MAY still read them for old data, so they are never reported as
;; missing -- only noted.
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'mindwtr-model)

(defconst mindwtr-parity-entities '(task project section area person)
  "Entity types checked for synced-field parity.
Every type in `mindwtr-model-known-fields' has an upstream fixture; `person'
is included here deliberately -- `mindwtr-smoke-schema-coverage' omits it,
so person drift was previously undetectable by any check.")

(defconst mindwtr-parity--core-subdir "packages/core/src"
  "Path from an upstream monorepo root to the directory holding the fixtures.")

(defun mindwtr-parity--fixture-name (entity)
  "Return the fixture basename for ENTITY."
  (format "%s-sync-schema.fixture.json" entity))

(defun mindwtr-parity-core-dir ()
  "Return the directory holding the upstream sync-schema fixtures, or nil.
Resolved from the MINDWTR_CORE_PATH environment variable, which may name
either the monorepo root or `packages/core/src' directly.  Returns nil when
the variable is unset or neither candidate holds the task fixture, so callers
can skip rather than fail on a machine with no upstream checkout."
  (let ((root (getenv "MINDWTR_CORE_PATH")))
    (when (and root (not (string-empty-p root)))
      (let* ((root (expand-file-name root))
             (probe (mindwtr-parity--fixture-name 'task))
             (nested (expand-file-name mindwtr-parity--core-subdir root)))
        (cond
         ((file-readable-p (expand-file-name probe nested)) nested)
         ((file-readable-p (expand-file-name probe root)) root))))))

(defun mindwtr-parity--read-json (file)
  "Parse FILE as JSON, returning alists for objects and lists for arrays.
Prefers the native `json-parse-buffer'; falls back to json.el so an Emacs
built without libjansson still works."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (fboundp 'json-parse-buffer)
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-false nil)
            (json-null nil))
        (json-read)))))

(defun mindwtr-parity--field-keyword (field)
  "Return FIELD's `name' as a model keyword (e.g. :startDate)."
  (intern (concat ":" (alist-get 'name field))))

(defun mindwtr-parity-fixture (entity dir)
  "Read ENTITY's fixture from DIR into a plist describing its synced fields.
Keys: `:version' (fixture schemaVersion), `:wire' (every declared field),
`:legacy' (deprecated aliases, v2 only) and `:signature' (fields in the
server's own content signature, v2 only).  Signals if the file is unreadable."
  (let* ((file (expand-file-name (mindwtr-parity--fixture-name entity) dir))
         (doc (mindwtr-parity--read-json file))
         (version (alist-get 'schemaVersion doc))
         (fields (alist-get 'fields doc)))
    (list :version version
          :file file
          :wire (mapcar #'mindwtr-parity--field-keyword fields)
          :legacy (mapcar #'mindwtr-parity--field-keyword
                          (seq-filter
                           (lambda (f) (equal (alist-get 'sync f) "legacy-alias"))
                           fields))
          :signature (mapcar #'mindwtr-parity--field-keyword
                             (seq-filter
                              (lambda (f) (equal (alist-get 'signature f) "content"))
                              fields)))))

(defun mindwtr-parity-compare (entity dir)
  "Compare ENTITY's model fields against its upstream fixture in DIR.
Return a plist with `:missing' (upstream declares it, the model does not --
this is drift the model must adopt), `:extra' (the model carries a field
upstream no longer declares) and `:legacy' (deprecated aliases, reported for
information only).  `:missing' excludes legacy aliases: the model may keep
reading one for old data without upstream still declaring it current."
  (let* ((fx (mindwtr-parity-fixture entity dir))
         (known (cdr (assq entity mindwtr-model-known-fields)))
         (wire (plist-get fx :wire))
         (legacy (plist-get fx :legacy)))
    (append
     (list :missing (seq-remove (lambda (k) (or (memq k known) (memq k legacy))) wire)
           :extra (seq-remove (lambda (k) (memq k wire)) known))
     fx)))

(defun mindwtr-parity-check (&optional dir)
  "Compare every entity's model fields against the upstream fixtures in DIR.
DIR defaults to `mindwtr-parity-core-dir'.  Return an alist of
\(ENTITY . PLIST) as produced by `mindwtr-parity-compare', or nil when no
upstream checkout is configured."
  (let ((dir (or dir (mindwtr-parity-core-dir))))
    (when dir
      (mapcar (lambda (e) (cons e (mindwtr-parity-compare e dir)))
              mindwtr-parity-entities))))

(defun mindwtr-parity-drift (result)
  "Return the entries of RESULT that carry `:missing' or `:extra' fields."
  (seq-filter (lambda (entry)
                (or (plist-get (cdr entry) :missing)
                    (plist-get (cdr entry) :extra)))
              result))

(defun mindwtr-parity-format (result)
  "Return RESULT as a list of human-readable report lines."
  (let (lines)
    (dolist (entry result)
      (let* ((entity (car entry)) (pl (cdr entry))
             (missing (plist-get pl :missing))
             (extra (plist-get pl :extra))
             (legacy (plist-get pl :legacy)))
        (cond
         ((or missing extra)
          (when missing
            (push (format "DRIFT %s: upstream declares %S -- absent from mindwtr-model-known-fields"
                          entity missing)
                  lines))
          (when extra
            (push (format "DRIFT %s: model carries %S -- no longer declared upstream"
                          entity extra)
                  lines)))
         (t (push (format "ok    %s: %d fields match (fixture v%s)"
                          entity (length (plist-get pl :wire))
                          (plist-get pl :version))
                  lines)))
        (when legacy
          (push (format "note  %s: upstream marks %S legacy-alias" entity legacy)
                lines))))
    (nreverse lines)))

;;;###autoload
(defun mindwtr-parity-report ()
  "Print a synced-field parity report; return non-nil when drift was found.
Prints a single skip line and returns nil when MINDWTR_CORE_PATH names no
usable checkout, so an unconfigured machine reports nothing rather than
failing."
  (let ((result (mindwtr-parity-check)))
    (if (null result)
        (progn
          (message "parity: SKIP -- set MINDWTR_CORE_PATH to an upstream Mindwtr checkout")
          nil)
      (dolist (line (mindwtr-parity-format result)) (message "%s" line))
      (let ((drift (mindwtr-parity-drift result)))
        (when drift
          (message "parity: %d entit%s drifted from the upstream fixtures"
                   (length drift) (if (= 1 (length drift)) "y" "ies")))
        drift))))

(provide 'mindwtr-parity)
;;; mindwtr-parity.el ends here
