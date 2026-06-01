;;; mindwtr-signature.el --- Content signatures -*- lexical-binding: t; -*-
;;; Commentary:
;; A stable hash over only the editable fields of an entity, used for
;; change detection.  Excludes shadow-only and display-mirror fields.
;;; Code:

(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-signature--set-fields '(:tags :contexts)
  "Fields whose list value is a set (order-insensitive).")

(defun mindwtr-signature--canonical-plist (entity)
  "Return a canonical flat plist of ENTITY's editable fields, sorted by key.
Excludes shadow-only and display-mirror fields; sorts set-valued fields.
An empty editable value (nil, empty list, or empty string) is treated as
absent so that producers which emit an explicit empty (e.g. the parser
sets `:priority nil'/`:tags nil'/`:description \"\"' for a sparse task)
sign identically to producers which omit the key.  Without this, an
unchanged sparse entity would get a different signature after a
render/parse cycle and trigger a phantom `rev' bump."
  (let (pairs (i 0))
    (while (< i (length entity))
      (let ((k (nth i entity)) (v (nth (1+ i) entity)))
        (unless (or (mindwtr-model-shadow-only-field-p k)
                    (memq k mindwtr-model-display-mirror-fields)
                    ;; internal parse-only keys must never affect the signature.
                    ;; `:mw-area-override' is an internal mirror of an explicit
                    ;; MW_AREA_ID; the semantic it carries is already captured by
                    ;; the signed `:areaId', so it stays excluded.  Containment
                    ;; IDs (:areaId :projectId :sectionId) ARE editable, mapped
                    ;; fields and MUST be signed: refiling a heading = re-parenting
                    ;; in Mindwtr, so a changed parent must change the signature.
                    (memq k '(:mw-kind :mw-extra-props :mw-ancestors
                              :mw-area-override))
                    ;; empty == absent: nil, empty list, or empty string
                    (null v)
                    (and (stringp v) (string-empty-p v)))
          (when (and (memq k mindwtr-signature--set-fields) (listp v))
            (setq v (sort (copy-sequence v) #'string<)))
          (push (cons k v) pairs)))
      (setq i (+ i 2)))
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
