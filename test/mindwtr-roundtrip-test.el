;;; mindwtr-roundtrip-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)

(defconst mindwtr-roundtrip--task
  '(:id "t1" :mw-kind task :title "Buy milk" :status "next" :priority "high"
    :areaId "a1"
    :contexts ("@errands") :tags ("#focused") :energyLevel "medium"
    :timeEstimate "1hr" :description "Line one.\nLine two."
    :checklist ((:title "a" :isCompleted :false) (:title "b" :isCompleted t))
    :startTime "2026-02-09T00:00:00Z"
    :mw-extra-props ("CUSTOM_KEY" "keepme")))

(ert-deftest mindwtr-roundtrip-render-parse-signature-stable ()
  "render -> parse preserves the editable content signature."
  (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading mindwtr-roundtrip--task 2 shadow)))
         (sig-before (mindwtr-signature mindwtr-roundtrip--task)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((ad (mindwtr-parse-buffer))
             (task (car (plist-get ad :tasks))))
        (should (string= (mindwtr-signature task) sig-before))
        (should (string= (plist-get (plist-get task :mw-extra-props) "CUSTOM_KEY" #'equal)
                         "keepme"))))))

(ert-deftest mindwtr-roundtrip-render-is-stable ()
  "render(parse(render(x))) == render(parse(render(x))) (idempotent text)."
  (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
         (t1 (mindwtr-render-heading mindwtr-roundtrip--task 2 shadow)))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n" t1)
        (org-mode))
      (let* ((task (car (plist-get (mindwtr-parse-buffer) :tasks)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence task) :mw-kind 'task) 2 shadow)))
        (should (string= t1 t2))))))

(ert-deftest mindwtr-roundtrip-containment-affects-signature ()
  "Re-parenting (changed containment) must change the signature."
  (let ((a '(:id "t1" :title "x" :status "next" :projectId "p1"))
        (b '(:id "t1" :title "x" :status "next" :projectId "p2")))
    (should-not (string= (mindwtr-signature a) (mindwtr-signature b)))))

(ert-deftest mindwtr-roundtrip-unsafe-contexts-use-drawer ()
  "Contexts/tags org can't represent move to MW_CONTEXTS/MW_TAGS and round-trip.
Regression for a task whose `@agenda/jane-doe' context (with
`/' and `-') was swallowed into the title by org's tag parser."
  (let* ((task '(:id "t1" :mw-kind task :title "Talk to Jane" :status "next"
                 :areaId "a1"
                 :contexts ("@agenda/jane-doe" "@work")
                 :tags ("#in-progress")))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading task 2 nil)))
         (sig (mindwtr-signature task)))
    ;; native tag line must NOT carry the unsafe values
    (should-not (string-match-p ":@agenda/jane-doe:" text))
    (should (string-match-p "MW_CONTEXTS:" text))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let ((re (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get re :title) "Talk to Jane"))
        (should (equal (plist-get re :contexts)
                       '("@agenda/jane-doe" "@work")))
        (should (equal (plist-get re :tags) '("#in-progress")))
        (should (string= (mindwtr-signature re) sig))))))

(ert-deftest mindwtr-roundtrip-safe-tags-stay-native ()
  "Safe contexts/tags still render as native org tags (no drawer fallback)."
  (let* ((task '(:id "t1" :mw-kind task :title "x" :status "next" :areaId "a1"
                 :contexts ("@work") :tags ("#focused")))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading task 2 nil))))
    (should (string-match-p ":@work:focused:" text))
    (should-not (string-match-p "MW_CONTEXTS:" text))))

(ert-deftest mindwtr-roundtrip-checklist-server-shape ()
  "A server checklist (items carry :id + :isCompleted) round-trips stably.
Render reads :isCompleted, org checkboxes drop the server-assigned :id,
and the signature normalizes items to (:title :isCompleted) so the lost
:id does not cause drift.  Completion state must survive the trip."
  (let* ((task '(:id "t1" :mw-kind task :title "x" :status "next" :areaId "a1"
                 :checklist ((:id "c1" :title "first" :isCompleted t)
                             (:id "c2" :title "second" :isCompleted :false))))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading task 2 nil)))
         (sig (mindwtr-signature task)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((re (car (plist-get (mindwtr-parse-buffer) :tasks)))
             (items (plist-get re :checklist)))
        (should (string= (mindwtr-signature re) sig))
        (should (eq (plist-get (nth 0 items) :isCompleted) t))
        (should (eq (plist-get (nth 1 items) :isCompleted) :false))))))

(ert-deftest mindwtr-roundtrip-date-only-start-time ()
  (let* ((task '(:id "t1" :mw-kind task :title "x" :status "next"
                 :areaId "a1" :startTime "2026-06-20" :mw-extra-props nil))
         (text (concat "* Area\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                       (mindwtr-render-heading task 2 nil)))
         (sig (mindwtr-signature task)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let ((re (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get re :startTime) "2026-06-20"))
        (should (string= (mindwtr-signature re) sig))))))

(provide 'mindwtr-roundtrip-test)
;;; mindwtr-roundtrip-test.el ends here
