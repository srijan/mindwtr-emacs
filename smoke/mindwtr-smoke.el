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
  "Return diagnostic lines for every key whose value differs between A and B.
A raw whole-plist diff (every key, not just content fields), provided for
ad-hoc interactive debugging; the built-in phases use the content-scoped
`mindwtr-smoke-canonical-field-diff' instead."
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

;;;; Buffer rendering helper

(defun mindwtr-smoke--render-appdata (appdata)
  "Erase the current buffer and render APPDATA into it as a Mindwtr org file."
  (erase-buffer)
  (let ((org-inhibit-startup t))
    (insert "#+TITLE: mw smoke\n")
    (org-mode))
  (mindwtr-parse-ensure-keywords)
  (mindwtr-reconcile-buffer appdata))

;;;; Read-only phases

(defun mindwtr-smoke-phase-connectivity ()
  "HEAD the server; PASS (returning t) on success, FAIL (returning nil) otherwise."
  (condition-case err
      (let ((etag (mindwtr-api-head-etag)))
        (mindwtr-smoke-pass "connectivity (HEAD)" (format "ETag: %s" (or etag "(none)")))
        t)
    (mindwtr-api-auth-error
     (mindwtr-smoke-fail "connectivity (HEAD)" "authentication failed (401)")
     nil)
    (error
     (mindwtr-smoke-fail "connectivity (HEAD)" (error-message-string err))
     nil)))

(defun mindwtr-smoke-phase-snapshot ()
  "GET + validate the snapshot.  Return the appdata, or nil on error."
  (condition-case err
      (let* ((got (mindwtr-api-get-data))
             (ad (plist-get got :appdata)))
        (mindwtr-smoke-pass
         "snapshot (GET)"
         (format "%d tasks, %d projects, %d sections, %d areas, settings:%s"
                 (length (plist-get ad :tasks)) (length (plist-get ad :projects))
                 (length (plist-get ad :sections)) (length (plist-get ad :areas))
                 (if (plist-get ad :settings) "present" "empty")))
        (condition-case verr
            (progn (mindwtr-model-validate-appdata ad)
                   (mindwtr-smoke-pass "validate-appdata"))
          (error (mindwtr-smoke-fail "validate-appdata" (error-message-string verr))))
        ad)
    (mindwtr-api-auth-error
     (mindwtr-smoke-fail "snapshot (GET)" "authentication failed (401)") nil)
    (error (mindwtr-smoke-fail "snapshot (GET)" (error-message-string err)) nil)))

(defun mindwtr-smoke-phase-roundtrip (appdata)
  "Render APPDATA to org, parse it back, and compare content signatures.
On drift, FAIL and print the per-field canonical diff for each entity."
  (condition-case err
      (with-temp-buffer
        (mindwtr-smoke--render-appdata appdata)
        (let* ((reparsed (mindwtr-parse-buffer))
               (orig-idx (mindwtr-smoke-index-by-id appdata))
               (drift 0) (checked 0))
          (dolist (key mindwtr-smoke--entity-keys)
            (dolist (re (plist-get reparsed key))
              (setq checked (1+ checked))
              (let ((orig (gethash (plist-get re :id) orig-idx)))
                (when (and orig (not (string= (mindwtr-signature re)
                                              (mindwtr-signature orig))))
                  (setq drift (1+ drift))
                  (mindwtr-smoke-fail
                   (format "round-trip drift id=%s title=%S"
                           (plist-get re :id)
                           (or (plist-get re :title) (plist-get re :name))))
                  (dolist (line (mindwtr-smoke-canonical-field-diff orig re))
                    (mindwtr-smoke-info line))))))
          (when (= drift 0)
            (mindwtr-smoke-pass
             (format "round-trip signature (%d entities clean)" checked)))))
    (error (mindwtr-smoke-fail "round-trip" (error-message-string err)))))

;;;; Write lifecycle (opt-in; self-cleaning)

(defconst mindwtr-smoke-device-id "mw-smoke"
  "Recognizable `revBy' device id stamped on lifecycle writes.")

(defun mindwtr-smoke--now ()
  "Current UTC instant as a whole-second ISO `...Z' string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun mindwtr-smoke--build-wire (local shadow now)
  "Build the wire payload from LOCAL parse and SHADOW, stamped with NOW."
  (mindwtr-sync--strip-internal-keys
   (mindwtr-sync-build-candidate local shadow mindwtr-smoke-device-id now)))

