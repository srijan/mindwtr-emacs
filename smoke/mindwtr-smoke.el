;;; mindwtr-smoke.el --- Live smoke suite against a Mindwtr server -*- lexical-binding: t; -*-
;;; Commentary:
;; Reusable, committed smoke suite.  Read-only phases (connectivity,
;; snapshot+validate, schema coverage, render/parse round-trip) run by
;; default; an opt-in self-cleaning GTD write lifecycle exercises the PUT
;; path.  Run it via the Makefile so the token stays in your shell:
;;
;;   make smoke         ; read-only phases only
;;   make smoke-write   ; read-only phases + write lifecycle
;;
;; Config from the environment: MINDWTR_URL (required) and MINDWTR_TOKEN
;; (falls back to auth-source for the URL host when unset).
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-reconcile)
(require 'mindwtr-sync)
(require 'mindwtr)

;;;; Reporting + exit

(defvar mindwtr-smoke--counts (list :pass 0 :fail 0 :warn 0)
  "Plist (:pass N :fail N :warn N) of results for the current run.")

(defun mindwtr-smoke-reset ()
  "Reset the result counters."
  (setq mindwtr-smoke--counts (list :pass 0 :fail 0 :warn 0)))

(defun mindwtr-smoke--bump (key)
  (setq mindwtr-smoke--counts
        (plist-put mindwtr-smoke--counts key
                   (1+ (plist-get mindwtr-smoke--counts key)))))

(defun mindwtr-smoke-info (msg)
  "Print an indented diagnostic/info line MSG (not counted)."
  (message "       %s" msg))

(defun mindwtr-smoke-pass (label &rest details)
  "Record a pass for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :pass)
  (message "[PASS] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-fail (label &rest details)
  "Record a fail for LABEL and print it with optional DETAILS lines."
  (mindwtr-smoke--bump :fail)
  (message "[FAIL] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-warn (label &rest details)
  "Record a warning for LABEL (never affects exit code)."
  (mindwtr-smoke--bump :warn)
  (message "[WARN] %s" label)
  (dolist (d details) (mindwtr-smoke-info d)))

(defun mindwtr-smoke-summary ()
  "Print the run summary; return 1 if any fail was recorded, else 0."
  (message "---")
  (message "Summary: %d pass, %d fail, %d warn"
           (plist-get mindwtr-smoke--counts :pass)
           (plist-get mindwtr-smoke--counts :fail)
           (plist-get mindwtr-smoke--counts :warn))
  (if (> (plist-get mindwtr-smoke--counts :fail) 0) 1 0))

;;;; Config

(defun mindwtr-smoke-configure ()
  "Set `mindwtr-api-base-url' and `mindwtr-api-token' from the environment."
  (setq mindwtr-api-base-url
        (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
  (setq mindwtr-api-token
        (or (getenv "MINDWTR_TOKEN")
            (let ((mindwtr-server-url mindwtr-api-base-url))
              (ignore-errors (mindwtr--resolve-token)))
            (error "No token: set MINDWTR_TOKEN or an auth-source entry for the host"))))

;;;; Pure helpers

(defconst mindwtr-smoke--entity-keys '(:tasks :projects :sections :areas))

(defun mindwtr-smoke-plist-keys (pl)
  "Return the list of keys in plist PL."
  (let (ks (i 0))
    (while (< i (length pl)) (push (nth i pl) ks) (setq i (+ i 2)))
    (nreverse ks)))

(defun mindwtr-smoke-plist-same-p (a b)
  "Non-nil if plists A and B have identical key->value sets (order-insensitive)."
  (let ((ka (mindwtr-smoke-plist-keys a)) (kb (mindwtr-smoke-plist-keys b)))
    (and (= (length ka) (length kb))
         (seq-every-p (lambda (k) (and (plist-member b k)
                                       (equal (plist-get a k) (plist-get b k))))
                      ka))))

(defun mindwtr-smoke-find-by-id (appdata id)
  "Return the entity with ID anywhere in APPDATA, or nil."
  (catch 'hit
    (dolist (key mindwtr-smoke--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (string= (plist-get e :id) id) (throw 'hit e))))
    nil))

(defun mindwtr-smoke-index-by-id (appdata &optional live-only)
  "Return a hash id->entity over all of APPDATA's entity lists.
With LIVE-ONLY non-nil, omit tombstoned entities (those with :deletedAt)."
  (let ((idx (make-hash-table :test 'equal)))
    (dolist (key mindwtr-smoke--entity-keys)
      (dolist (e (plist-get appdata key))
        (unless (and live-only (plist-get e :deletedAt))
          (puthash (plist-get e :id) e idx))))
    idx))

(defun mindwtr-smoke-blast-radius (wire prior)
  "Return the sorted list of entity ids that differ between PRIOR and WIRE.
Considers only the live view of each (tombstones are not live): an id is
in the radius if it is newly live in WIRE (create), no longer live in WIRE
\(delete/tombstone), or live in both but with different content (update)."
  (let ((wi (mindwtr-smoke-index-by-id wire t))
        (pi (mindwtr-smoke-index-by-id prior t))
        (ids (make-hash-table :test 'equal))
        out)
    (maphash (lambda (id w)
               (let ((p (gethash id pi)))
                 (when (or (null p) (not (mindwtr-smoke-plist-same-p w p)))
                   (puthash id t ids))))
             wi)
    (maphash (lambda (id _p)
               (unless (gethash id wi) (puthash id t ids)))
             pi)
    (maphash (lambda (id _) (push id out)) ids)
    (sort out #'string<)))

;;;; Diagnostics (returned as lists of printable lines)

(defun mindwtr-smoke-canonical-field-diff (orig re)
  "Return diagnostic lines for content fields that differ between ORIG and RE.
Compares the signature's canonical plists, so it reports exactly the
fields that move the content signature."
  (let* ((co (mindwtr-signature--canonical-plist orig))
         (cr (mindwtr-signature--canonical-plist re))
         (allk (delete-dups (append (mindwtr-smoke-plist-keys co)
                                    (mindwtr-smoke-plist-keys cr))))
         lines)
    (dolist (k allk)
      (let ((vo (plist-get co k)) (vr (plist-get cr k)))
        (unless (equal vo vr)
          (push (format "%s: orig=%S  other=%S" k vo vr) lines))))
    (nreverse lines)))

(defun mindwtr-smoke-key-diff (a b)
  "Return diagnostic lines for every key whose value differs between A and B."
  (let ((allk (delete-dups (append (mindwtr-smoke-plist-keys a)
                                   (mindwtr-smoke-plist-keys b))))
        lines)
    (dolist (k allk)
      (unless (equal (plist-get a k) (plist-get b k))
        (push (format "%s: a=%S  b=%S" k (plist-get a k) (plist-get b k)) lines)))
    (nreverse lines)))

;;;; Schema coverage

(defconst mindwtr-smoke--type->key
  '((task . :tasks) (project . :projects) (section . :sections) (area . :areas))
  "Map a known-fields entity type to its appdata list key.")

(defun mindwtr-smoke--union-keys (entities)
  "Return the set (deduped list) of keys appearing on any entity in ENTITIES."
  (let (acc)
    (dolist (e entities) (setq acc (append (mindwtr-smoke-plist-keys e) acc)))
    (delete-dups acc)))

(defun mindwtr-smoke-schema-coverage (appdata)
  "Compute per-type schema coverage for APPDATA against the known-fields registry.
Return an alist (TYPE . (:unknown KEYS :unexercised KEYS)): :unknown are
wire keys we do not model (server drift); :unexercised are known fields no
entity of that type uses on this instance."
  (mapcar
   (lambda (type)
     (let* ((known (cdr (assq type mindwtr-model-known-fields)))
            (live (mindwtr-smoke--union-keys
                   (plist-get appdata (cdr (assq type mindwtr-smoke--type->key)))))
            (unknown (seq-remove (lambda (k) (memq k known)) live))
            (unexercised (seq-remove (lambda (k) (memq k live)) known)))
       (cons type (list :unknown unknown :unexercised unexercised))))
   '(task project section area)))

(defun mindwtr-smoke-phase-schema-coverage (appdata)
  "Report schema coverage: UNKNOWN keys WARN; unexercised keys as one info line."
  (let ((cov (mindwtr-smoke-schema-coverage appdata)) (any-unknown nil))
    (dolist (entry cov)
      (let ((unknown (plist-get (cdr entry) :unknown)))
        (when unknown
          (setq any-unknown t)
          (mindwtr-smoke-warn
           (format "schema: %s has unknown keys" (car entry))
           (format "%S -- model may need updating for this server version"
                   unknown)))))
    (unless any-unknown
      (mindwtr-smoke-pass "schema coverage (no unknown keys)"))
    ;; one non-fatal info line listing model fields not seen on this instance
    (dolist (entry cov)
      (let ((unex (plist-get (cdr entry) :unexercised)))
        (when unex
          (mindwtr-smoke-info
           (format "%s fields not exercised on this instance: %S"
                   (car entry) unex)))))))

(provide 'mindwtr-smoke)
;;; mindwtr-smoke.el ends here
