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

(defun mindwtr-roundtrip--wrap (task-text)
  "Wrap rendered TASK-TEXT in a minimal buffer with an Areas-of-Focus section.
The `** Personal' area heading (MW_ID a1) supplies the name->id mapping that
parse uses to resolve a task's :MW_AREA: property back to :areaId \"a1\"."
  (concat "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
          task-text
          "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
          "** Personal\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"))

(defun mindwtr-roundtrip--render-wrapped (task &optional shadow)
  "Render TASK at level 2 with area-names bound (a1->Personal), wrapped.
Returns the full buffer text ready to parse."
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (puthash "a1" "Personal" mindwtr-render-area-names)
    (mindwtr-roundtrip--wrap (mindwtr-render-heading task 2 shadow))))

(defun mindwtr-roundtrip--wrap-project (project-text)
  "Wrap a rendered level-2 PROJECT-TEXT under a `* Projects' container.
The task wrapper nests at level 2 under Next Actions, which would parse a
project as a standalone task; projects must sit directly under the projects
container so parse classifies and nests them correctly."
  (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
          project-text))

(defun mindwtr-roundtrip--wrap-section (section-text)
  "Wrap a rendered level-3 SECTION-TEXT under a project under `* Projects'.
A section's :projectId is derived from its project ancestor, so it must be
nested under a typed project heading to round-trip its containment."
  (concat "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
          "** ACTIVE Parent\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: pX\n:END:\n"
          section-text))

