;;; mindwtr-signature.el --- Content signatures -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; A stable hash over only the editable fields of an entity, used for
;; change detection.  Excludes shadow-only and display-mirror fields.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-signature--set-fields '(:tags :contexts)
  "Fields whose list value is a set (order-insensitive).")

(defconst mindwtr-signature--datetime-fields '(:startTime :dueDate :completedAt :reviewAt)
  "Content fields holding ISO datetimes.
Coarsened to minute precision for signing, because org timestamps cannot
represent sub-minute values and so the seconds never round-trip.")

(defconst mindwtr-signature--boolean-fields '(:isFocusedToday :isSequential :isFocused)
  "Content fields holding a server boolean.
Canonicalized so a genuine `t' signs as `t' and everything else (`:false',
nil) folds to nil -- which `--canonical-plist' then drops -- so a server
`:false', a parsed nil, and an omitted key all sign identically (no phantom
drift).  Server false is the symbol `:false', non-nil in elisp, so without
this fold it would sign as a distinct present value.")

(defun mindwtr-signature--norm-checklist (items)
  "Normalize checklist ITEMS to a stable signable form.
Keeps only (:title :isCompleted) per item, in fixed key order, dropping
the server-assigned :id (org checkbox syntax cannot carry it, so it does
not round-trip).  Order is preserved -- a checklist is a sequence, not a
set.  Completion is coerced to t/`:false' so a missing flag and an
explicit false sign identically."
  (mapcar (lambda (it)
            (list :title (or (plist-get it :title) "")
                  :isCompleted (if (eq (plist-get it :isCompleted) t) t :false)))
          items))

(defun mindwtr-signature-canonical-value (k v)
  "Return the canonical signing form of content field K's value V.
Set-valued fields are sorted, datetimes coarsened to minute precision,
and checklists normalized (item :id dropped); every other field is
returned unchanged.  Callers treat empty values as absent separately.
Shared with the sync engine so change detection and write-merge use one
definition of \"the same content\"."
  (cond
   ((and (memq k mindwtr-signature--set-fields) (listp v))
    (sort (copy-sequence v) #'string<))
   ((memq k mindwtr-signature--datetime-fields)
    (mindwtr-util-iso-coarsen-minute v))
   ((memq k mindwtr-signature--boolean-fields)
    (if (eq v t) t nil))
   ((eq k :checklist)
    (mindwtr-signature--norm-checklist v))
   (t v)))

(defun mindwtr-signature--canonical-plist (entity)
  "Return a canonical flat plist of ENTITY's content fields, sorted by key.
Signs only the editable fields named in `mindwtr-model-content-fields'
\(an allow-list); every other server field is excluded by construction,
so unmapped fields can neither drift the signature nor leak into change
detection.  Set-valued fields are sorted, datetimes coarsened to minute
precision, and checklists normalized (see
`mindwtr-signature--norm-checklist').  An empty value (nil, empty list,
or empty string) is treated as absent so a sparse entity signs
identically whether a producer omits the key or emits an explicit empty;
without this an unchanged sparse entity would get a different signature
after a render/parse cycle and trigger a phantom `rev' bump."
  (let (pairs)
    (dolist (k mindwtr-model-content-fields)
      (let ((v (plist-get entity k)))
        (unless (or (null v) (and (stringp v) (string-empty-p v)))
          ;; Re-test emptiness on the CANONICAL value, not the raw one: a
          ;; boolean `:false' is a non-nil symbol that passes the raw check
          ;; above but folds to nil in `canonical-value', and it must drop out
          ;; exactly like an absent key so `:false'/nil/absent sign identically
          ;; (KTD-4).  Datetime/set fields with a non-empty raw value never
          ;; canonicalize to nil, so this only fires for the boolean fold.
          (let ((cv (mindwtr-signature-canonical-value k v)))
            (unless (or (null cv) (and (stringp cv) (string-empty-p cv)))
              (push (cons k cv) pairs))))))
    (setq pairs (sort pairs (lambda (a b)
                              (string< (symbol-name (car a))
                                       (symbol-name (car b))))))
    (let (flat)
      (dolist (p pairs)
        (setq flat (plist-put flat (car p) (cdr p))))
      flat)))

(defvar mindwtr-signature--cache (make-hash-table :test 'eq :weakness 'key)
  "Weak eq-keyed memo of ENTITY object -> signature string.
One sync cycle signs the same entity plists repeatedly (change detection,
stats, the change list, candidate construction, conflict detection), and each
signature is a canonicalize + JSON-encode + SHA-256 -- the engine's dominant
per-entity CPU cost.  Keying on the plist object (eq) is sound because the
engine never mutates an entity in place after signing: every derived entity is
built via `copy-sequence'/fresh construction first.  KEEP IT THAT WAY -- an
in-place `plist-put' on a signed entity would silently serve a stale
signature.  Key weakness lets GC drop entries once a cycle's objects die.")

(defun mindwtr-signature (entity)
  "Return a stable SHA-256 signature string for ENTITY's editable content.
Memoized per ENTITY object (see `mindwtr-signature--cache')."
  (or (gethash entity mindwtr-signature--cache)
      (puthash entity
               (secure-hash 'sha256 (mindwtr-util-json-encode
                                     (mindwtr-signature--canonical-plist entity)))
               mindwtr-signature--cache)))

(provide 'mindwtr-signature)
;;; mindwtr-signature.el ends here
