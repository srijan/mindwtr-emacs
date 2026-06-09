;;; mindwtr-sync-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'mindwtr-sync)
(require 'mindwtr)

(ert-deftest mindwtr-sync-build-candidate-create ()
  "A task absent from the shadow becomes a create: rev 1, gets id+createdAt."
  (let* ((local '(:tasks ((:id nil :mw-kind task :title "new" :status "next"))
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (stringp (plist-get task :id)))
    (should (= (plist-get task :rev) 1))
    (should (string= (plist-get task :createdAt) "2026-06-01T00:00:00Z"))
    (should (string= (plist-get task :revBy) "dev-1"))))

(ert-deftest mindwtr-sync-build-candidate-unchanged-echoes-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :revBy "phone" :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 7))
    (should (string= (plist-get task :revBy) "phone"))
    (should (string= (plist-get task :updatedAt) "U"))))

(ert-deftest mindwtr-sync-section-populated-description-not-clobbered ()
  "Covers R3 (section).  A section with a server-authored :description that the
user did not touch must round-trip as UNCHANGED -- the first post-U1 sync must
not PUT an empty description over the mobile value.

Pre-U1 this clobbered: render emitted no section body, parse left :description
absent, classify saw a diff (shadow had it, local did not) and merge-content
cleared it.  U1 renders + parses the description, so the parsed value now
equals the server value and the section classifies unchanged."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :order 0
                               :rev 2 :createdAt "2026-01-01T00:00:00Z"
                               :updatedAt "2026-06-01T00:00:00Z"))
                   :sections ((:id "s1" :projectId "p1" :title "Sec" :order 0
                               :description "Mobile-authored note." :rev 5
                               :createdAt "2026-01-01T00:00:00Z"
                               :updatedAt "2026-06-01T00:00:00Z"))
                   :areas nil :settings nil))
         ;; The buffer is what render produces from the shadow; parse it back
         ;; to get the local projection a real sync would compute.
         (text (mindwtr-render-appdata shadow))
         (local (with-temp-buffer
                  (let ((org-inhibit-startup t)) (insert text) (org-mode))
                  (mindwtr-parse-buffer)))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (sec (car (plist-get cand :sections))))
    ;; parse recovered the description from the rendered body
    (should (string= (plist-get (car (plist-get local :sections)) :description)
                     "Mobile-authored note."))
    ;; candidate keeps the server value and does NOT bump rev (unchanged echo)
    (should (string= (plist-get sec :description) "Mobile-authored note."))
    (should (= (plist-get sec :rev) 5))))

(ert-deftest mindwtr-sync-build-candidate-update-bumps-rev ()
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 7
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "CHANGED" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 8))
    (should (string= (plist-get task :updatedAt) "NOW"))
    (should (string= (plist-get task :revBy) "dev-1"))
    (should (string= (plist-get task :createdAt) "C"))))

(ert-deftest mindwtr-sync-build-candidate-delete-tombstones ()
  "A task in the shadow but absent from local becomes a tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :createdAt "C"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :deletedAt) "NOW"))
    (should (= (plist-get task :rev) 4))))

(ert-deftest mindwtr-sync-unchanged-preserves-full-fidelity ()
  "An unchanged entity echoes the shadow: checklist item ids and sub-minute
timestamps survive, even though the lossy org parse dropped them."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 4
                                       :createdAt "C" :updatedAt "U"
                                       :startTime "2026-02-09T14:30:45.500Z"
                                       :isFocusedToday :false
                                       :checklist ((:id "c1" :title "a" :isCompleted t)
                                                   (:id "c2" :title "b" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         ;; what parse would yield from the rendered org: no item ids, minute ts
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :startTime "2026-02-09T14:30:00Z"
                                      :checklist ((:title "a" :isCompleted t)
                                                  (:title "b" :isCompleted :false))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (= (plist-get task :rev) 4))                      ; not bumped
    (should (string= (plist-get task :startTime) "2026-02-09T14:30:45.500Z"))
    (should (string= (plist-get (nth 0 (plist-get task :checklist)) :id) "c1"))
    (should (eq (plist-get task :isFocusedToday) :false))))   ; unmapped field kept

(ert-deftest mindwtr-sync-update-preserves-untouched-fields ()
  "Editing one field (title) must not strip checklist ids or coarsen the
timestamp of fields the user did not change."
  (let* ((shadow '(:tasks ((:id "t1" :title "old" :status "next" :rev 4
                            :createdAt "C"
                            :startTime "2026-02-09T14:30:45.500Z"
                            :checklist ((:id "c1" :title "a" :isCompleted t)))
                           )
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "new" :status "next"
                                      :startTime "2026-02-09T14:30:00Z"
                                      :checklist ((:title "a" :isCompleted t))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :title) "new"))          ; the real change
    (should (= (plist-get task :rev) 5))                      ; bumped
    (should (string= (plist-get task :startTime) "2026-02-09T14:30:45.500Z"))
    (should (string= (plist-get (car (plist-get task :checklist)) :id) "c1"))))