(ert-deftest mindwtr-roundtrip-render-parse-signature-stable ()
  "render -> parse preserves the editable content signature."
  (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
         (text (mindwtr-roundtrip--render-wrapped mindwtr-roundtrip--task shadow))
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
  (let ((mindwtr-render-area-names (make-hash-table :test 'equal)))
    (puthash "a1" "Personal" mindwtr-render-area-names)
    (let* ((shadow '(:createdAt "2026-01-01T10:00:00Z" :updatedAt "2026-05-30T15:30:00Z"))
           (t1 (mindwtr-render-heading mindwtr-roundtrip--task 2 shadow)))
      (with-temp-buffer
        (let ((org-inhibit-startup t))
          (insert (mindwtr-roundtrip--wrap t1))
          (org-mode))
        (let* ((task (car (plist-get (mindwtr-parse-buffer) :tasks)))
               (t2 (mindwtr-render-heading
                    (plist-put (copy-sequence task) :mw-kind 'task) 2 shadow)))
          (should (string= t1 t2)))))))

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
         (text (mindwtr-roundtrip--render-wrapped task))
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
         (text (mindwtr-roundtrip--render-wrapped task)))
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
         (text (mindwtr-roundtrip--render-wrapped task))
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
         (text (mindwtr-roundtrip--render-wrapped task))
         (sig (mindwtr-signature task)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let ((re (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should (string= (plist-get re :startTime) "2026-06-20"))
        (should (string= (mindwtr-signature re) sig))))))

(ert-deftest mindwtr-roundtrip-appdata-signature-stable ()
  "render-appdata -> parse-buffer preserves every entity's content signature,
with areaId via MW_AREA and projectId via nesting."
  (let* ((ad '(:areas ((:id "a1" :name "Personal" :order 0))
               :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1" :order 0
                           :supportNotes "Project planning notes.")
                          (:id "pw" :title "Waiting proj" :status "waiting" :order 7)
                          (:id "ps" :title "Someday proj" :status "someday" :order 8))
               :sections ((:id "s1" :projectId "p1" :title "Sec" :order 0
                           :description "Section notes that must survive."))
               :tasks ((:id "t1" :mw-kind task :title "loose" :status "next"
                        :areaId "a1" :contexts ("@home") :order 0)
                       (:id "t2" :mw-kind task :title "child" :status "next"
                        :projectId "p1" :order 0)
                       (:id "tsd" :mw-kind task :title "Someday single" :status "someday" :order 9)
                       (:id "tsp" :mw-kind task :title "Someday proj task" :status "next"
                        :projectId "ps" :order 0))
               :settings nil))
         (text (mindwtr-render-appdata ad)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((re (mindwtr-parse-buffer))
             (idx (make-hash-table :test 'equal)))
        (dolist (k '(:tasks :projects :sections :areas))
          (dolist (e (plist-get re k)) (puthash (plist-get e :id) e idx)))
        (dolist (k '(:tasks :projects :sections :areas))
          (dolist (orig (plist-get ad k))
            (let ((got (gethash (plist-get orig :id) idx)))
              (should got)
              (should (string= (mindwtr-signature got) (mindwtr-signature orig))))))))))

(ert-deftest mindwtr-roundtrip-description-links-stable ()
  "Org links in a description survive render->parse->render unchanged.
A labelled link, a label-less link, and link-free text all round-trip:
parse converts org->markdown for the server, render converts it back, and the
org buffer text is byte-stable across the trip."
  (dolist (desc '("Check [[https://example.com][the site]] later."
                  "Raw url [[https://example.com]] inline."
                  "See [[https://en.wikipedia.org/wiki/Foo_(bar)][docs]] now."
                  "Just prose, no links at all."))
    (let* ((mw-task (list :id "t1" :mw-kind 'task :title "x" :status "next"
                          ;; description stored mindwtr-side is markdown
                          :description (mindwtr-parse--org->mw-text desc)
                          :mw-extra-props nil))
           ;; Render injects org link syntax into the buffer body.
           (text (mindwtr-roundtrip--render-wrapped mw-task)))
      ;; The org text is byte-identical after the trip: the original org link
      ;; (parens URL included) reappears verbatim in the rendered buffer.
      (should (string-match-p (regexp-quote desc) text))
      (with-temp-buffer
        (let ((org-inhibit-startup t)) (insert text) (org-mode))
        (let* ((ad (mindwtr-parse-buffer))
               (parsed (car (plist-get ad :tasks))))
          ;; parse re-derives the same markdown description.
          (should (string= (plist-get parsed :description)
                           (plist-get mw-task :description))))))))

(ert-deftest mindwtr-roundtrip-project-notes-links-stable ()
  "Covers R7.  Org links in a project :supportNotes survive render->parse->render
unchanged, reusing the same converters task descriptions use."
  (dolist (note '("Check [[https://example.com][the site]] later."
                  "Raw url [[https://example.com]] inline."
                  "See [[https://en.wikipedia.org/wiki/Foo_(bar)][docs]] now."
                  "Just prose, no links at all."))
    (let* ((mw-proj (list :id "p1" :mw-kind 'project :title "x" :status "active"
                          :supportNotes (mindwtr-parse--org->mw-text note)
                          :mw-extra-props nil))
           (text (mindwtr-roundtrip--wrap-project
                  (mindwtr-render-heading mw-proj 2 nil))))
      (should (string-match-p (regexp-quote note) text))
      (with-temp-buffer
        (let ((org-inhibit-startup t)) (insert text) (org-mode))
        (let ((parsed (car (plist-get (mindwtr-parse-buffer) :projects))))
          (should (string= (plist-get parsed :supportNotes)
                           (plist-get mw-proj :supportNotes))))))))

(ert-deftest mindwtr-roundtrip-section-notes-links-stable ()
  "Covers R7.  Org links in a section :description survive render->parse->render."
  (dolist (note '("Check [[https://example.com][the site]] later."
                  "Raw url [[https://example.com]] inline."
                  "Just prose, no links at all."))
    (let* ((mw-sec (list :id "s1" :mw-kind 'section :title "Sec"
                         :description (mindwtr-parse--org->mw-text note)
                         :mw-extra-props nil))
           (text (mindwtr-roundtrip--wrap-section
                  (mindwtr-render-heading mw-sec 3 nil))))
      (should (string-match-p (regexp-quote note) text))
      (with-temp-buffer
        (let ((org-inhibit-startup t)) (insert text) (org-mode))
        (let ((parsed (car (plist-get (mindwtr-parse-buffer) :sections))))
          (should (string= (plist-get parsed :description)
                           (plist-get mw-sec :description))))))))

(ert-deftest mindwtr-roundtrip-project-notes-render-stable ()
  "Covers R5.  render == render(parse(render(x))) byte-identical for a project note."
  (let* ((mw-proj (list :id "p1" :mw-kind 'project :title "x" :status "active"
                        :supportNotes "Line one.\nLine two." :mw-extra-props nil))
         (t1 (mindwtr-render-heading mw-proj 2 nil))
         (text (mindwtr-roundtrip--wrap-project t1)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((parsed (car (plist-get (mindwtr-parse-buffer) :projects)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence parsed) :mw-kind 'project) 2 nil)))
        (should (string= t1 t2))))))

(ert-deftest mindwtr-roundtrip-section-notes-render-stable ()
  "Covers R5.  render == render(parse(render(x))) byte-identical for a section note."
  (let* ((mw-sec (list :id "s1" :mw-kind 'section :title "Sec"
                       :description "Line one.\nLine two." :mw-extra-props nil))
         (t1 (mindwtr-render-heading mw-sec 3 nil))
         (text (mindwtr-roundtrip--wrap-section t1)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((parsed (car (plist-get (mindwtr-parse-buffer) :sections)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence parsed) :mw-kind 'section) 3 nil)))
        (should (string= t1 t2))))))

(ert-deftest mindwtr-roundtrip-project-notes-empty-nil-equivalent ()
  "Covers R8.  A nil/absent note and an empty-string note both render no body and
sign identically (no phantom change between the two empty forms)."
  (let ((nil-proj '(:id "p1" :mw-kind project :title "x" :status "active"))
        (empty-proj '(:id "p1" :mw-kind project :title "x" :status "active"
                      :supportNotes "")))
    (should (string-suffix-p ":END:\n" (mindwtr-render-heading nil-proj 2 nil)))
    (should (string-suffix-p ":END:\n" (mindwtr-render-heading empty-proj 2 nil)))
    (should (string= (mindwtr-signature nil-proj) (mindwtr-signature empty-proj)))))

(ert-deftest mindwtr-roundtrip-section-notes-empty-nil-equivalent ()
  "Covers R8.  Same empty/nil equivalence for a section :description."
  (let ((nil-sec '(:id "s1" :mw-kind section :title "Sec"))
        (empty-sec '(:id "s1" :mw-kind section :title "Sec" :description "")))
    (should (string-suffix-p ":END:\n" (mindwtr-render-heading nil-sec 3 nil)))
    (should (string-suffix-p ":END:\n" (mindwtr-render-heading empty-sec 3 nil)))
    (should (string= (mindwtr-signature nil-sec) (mindwtr-signature empty-sec)))))

(ert-deftest mindwtr-roundtrip-project-notes-non-ascii-stable ()
  "Covers R6 / AE1.  A non-ASCII project note round-trips byte-identical AND stays
a multibyte string.  Equality alone passes a symmetric encoder bug, so assert
representation too (per the encoder-symmetry learning)."
  (let* ((note "Café — “smart quotes” • naïve — 日本語")
         (mw-proj (list :id "p1" :mw-kind 'project :title "x" :status "active"
                        :supportNotes note :mw-extra-props nil))
         (t1 (mindwtr-render-heading mw-proj 2 nil))
         (text (mindwtr-roundtrip--wrap-project t1)))
    (should (multibyte-string-p text))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((parsed (car (plist-get (mindwtr-parse-buffer) :projects)))
             (got (plist-get parsed :supportNotes)))
        (should (string= got note))
        (should (multibyte-string-p got))
        ;; render is byte-stable on the non-ASCII note too
        (should (string= (mindwtr-render-heading
                          (plist-put (copy-sequence parsed) :mw-kind 'project) 2 nil)
                         t1))))))

(defun mindwtr-roundtrip--project-note-cycle (note)
  "Render a project whose :supportNotes is NOTE (markdown), parse it back, and
return a plist describing the round-trip:
  :org1   the rendered org body region (heading text)
  :ad     the parsed appdata
  :proj   the parsed project entity
  :org2   render of the parsed project (for byte-stability comparison)."
  (let* ((mw-proj (list :id "p1" :mw-kind 'project :title "Proj" :status "active"
                        :supportNotes note :mw-extra-props nil))
         (org1 (mindwtr-render-heading mw-proj 2 nil))
         (text (mindwtr-roundtrip--wrap-project org1))
         (ad (with-temp-buffer
               (let ((org-inhibit-startup t)) (insert text) (org-mode))
               (mindwtr-parse-buffer)))
         (proj (car (plist-get ad :projects)))
         (org2 (mindwtr-render-heading
                (plist-put (copy-sequence proj) :mw-kind 'project) 2 nil)))
    (list :org1 org1 :ad ad :proj proj :org2 org2)))

(ert-deftest mindwtr-roundtrip-notes-no-heading-injection ()
  "Covers B (heading injection).  No markdown note -- however structured --
renders a body line org would read as a heading, and parsing it never
fabricates a phantom sibling/child entity.  The note round-trips to exactly one
project with the note intact (bullet markers normalized to `- ')."
  (dolist (case '(;; (note . expected-parsed-supportNotes)
                  ("* foo\nbar"            . "- foo\nbar")
                  ("Intro\n* a\n* b\nmore" . "Intro\n- a\n- b\nmore")
                  ("+ plus bullet"         . "- plus bullet")
                  ("- dash bullet"         . "- dash bullet")
                  ;; pathological multi-star+space lines (not real markdown):
                  ;; neutralized to bullets, never injected as headings
                  ("** bold ** text"       . "- bold ** text")
                  ("*** triple star"       . "- triple star")))
    (let* ((note (car case))
           (expected (cdr case))
           (r (mindwtr-roundtrip--project-note-cycle note))
           (ad (plist-get r :ad)))
      ;; exactly one project, zero phantom tasks/projects
      (should (= 1 (length (plist-get ad :projects))))
      (should (= 0 (length (plist-get ad :tasks))))
      ;; no rendered body line is an org heading
      (should-not (string-match-p "\n\\*+ " (plist-get r :org1)))
      ;; the note content is preserved (bullets normalized to `- ')
      (should (string= (plist-get (plist-get r :proj) :supportNotes) expected)))))

(ert-deftest mindwtr-roundtrip-notes-literal-emphasis-not-corrupted ()
  "Covers B.  Ordinary prose containing `_', `*', backticks is left VERBATIM --
naive emphasis conversion would mangle identifiers and math.  Inline emphasis
does not collide with org headings, so it is safe to leave literal and must
round-trip byte-identically."
  (dolist (note '("snake_case_name and file_path_here"
                  "math: 2 * 3 * 4 = 24"
                  "**bold** and *italic* and `code` inline"
                  "trailing _underscore_ and a*b*c"))
    (let* ((r (mindwtr-roundtrip--project-note-cycle note)))
      (should (= 1 (length (plist-get (plist-get r :ad) :projects))))
      ;; literal text preserved exactly (no emphasis conversion applied)
      (should (string= (plist-get (plist-get r :proj) :supportNotes) note)))))

(ert-deftest mindwtr-roundtrip-notes-render-byte-stable-across-structures ()
  "Covers R5.  render == render(parse(render(x))) for every note shape above,
including bullets and literal emphasis -- the rendered org buffer is the fixed
point even when the markdown normalizes on the first pass."
  (dolist (note '("- already a dash bullet"
                  "Intro\n- a\n- b\nmore"
                  "snake_case and 2 * 3"
                  "**bold** inline"
                  "Check [[https://example.com][site]] then go."))
    (let ((r (mindwtr-roundtrip--project-note-cycle note)))
      (should (string= (plist-get r :org1) (plist-get r :org2))))))

;; U4 -- reserved drawer fields: representational byte-stability BEFORE the
;; fields join the allow-list (these assert render fixed-points, not signature
;; stability; the signature assertions live in U6 after promotion).

(ert-deftest mindwtr-roundtrip-focused-task-render-stable ()
  "Covers R3.  render == render(parse(render(x))) for a task with
:isFocusedToday t and :reviewAt."
  (let* ((task '(:id "t1" :mw-kind task :title "x" :status "next"
                 :isFocusedToday t :reviewAt "2026-06-09T14:30:00.000Z"
                 :mw-extra-props nil))
         (t1 (mindwtr-render-heading task 2 nil)))
    (should (string-match-p "^:MW_FOCUS_TODAY: t$" t1))
    (should (string-match-p ":MW_REVIEW_AT: 2026-06-09T14:30:00.000Z" t1))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert (mindwtr-roundtrip--wrap t1)) (org-mode))
      (let* ((parsed (car (plist-get (mindwtr-parse-buffer) :tasks)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence parsed) :mw-kind 'task) 2 nil)))
        (should (string= t1 t2))))))

(ert-deftest mindwtr-roundtrip-sequential-focused-project-render-stable ()
  "Covers R3.  render == render(parse(render(x))) for a project with
:isSequential t, :isFocused t, and :reviewAt."
  (let* ((proj '(:id "p1" :mw-kind project :title "x" :status "active"
                 :isSequential t :isFocused t :reviewAt "2026-06-09T14:30:00.000Z"
                 :mw-extra-props nil))
         (t1 (mindwtr-render-heading proj 2 nil))
         (text (mindwtr-roundtrip--wrap-project t1)))
    (should (string-match-p "^:MW_SEQUENTIAL: t$" t1))
    (should (string-match-p "^:MW_FOCUSED: t$" t1))
    (with-temp-buffer
      (let ((org-inhibit-startup t)) (insert text) (org-mode))
      (let* ((parsed (car (plist-get (mindwtr-parse-buffer) :projects)))
             (t2 (mindwtr-render-heading
                  (plist-put (copy-sequence parsed) :mw-kind 'project) 2 nil)))
        (should (string= t1 t2))))))

(ert-deftest mindwtr-roundtrip-boolean-false-and-absent-render-identically ()
  "Covers R3/R4.  A boolean `:false' and an absent boolean render to identical
bytes and parse to the same (key-less) entity shape."
  (let ((false-task '(:id "t1" :mw-kind task :title "x" :status "next"
                      :isFocusedToday :false :mw-extra-props nil))
        (absent-task '(:id "t1" :mw-kind task :title "x" :status "next"
                       :mw-extra-props nil)))
    (should (string= (mindwtr-render-heading false-task 2 nil)
                     (mindwtr-render-heading absent-task 2 nil)))
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert (mindwtr-roundtrip--wrap
                 (mindwtr-render-heading false-task 2 nil)))
        (org-mode))
      (let ((parsed (car (plist-get (mindwtr-parse-buffer) :tasks))))
        (should-not (plist-member parsed :isFocusedToday))))))

(provide 'mindwtr-roundtrip-test)
;;; mindwtr-roundtrip-test.el ends here
