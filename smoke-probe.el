;;; smoke-probe.el --- Inspect real entity shapes -*- lexical-binding: t; -*-
;;; Commentary:
;; Throwaway, read-only.  Dumps the raw plist of: any task that carries a
;; checklist, every project (to see area handling incl. the new area-less
;; one), and the areas.  No render/parse, no writes -- just the wire shape.
;;
;;   MINDWTR_URL=https://your.server MINDWTR_TOKEN=xxxx \
;;     emacs -Q --batch -L . -l smoke-probe.el
;;; Code:

(require 'mindwtr-api)
(require 'mindwtr)

(setq mindwtr-api-base-url (or (getenv "MINDWTR_URL") (error "Set MINDWTR_URL")))
(setq mindwtr-api-token
      (or (getenv "MINDWTR_TOKEN")
          (let ((mindwtr-server-url mindwtr-api-base-url))
            (ignore-errors (mindwtr--resolve-token)))
          (error "No token")))

(defun probe--keys (pl)
  (let (ks (i 0)) (while (< i (length pl)) (push (nth i pl) ks) (setq i (+ i 2)))
       (nreverse ks)))

(let* ((got (mindwtr-api-get-data)) (ad (plist-get got :appdata)))

  (message "== AREAS (%d) ==" (length (plist-get ad :areas)))
  (dolist (a (plist-get ad :areas))
    (message "  area id=%s name=%S keys=%S"
             (plist-get a :id) (plist-get a :name) (probe--keys a)))

  (message "\n== PROJECTS (%d) ==" (length (plist-get ad :projects)))
  (dolist (p (plist-get ad :projects))
    (message "  project id=%s title=%S areaId=%S deletedAt=%S"
             (plist-get p :id) (plist-get p :title)
             (plist-get p :areaId) (plist-get p :deletedAt))
    (message "    keys=%S" (probe--keys p)))

  (message "\n== TASKS WITH CHECKLIST ==")
  (let ((found nil))
    (dolist (tk (plist-get ad :tasks))
      (let ((cl (or (plist-get tk :checklist) (plist-get tk :subtasks)
                    (plist-get tk :checkItems) (plist-get tk :items))))
        (when cl
          (setq found t)
          (message "  task id=%s title=%S deletedAt=%S"
                   (plist-get tk :id) (plist-get tk :title) (plist-get tk :deletedAt))
          (message "    task keys=%S" (probe--keys tk))
          (message "    checklist raw=%S" cl)
          (when (and (listp cl) (listp (car cl)))
            (message "    first item keys=%S" (probe--keys (car cl)))))))
    (unless found (message "  (no task carries a checklist/subtasks field)")))

  (message "\n== SAMPLE TASK KEYS (first live task) ==")
  (let ((tk (seq-find (lambda (x) (not (plist-get x :deletedAt)))
                      (plist-get ad :tasks))))
    (when tk (message "  id=%s keys=%S" (plist-get tk :id) (probe--keys tk)))))

(message "\n== probe complete (no writes) ==")
;;; smoke-probe.el ends here
