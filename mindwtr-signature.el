;;; mindwtr-signature.el --- Content signatures -*- lexical-binding: t; -*-
;;; Commentary:
;; A stable hash over only the editable fields of an entity, used for
;; change detection.  Excludes shadow-only and display-mirror fields.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-signature--set-fields '(:tags :contexts)
  "Fields whose list value is a set (order-insensitive).")

(defconst mindwtr-signature--datetime-fields '(:startTime :dueDate :completedAt)
  "Content fields holding ISO datetimes.
Coarsened to minute precision for signing, because org timestamps cannot
represent sub-minute values and so the seconds never round-trip.")

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
          (cond
           ((and (memq k mindwtr-signature--set-fields) (listp v))
            (setq v (sort (copy-sequence v) #'string<)))
           ((memq k mindwtr-signature--datetime-fields)
            (setq v (mindwtr-util-iso-coarsen-minute v)))
           ((eq k :checklist)
            (setq v (mindwtr-signature--norm-checklist v))))
          (push (cons k v) pairs))))
    (setq pairs (sort pairs (lambda (a b)
                              (string< (symbol-name (car a))
                                       (symbol-name (car b))))))
    (let (flat)
      (dolist (p pairs)
        (setq flat (plist-put flat (car p) (cdr p))))
      flat)))

(defun mindwtr-signature (entity)
  "Return a stable SHA-256 signature string for ENTITY's editable content."
  (secure-hash 'sha256 (mindwtr-util-json-encode
                        (mindwtr-signature--canonical-plist entity))))

(provide 'mindwtr-signature)
;;; mindwtr-signature.el ends here