(ert-deftest mindwtr-sync-deploy-transition-preserves-project-note ()
  "Finding A regression.  On the first sync after upgrade, the on-disk buffer was
written by the OLD renderer (no project-note body), so parse yields an empty
:supportNotes.  With protect-empty-notes on, build-candidate must NOT clear the
server-authored note -- it preserves the shadow value instead of clobbering it."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :order 0
                               :supportNotes "Mobile-authored note." :rev 5
                               :createdAt "2026-01-01T00:00:00Z"
                               :updatedAt "2026-06-01T00:00:00Z"))
                   :sections nil :areas nil :settings nil))
         ;; stale buffer: project with NO body (old renderer never emitted it)
         (stale "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
         (local (with-temp-buffer
                  (let ((org-inhibit-startup t)) (insert stale) (org-mode))
                  (mindwtr-parse-buffer))))
    ;; the parsed local note IS empty (the bug's precondition)
    (should (mindwtr-sync--empty-p
             (plist-get (car (plist-get local :projects)) :supportNotes)))
    ;; WITHOUT protection the note is clobbered (documents the hazard)
    (let ((proj (car (plist-get (mindwtr-sync-build-candidate
                                 local shadow "dev-1" "NOW" nil) :projects))))
      (should (null (plist-get proj :supportNotes))))
    ;; WITH protection (pre-migration) the server note is preserved
    (let ((proj (car (plist-get (mindwtr-sync-build-candidate
                                 local shadow "dev-1" "NOW" t) :projects))))
      (should (string= (plist-get proj :supportNotes) "Mobile-authored note.")))))

(ert-deftest mindwtr-sync-protect-notes-does-not-block-task-description-clear ()
  "protect-empty-notes guards only NON-task notes (project :supportNotes, section
:description).  A genuinely emptied task :description still clears -- tasks always
rendered their description, so an empty one is a real edit, never a pre-render
artifact."
  (let* ((shadow '(:tasks ((:id "t1" :title "t" :status "next" :rev 3
                            :description "old desc" :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "t" :status "next"
                                     :description ""))
                      :projects nil :sections nil :areas nil))
         (proj (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev-1" "NOW" t) :tasks))))
    (should (null (plist-get proj :description)))))

(ert-deftest mindwtr-sync-protect-notes-still-adopts-a-real-edit ()
  "protect-empty-notes only suppresses clearing on an EMPTY local note; a real
edited note value is always adopted, even pre-migration."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :rev 3
                               :supportNotes "old" :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "Proj"
                                        :status "active" :supportNotes "edited"))
                      :sections nil :areas nil))
         (proj (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev-1" "NOW" t) :projects))))
    (should (string= (plist-get proj :supportNotes) "edited"))))

(ert-deftest mindwtr-sync-project-note-edit-adopted ()
  "Covers R3/R4 (project).  After :supportNotes joins the allow-list, a buffer
edit to a project's notes is detected and adopted into the candidate; the
project's rev bumps."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :rev 3
                               :supportNotes "old note" :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "Proj"
                                        :status "active" :supportNotes "new note"))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (proj (car (plist-get cand :projects))))
    (should (string= (plist-get proj :supportNotes) "new note"))
    (should (= (plist-get proj :rev) 4))))

(ert-deftest mindwtr-sync-project-note-emptied-clears ()
  "Covers R3 (project).  Emptying a project's notes in the buffer clears the
field on the candidate (an empty local note is a genuine clear)."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :rev 3
                               :supportNotes "old note" :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "Proj"
                                        :status "active" :supportNotes ""))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (proj (car (plist-get cand :projects))))
    (should-not (plist-get proj :supportNotes))
    (should (= (plist-get proj :rev) 4))))

(ert-deftest mindwtr-sync-project-note-unchanged-echoes-rev ()
  "Covers R4.  An untouched project note classifies unchanged: rev is echoed,
no spurious change."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "Proj" :status "active" :rev 9
                               :revBy "phone" :supportNotes "stable note"
                               :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "Proj"
                                        :status "active" :supportNotes "stable note"))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (proj (car (plist-get cand :projects))))
    (should (= (plist-get proj :rev) 9))
    (should (string= (plist-get proj :revBy) "phone"))))

(ert-deftest mindwtr-sync-update-adopts-genuine-checklist-change ()
  "When the checklist content actually changes, the new value is taken."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                       :checklist ((:id "c1" :title "a" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :checklist ((:title "a" :isCompleted t))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (item (car (plist-get (car (plist-get cand :tasks)) :checklist))))
    (should (eq (plist-get item :isCompleted) t))             ; flipped
    (should (null (plist-get item :id)))))                    ; org can't carry it

(ert-deftest mindwtr-sync-update-clears-emptied-field ()
  "Clearing a field in org (e.g. deleting the description) clears it on write."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 1
                            :description "had notes"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :description ""))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-member task :description)))))

(ert-deftest mindwtr-sync-candidate-carries-settings-verbatim ()
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :settings (:theme "dark" :gtd (:x 1))))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW")))
    (should (equal (plist-get cand :settings) '(:theme "dark" :gtd (:x 1))))))

(ert-deftest mindwtr-sync-candidate-creates-initial-settings-when-absent ()
  "A namespace with no settings gets a fresh non-null settings blob, so the
server's settings merge is never handed a null value (which 500s)."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW")))
    (should (equal (plist-get cand :settings) (mindwtr-model-default-settings)))))

(ert-deftest mindwtr-sync-candidate-strips-device-local-fields ()
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                      :createdAt "C" :localStatus "dirty"))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-member task :localStatus)))))

