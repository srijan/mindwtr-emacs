;;; mindwtr-roundtrip-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-signature)

(defconst mindwtr-roundtrip--task
  '(:id "t1" :mw-kind task :title "Buy milk" :status "next" :priority "high"
    :contexts ("@errands") :tags ("#focused") :energyLevel "medium"
    :timeEstimate "1hr" :description "Line one.\nLine two."
    :checklist ((:title "a" :done :false) (:title "b" :done t))
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

(provide 'mindwtr-roundtrip-test)
;;; mindwtr-roundtrip-test.el ends here