(defun mindwtr-smoke--replace-heading (id entity)
  "Replace the top-level heading with MW_ID ID by re-rendering ENTITY.
ENTITY is a task content plist; it is rendered at level 1 (the lifecycle
task has no container)."
  (let ((m (gethash id (mindwtr-reconcile--id-markers))))
    (unless m (error "smoke: heading %s not found in buffer" id))
    (goto-char m) (org-back-to-heading t) (org-cut-subtree)
    (insert (mindwtr-render-heading
             (plist-put (copy-sequence entity) :mw-kind 'task) 1 nil))))

(defun mindwtr-smoke--assert-target (label tgt desired exp-status exp-rev)
  "Assert TGT (server entity) matches DESIRED content and EXP-STATUS/EXP-REV.
Returns non-nil on full success.  On content drift prints the field diff."
  (let ((ok t))
    (cond
     ((null tgt)
      (setq ok nil) (mindwtr-smoke-fail (format "%s: target present" label)
                                        "not found after PUT"))
     (t
      (unless (equal (plist-get tgt :status) exp-status)
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: status" label)
                            (format "expected %S got %S"
                                    exp-status (plist-get tgt :status))))
      (unless (equal (plist-get tgt :rev) exp-rev)
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: rev" label)
                            (format "expected %S got %S"
                                    exp-rev (plist-get tgt :rev))))
      (unless (string= (mindwtr-signature desired) (mindwtr-signature tgt))
        (setq ok nil)
        (mindwtr-smoke-fail (format "%s: content round-trip" label))
        (dolist (line (mindwtr-smoke-canonical-field-diff desired tgt))
          (mindwtr-smoke-info line)))))
    (when ok (mindwtr-smoke-pass label))
    ok))

(defun mindwtr-smoke--step (label target-id edit-fn assert-fn)
  "Run one lifecycle step and return the new server appdata, or nil on failure.
GET the server, render it, run EDIT-FN to mutate the buffer, parse, build
the wire, assert the blast radius is exactly TARGET-ID, PUT, GET again, and
run ASSERT-FN with the new appdata and the target entity."
  (condition-case err
      (let ((prior (plist-get (mindwtr-api-get-data) :appdata)))
        (with-temp-buffer
          (mindwtr-smoke--render-appdata prior)
          (funcall edit-fn)
          (let* ((local (mindwtr-parse-buffer))
                 (now (mindwtr-smoke--now))
                 (wire (mindwtr-smoke--build-wire local prior now))
                 (radius (mindwtr-smoke-blast-radius wire prior)))
            (mindwtr-model-validate-appdata wire)
            (if (not (equal radius (list target-id)))
                (progn
                  (mindwtr-smoke-fail (format "%s: blast radius" label)
                                      (format "expected only (%s) got %S"
                                              target-id radius))
                  nil)
              (mindwtr-api-put-data wire)
              (let* ((after (plist-get (mindwtr-api-get-data) :appdata))
                     (tgt (mindwtr-smoke-find-by-id after target-id)))
                (funcall assert-fn after tgt)
                after)))))
    (error (mindwtr-smoke-fail (format "%s (error)" label)
                               (error-message-string err))
           nil)))

(defun mindwtr-smoke--cleanup (id baseline)
  "Delete the lifecycle task ID (tombstone) and confirm BASELINE is untouched.
BASELINE is the appdata captured before the lifecycle began.  Always safe
to call: a no-op PASS if the task is already gone."
  (condition-case err
      (let* ((prior (plist-get (mindwtr-api-get-data) :appdata))
             (tgt (mindwtr-smoke-find-by-id prior id)))
        (if (or (null tgt) (plist-get tgt :deletedAt))
            (mindwtr-smoke-pass "cleanup (already gone)")
          (with-temp-buffer
            (mindwtr-smoke--render-appdata prior)
            (let ((m (gethash id (mindwtr-reconcile--id-markers))))
              (when m (goto-char m) (org-back-to-heading t) (org-cut-subtree)))
            (let* ((local (mindwtr-parse-buffer))
                   (now (mindwtr-smoke--now))
                   (wire (mindwtr-smoke--build-wire local prior now))
                   (radius (mindwtr-smoke-blast-radius wire prior)))
              (if (not (equal radius (list id)))
                  (mindwtr-smoke-fail "cleanup: blast radius"
                                      (format "expected only (%s) got %S" id radius))
                (mindwtr-api-put-data wire)
                (let* ((after (plist-get (mindwtr-api-get-data) :appdata))
                       (t2 (mindwtr-smoke-find-by-id after id)))
                  (if (and t2 (not (plist-get t2 :deletedAt)))
                      (mindwtr-smoke-fail "cleanup (delete)" "task still live after delete")
                    (mindwtr-smoke-pass "cleanup (delete)"))
                  ;; final non-target drift check against the pre-lifecycle baseline
                  (let ((drift 0))
                    (dolist (key mindwtr-smoke--entity-keys)
                      (dolist (e (plist-get baseline key))
                        (let ((e2 (mindwtr-smoke-find-by-id after (plist-get e :id))))
                          (when (and e2 (not (string= (mindwtr-signature e)
                                                      (mindwtr-signature e2))))
                            (setq drift (1+ drift))
                            (mindwtr-smoke-info
                             (format "baseline drift id=%s" (plist-get e :id)))))))
                    (if (= drift 0)
                        (mindwtr-smoke-pass "lifecycle non-target drift: 0")
                      (mindwtr-smoke-fail
                       (format "lifecycle non-target drift: %d" drift))))))))))
    (error (mindwtr-smoke-fail "cleanup (error)" (error-message-string err)))))

(defun mindwtr-smoke-phase-write-lifecycle ()
  "Drive a throwaway task through inbox -> next -> done -> delete, self-cleaning."
  (let* ((baseline (plist-get (mindwtr-api-get-data) :appdata))
         (run-id (format-time-string "%Y%m%dT%H%M%S"))
         (id (mindwtr-util-uuid))
         (base-title (format "[mw-smoke] lifecycle %s" run-id))
         (desired (list :mw-kind 'task :id id :status "inbox" :title base-title
                        :contexts '("@computer") :tags '("#smoke")
                        :priority "high" :energyLevel "low" :dueDate "2099-12-31"
                        :checklist (list (list :title "step one" :isCompleted :false)
                                         (list :title "step two" :isCompleted :false)))))
    (unwind-protect
        (catch 'abort
          ;; CREATE in inbox
          (unless (mindwtr-smoke--step
                   "create (inbox)" id
                   (lambda () (goto-char (point-max))
                     (insert (mindwtr-render-heading desired 1 nil)))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "create (inbox)" tgt desired
                                                   "inbox" 1)))
            (throw 'abort nil))
          ;; MUTATE: edit title + complete the first checklist item
          (setq desired (plist-put (copy-sequence desired)
                                   :title (concat base-title " (edited)")))
          (setq desired (plist-put desired :checklist
                                   (list (list :title "step one" :isCompleted t)
                                         (list :title "step two" :isCompleted :false))))
          (unless (mindwtr-smoke--step
                   "mutate (title+checklist)" id
                   (lambda () (mindwtr-smoke--replace-heading id desired))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "mutate (title+checklist)" tgt
                                                   desired "inbox" 2)))
            (throw 'abort nil))
          ;; TRANSITION -> next
          (setq desired (plist-put (copy-sequence desired) :status "next"))
          (unless (mindwtr-smoke--step
                   "transition next" id
                   (lambda () (mindwtr-smoke--replace-heading id desired))
                   (lambda (_after tgt)
                     (mindwtr-smoke--assert-target "transition next" tgt
                                                   desired "next" 3)))
            (throw 'abort nil))
          ;; TRANSITION -> done.  completedAt is a content field, so
          ;; `mindwtr-smoke--assert-target' already fails on a missing or
          ;; mismatched value via the signature check -- no separate guard.
          (setq desired (plist-put (copy-sequence desired) :status "done"))
          (setq desired (plist-put desired :completedAt (mindwtr-smoke--now)))
          (mindwtr-smoke--step
           "transition done" id
           (lambda () (mindwtr-smoke--replace-heading id desired))
           (lambda (_after tgt)
             (mindwtr-smoke--assert-target "transition done" tgt desired "done" 4))))
      ;; CLEANUP always runs
      (mindwtr-smoke--cleanup id baseline))))

(provide 'mindwtr-smoke)
;;; mindwtr-smoke.el ends here
