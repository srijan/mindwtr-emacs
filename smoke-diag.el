;;; smoke-diag.el --- Field-level drift diagnostic -*- lexical-binding: t; -*-
;;; Commentary:
;; Throwaway.  Read-only.  For each entity whose signature drifts after a
;; render->parse round-trip, print the per-key diff of the canonical plist
;; (original vs reparsed) so we can see exactly which fields don't survive.
;;
;;   MINDWTR_URL=https://your.server MINDWTR_TOKEN=xxxx \
;;     emacs -Q --batch -L . -l smoke-diag.el
;;; Code:

(require 'mindwtr-api)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)
(require 'mindwtr)

(setq mindwtr-api-base-url (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
(setq mindwtr-api-token
      (or (getenv "MINDWTR_TOKEN")
          (let ((mindwtr-server-url mindwtr-api-base-url))
            (ignore-errors (mindwtr--resolve-token)))
          (error "No token")))

(defun diag--canon (e) (mindwtr-signature--canonical-plist e))

(defun diag--keys (pl)
  (let (ks (i 0)) (while (< i (length pl)) (push (nth i pl) ks) (setq i (+ i 2)))
       (nreverse ks)))

(defun diag--diff (orig re)
  "Print key-level differences between canonical plists of ORIG and RE."
  (let* ((co (diag--canon orig)) (cr (diag--canon re))
         (allk (delete-dups (append (diag--keys co) (diag--keys cr)))))
    (dolist (k allk)
      (let ((vo (plist-get co k)) (vr (plist-get cr k)))
        (unless (equal vo vr)
          (message "      %s: orig=%S  reparsed=%S" k vo vr))))))

(let* ((got (mindwtr-api-get-data)) (ad (plist-get got :appdata))
       (orig-idx (make-hash-table :test 'equal)) (shown 0))
  (dolist (key '(:tasks :projects :sections :areas))
    (dolist (e (plist-get ad key)) (puthash (plist-get e :id) e orig-idx)))
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "#+TITLE: diag\n") (org-mode))
    (mindwtr-parse-ensure-keywords)
    (mindwtr-reconcile-buffer ad)
    (let ((reparsed (mindwtr-parse-buffer)))
      (dolist (key '(:tasks :projects :sections :areas))
        (dolist (re (plist-get reparsed key))
          (let ((orig (gethash (plist-get re :id) orig-idx)))
            (when (and orig (< shown 40)
                       (not (string= (mindwtr-signature re) (mindwtr-signature orig))))
              (setq shown (1+ shown))
              (message "DRIFT id=%s title=%S"
                       (plist-get re :id)
                       (or (plist-get re :title) (plist-get re :name)))
              (diag--diff orig re))))))))
(message "== diag complete ==")
;;; smoke-diag.el ends here