(ert-deftest mindwtr-sync-stats-counts-create-update-delete ()
  "Stats distinguish create vs update vs delete (not all lumped as created)."
  (let* ((shadow '(:tasks ((:id "t1" :title "keep" :status "next" :rev 1)
                           (:id "t2" :title "edit" :status "next" :rev 1)
                           (:id "t3" :title "gone" :status "next" :rev 1))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "keep" :status "next")
                                    '(:id "t2" :mw-kind task :title "EDITED" :status "next")
                                    '(:id nil :mw-kind task :title "brand new" :status "next"))
                      :projects nil :sections nil :areas nil))
         (stats (mindwtr-sync--stats local shadow)))
    (should (= (plist-get stats :created) 1))   ; the id-less new heading
    (should (= (plist-get stats :updated) 1))   ; t2
    (should (= (plist-get stats :deleted) 1))   ; t3 absent locally
    ;; t1 is unchanged, so it is none of the three
    (should (= (+ (plist-get stats :created) (plist-get stats :updated)
                  (plist-get stats :deleted))
               3))))

(require 'mindwtr-api)
(require 'mindwtr-reconcile)

(ert-deftest mindwtr-sync-once-surfaces-clock-skew-and-stats ()
  "sync-once returns the PUT clockSkewWarning and accurate create/update/delete
stats in its result."
  (let* ((dir (make-temp-file "mw-skew" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil
                       :body "{\"ok\":true,\"clockSkewWarning\":\"clock off by 5m\",\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (string= (plist-get result :skew) "clock off by 5m"))
            (should (= (plist-get (plist-get result :stats) :updated) 1))
            (should (= (plist-get (plist-get result :stats) :created) 0))
            (should (= (plist-get (plist-get result :stats) :deleted) 0))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-detect-conflicts-records-kind ()
  "A detected conflict carries the entity KIND so a restore can rebuild it."
  (let* ((candidate '(:tasks ((:id "t1" :title "MINE" :status "next" :rev 8))
                      :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "THEIRS" :status "next" :rev 9))
                   :projects nil :sections nil :areas nil))
         (c (car (mindwtr-sync-detect-conflicts candidate merged '("t1")))))
    (should (eq (plist-get c :kind) 'task))))

(ert-deftest mindwtr-sync-merge-content-only-touches-content-fields ()
  "merge-content must not introduce or change any field outside the
signature's content-fields (plus identity keys).  The HEAD short-circuit's
safety depends on this: anything build-candidate can meaningfully change
must be visible to the content signature, or a sync could be skipped that
would actually alter a field."
  (let* ((se '(:id "t1" :title "x" :rev 5 :revBy "p" :createdAt "C"
               :weirdServerField "keep"))
         (le '(:id "t1" :mw-kind task :title "y"))
         (merged (mindwtr-sync--merge-content le se))
         (allowed (append '(:id :mw-kind :mw-extra-props :mw-area-override)
                          mindwtr-model-content-fields))
         (i 0))
    (while (< i (length merged))
      (let ((k (nth i merged)) (v (nth (1+ i) merged)))
        (unless (equal v (plist-get se k))
          (should (memq k allowed))))
      (setq i (+ i 2)))
    ;; an unmapped server field is preserved verbatim, never dropped
    (should (string= (plist-get merged :weirdServerField) "keep"))))

(ert-deftest mindwtr-sync-once-noop-when-clean-and-etag-matches ()
  "No local edits + a remote ETag matching the shadow => HEAD only, no PUT/GET."
  (let* ((dir (make-temp-file "mw-noop" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (calls nil)
         (mindwtr-api-http-function
          (lambda (req)
            (push (plist-get req :method) calls)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              (m (error "mindwtr: unexpected %s on a no-op sync" m))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (let ((res (mindwtr-sync-once (current-buffer) "NOW")))
            (should (plist-get res :noop))
            (should (equal calls '("HEAD")))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-pulls-when-clean-but-remote-moved ()
  "No local edits but a changed remote ETag => full cycle that pulls the
remote change into the buffer."
  (let* ((dir (make-temp-file "mw-pull" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (remote (concat "{\"tasks\":[{\"id\":\"t9\",\"title\":\"from server\","
                         "\"status\":\"next\",\"areaId\":\"a1\",\"rev\":1,"
                         "\"createdAt\":\"2026-06-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}],"
                         "\"projects\":[],\"sections\":[],"
                         "\"areas\":[{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],\"settings\":{}}"))
         (saw-put nil) (saw-get nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v2")) :body ""))
              ("PUT" (setq saw-put t) '(:status 200 :headers nil :body "{\"ok\":true}"))
              ("GET" (setq saw-get t)
                     (list :status 200 :headers '(("ETag" . "v2")) :body remote))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (let ((res (mindwtr-sync-once (current-buffer) "NOW")))
            (should-not (plist-get res :noop))
            (should saw-put)
            (should saw-get)
            (goto-char (point-min))
            (should (search-forward "from server" nil t))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-handles-non-ascii-content ()
  "A server task with non-ASCII content (bullet, curly quotes) syncs and
shadow-saves without raw-byte corruption or a coding-system prompt."
  (let* ((dir (make-temp-file "mw-uni" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         ;; raw (unibyte) UTF-8 body, exactly as it arrives off the wire
         (remote (encode-coding-string
                  (concat "{\"tasks\":[{\"id\":\"t1\",\"title\":\"Plan • review “x”\","
                          "\"status\":\"next\",\"areaId\":\"a1\",\"rev\":1,"
                          "\"createdAt\":\"2026-06-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}],"
                          "\"projects\":[],\"sections\":[],"
                          "\"areas\":[{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],\"settings\":{}}")
                  'utf-8))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("PUT" '(:status 200 :headers nil :body "{\"ok\":true}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body remote))
              ("HEAD" '(:status 200 :headers (("ETag" . "v0")) :body ""))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          ;; no shadow etag => full cycle (not a no-op), exercising GET+reconcile+save
          (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")
          (let ((task (car (plist-get (mindwtr-shadow-load) :tasks))))
            (should (string= (plist-get task :title) "Plan • review “x”"))
            (should (multibyte-string-p (plist-get task :title))))
          (goto-char (point-min))
          (should (search-forward "Plan • review “x”" nil t)))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-archived-not-tombstoned ()
  "An archived shadow entity absent from org is not turned into a tombstone."
  (let* ((shadow '(:tasks ((:id "t1" :title "live" :status "next" :rev 1)
                           (:id "t2" :title "arch" :status "archived" :rev 1))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "live" :status "next"))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t2 (seq-find (lambda (e) (equal (plist-get e :id) "t2")) (plist-get cand :tasks))))
    ;; t2 is echoed (still archived), NOT freshly tombstoned with :deletedAt NOW
    (should t2)
    (should (string= (plist-get t2 :status) "archived"))
    (should-not (string= (or (plist-get t2 :deletedAt) "") "NOW"))
    ;; and stats does not count it as a delete
    (should (= (plist-get (mindwtr-sync--stats local shadow) :deleted) 0))))

(ert-deftest mindwtr-sync-task-under-archived-project-not-tombstoned ()
  "A live task whose parent project is archived is echoed verbatim, never
tombstoned -- archiving a project must not delete the tasks it keeps."
  (let* ((shadow '(:tasks ((:id "t1" :title "kept" :status "done" :projectId "p1" :rev 3))
                   :projects ((:id "p1" :title "P" :status "archived" :rev 2))
                   :sections nil :areas nil :settings nil))
         ;; org renders neither p1 (archived) nor t1 (parent archived), so local is empty
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get cand :tasks))))
    (should t1)                                              ; echoed, not dropped
    (should-not (string= (or (plist-get t1 :deletedAt) "") "NOW")) ; not freshly tombstoned
    (should (string= (plist-get t1 :status) "done"))          ; status UNCHANGED (option a)
    (should (= (plist-get t1 :rev) 3))                        ; rev UNCHANGED (verbatim echo)
    (should (= (plist-get (mindwtr-sync--stats local shadow) :deleted) 0))))

(ert-deftest mindwtr-sync-task-under-archived-section-not-tombstoned ()
  "A live task under a section whose project is archived is also protected."
  (let* ((shadow '(:tasks ((:id "t1" :title "kept" :status "next" :sectionId "s1" :rev 1))
                   :projects ((:id "p1" :title "P" :status "archived" :rev 1))
                   :sections ((:id "s1" :title "S" :projectId "p1" :rev 1))
                   :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get cand :tasks)))
         (s1 (seq-find (lambda (e) (equal (plist-get e :id) "s1")) (plist-get cand :sections))))
    (should t1)
    (should-not (string= (or (plist-get t1 :deletedAt) "") "NOW"))
    (should s1)                                               ; the section itself also protected
    (should-not (string= (or (plist-get s1 :deletedAt) "") "NOW"))
    (should (= (plist-get (mindwtr-sync--stats local shadow) :deleted) 0))))

(ert-deftest mindwtr-sync-standalone-unmapped-status-not-tombstoned ()
  "A standalone task whose status maps to no list (would render nowhere) is
not tombstoned for being absent from org."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "someFutureStatus" :rev 1))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get cand :tasks))))
    (should t1)
    (should-not (string= (or (plist-get t1 :deletedAt) "") "NOW"))))

(ert-deftest mindwtr-sync-normal-deletion-still-tombstoned ()
  "Regression guard: a live task with a LIVE parent, absent from org, is still
tombstoned -- the guard must not suppress genuine deletions."
  (let* ((shadow '(:tasks ((:id "t1" :title "gone" :status "next" :projectId "p1" :rev 1))
                   :projects ((:id "p1" :title "P" :status "active" :rev 1))
                   :sections nil :areas nil :settings nil))
         ;; org still has the live project p1 but the user removed task t1
         (local '(:tasks nil
                  :projects (( :id "p1" :mw-kind project :title "P" :status "active"))
                  :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (t1 (seq-find (lambda (e) (equal (plist-get e :id) "t1")) (plist-get cand :tasks))))
    (should t1)
    (should (string= (plist-get t1 :deletedAt) "NOW"))        ; genuinely tombstoned
    (should (= (plist-get (mindwtr-sync--stats local shadow) :deleted) 1))))

(ert-deftest mindwtr-sync-once-end-to-end ()
  "A local edit is PUT, merged result is reconciled, shadow updated."
  (let* ((dir (make-temp-file "mw-e2e" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2"))
                           :body put-body))))))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get result :ok))
            (should (string-match-p "do it" put-body))
            (let ((task (car (plist-get (mindwtr-shadow-load) :tasks))))
              (should (string= (plist-get task :title) "do it")))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-merge-never-clears-status ()
  "When the local parse omits :status (type-invalid keyword), merge keeps the
shadow's status instead of clearing the mandatory field."
  (let* ((se '(:id "t1" :title "Task" :status "waiting" :rev 3))
         (le '(:id "t1" :title "Task"))            ; status omitted by the backstop
         (m (mindwtr-sync--merge-content le se)))
    (should (string= (plist-get m :status) "waiting"))))

(ert-deftest mindwtr-sync-build-candidate-defaults-new-entity-status ()
  "A brand-new local task with no status (parser omitted it) gets the type
default so validation does not abort."
  (let* ((local '(:tasks ((:title "Fresh") )    ; no :id, no :status
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "2026-06-02T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :status) "inbox"))
    ;; the candidate validates (no invalid nil status)
    (should (mindwtr-model-validate-appdata
             (mindwtr-sync--strip-internal-keys cand)))))

(ert-deftest mindwtr-sync-once-threads-parse-warnings-into-report ()
  "A type-invalid keyword surfaces in the return plist and the report buffer."
  (let* ((dir (make-temp-file "mw-warn" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2"))
                           :body put-body))))))
    (unwind-protect
        (progn
          (when (get-buffer "*Mindwtr Sync Report*")
            (kill-buffer "*Mindwtr Sync Report*"))
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              ;; NEXT is task-only; on a project it is type-invalid.  The new
              ;; title makes the entity dirty so the full cycle (not the noop
              ;; path) runs and renders the report.
              (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                      "** NEXT Build the deck\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks nil
               :projects ((:id "p1" :title "old name" :status "active" :rev 1
                           :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :sections nil :areas nil :settings nil))
            (let ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (plist-get result :ok))
              (let ((ws (plist-get result :warnings)))
                (should (= (length ws) 1))
                (should (string= (plist-get (car ws) :keyword) "NEXT"))
                (should (string= (plist-get (car ws) :id) "p1")))
              (with-current-buffer "*Mindwtr Sync Report*"
                (goto-char (point-min))
                (should (search-forward "invalid status keyword" nil t))))))
      (when (get-buffer "*Mindwtr Sync Report*")
        (kill-buffer "*Mindwtr Sync Report*"))
      (delete-directory dir t))))

;;; incoming remote changes ---------------------------------------------------

(defun mindwtr-sync-test--incoming-find (incoming id)
  "Return the incoming entry for ID, or nil."
  (seq-find (lambda (e) (equal (plist-get e :id) id)) incoming))

(ert-deftest mindwtr-sync-incoming-reports-remote-update-not-own-edit ()
  "Covers AE1.  An untouched task changed on the server is `updated'; the
device's own accepted edit (merged == wire) is not incoming."
  (let* ((shadow '(:tasks ((:id "t1" :title "orig" :status "next")
                           (:id "t2" :title "old" :status "next"))
                   :projects nil :sections nil :areas nil))
         ;; t1 echoed unchanged; t2 carries the user's local edit.
         (wire '(:tasks ((:id "t1" :title "orig" :status "next")
                         (:id "t2" :title "MINE" :status "next"))
                 :projects nil :sections nil :areas nil))
         ;; server moved t1; accepted the user's t2 edit verbatim.
         (merged '(:tasks ((:id "t1" :title "remote-new" :status "next")
                           (:id "t2" :title "MINE" :status "next"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (= (length incoming) 1))
    (let ((e (mindwtr-sync-test--incoming-find incoming "t1")))
      (should e)
      (should (eq (plist-get e :change) 'updated))
      (should (eq (plist-get e :kind) 'task))
      (should (string= (plist-get e :title) "remote-new")))
    (should-not (mindwtr-sync-test--incoming-find incoming "t2"))))

(ert-deftest mindwtr-sync-incoming-reports-remote-delete-with-content-tombstone ()
  "Covers AE2.  A server tombstone that KEEPS its content fields (so its content
signature equals the live wire entity's) is still reported `deleted', because
the delete test precedes the signature own-edit gate.  Title comes from shadow."
  (let* ((shadow '(:tasks ((:id "t1" :title "doomed" :status "next" :areaId "a1"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t1" :title "doomed" :status "next" :areaId "a1"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "doomed" :status "next" :areaId "a1"
                            :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (= (length incoming) 1))
    (let ((e (car incoming)))
      (should (eq (plist-get e :change) 'deleted))
      (should (string= (plist-get e :title) "doomed")))))

(ert-deftest mindwtr-sync-incoming-excludes-own-local-delete ()
  "A delete this device pushed (tombstone in WIRE) is the user's own, not
incoming, even though it is also tombstoned in MERGED."
  (let* ((shadow '(:tasks ((:id "t1" :title "gone" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t1" :title "gone" :status "next"
                          :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "gone" :status "next"
                            :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (null incoming))))

(ert-deftest mindwtr-sync-incoming-reports-remote-create ()
  "An id present in MERGED, absent from SHADOW and WIRE, is a remote `created'."
  (let* ((shadow '(:tasks ((:id "t0" :title "anchor" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t0" :title "anchor" :status "next"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t0" :title "anchor" :status "next")
                           (:id "t9" :title "from phone" :status "next"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (= (length incoming) 1))
    (let ((e (car incoming)))
      (should (string= (plist-get e :id) "t9"))
      (should (eq (plist-get e :change) 'created))
      (should (string= (plist-get e :title) "from phone")))))

(ert-deftest mindwtr-sync-incoming-excludes-conflicts ()
  "Covers AE3.  An id already reported as a conflict is excluded from incoming."
  (let* ((shadow '(:tasks ((:id "t1" :title "orig" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t1" :title "MINE" :status "next"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "THEIRS" :status "next"))
                   :projects nil :sections nil :areas nil))
         (conflicts '((:id "t1" :kind task :mine (:title "MINE")
                       :theirs (:title "THEIRS"))))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow conflicts)))
    (should (null incoming))))

(ert-deftest mindwtr-sync-incoming-excludes-remotely-unchanged ()
  "An entity whose MERGED signature equals its SHADOW signature is excluded."
  (let* ((shadow '(:tasks ((:id "t1" :title "same" :status "next" :rev 1))
                   :projects nil :sections nil :areas nil))
         ;; wire absent for t1 (hypothetical), merged unchanged content but new rev.
         (wire '(:tasks nil :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "same" :status "next" :rev 5))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (null incoming))))

(ert-deftest mindwtr-sync-incoming-excludes-own-create ()
  "A locally-created entity (present in WIRE, absent from SHADOW, merged ==
wire) is the user's own accepted create, not a remote `created'."
  (let* ((shadow '(:tasks ((:id "t0" :title "anchor" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t0" :title "anchor" :status "next")
                         (:id "t1" :title "i made this" :status "next"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t0" :title "anchor" :status "next")
                           (:id "t1" :title "i made this" :status "next"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (null incoming))))

(ert-deftest mindwtr-sync-incoming-reports-empty-content-remote-create ()
  "A remote create whose content fields are all empty is still `created' -- the
merged-vs-shadow gate must not run against the nil shadow entity and skip it."
  (let* ((shadow '(:tasks ((:id "t0" :title "anchor" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t0" :title "anchor" :status "next"))
                 :projects nil :sections nil :areas nil))
         ;; t9 carries only identity + server-managed fields, no content.
         (merged '(:tasks ((:id "t0" :title "anchor" :status "next")
                           (:id "t9" :rev 1 :createdAt "Z" :updatedAt "Z"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (= (length incoming) 1))
    (let ((e (car incoming)))
      (should (string= (plist-get e :id) "t9"))
      (should (eq (plist-get e :change) 'created))
      (should (null (plist-get e :title))))))

(ert-deftest mindwtr-sync-incoming-cold-start-returns-nil ()
  "Covers KTD3.  An empty pre-sync shadow yields no incoming changes even when
merged is populated -- the first sync is an initial population."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil))
         (wire '(:tasks nil :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "x" :status "next"))
                   :projects ((:id "p1" :title "P" :status "active"))
                   :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (null incoming))))

(ert-deftest mindwtr-sync-incoming-sets-kind-per-entity-list ()
  "Each entity list maps to the correct singular :kind."
  (let* ((shadow '(:tasks nil :projects nil :sections nil
                   :areas ((:id "a0" :name "anchor"))))
         (wire '(:tasks nil :projects nil :sections nil
                 :areas ((:id "a0" :name "anchor"))))
         (merged '(:tasks ((:id "t1" :title "T" :status "next"))
                   :projects ((:id "p1" :title "P" :status "active"))
                   :sections ((:id "s1" :title "S" :projectId "p1"))
                   :areas ((:id "a0" :name "anchor") (:id "a1" :name "A"))))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (should (eq (plist-get (mindwtr-sync-test--incoming-find incoming "t1") :kind) 'task))
    (should (eq (plist-get (mindwtr-sync-test--incoming-find incoming "p1") :kind) 'project))
    (should (eq (plist-get (mindwtr-sync-test--incoming-find incoming "s1") :kind) 'section))
    (should (eq (plist-get (mindwtr-sync-test--incoming-find incoming "a1") :kind) 'area))))

;;; U1: echo-suppression infrastructure --------------------------------------

(ert-deftest mindwtr-quiet-save-writes-and-cleans-file-buffer ()
  "On a file-visiting modified buffer the helper writes to disk and leaves the
buffer unmodified, returning t."
  (let ((f (make-temp-file "mw-qs" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (insert "hello quiet save\n")
          (should (buffer-modified-p))
          (should (eq (mindwtr-sync--save-buffer-quietly) t))
          (should-not (buffer-modified-p))
          (should (string= (with-temp-buffer (insert-file-contents f) (buffer-string))
                           "hello quiet save\n")))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-quiet-save-noop-on-non-file-buffer ()
  "A buffer not visiting a file is a no-op returning :skipped, never an error."
  (with-temp-buffer
    (insert "x")
    (should (eq (mindwtr-sync--save-buffer-quietly) :skipped))))

(ert-deftest mindwtr-quiet-save-catches-save-failure ()
  "When the underlying save-buffer signals, the helper returns nil, does not
throw, and the buffer is left modified."
  (let ((f (make-temp-file "mw-qs-fail" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (insert "unsaved\n")
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (should (null (mindwtr-sync--save-buffer-quietly))))
          (should (buffer-modified-p)))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-quiet-save-suppresses-debounce-echo ()
  "During the quiet save -- with the debounce live on after-save-hook -- no
debounce timer is armed; the engine's own save does not echo."
  (let ((f (make-temp-file "mw-qs-echo" nil ".org"))
        (mindwtr--debounce-timer nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((mindwtr-file f)
                (after-save-hook (cons #'mindwtr--maybe-debounced-sync after-save-hook)))
            (insert "content\n")
            (mindwtr-sync--save-buffer-quietly)
            (should-not mindwtr--debounce-timer)))
      (when (timerp mindwtr--debounce-timer) (cancel-timer mindwtr--debounce-timer))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-debounce-arms-when-flag-nil ()
  "mindwtr--maybe-debounced-sync arms a timer for the mindwtr file when the
inhibit flag is nil (existing behavior preserved)."
  (let ((f (make-temp-file "mw-deb" nil ".org"))
        (mindwtr--debounce-timer nil)
        (mindwtr--inhibit-save-sync nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((mindwtr-file f))
            (mindwtr--maybe-debounced-sync)
            (should (timerp mindwtr--debounce-timer))))
      (when (timerp mindwtr--debounce-timer) (cancel-timer mindwtr--debounce-timer))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-debounce-stands-down-when-flag-set ()
  "With mindwtr--inhibit-save-sync bound t the scheduler arms nothing and
leaves an existing debounce timer untouched."
  (let* ((f (make-temp-file "mw-deb2" nil ".org"))
         (sentinel (run-with-idle-timer 9999 nil #'ignore))
         (mindwtr--debounce-timer sentinel)
         (mindwtr--inhibit-save-sync t))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((mindwtr-file f))
            (mindwtr--maybe-debounced-sync)
            (should (eq mindwtr--debounce-timer sentinel))))
      (cancel-timer sentinel)
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-quiet-save-protect-content-suppresses-before-save-hook ()
  "PROTECT-CONTENT non-nil suppresses a content-mutating before-save-hook."
  (let ((f (make-temp-file "mw-bsh-on" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          ;; let* so the lambda closes over THIS `ran', not a free var.
          (let* ((ran nil)
                 (before-save-hook (list (lambda () (setq ran t)))))
            (insert "body\n")
            (mindwtr-sync--save-buffer-quietly t)
            (should-not ran)))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

(ert-deftest mindwtr-quiet-save-without-protect-runs-before-save-hook ()
  "Without PROTECT-CONTENT the user's before-save-hook runs, matching an
ordinary `C-x C-s'."
  (let ((f (make-temp-file "mw-bsh-off" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          ;; let* so the lambda closes over THIS `ran', not a free var.
          (let* ((ran nil)
                 (before-save-hook (list (lambda () (setq ran t)))))
            (insert "body\n")
            (mindwtr-sync--save-buffer-quietly)
            (should ran)))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f))))

;;; U2: auto-save after a content-changing reconcile -------------------------

(defun mindwtr-test--kill-file-buffer (f)
  "Kill the buffer visiting F without a modified-buffer prompt."
  (when (get-file-buffer f)
    (with-current-buffer (get-file-buffer f) (set-buffer-modified-p nil))
    (kill-buffer (get-file-buffer f))))

(ert-deftest mindwtr-sync-once-saves-file-after-reconcile ()
  "A full reconcile cycle on a file-visiting buffer leaves the buffer clean
and the file on disk holding the merged content.  (Also exercises the
buffer-chars-modified-tick guard end-to-end: the save is downstream of the
guard, so the cycle completes without a \"buffer changed during sync\" error.)"
  (let* ((dir (make-temp-file "mw-save" t))
         (f (make-temp-file "mw-save-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get res :ok))
            (should-not (plist-get res :save-failed))
            (should-not (buffer-modified-p))
            (should (string-match-p
                     "do it"
                     (with-temp-buffer (insert-file-contents f) (buffer-string))))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-noop-does-not-write-file ()
  "On the :noop (HEAD-match) branch the engine never writes the file, even
when the buffer is modified -- it does not save edits it did not cause."
  (let* ((dir (make-temp-file "mw-noop-save" t))
         (f (make-temp-file "mw-noop-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              (m (error "mindwtr: unexpected %s on a no-op sync" m))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          (save-buffer)                       ; clean baseline on disk
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (mindwtr-shadow-set-etag "v1")
          ;; A cosmetic, unsaved edit (a comment line -- not an entity heading)
          ;; leaves the buffer modified but the entity state unchanged.
          (goto-char (point-max))
          (insert "# scratch note\n")
          (should (buffer-modified-p))
          (let* ((disk-before (with-temp-buffer (insert-file-contents f) (buffer-string)))
                 (res (mindwtr-sync-once (current-buffer) "NOW"))
                 (disk-after (with-temp-buffer (insert-file-contents f) (buffer-string))))
            (should (plist-get res :noop))
            (should (string= disk-before disk-after))   ; file NOT rewritten
            (should (buffer-modified-p))))               ; buffer left dirty
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-engine-save-suppresses-debounce-echo ()
  "The engine's post-reconcile save does not arm a debounce echo, even with
mindwtr--maybe-debounced-sync live on after-save-hook."
  (let* ((dir (make-temp-file "mw-echo2" t))
         (f (make-temp-file "mw-echo2-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-file f)
         (mindwtr--debounce-timer nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (let ((after-save-hook (cons #'mindwtr--maybe-debounced-sync after-save-hook)))
            (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z"))
          (should-not mindwtr--debounce-timer))
      (when (timerp mindwtr--debounce-timer) (cancel-timer mindwtr--debounce-timer))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-save-failure-is-isolated ()
  "When the post-reconcile save signals, sync-once still returns :ok, advances
shadow/etag, leaves the buffer modified, and flags :save-failed -- the server
write already committed, so a disk-write hiccup must not fail the sync."
  (let* ((dir (make-temp-file "mw-sf" t))
         (f (make-temp-file "mw-sf-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (plist-get res :ok))
              (should (plist-get res :save-failed))
              (should (buffer-modified-p))
              (should (string= (mindwtr-shadow-get-etag) "v2"))
              (let ((task (car (plist-get (mindwtr-shadow-load) :tasks))))
                (should (string= (plist-get task :title) "do it"))))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-save-failure-does-not-latch-notes-migration ()
  "Regression: the notes-migration latch must NOT be set when the post-reconcile
save fails.  If it were, a later reload from the stale (note-less) file would
parse empty notes with protection OFF and clear a server note via LWW.  The
latch is gated on a confirmed save (see `mindwtr-sync-once')."
  (let* ((dir (make-temp-file "mw-nl" t))
         (f (make-temp-file "mw-nl-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (should-not (mindwtr-shadow-notes-migrated-p))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (plist-get res :save-failed))
              ;; The save failed, so the on-disk file is stale -- protection
              ;; must remain on for the next sync.
              (should-not (mindwtr-shadow-notes-migrated-p)))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-latches-notes-migration-after-successful-save ()
  "A full cycle that saves the rendered buffer to disk durably latches the
notes migration, so subsequent syncs stop protecting empty notes."
  (let* ((dir (make-temp-file "mw-ml" t))
         (f (make-temp-file "mw-ml-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (should-not (mindwtr-shadow-notes-migrated-p))
          (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get res :ok))
            (should-not (plist-get res :save-failed))
            (should (mindwtr-shadow-notes-migrated-p))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-writes-pre-reconcile-backup ()
  "A full cycle on a file-visiting buffer snapshots the buffer to backups/
BEFORE reconcile overwrites it.  The server returns a title that overrides the
local edit, so the post-sync buffer differs from the backup: the backup must
hold the user's PRE-sync text (the safety net the report points at), not the
server's version, and the report must surface that path."
  (let* ((dir (make-temp-file "mw-bak" t))
         (f (make-temp-file "mw-bak-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         ;; The GET deliberately does NOT echo the PUT: the server wins with a
         ;; different title, so reconcile rewrites the heading and the backup
         ;; (taken before reconcile) is the only place LOCALWON survives.
         (server-body
          (concat "{\"tasks\":[{\"id\":\"t1\",\"title\":\"SERVERWON\","
                  "\"status\":\"next\",\"areaId\":\"a1\",\"rev\":3,"
                  "\"createdAt\":\"2026-01-01T00:00:00Z\","
                  "\"updatedAt\":\"2026-06-02T00:00:00Z\"}],"
                  "\"projects\":[],\"sections\":[],"
                  "\"areas\":[{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],"
                  "\"settings\":{}}"))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body server-body))))))
    (unwind-protect
        (progn
          (when (get-buffer "*Mindwtr Sync Report*")
            (kill-buffer "*Mindwtr Sync Report*"))
          (with-current-buffer (find-file-noselect f)
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                      "** NEXT LOCALWON :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :projects nil :sections nil
               :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (let* ((result (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z"))
                   (bdir (expand-file-name "backups/" dir))
                   (backups (and (file-directory-p bdir)
                                 (directory-files bdir t "\\.org\\'"))))
              (should (plist-get result :ok))
              ;; reconcile applied the server's version into the live buffer
              (goto-char (point-min))
              (should (search-forward "SERVERWON" nil t))
              ;; exactly one backup file was written for this single cycle
              (should (= (length backups) 1))
              (let ((snap (with-temp-buffer
                            (insert-file-contents (car backups))
                            (buffer-string))))
                ;; the backup is the PRE-reconcile snapshot: it preserves the
                ;; user's overridden edit and does NOT contain the server's
                (should (string-match-p "LOCALWON" snap))
                (should-not (string-match-p "SERVERWON" snap)))
              ;; the report points the user at exactly this backup path
              (with-current-buffer "*Mindwtr Sync Report*"
                (goto-char (point-min))
                (should (search-forward (car backups) nil t))))))
      (when (get-buffer "*Mindwtr Sync Report*")
        (kill-buffer "*Mindwtr Sync Report*"))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-prunes-stale-backups ()
  "A full sync writes a fresh backup and prunes ones older than retention."
  (let* ((dir (make-temp-file "mw-prune" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-backup-retention-days 3)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (orgfile (expand-file-name "mw.org" dir))
         (bdir (expand-file-name "backups/" dir))
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (progn
          (make-directory bdir t)
          (write-region "" nil (expand-file-name "mindwtr-20200101T000000.org" bdir))
          (with-temp-buffer
            (setq buffer-file-name orgfile)
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                      "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :projects nil :sections nil
               :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (should (plist-get (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z") :ok))
            (set-buffer-modified-p nil))
          (should-not (file-exists-p
                       (expand-file-name "mindwtr-20200101T000000.org" bdir)))
          (should (seq-some (lambda (f) (string-match-p "\\`mindwtr-.*\\.org\\'" f))
                            (directory-files bdir))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-survives-prune-failure ()
  "A prune that signals must not abort the sync (post-PUT must never throw)."
  (let* ((dir (make-temp-file "mw-prunefail" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-backup-retention-days 3)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (orgfile (expand-file-name "mw.org" dir))
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (cl-letf (((symbol-function 'mindwtr-shadow-prune-backups)
                   (lambda (&optional _now) (error "boom"))))
          (with-temp-buffer
            (setq buffer-file-name orgfile)
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                      "** NEXT do it :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :projects nil :sections nil
               :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (should (plist-get (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z") :ok))
            (set-buffer-modified-p nil)))
      (delete-directory dir t))))
