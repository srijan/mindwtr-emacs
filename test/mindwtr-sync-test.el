;;; mindwtr-sync-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'mindwtr-sync)
(require 'mindwtr)
(require 'mindwtr-test-helpers)

;; The archive surface auto-derives a sibling file beside any file-visiting
;; buffer, so these pre-archive sync tests would each create and leak a shared
;; `mindwtr_archive.org' buffer across the suite.  Default it OFF here; the
;; archive-specific tests opt back in by let-binding `mindwtr-archive-file'.
(setq mindwtr-archive-file (lambda () nil))

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

(ert-deftest mindwtr-sync-ensure-status-defaults-inbox-for-standalone-task ()
  "A keyword-less new task with no container parent defaults to inbox."
  (let ((m (mindwtr-sync--ensure-status '(:id "t" :title "x") 'task)))
    (should (string= (plist-get m :status) "inbox"))))

(ert-deftest mindwtr-sync-ensure-status-defaults-next-for-project-task ()
  "A keyword-less new task created directly inside a project defaults to NEXT,
not inbox -- inbox is the wrong resting state for a project task."
  (let ((m (mindwtr-sync--ensure-status '(:id "t" :title "x" :projectId "p1") 'task)))
    (should (string= (plist-get m :status) "next"))))

(ert-deftest mindwtr-sync-ensure-status-defaults-next-for-section-task ()
  "A keyword-less new task inside a section also defaults to NEXT."
  (let ((m (mindwtr-sync--ensure-status '(:id "t" :title "x" :sectionId "s1") 'task)))
    (should (string= (plist-get m :status) "next"))))

(ert-deftest mindwtr-sync-build-candidate-keywordless-project-task-is-next ()
  "End-to-end: a new keyword-less task parsed under a project (carrying
:projectId but no :status) syncs as NEXT, not INBOX."
  (let* ((local '(:tasks ((:id nil :mw-kind task :title "do it" :projectId "p1"))
                  :projects nil :sections nil :areas nil))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :status) "next"))))

(ert-deftest mindwtr-sync-build-candidate-keywordless-someday-project-task-is-next ()
  "A new keyword-less task under a SOMEDAY (or waiting) project still defaults to
NEXT -- the default is project-status-agnostic; we never cascade the project's
deferred status onto the task (matches upstream, which leaves task status
untouched when a project is someday)."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "parked" :status "someday" :rev 1))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id nil :mw-kind task :title "do it"
                                     :projectId "p1"))
                      :projects (list '(:id "p1" :mw-kind project :title "parked"
                                        :status "someday"))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :status) "next"))))

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

(ert-deftest mindwtr-sync-protect-fields-preserves-task-boolean-pre-migration ()
  "Covers R6 (post-promotion).  Pre-migration, an empty local :isFocusedToday
against a shadow that has it `t' keeps the shadow value -- the false-empty seam
the fields latch guards.  Without protection the value is clobbered."
  (let* ((shadow '(:tasks ((:id "t1" :title "t" :status "next" :rev 3
                            :isFocusedToday t :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         ;; old buffer never rendered the boolean, so parse omits it
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "t" :status "next"))
                      :projects nil :sections nil :areas nil)))
    ;; WITHOUT protection (5th/6th args nil) -> clobbered to absent
    (let ((unprot (car (plist-get (mindwtr-sync-build-candidate
                                   local shadow "dev" "NOW" nil nil) :tasks))))
      (should-not (plist-get unprot :isFocusedToday)))
    ;; WITH fields protection (6th arg t) -> shadow t preserved
    (let ((prot (car (plist-get (mindwtr-sync-build-candidate
                                 local shadow "dev" "NOW" nil t) :tasks))))
      (should (eq (plist-get prot :isFocusedToday) t)))))

(ert-deftest mindwtr-sync-protect-fields-preserves-project-booleans-pre-migration ()
  "Covers R6 (post-promotion).  A project's :isSequential/:isFocused are
protected the same way as a task's boolean pre-migration."
  (let* ((shadow '(:tasks nil
                   :projects ((:id "p1" :title "P" :status "active" :rev 3
                               :isSequential t :isFocused t
                               :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "P"
                                        :status "active"))
                      :sections nil :areas nil))
         (prot (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev" "NOW" nil t) :projects))))
    (should (eq (plist-get prot :isSequential) t))
    (should (eq (plist-get prot :isFocused) t))))

(ert-deftest mindwtr-sync-protect-fields-still-adopts-real-boolean-edit ()
  "Covers R6.  Protection only suppresses an EMPTY local boolean; a genuine
local `t' (shadow had it absent) is adopted even pre-migration."
  (let* ((shadow '(:tasks ((:id "t1" :title "t" :status "next" :rev 3
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "t" :status "next"
                                     :isFocusedToday t))
                      :projects nil :sections nil :areas nil))
         (cand (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev" "NOW" nil t) :tasks))))
    (should (eq (plist-get cand :isFocusedToday) t))))

(ert-deftest mindwtr-sync-review-at-not-protected-clears-pre-migration ()
  "Covers R6.  :reviewAt is excluded from the protected set -- even with both
latches' protection on, an empty local :reviewAt against a non-empty shadow
clears (a genuine deletion, because :reviewAt always rendered)."
  (let* ((shadow '(:tasks ((:id "t1" :title "t" :status "next" :rev 3
                            :reviewAt "2026-06-09T14:30:00Z"
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "t" :status "next"))
                      :projects nil :sections nil :areas nil))
         (prot (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev" "NOW" t t) :tasks))))
    (should-not (plist-get prot :reviewAt))))

(ert-deftest mindwtr-sync-boolean-clears-post-migration ()
  "Covers R6.  Post-migration (protection off), an empty local boolean against a
non-empty shadow clears normally."
  (let* ((shadow '(:tasks ((:id "t1" :title "t" :status "next" :rev 3
                            :isFocusedToday t :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "t" :status "next"))
                      :projects nil :sections nil :areas nil))
         (post (car (plist-get (mindwtr-sync-build-candidate
                                local shadow "dev" "NOW" nil nil) :tasks))))
    (should-not (plist-get post :isFocusedToday))))

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
  "When the checklist content actually changes, the new value is taken, but the
server-assigned item id is re-attached by matching title so the item keeps its
identity across the org round-trip (the phone's conflict comparison is id-
sensitive; a toggled item that lost its id looks like a delete+add and gets
overwritten -- the checklist-overwrite loop)."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                       :checklist ((:id "c1" :title "a" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :checklist ((:title "a" :isCompleted t))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (item (car (plist-get (car (plist-get cand :tasks)) :checklist))))
    (should (eq (plist-get item :isCompleted) t))             ; flipped
    (should (string= (plist-get item :id) "c1"))))            ; id re-attached by title

(ert-deftest mindwtr-sync-checklist-reorder-preserves-ids ()
  "Reordering checklist items in org (which drops ids) must re-attach each id by
title, so the phone sees the same items reordered -- not two foreign items."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                       :checklist ((:id "c1" :title "a" :isCompleted :false)
                                                   (:id "c2" :title "b" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :checklist ((:title "b" :isCompleted t)
                                                  (:title "a" :isCompleted :false))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (items (plist-get (car (plist-get cand :tasks)) :checklist)))
    (should (string= (plist-get (nth 0 items) :title) "b"))
    (should (string= (plist-get (nth 0 items) :id) "c2"))        ; id follows the item
    (should (string= (plist-get (nth 1 items) :id) "c1"))))

(ert-deftest mindwtr-sync-checklist-add-mints-id-keeps-existing ()
  "Adding a new item keeps existing item ids and mints a fresh uuid for the new
one (never nil), so the phone accepts it as a clean add rather than rejecting an
id-less item."
  (let* ((shadow (list :tasks (list '(:id "t1" :title "x" :status "next" :rev 1
                                       :checklist ((:id "c1" :title "a" :isCompleted :false))))
                       :projects nil :sections nil :areas nil :settings nil))
         (local (list :tasks (list '(:id "t1" :mw-kind task :title "x" :status "next"
                                      :checklist ((:title "a" :isCompleted :false)
                                                  (:title "new" :isCompleted :false))))
                      :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (items (plist-get (car (plist-get cand :tasks)) :checklist)))
    (should (string= (plist-get (nth 0 items) :id) "c1"))        ; existing kept
    (let ((new-id (plist-get (nth 1 items) :id)))
      (should (stringp new-id))                               ; minted, not nil
      (should-not (string= new-id "c1")))))                   ; distinct from existing

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

(ert-deftest mindwtr-sync-full-cycle-commits-state-then-noops ()
  "A full cycle on the in-memory adapters: no temp dir, no files.  The first
cycle pushes the local edit and commits shadow, etag and the migration
latches through `mindwtr-shadow-commit'; with nothing changed, the second
cycle HEAD-matches the committed etag and is a noop that touches the server
with HEAD only."
  (mindwtr-test-with-sync-env
      (:server srv
       :initial '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                           :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                  :projects nil :sections nil
                  :areas ((:id "a1" :name "Work" :rev 1)) :settings nil)
       :shadow '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                          :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                 :projects nil :sections nil
                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil)
       :etag "v1")
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                "** NEXT renamed :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
        (org-mode))
      (should-not (mindwtr-shadow-latched-names))
      (let ((r1 (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
        (should (plist-get r1 :ok))
        (should-not (plist-get r1 :noop))
        (should (= (plist-get (plist-get r1 :stats) :updated) 1)))
      ;; Committed: shadow carries the pushed title, etag advanced, latches set
      ;; (a temp buffer has no file, so its save is :skipped, not a failure).
      (should (string= (plist-get (car (plist-get (mindwtr-shadow-load) :tasks)) :title)
                       "renamed"))
      (should (string= (mindwtr-shadow-get-etag) "v2"))
      (should (equal (mindwtr-shadow-latched-names) '(notes fields)))
      (should (equal (reverse (mindwtr-test-server-requests srv)) '("PUT" "GET")))
      (setf (mindwtr-test-server-requests srv) nil)
      (let ((r2 (mindwtr-sync-once (current-buffer) "2026-06-01T00:01:00Z")))
        (should (plist-get r2 :noop)))
      (should (equal (mindwtr-test-server-requests srv) '("HEAD"))))))

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

(ert-deftest mindwtr-sync-merge-content-protected-set-is-a-list ()
  "Covers R6 (mechanism).  merge-content's protected-set is a LIST: any listed
field whose local value is empty but shadow's is not keeps the shadow value,
while an unlisted field clears.  This is the generalization of the former
single protected-field to the shared field-set guard."
  (let ((se '(:id "p1" :status "active" :supportNotes "server note"))
        (le '(:id "p1" :mw-kind project :status "active" :supportNotes "")))
    ;; listed -> protected (kept)
    (should (string= (plist-get (mindwtr-sync--merge-content le se '(:supportNotes))
                                :supportNotes)
                     "server note"))
    ;; not listed -> cleared
    (should-not (plist-get (mindwtr-sync--merge-content le se nil) :supportNotes))
    ;; a real (non-empty) edit is adopted regardless of protection
    (let ((le2 '(:id "p1" :mw-kind project :status "active" :supportNotes "edit")))
      (should (string= (plist-get (mindwtr-sync--merge-content le2 se '(:supportNotes))
                                  :supportNotes)
                       "edit")))))

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
          (let ((res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
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
          (let ((res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
            (should-not (plist-get res :noop))
            (should saw-put)
            (should saw-get)
            (goto-char (point-min))
            (should (search-forward "from server" nil t))))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-reports-incoming-remote-change ()
  "Covers AE1 end-to-end.  A clean local buffer with a remote-created entity
surfaces an incoming line in the report and the :incoming result."
  (let* ((dir (make-temp-file "mw-inc" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (remote (concat "{\"tasks\":[{\"id\":\"t9\",\"title\":\"from server\","
                         "\"status\":\"next\",\"areaId\":\"a1\",\"rev\":1,"
                         "\"createdAt\":\"2026-06-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}],"
                         "\"projects\":[],\"sections\":[],"
                         "\"areas\":[{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],\"settings\":{}}"))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v2")) :body ""))
              ("PUT" '(:status 200 :headers nil :body "{\"ok\":true}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body remote))))))
    (unwind-protect
        (progn
          (when (get-buffer "*Mindwtr Sync Report*")
            (kill-buffer "*Mindwtr Sync Report*"))
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                   :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (mindwtr-shadow-set-etag "v1")
            (let* ((res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z"))
                   (inc (plist-get res :incoming)))
              (should (= (length inc) 1))
              (should (eq (plist-get (car inc) :change) 'created))
              (should (eq (plist-get (car inc) :kind) 'task))
              (should (string= (plist-get (car inc) :title) "from server"))
              (with-current-buffer "*Mindwtr Sync Report*"
                (goto-char (point-min))
                (should (search-forward "Incoming from remote:" nil t))
                (should (save-excursion
                          (goto-char (point-min))
                          (search-forward "↓ from server (task) — created" nil t)))))))
      (when (get-buffer "*Mindwtr Sync Report*")
        (kill-buffer "*Mindwtr Sync Report*"))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-noop-reports-no-incoming ()
  "Covers AE4.  A HEAD-match no-op surfaces no incoming and creates no report."
  (let* ((dir (make-temp-file "mw-noop" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v2")) :body ""))
              (_ (error "no PUT/GET expected on a no-op"))))))
    (unwind-protect
        (progn
          (when (get-buffer "*Mindwtr Sync Report*")
            (kill-buffer "*Mindwtr Sync Report*"))
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                   :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (mindwtr-shadow-set-etag "v2")
            (let ((res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
              (should (plist-get res :noop))
              (should (null (plist-get res :incoming))))
            ;; Nothing reportable and no parse warnings: no report buffer at all.
            (should (null (get-buffer "*Mindwtr Sync Report*")))))
      (when (get-buffer "*Mindwtr Sync Report*")
        (kill-buffer "*Mindwtr Sync Report*"))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-own-edit-won-no-incoming ()
  "A full cycle where the user's own edit won and the server changed nothing
else yields no incoming lines -- the own-edit exclusion holds through the
real cycle, not just the unit helper."
  (let* ((dir (make-temp-file "mw-own" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true}"))
              ;; Server echoes exactly what we PUT: our edit won, nothing else moved.
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (progn
          (when (get-buffer "*Mindwtr Sync Report*")
            (kill-buffer "*Mindwtr Sync Report*"))
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                      "** NEXT renamed by me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
              (org-mode))
            (mindwtr-shadow-save
             '(:tasks ((:id "t1" :title "old name" :status "next" :areaId "a1" :rev 1
                        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
               :projects nil :sections nil
               :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
            (mindwtr-shadow-set-etag "v1")
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (null (plist-get res :incoming)))
              (should (null (plist-get res :conflicts))))))
      (when (get-buffer "*Mindwtr Sync Report*")
        (kill-buffer "*Mindwtr Sync Report*"))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
            (should (string-match-p "do it" (mindwtr-test-server-last-put srv)))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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

(ert-deftest mindwtr-sync-incoming-updated-carries-before-after ()
  "An `updated' incoming change carries :before (shadow entity) and :after (merged
entity) so the report can render a field diff."
  (let* ((shadow '(:tasks ((:id "t1" :title "orig" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t1" :title "orig" :status "next"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t1" :title "remote-new" :status "next"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil))
         (e (mindwtr-sync-test--incoming-find incoming "t1")))
    (should (eq (plist-get e :change) 'updated))
    (should (plist-get e :before))
    (should (plist-get e :after))
    (should (string= (plist-get (plist-get e :before) :title) "orig"))
    (should (string= (plist-get (plist-get e :after) :title) "remote-new"))))

(ert-deftest mindwtr-sync-incoming-created-deleted-carry-no-before-after ()
  "Created and deleted incoming entries do not carry :before or :after."
  (let* ((shadow '(:tasks ((:id "t0" :title "anchor" :status "next")
                           (:id "t2" :title "doomed" :status "next"))
                   :projects nil :sections nil :areas nil))
         (wire '(:tasks ((:id "t0" :title "anchor" :status "next")
                         (:id "t2" :title "doomed" :status "next"))
                 :projects nil :sections nil :areas nil))
         (merged '(:tasks ((:id "t0" :title "anchor" :status "next")
                           (:id "t1" :title "from phone" :status "next"))
                   :projects nil :sections nil :areas nil))
         (incoming (mindwtr-sync--incoming-changes wire merged shadow nil)))
    (let ((created (mindwtr-sync-test--incoming-find incoming "t1"))
          (deleted (mindwtr-sync-test--incoming-find incoming "t2")))
      (should (eq (plist-get created :change) 'created))
      (should-not (plist-member created :before))
      (should-not (plist-member created :after))
      (should (eq (plist-get deleted :change) 'deleted))
      (should-not (plist-member deleted :before))
      (should-not (plist-member deleted :after)))))

(ert-deftest mindwtr-sync-local-changes-classifies-creates-updates-deletes ()
  "mindwtr-sync--local-changes returns created, updated (with :before/:after),
and deleted entries for the corresponding local vs shadow differences."
  (let* ((shadow '(:tasks ((:id "t1" :title "orig" :status "next")
                           (:id "t2" :title "gone" :status "next"))
                   :projects nil :sections nil :areas nil))
         (local '(:tasks ((:id "t1" :title "edited" :status "next")
                          (:id "t3" :title "brand-new" :status "next"))
                  :projects nil :sections nil :areas nil))
         (changes (mindwtr-sync--local-changes local shadow))
         (upd (seq-find (lambda (c) (string= (plist-get c :id) "t1")) changes))
         (cre (seq-find (lambda (c) (string= (plist-get c :id) "t3")) changes))
         (del (seq-find (lambda (c) (string= (plist-get c :id) "t2")) changes)))
    (should (eq (plist-get upd :change) 'updated))
    (should (plist-get upd :before))
    (should (plist-get upd :after))
    (should (string= (plist-get (plist-get upd :before) :title) "orig"))
    (should (string= (plist-get (plist-get upd :after) :title) "edited"))
    (should (eq (plist-get cre :change) 'created))
    (should-not (plist-member cre :before))
    (should-not (plist-member cre :after))
    (should (eq (plist-get del :change) 'deleted))
    (should (string= (plist-get del :title) "gone"))))

(ert-deftest mindwtr-sync-local-changes-counts-match-stats ()
  "The count of created/updated/deleted in mindwtr-sync--local-changes matches
what mindwtr-sync--stats returns for the same local and shadow."
  (let* ((shadow '(:tasks ((:id "t1" :title "orig" :status "next")
                           (:id "t2" :title "gone" :status "next"))
                   :projects ((:id "p1" :title "proj" :status "active"))
                   :sections nil :areas nil))
         (local '(:tasks ((:id "t1" :title "edited" :status "next")
                          (:id "t3" :title "brand-new" :status "next"))
                  :projects ((:id "p1" :title "proj" :status "active"))
                  :sections nil :areas nil))
         (stats (mindwtr-sync--stats local shadow))
         (changes (mindwtr-sync--local-changes local shadow)))
    (should (= (plist-get stats :created)
               (length (seq-filter (lambda (c) (eq (plist-get c :change) 'created)) changes))))
    (should (= (plist-get stats :updated)
               (length (seq-filter (lambda (c) (eq (plist-get c :change) 'updated)) changes))))
    (should (= (plist-get stats :deleted)
               (length (seq-filter (lambda (c) (eq (plist-get c :change) 'deleted)) changes))))))

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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
                 (res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z"))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
          (should-not (mindwtr-shadow-latched-p 'notes))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (plist-get res :save-failed))
              ;; The save failed, so the on-disk file is stale -- protection
              ;; must remain on for the next sync.
              (should-not (mindwtr-shadow-latched-p 'notes)))))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
          (should-not (mindwtr-shadow-latched-p 'notes))
          (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get res :ok))
            (should-not (plist-get res :save-failed))
            (should (mindwtr-shadow-latched-p 'notes))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-save-failure-does-not-latch-fields-migration ()
  "Covers R6.  The fields-migration latch must NOT be set when the post-reconcile
save fails: a later reload from the stale (boolean-less) file would parse empty
booleans with protection OFF and clobber server-authored values via LWW.  Gated
on a confirmed save, exactly like the notes latch."
  (let* ((dir (make-temp-file "mw-fl" t))
         (f (make-temp-file "mw-fl-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
          (should-not (mindwtr-shadow-latched-p 'fields))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
              (should (plist-get res :save-failed))
              (should-not (mindwtr-shadow-latched-p 'fields)))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-latches-fields-migration-after-successful-save ()
  "Covers R6.  A full cycle that durably saves the boolean-capable render latches
the fields migration, so subsequent syncs stop protecting empty booleans."
  (let* ((dir (make-temp-file "mw-fm" t))
         (f (make-temp-file "mw-fm-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
          (should-not (mindwtr-shadow-latched-p 'fields))
          (let ((res (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
            (should (plist-get res :ok))
            (should-not (plist-get res :save-failed))
            (should (mindwtr-shadow-latched-p 'fields))))
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
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
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
  "A prune that fails must not abort the sync (post-PUT must never throw).
The failure is injected at the store seam -- a backup listing that signals --
so it exercises the guard inside `mindwtr-shadow-prune-backups' instead of
replacing the function."
  (let* ((dir (make-temp-file "mw-prunefail" t))
         (store (mindwtr-shadow-memory-store))
         (mindwtr-shadow-store store)
         (mindwtr-backup-retention-days 3)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (orgfile (expand-file-name "mw.org" dir))
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
    (setf (mindwtr-shadow-store-keys store) (lambda (_prefix) (error "boom")))
    (unwind-protect
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
      (delete-directory dir t))))

;;; U4: migration latch + strict absence semantics ---------------------------

(ert-deftest mindwtr-sync-archive-strict-tombstones-absent-archived-task ()
  "Covers R8 deletion semantics.  With strict mode on, an archived shadow task
absent from local is a user deletion -> tombstone stamped with this cycle's NOW."
  (let* ((mindwtr-sync--archive-strict t)
         (shadow '(:tasks ((:id "t1" :title "x" :status "archived" :rev 3
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (string= (plist-get task :deletedAt) "NOW"))
    (should (= (plist-get task :rev) 4))
    (should (string= (plist-get task :revBy) "dev1"))))

(ert-deftest mindwtr-sync-archive-legacy-echoes-absent-archived-task ()
  "Covers R9.  With strict mode OFF (today's default), the same absent archived
task is echoed verbatim -- original rev, no :deletedAt -- byte-identical to now."
  (let* ((mindwtr-sync--archive-strict nil)
         (shadow '(:tasks ((:id "t1" :title "x" :status "archived" :rev 3
                            :createdAt "C" :updatedAt "U"))
                   :projects nil :sections nil :areas nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "NOW"))
         (task (car (plist-get cand :tasks))))
    (should (null (plist-get task :deletedAt)))
    (should (= (plist-get task :rev) 3))))

(ert-deftest mindwtr-sync-archive-strict-tombstones-archived-project-child ()
  "Covers R8.  With strict mode on, archived projects count as live containers,
so a done child of an archived project absent from local tombstones (the
project is still present locally, isolating the child's deletion)."
  (let* ((mindwtr-sync--archive-strict t)
         (shadow '(:tasks ((:id "t1" :title "child" :status "done" :projectId "p1"
                            :rev 2 :createdAt "C" :updatedAt "U"))
                   :projects ((:id "p1" :title "P" :status "archived" :rev 1
                               :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "P"
                                        :status "archived"))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "NOW"))
         (tomb (seq-find (lambda (e) (equal (plist-get e :id) "t1"))
                         (plist-get cand :tasks))))
    (should (string= (plist-get tomb :deletedAt) "NOW"))))

(ert-deftest mindwtr-sync-archive-legacy-echoes-archived-project-child ()
  "Covers R9.  With strict mode off, the archived project's done child is echoed
\(its parent container does not render in legacy mode), never tombstoned."
  (let* ((mindwtr-sync--archive-strict nil)
         (shadow '(:tasks ((:id "t1" :title "child" :status "done" :projectId "p1"
                            :rev 2 :createdAt "C" :updatedAt "U"))
                   :projects ((:id "p1" :title "P" :status "archived" :rev 1
                               :createdAt "C" :updatedAt "U"))
                   :sections nil :areas nil :settings nil))
         (local (list :tasks nil
                      :projects (list '(:id "p1" :mw-kind project :title "P"
                                        :status "archived"))
                      :sections nil :areas nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev1" "NOW"))
         (echoed (seq-find (lambda (e) (equal (plist-get e :id) "t1"))
                           (plist-get cand :tasks))))
    (should (null (plist-get echoed :deletedAt)))
    (should (= (plist-get echoed :rev) 2))))

(ert-deftest mindwtr-shadow-archive-migrated-latch ()
  "The archive-migrated latch is a one-way persistent flag, parallel to the
notes/fields latches."
  (let* ((dir (make-temp-file "mw-arch-latch" t))
         (mindwtr-shadow-directory dir))
    (unwind-protect
        (progn
          (should (null (mindwtr-shadow-latched-p 'archive)))
          (mindwtr-shadow-latch 'archive)
          (should (mindwtr-shadow-latched-p 'archive)))
      (delete-directory dir t))))

;;; U5: surface-list orchestration (end-to-end, file-visiting) ---------------

(ert-deftest mindwtr-sync-once-archive-surface-receives-cloud-archive ()
  "Covers R1.  A task the server reports as archived (held locally as done)
leaves the tasks file and lands under * Archive in the archive file after one
cycle; the migration latch flips."
  (let* ((root (make-temp-file "mw-arch-r1" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (server-body
          (concat "{\"tasks\":[{\"id\":\"t1\",\"title\":\"Old task\","
                  "\"status\":\"archived\",\"rev\":2,"
                  "\"createdAt\":\"2026-01-01T00:00:00Z\","
                  "\"updatedAt\":\"2026-06-05T00:00:00Z\"}],"
                  "\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}"))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body server-body))))))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks ((:id "t1" :title "Old task" :status "done" :order 0))
                       :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Old task" :status "done" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              (should-not
               (string-match-p "Old task"
                               (with-temp-buffer (insert-file-contents tasks-file)
                                                 (buffer-string))))
              (let ((atext (with-temp-buffer (insert-file-contents archive-file)
                                             (buffer-string))))
                (should (string-match-p "^\\* Archive" atext))
                (should (string-match-p "ARCH Old task" atext)))
              (should (mindwtr-shadow-latched-p 'archive)))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-archive-edit-unarchives ()
  "Covers R2.  With the latch set and the archive file present, editing an entry
ARCH -> NEXT pushes status next, returns the heading to the tasks file, and
drops it from the archive file."
  (let* ((root (make-temp-file "mw-arch-r2" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ;; server accepts the un-archive: echoes the PUT back
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (progn
          ;; tasks file: t1 is archived -> dropped from the main render
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks ((:id "t1" :title "Resurrected" :status "archived"))
                       :projects nil :sections nil :areas nil :settings nil))))
          ;; archive file: the user edited the keyword ARCH -> NEXT (un-archive)
          (with-temp-file archive-file
            (insert (mindwtr-model-todo-keyword-line) "\n"
                    "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
                    "** NEXT Resurrected\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Resurrected" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (mindwtr-shadow-latch 'archive)
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; pushed status next
              (should (string-match-p "\"status\":\"next\"" put-body))
              ;; heading is back in the tasks file...
              (should (string-match-p "Resurrected"
                                      (with-temp-buffer (insert-file-contents tasks-file)
                                                        (buffer-string))))
              ;; ...and no longer in the archive file
              (should-not
               (string-match-p "Resurrected"
                               (with-temp-buffer (insert-file-contents archive-file)
                                                 (buffer-string)))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-first-cycle-backfills-without-tombstoning ()
  "Covers R8.  Latch unset, archive file absent, shadow holds an archived task:
the PUT carries no tombstone for it (echoed, never deleted), and the archive
file is created containing it (backfill)."
  (let* ((root (make-temp-file "mw-arch-r8" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil)
         (server-body
          (concat "{\"tasks\":[{\"id\":\"t1\",\"title\":\"Backlog item\","
                  "\"status\":\"archived\",\"rev\":2,"
                  "\"createdAt\":\"2026-01-01T00:00:00Z\","
                  "\"updatedAt\":\"2026-06-05T00:00:00Z\"}],"
                  "\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}"))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body server-body))))))
    (unwind-protect
        (progn
          ;; tasks file: empty layout (the archived task is not rendered here)
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Backlog item" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (should-not (file-exists-p archive-file))
          (should-not (mindwtr-shadow-latched-p 'archive))
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; backfill never tombstones the not-yet-rendered archived task
              (should-not (string-match-p "deletedAt" put-body))
              ;; the archive file is created and holds the backlog item
              (should (file-exists-p archive-file))
              (let ((atext (with-temp-buffer (insert-file-contents archive-file)
                                             (buffer-string))))
                (should (string-match-p "ARCH Backlog item" atext)))
              (should (mindwtr-shadow-latched-p 'archive)))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

;;; Strict-mode safety gate (degraded/empty archive must not mass-delete) -----

(ert-deftest mindwtr-sync--archived-count-counts-only-live-archived ()
  "Counts non-deleted archived entities across kinds; ignores other statuses
and tombstones."
  (should (= 0 (mindwtr-sync--archived-count
                '(:tasks ((:id "a" :status "next")) :projects nil
                  :sections nil :areas nil))))
  (should (= 2 (mindwtr-sync--archived-count
                '(:tasks ((:id "a" :status "archived"))
                  :projects ((:id "p" :status "archived"))
                  :sections nil :areas nil))))
  (should (= 1 (mindwtr-sync--archived-count
                '(:tasks ((:id "a" :status "archived")
                          (:id "b" :status "archived" :deletedAt "X"))
                  :projects nil :sections nil :areas nil)))))

(ert-deftest mindwtr-sync--archive-strict-safe-p-gates ()
  "Strict mode is withheld on a warned parse or an empty-shortfall, allowed when
the archive parsed cleanly with a plausible archived count."
  (let ((shadow '(:tasks ((:id "t1" :status "archived")) :projects nil
                  :sections nil :areas nil))
        (have '(:tasks ((:id "t1" :status "archived")) :projects nil
                :sections nil :areas nil))
        (empty '(:tasks nil :projects nil :sections nil :areas nil)))
    ;; clean parse, archived present on both sides -> safe
    (should (mindwtr-sync--archive-strict-safe-p have shadow nil))
    ;; archive parsed with an unparsed heading -> withheld
    (should-not (mindwtr-sync--archive-strict-safe-p have shadow t))
    ;; shadow has archived, local parsed none (empty/truncated) -> withheld
    (should-not (mindwtr-sync--archive-strict-safe-p empty shadow nil))
    ;; neither side has archived entities -> nothing to protect, safe
    (should (mindwtr-sync--archive-strict-safe-p empty empty nil))))

(ert-deftest mindwtr-sync--surface-has-unparsed-entity-p-detects-untyped ()
  "A heading with an MW_ID but no parseable type (untyped/quarantined) is
flagged; a fully-parsed buffer is not."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert (mindwtr-model-todo-keyword-line) "\n"
              "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
              "** ARCH Real\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ;; MW_TYPE removed by a raw edit -- inference under * Archive is nil,
              ;; so the parser skips it though its MW_ID is intact.
              "** ARCH Mangled\n:PROPERTIES:\n:MW_ID: t2\n:END:\n")
      (org-mode))
    (let ((ad (mindwtr-parse-buffer)))
      ;; t2 did not parse into an entity but its MW_ID is in the buffer.
      (should (mindwtr-sync--surface-has-unparsed-entity-p ad))))
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert (mindwtr-model-todo-keyword-line) "\n"
              "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
              "** ARCH Real\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((ad (mindwtr-parse-buffer)))
      (should-not (mindwtr-sync--surface-has-unparsed-entity-p ad)))))

(ert-deftest mindwtr-sync-once-latch-set-missing-file-echoes-not-deletes ()
  "Covers R8/KTD5.  Latch SET but the archive file deleted from disk: the
file-exists-p guard keeps strict OFF, so an archived shadow task absent from
local is echoed (no tombstone) and the archive file is recreated."
  (let* ((root (make-temp-file "mw-arch-rm" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Kept" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z"))
             :projects nil :sections nil :areas nil :settings nil))
          ;; Latch set (migrated) but NO etag and NO archive file on disk.
          (mindwtr-shadow-latch 'archive)
          (should-not (file-exists-p archive-file))
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; strict stayed OFF (file absent) -> no tombstone for t1
              (should-not (string-match-p "deletedAt" (or (mindwtr-test-server-last-put srv) "")))
              ;; the archive file is recreated holding the echoed archived task
              (should (file-exists-p archive-file))
              (should (string-match-p
                       "ARCH Kept"
                       (with-temp-buffer (insert-file-contents archive-file)
                                         (buffer-string)))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-empty-archive-does-not-mass-delete ()
  "Covers the P0 steady-state seam.  Latch set, archive file PRESENT but empty
\(only the container -- a truncation/bad-save), shadow holds an archived task:
the empty-shortfall gate withholds strict, the task is echoed (not tombstoned),
and the archive file is re-backfilled."
  (let* ((root (make-temp-file "mw-arch-empty" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          ;; archive file present but holds only the container (no archived heading)
          (with-temp-file archive-file
            (insert (mindwtr-render-archive-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Backlog" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-latch 'archive)
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; strict withheld -> NO mass deletion of the archived backlog
              (should-not (string-match-p "deletedAt" (or (mindwtr-test-server-last-put srv) "")))
              ;; the empty archive file is re-backfilled with the echoed task
              (should (string-match-p
                       "ARCH Backlog"
                       (with-temp-buffer (insert-file-contents archive-file)
                                         (buffer-string)))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-warned-archive-does-not-tombstone-absent ()
  "Covers the P0 quarantine seam.  Latch set, archive file present with a valid
archived task AND an untyped (quarantined) heading, shadow holds a SECOND
archived task absent from the file: the warned-parse gate withholds strict, so
the absent task is echoed rather than tombstoned despite no count shortfall."
  (let* ((root (make-temp-file "mw-arch-warn" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          ;; archive file: t2 present + an untyped heading (MW_ID intact, MW_TYPE
          ;; removed by a raw edit) that quarantines.
          (with-temp-file archive-file
            (insert (mindwtr-model-todo-keyword-line) "\n"
                    "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
                    "** ARCH Kept\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\n"
                    "** ARCH Mangled\n:PROPERTIES:\n:MW_ID: t3\n:END:\n"))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Absent" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z")
                     (:id "t2" :title "Kept" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z")
                     (:id "t3" :title "Mangled" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-latch 'archive)
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; warned parse -> strict withheld -> no tombstone for the absent t1
              (should-not (string-match-p "deletedAt" (or (mindwtr-test-server-last-put srv) ""))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-clean-archive-deletes-absent-archived ()
  "Covers R2 delete + the strict-mode sync-once derivation end-to-end.  Latch
set, archive file present and clean with one of two archived tasks, the other
deleted by the user (its heading removed): strict activates (no shortfall, no
warning) and the PUT tombstones the removed task only."
  (let* ((root (make-temp-file "mw-arch-del" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (srv (mindwtr-test-server))
         (mindwtr-api-http-function (mindwtr-test-server-http srv)))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
          ;; archive file: only t2 remains; the user deleted t1's heading.
          (with-temp-file archive-file
            (insert (mindwtr-render-archive-appdata
                     '(:tasks ((:id "t2" :title "Kept" :status "archived"))
                       :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Deleted" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z")
                     (:id "t2" :title "Kept" :status "archived" :rev 2
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-latch 'archive)
          (with-current-buffer (find-file-noselect tasks-file)
            (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
              (should (plist-get res :ok))
              ;; t1 (removed from the archive file) is tombstoned...
              (should (string-match-p "\"id\":\"t1\"[^}]*\"deletedAt\"" (mindwtr-test-server-last-put srv)))
              ;; ...t2 (still present) is not deleted.
              (should-not (string-match-p "\"id\":\"t2\"[^}]*\"deletedAt\"" (mindwtr-test-server-last-put srv))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync-once-archive-save-failure-does-not-latch ()
  "Covers KTD5 partial-save.  When the archive surface's save fails, the cycle
reports :save-failed and the archive-migrated latch is NOT set -- so the next
cycle keeps strict OFF rather than reading the stale file as deletions.  The
main save can succeed independently; the archive failure alone withholds the
latch."
  (let* ((root (make-temp-file "mw-arch-sf" t))
         (tasks-file (expand-file-name "tasks.org" root))
         (archive-file (expand-file-name "mindwtr_archive.org" root))
         (mindwtr-shadow-directory (expand-file-name "shadow/" root))
         (mindwtr-file tasks-file)
         (mindwtr-archive-file nil)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (server-body
          (concat "{\"tasks\":[{\"id\":\"t1\",\"title\":\"Old task\","
                  "\"status\":\"archived\",\"rev\":2,"
                  "\"createdAt\":\"2026-01-01T00:00:00Z\","
                  "\"updatedAt\":\"2026-06-05T00:00:00Z\"}],"
                  "\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}"))
         (orig-save (symbol-function 'save-buffer))
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body server-body))))))
    (unwind-protect
        (progn
          (with-temp-file tasks-file
            (insert (mindwtr-render-appdata
                     '(:tasks ((:id "t1" :title "Old task" :status "done" :order 0))
                       :projects nil :sections nil :areas nil :settings nil))))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "Old task" :status "done" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-05T00:00:00Z"))
             :projects nil :sections nil :areas nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (should-not (mindwtr-shadow-latched-p 'archive))
          ;; Fail only the archive buffer's save; the main save succeeds.
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest args)
                       (if (and (buffer-file-name)
                                (string-match-p "mindwtr_archive" (buffer-file-name)))
                           (error "disk full")
                         (apply orig-save args)))))
            (with-current-buffer (find-file-noselect tasks-file)
              (let ((res (mindwtr-sync-once (current-buffer) "2026-06-06T00:00:00Z")))
                (should (plist-get res :save-failed))
                ;; The archive save failed -> latch withheld -> strict stays off.
                (should-not (mindwtr-shadow-latched-p 'archive))))))
      (mindwtr-test--kill-file-buffer tasks-file)
      (mindwtr-test--kill-file-buffer archive-file)
      (delete-directory root t))))

(ert-deftest mindwtr-sync--parse-surfaces-duplicate-id-surfaces-in-warnings ()
  "Covers the duplicate-id durability fix.  An id present in both surfaces keeps
the first (main) copy and records the dropped id in :duplicates and as a
:duplicate warning so the loss is visible in the sync report."
  (let* ((main (get-buffer-create " *mw-dup-main*"))
         (arch (get-buffer-create " *mw-dup-arch*")))
    (unwind-protect
        (progn
          (with-current-buffer main
            (let ((org-inhibit-startup t))
              (erase-buffer)
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
                      "** NEXT Dup\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: d1\n:END:\n")
              (org-mode)))
          (with-current-buffer arch
            (let ((org-inhibit-startup t))
              (erase-buffer)
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
                      "** ARCH Dup\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: d1\n:END:\n")
              (org-mode)))
          (let* ((surfaces (list (list :buffer main :kind 'main)
                                 (list :buffer arch :kind 'archive)))
                 (parsed (mindwtr-sync--parse-surfaces surfaces)))
            (should (member "d1" (plist-get parsed :duplicates)))
            (should (seq-find (lambda (w) (and (plist-get w :duplicate)
                                               (equal (plist-get w :id) "d1")))
                              (plist-get parsed :warnings)))
            ;; the kept copy is the main (first) surface's NEXT task
            (let ((task (car (plist-get (plist-get parsed :appdata) :tasks))))
              (should (equal (plist-get task :status) "next")))))
      (kill-buffer main)
      (kill-buffer arch))))

(ert-deftest mindwtr-sync--parse-surfaces-archive-resolves-main-areas ()
  "An archived task's `:CATEGORY:' resolves against the MAIN surface's area
headings.  Parsed alone, the archive file has no areas, `:areaId' dropped, and
the next sync pushed `areaId -> (empty)' to the server."
  (let ((main (get-buffer-create " *mw-area-main*"))
        (arch (get-buffer-create " *mw-area-arch*")))
    (unwind-protect
        (progn
          (with-current-buffer main
            (let ((org-inhibit-startup t))
              (erase-buffer)
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (org-mode)))
          (with-current-buffer arch
            (let ((org-inhibit-startup t))
              (erase-buffer)
              (insert (mindwtr-model-todo-keyword-line) "\n"
                      "* Archive\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: archive\n:END:\n"
                      "** ARCH Cancelled\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
                      ":CATEGORY: Work\n:END:\n")
              (org-mode)))
          (let* ((parsed (mindwtr-sync--parse-surfaces
                          (list (list :buffer main :kind 'main)
                                (list :buffer arch :kind 'archive))))
                 (task (car (plist-get (plist-get parsed :appdata) :tasks))))
            (should (equal (plist-get task :areaId) "a1"))))
      (kill-buffer main)
      (kill-buffer arch))))

;;; People sync (U4) ----------------------------------------------------------

(ert-deftest mindwtr-sync-key->kind-maps-people-to-person ()
  "The irregular plural :people maps to person, not `peopl' (KTD2)."
  (should (eq (mindwtr-sync--key->kind :people) 'person))
  ;; regular plurals unaffected
  (should (eq (mindwtr-sync--key->kind :tasks) 'task))
  (should (eq (mindwtr-sync--key->kind :areas) 'area)))

(ert-deftest mindwtr-sync-build-candidate-person-create ()
  "A person heading with no id/not in shadow is created: rev 1 + timestamps."
  (let* ((local '(:tasks nil :projects nil :sections nil :areas nil
                  :people ((:id nil :mw-kind person :name "Alex"))))
         (shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :people nil :settings nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1"
                                             "2026-06-01T00:00:00Z"))
         (p (car (plist-get cand :people))))
    (should (stringp (plist-get p :id)))
    (should (string= (plist-get p :name) "Alex"))
    (should (= (plist-get p :rev) 1))
    (should (string= (plist-get p :createdAt) "2026-06-01T00:00:00Z"))
    (should (string= (plist-get p :revBy) "dev-1"))))

(ert-deftest mindwtr-sync-build-candidate-person-update-bumps-rev ()
  "Editing a person's name classifies as update: rev incremented, content merged."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :people ((:id "pe1" :name "Alex" :rev 2 :createdAt "C"))
                   :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil
                  :people ((:id "pe1" :mw-kind person :name "Alexandra"))))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (p (car (plist-get cand :people))))
    (should (string= (plist-get p :name) "Alexandra"))
    (should (= (plist-get p :rev) 3))
    (should (string= (plist-get p :updatedAt) "NOW"))))

(ert-deftest mindwtr-sync-person-absence-is-pull-only-no-tombstone ()
  "Covers R4.  Removing a rendered person from the buffer echoes the shadow
person verbatim -- no :deletedAt is stamped (people deletion is pull-only)."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :people ((:id "pe1" :name "Alex" :rev 5 :createdAt "C"))
                   :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil :people nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (p (car (plist-get cand :people))))
    ;; echoed verbatim: present, unchanged rev, NO deletedAt
    (should p)
    (should (string= (plist-get p :name) "Alex"))
    (should (= (plist-get p :rev) 5))
    (should-not (plist-get p :deletedAt))))

(ert-deftest mindwtr-sync-first-upgrade-does-not-tombstone-people ()
  "Covers R5.  Shadow holds people but the (pre-upgrade) buffer has no People
container, so local parses none -> every person is echoed verbatim, none
tombstoned, so the first post-upgrade sync cannot lose server people."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :people ((:id "pe1" :name "Alex" :rev 1 :createdAt "C")
                            (:id "pe2" :name "Sam" :rev 1 :createdAt "C"))
                   :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil :people nil))
         (cand (mindwtr-sync-build-candidate local shadow "dev-1" "NOW"))
         (people (plist-get cand :people)))
    (should (= (length people) 2))
    (dolist (p people)
      (should-not (plist-get p :deletedAt)))))

(ert-deftest mindwtr-sync-person-stats-never-counts-absence-as-delete ()
  "A person absent from local never appears in the deleted stat (pull-only)."
  (let* ((shadow '(:tasks nil :projects nil :sections nil :areas nil
                   :people ((:id "pe1" :name "Alex" :rev 1 :createdAt "C"))
                   :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil :people nil))
         (stats (mindwtr-sync--stats local shadow)))
    (should (= (plist-get stats :deleted) 0))))

(ert-deftest mindwtr-sync-strip-internal-drops-clock-device-local-keys ()
  "The wire strip removes :mw-logbook-minutes and :mw-clock-synced (R3/KTD13)."
  (let* ((appdata '(:tasks ((:id "t1" :title "x" :status "next"
                             :mw-kind task :mw-logbook-minutes 90 :mw-clock-synced 60))
                    :projects nil :sections nil :areas nil :people nil :settings nil))
         (wire (mindwtr-sync--strip-internal-keys appdata))
         (task (car (plist-get wire :tasks))))
    (should-not (plist-member task :mw-logbook-minutes))
    (should-not (plist-member task :mw-clock-synced))
    (should-not (plist-member task :mw-kind))
    (should (string= (plist-get task :title) "x"))))

;;; Project task order (org sibling order -> :order) -------------------------

(defconst mindwtr-sync-test--order-shadow
  '(:tasks ((:id "t1" :title "a" :status "next" :projectId "p1" :rev 1 :order 0)
            (:id "t2" :title "b" :status "next" :projectId "p1" :rev 1 :order 5)
            (:id "t3" :title "c" :status "next" :projectId "p1" :rev 1 :order 9))
    :projects ((:id "p1" :title "P" :status "active" :rev 1 :order 0))
    :sections nil :areas nil :people nil :settings nil)
  "Three project tasks with sparse server orders (as the apps assign them).")

(defun mindwtr-sync-test--order-local (&rest ids)
  "A parsed-shape local AppData listing project p1's tasks in IDS order."
  (list :tasks (mapcar (lambda (id) (list :id id :title id :status "next" :projectId "p1"))
                       ids)
        :projects '((:id "p1" :title "P" :status "active"))
        :sections nil :areas nil :people nil))

(ert-deftest mindwtr-sync-order-plan-fixed-point-with-sparse-orders ()
  "Document order matching the shadow's sort yields no plan, whatever the values."
  (should-not (mindwtr-sync--order-plan
               (mindwtr-sync-test--order-local "t1" "t2" "t3")
               mindwtr-sync-test--order-shadow)))

(ert-deftest mindwtr-sync-order-plan-detects-a-move ()
  "Moving a heading re-indexes the group; unmoved leading tasks keep their value."
  (let ((plan (mindwtr-sync--order-plan
               (mindwtr-sync-test--order-local "t1" "t3" "t2")
               mindwtr-sync-test--order-shadow)))
    (should (equal (cdr (assoc "t3" plan)) 1))
    (should (equal (cdr (assoc "t2" plan)) 2))
    (should-not (assoc "t1" plan))))

(ert-deftest mindwtr-sync-order-plan-tie-break-follows-shadow-list-order ()
  "Tasks without :order render in server list order; swapping them still counts."
  (let ((shadow '(:tasks ((:id "t1" :title "a" :status "next" :projectId "p1" :rev 1)
                          (:id "t2" :title "b" :status "next" :projectId "p1" :rev 1))
                  :projects nil :sections nil :areas nil :people nil :settings nil)))
    (should-not (mindwtr-sync--order-plan
                 (mindwtr-sync-test--order-local "t1" "t2") shadow))
    (should (equal (mindwtr-sync--order-plan
                    (mindwtr-sync-test--order-local "t2" "t1") shadow)
                   '(("t1" . 1) ("t2" . 0))))))

(ert-deftest mindwtr-sync-order-plan-new-task-tail-vs-insertion ()
  "A new task appended is not a reorder; one inserted mid-sequence is."
  (should-not (mindwtr-sync--order-plan
               (mindwtr-sync-test--order-local "t1" "t2" "t3" "new")
               mindwtr-sync-test--order-shadow))
  (let ((plan (mindwtr-sync--order-plan
               (mindwtr-sync-test--order-local "t1" "new" "t2" "t3")
               mindwtr-sync-test--order-shadow)))
    (should (equal (cdr (assoc "new" plan)) 1))
    (should (equal (cdr (assoc "t2" plan)) 2))
    (should (equal (cdr (assoc "t3" plan)) 3))))

(ert-deftest mindwtr-sync-order-plan-skips-standalone-and-archived ()
  "Standalone tasks have no sibling sequence; archived ones live in another file."
  (let ((shadow '(:tasks ((:id "s1" :title "a" :status "next" :rev 1 :order 0)
                          (:id "s2" :title "b" :status "next" :rev 1 :order 1)
                          (:id "t1" :title "c" :status "next" :projectId "p1" :rev 1 :order 0)
                          (:id "t2" :title "d" :status "archived" :projectId "p1" :rev 1 :order 1))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
        (local '(:tasks ((:id "s2" :title "b" :status "next")
                         (:id "s1" :title "a" :status "next")
                         (:id "t2" :title "d" :status "archived" :projectId "p1")
                         (:id "t1" :title "c" :status "next" :projectId "p1"))
                 :projects nil :sections nil :areas nil :people nil)))
    (should-not (mindwtr-sync--order-plan local shadow))))

(ert-deftest mindwtr-sync-order-plan-groups-by-section ()
  "Tasks under a section form their own sequence, separate from the project's."
  (let ((shadow '(:tasks ((:id "t1" :title "a" :status "next" :projectId "p1" :rev 1 :order 0)
                          (:id "t2" :title "b" :status "next" :projectId "p1" :rev 1 :order 1)
                          (:id "u1" :title "c" :status "next" :sectionId "s1" :rev 1 :order 0)
                          (:id "u2" :title "d" :status "next" :sectionId "s1" :rev 1 :order 1))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
        (local '(:tasks ((:id "u2" :title "d" :status "next" :sectionId "s1")
                         (:id "u1" :title "c" :status "next" :sectionId "s1")
                         (:id "t1" :title "a" :status "next" :projectId "p1")
                         (:id "t2" :title "b" :status "next" :projectId "p1"))
                 :projects nil :sections nil :areas nil :people nil)))
    (should (equal (sort (copy-sequence (mindwtr-sync--order-plan local shadow))
                         (lambda (a b) (string< (car a) (car b))))
                   '(("u1" . 1) ("u2" . 0))))))

(ert-deftest mindwtr-sync-apply-order-plan-stamps-and-promotes ()
  "The plan writes :order/:orderNum and bumps an echoed task to an update."
  (let* ((shadow mindwtr-sync-test--order-shadow)
         (candidate (list :tasks (mapcar #'copy-sequence (plist-get shadow :tasks))))
         (tasks (plist-get (mindwtr-sync--apply-order-plan
                            candidate '(("t3" . 1) ("t2" . 2)) shadow "dev" "NOW")
                           :tasks)))
    (should (= (plist-get (nth 0 tasks) :rev) 1))
    (should (= (plist-get (nth 1 tasks) :order) 2))
    (should (= (plist-get (nth 1 tasks) :orderNum) 2))
    (should (= (plist-get (nth 1 tasks) :rev) 2))
    (should (string= (plist-get (nth 1 tasks) :revBy) "dev"))
    (should (= (plist-get (nth 2 tasks) :order) 1))))

(ert-deftest mindwtr-sync-full-cycle-pushes-project-task-reorder-then-noops ()
  "Moving a project task heading in org reaches the server as new :order
values, the rebuilt buffer keeps the moved order, and the next cycle is a
HEAD-only noop (no churn)."
  (let ((shadow mindwtr-sync-test--order-shadow))
    (mindwtr-test-with-sync-env
        (:server srv :initial shadow :shadow shadow :etag "v1")
      (with-temp-buffer
        (let ((org-inhibit-startup t))
          ;; Render with t3 ahead of t2: the org buffer as the user left it
          ;; after moving the heading (the parse never reads :order).
          (insert (mindwtr-render-appdata
                   '(:tasks ((:id "t1" :title "a" :status "next" :projectId "p1" :order 0)
                             (:id "t3" :title "c" :status "next" :projectId "p1" :order 1)
                             (:id "t2" :title "b" :status "next" :projectId "p1" :order 2))
                     :projects ((:id "p1" :title "P" :status "active" :order 0))
                     :sections nil :areas nil :people nil)))
          (org-mode))
        (let ((r1 (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
          (should (plist-get r1 :ok))
          (should-not (plist-get r1 :noop)))
        (let ((by-id (mindwtr-shadow-index (mindwtr-test-server-state srv) :tasks)))
          (should (= (plist-get (gethash "t1" by-id) :order) 0))
          (should (= (plist-get (gethash "t3" by-id) :order) 1))
          (should (= (plist-get (gethash "t2" by-id) :order) 2))
          (should (= (plist-get (gethash "t2" by-id) :orderNum) 2))
          (should (= (plist-get (gethash "t2" by-id) :rev) 2))
          (should (= (plist-get (gethash "t1" by-id) :rev) 1)))
        (goto-char (point-min))
        (should (< (progn (search-forward "NEXT c") (point))
                   (progn (search-forward "NEXT b") (point))))
        (setf (mindwtr-test-server-requests srv) nil)
        (should (plist-get (mindwtr-sync-once (current-buffer) "2026-06-01T00:01:00Z")
                           :noop))
        (should (equal (mindwtr-test-server-requests srv) '("HEAD")))))))

;;; U3: clock-time roll-up reconcile pass ------------------------------------

(ert-deftest mindwtr-sync-clock-new-first-run ()
  "clock-new with no shadow value and no baseline adds the full LOGBOOK sum."
  (let ((sidx (mindwtr-shadow-index
               '(:tasks ((:id "t1" :rev 1)) :projects nil :sections nil
                 :areas nil :people nil :settings nil) :tasks)))
    (should (= (mindwtr-sync--clock-new
                '(:id "t1" :mw-logbook-minutes 120) sidx) 120))))

(ert-deftest mindwtr-sync-clock-dirty-p ()
  "Dirty when the reconciled total differs from the shadow; clean at fixed point."
  (let ((s30 '(:tasks ((:id "t1" :rev 1 :timeSpentMinutes 30)) :projects nil
               :sections nil :areas nil :people nil :settings nil))
        (s90 '(:tasks ((:id "t1" :rev 1 :timeSpentMinutes 90)) :projects nil
               :sections nil :areas nil :people nil :settings nil)))
    (should (mindwtr-sync--clock-dirty-p
             '(:tasks ((:id "t1" :mw-clock-synced 0 :mw-logbook-minutes 60))) s30))
    (should-not (mindwtr-sync--clock-dirty-p
                 '(:tasks ((:id "t1" :mw-clock-synced 60 :mw-logbook-minutes 60))) s90))))

(ert-deftest mindwtr-sync-clock-reconcile-promotes-echo-to-update ()
  "new != S sets timeSpentMinutes and promotes an echoed task to an update (KTD2)."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :timeSpentMinutes 30))
                   :projects nil :sections nil :areas nil :people nil :settings nil))
         (local '(:tasks ((:id "t1" :mw-clock-synced 0 :mw-logbook-minutes 60))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
         (candidate (list :tasks (list (copy-sequence (car (plist-get shadow :tasks))))
                          :projects nil :sections nil :areas nil :people nil :settings nil))
         (task (car (plist-get (mindwtr-sync--apply-clock-reconcile
                                candidate local shadow "dev" "NOW") :tasks))))
    (should (= (plist-get task :timeSpentMinutes) 90))
    (should (= (plist-get task :rev) 4))
    (should (string= (plist-get task :updatedAt) "NOW"))
    (should (string= (plist-get task :revBy) "dev"))))

(ert-deftest mindwtr-sync-clock-reconcile-fixed-point-no-change ()
  "new == S leaves the echoed task untouched (no timeSpentMinutes churn, no rev bump)."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :timeSpentMinutes 90))
                   :projects nil :sections nil :areas nil :people nil :settings nil))
         (local '(:tasks ((:id "t1" :mw-clock-synced 60 :mw-logbook-minutes 60))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
         (candidate (list :tasks (list (copy-sequence (car (plist-get shadow :tasks))))
                          :projects nil :sections nil :areas nil :people nil :settings nil))
         (task (car (plist-get (mindwtr-sync--apply-clock-reconcile
                                candidate local shadow "dev" "NOW") :tasks))))
    (should (= (plist-get task :timeSpentMinutes) 90))
    (should (= (plist-get task :rev) 3))))

(ert-deftest mindwtr-sync-clock-reconcile-logbook-deleted-lowers-total ()
  "Deleting LOGBOOK entries (L<B) lowers timeSpentMinutes by exactly the removed amount."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :timeSpentMinutes 90))
                   :projects nil :sections nil :areas nil :people nil :settings nil))
         (local '(:tasks ((:id "t1" :mw-clock-synced 60 :mw-logbook-minutes 10))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
         (candidate (list :tasks (list (copy-sequence (car (plist-get shadow :tasks))))
                          :projects nil :sections nil :areas nil :people nil :settings nil))
         (task (car (plist-get (mindwtr-sync--apply-clock-reconcile
                                candidate local shadow "dev" "NOW") :tasks))))
    (should (= (plist-get task :timeSpentMinutes) 40))))

(ert-deftest mindwtr-sync-clock-reconcile-ignores-unscanned-task ()
  "A task absent from LOCAL (server-live, not parsed this cycle) is untouched (R9)."
  (let* ((shadow '(:tasks ((:id "t2" :title "x" :status "next" :rev 3 :timeSpentMinutes 30))
                   :projects nil :sections nil :areas nil :people nil :settings nil))
         (local '(:tasks nil :projects nil :sections nil :areas nil :people nil :settings nil))
         (candidate (list :tasks (list (copy-sequence (car (plist-get shadow :tasks))))
                          :projects nil :sections nil :areas nil :people nil :settings nil))
         (task (car (plist-get (mindwtr-sync--apply-clock-reconcile
                                candidate local shadow "dev" "NOW") :tasks))))
    (should (= (plist-get task :timeSpentMinutes) 30))
    (should (= (plist-get task :rev) 3))))

(ert-deftest mindwtr-sync-clock-overlay-stamps-baseline ()
  "Overlay stamps :mw-clock-synced=L on merged tasks in local; others untouched (KTD12)."
  (let* ((local '(:tasks ((:id "t1" :mw-logbook-minutes 60)
                          (:id "t2" :mw-logbook-minutes 0))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
         (merged (list :tasks (list '(:id "t1" :title "x") '(:id "t2" :title "y")
                                    '(:id "t3" :title "z"))
                       :projects nil :sections nil :areas nil :people nil :settings nil))
         (tasks (plist-get (mindwtr-sync--overlay-clock-baseline merged local) :tasks)))
    (should (= (plist-get (nth 0 tasks) :mw-clock-synced) 60))
    (should (= (plist-get (nth 1 tasks) :mw-clock-synced) 0))
    (should-not (plist-member (nth 2 tasks) :mw-clock-synced))))

;; --- Full-cycle integration ------------------------------------------------

(defmacro mindwtr-clock-sync-test--with (shadow-task buffer-text &rest body)
  "Run one `mindwtr-sync-once' over BUFFER-TEXT with SHADOW-TASK seeded.
Binds `put-body' (captured PUT wire JSON) and `res' (the sync result) for BODY.
GET echoes the PUT body; HEAD matches the shadow etag (v1)."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "mw-clk" t))
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
               ("GET" (list :status 200 :headers '(("ETag" . "v1"))
                            :body (or put-body "{}")))))))
     (unwind-protect
         (with-temp-buffer
           (let ((org-inhibit-startup t)) (insert ,buffer-text) (org-mode))
           (mindwtr-shadow-save (list :tasks (list ,shadow-task) :projects nil
                                      :sections nil :areas nil :people nil :settings nil))
           (mindwtr-shadow-set-etag "v1")
           (let ((res (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z"))) (ignore res) ,@body))
       (delete-directory dir t))))

(ert-deftest mindwtr-sync-clock-integration-outside-work-preserved ()
  "S=30, L=60, B=0 -> PUT timeSpentMinutes=90 despite a matching HEAD ETag
(clock-only change bypasses the noop gate, R8), and MW_CLOCK_SYNCED: 60 persists."
  (mindwtr-clock-sync-test--with
      '(:id "t1" :title "Task" :status "next" :rev 1 :timeSpentMinutes 30
        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U")
      "* NEXT Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n:LOGBOOK:\nCLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 11:00] =>  1:00\n:END:\n"
    (should-not (plist-get res :noop))
    (should (string-match-p "\"timeSpentMinutes\":90" put-body))
    (goto-char (point-min))
    (should (search-forward ":MW_CLOCK_SYNCED: 60" nil t))))

(ert-deftest mindwtr-sync-clock-integration-fixed-point-noop ()
  "At the fixed point (S=90, B=60, L=60) the cycle is a noop: no PUT, no churn."
  (mindwtr-clock-sync-test--with
      '(:id "t1" :title "Task" :status "next" :rev 1 :timeSpentMinutes 90
        :createdAt "2026-01-01T00:00:00Z" :updatedAt "U")
      "* NEXT Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:MW_CLOCK_SYNCED: 60\n:END:\n:LOGBOOK:\nCLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 11:00] =>  1:00\n:END:\n"
    (should (plist-get res :noop))
    (should-not put-body)))

(ert-deftest mindwtr-sync-clock-integration-two-cycle-persistence ()
  "The regression the design hinges on: cycle 1 persists MW_CLOCK_SYNCED to disk;
cycle 2 reads it back from disk and produces a noop (R5/KTD12)."
  (let* ((dir (make-temp-file "mw-clk2" t))
         (f (make-temp-file "mw-clk2-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (put-body nil) (put-count 0)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body) put-count (1+ put-count))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v1")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* NEXT Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
                    ":LOGBOOK:\nCLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 11:00] =>  1:00\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks ((:id "t1" :title "Task" :status "next" :rev 1
                                          :timeSpentMinutes 0 :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                                 :projects nil :sections nil :areas nil :people nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (let ((r1 (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
            (should-not (plist-get r1 :noop))
            (should (string-match-p "\"timeSpentMinutes\":60" put-body)))
          (should (= put-count 1))
          (should (string-match-p ":MW_CLOCK_SYNCED: 60"
                                  (with-temp-buffer (insert-file-contents f) (buffer-string))))
          (let ((r2 (mindwtr-sync-once (current-buffer) "2026-07-24T13:00:00Z")))
            (should (plist-get r2 :noop)))
          (should (= put-count 1)))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-clock-integration-baseline-not-advanced-on-failed-save ()
  "KTD4 residual: a buffer-save failure after a successful PUT leaves the on-disk
baseline un-advanced -- the server got timeSpentMinutes but the drawer did not."
  (let* ((dir (make-temp-file "mw-clkf" t))
         (f (make-temp-file "mw-clkf-org" nil ".org"))
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
              ("GET" (list :status 200 :headers '(("ETag" . "v1")) :body put-body))))))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (let ((org-inhibit-startup t))
            (insert "* NEXT Task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
                    ":LOGBOOK:\nCLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 11:00] =>  1:00\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks ((:id "t1" :title "Task" :status "next" :rev 1
                                          :timeSpentMinutes 0 :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                                 :projects nil :sections nil :areas nil :people nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (cl-letf (((symbol-function 'mindwtr-sync--save-buffer-quietly)
                     (lambda (&optional _) nil)))
            (let ((r (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
              (should (plist-get r :save-failed))
              (should (string-match-p "\"timeSpentMinutes\":60" put-body))))
          (should-not (string-match-p ":MW_CLOCK_SYNCED:"
                                      (with-temp-buffer (insert-file-contents f) (buffer-string)))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-clock-reconcile-no-double-bump-on-already-updated ()
  "A task already promoted to an update by build-candidate (a content edit) gets
its timeSpentMinutes set WITHOUT a second rev bump or clobbered updatedAt/revBy."
  (let* ((shadow '(:tasks ((:id "t1" :title "x" :status "next" :rev 3 :timeSpentMinutes 30))
                   :projects nil :sections nil :areas nil :people nil :settings nil))
         (local '(:tasks ((:id "t1" :mw-clock-synced 0 :mw-logbook-minutes 60))
                  :projects nil :sections nil :areas nil :people nil :settings nil))
         ;; candidate is a genuine update: rev already bumped to 4, updatedAt/revBy stamped.
         (candidate (list :tasks (list '(:id "t1" :title "edited" :status "next"
                                         :rev 4 :updatedAt "EDIT" :revBy "editdev"
                                         :timeSpentMinutes 30))
                          :projects nil :sections nil :areas nil :people nil :settings nil))
         (task (car (plist-get (mindwtr-sync--apply-clock-reconcile
                                candidate local shadow "dev" "NOW") :tasks))))
    (should (= (plist-get task :timeSpentMinutes) 90))
    (should (= (plist-get task :rev) 4))
    (should (string= (plist-get task :updatedAt) "EDIT"))
    (should (string= (plist-get task :revBy) "editdev"))))

;;; Async pipeline -------------------------------------------------------------
;; A callback-capable (2-argument) transport makes the engine suspend at each
;; network leg and resume from the leg's completion callback.  These tests
;; drive that transport by hand: each request is queued as (METHOD . CALLBACK)
;; and the test fires the callbacks itself, asserting what the engine did (and
;; did not do) between the legs.

(ert-deftest mindwtr-sync-once-async-defers-across-callbacks ()
  "The full cycle suspends at PUT and GET; the result is delivered only after
the last leg's callback fires, and by then the buffer is reconciled and the
shadow/etag persisted."
  (let* ((dir (make-temp-file "mw-async" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (remote (concat "{\"tasks\":[{\"id\":\"t9\",\"title\":\"from server\","
                         "\"status\":\"next\",\"rev\":1,"
                         "\"createdAt\":\"2026-06-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}],"
                         "\"projects\":[],\"sections\":[],"
                         "\"areas\":[{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],\"settings\":{}}"))
         (pending nil)                  ; queue of (METHOD . CALLBACK)
         (mindwtr-api-http-function
          (lambda (req cb) (push (cons (plist-get req :method) cb) pending)))
         result err done)
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          ;; Empty shadow => the local area is a create => local-dirty, so the
          ;; cycle goes straight to the PUT (no HEAD leg).
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas nil :settings nil))
          (mindwtr-sync-once-async (current-buffer) "2026-07-24T12:00:00Z"
                                   (lambda (r e) (setq done t result r err e)))
          ;; Suspended at the PUT: nothing delivered, buffer untouched.
          (should-not done)
          (should (equal (mapcar #'car pending) '("PUT")))
          (funcall (cdr (pop pending))
                   '(:status 200 :headers nil :body "{\"ok\":true}"))
          ;; Suspended at the GET.
          (should-not done)
          (should (equal (mapcar #'car pending) '("GET")))
          (funcall (cdr (pop pending))
                   (list :status 200 :headers '(("ETag" . "v2")) :body remote))
          ;; Now complete: result delivered, buffer reconciled, state persisted.
          (should done)
          (should-not err)
          (should (plist-get result :ok))
          (goto-char (point-min))
          (should (search-forward "from server" nil t))
          (should (equal (mindwtr-shadow-get-etag) "v2")))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-async-aborts-before-put-on-edit-during-head ()
  "A buffer edit that lands during the async HEAD gap aborts the cycle BEFORE
the PUT: the error is delivered through the callback, no PUT is ever issued,
and the shadow etag is untouched -- nothing was committed anywhere."
  (let* ((dir (make-temp-file "mw-async-abort" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (pending nil)
         (mindwtr-api-http-function
          (lambda (req cb) (push (cons (plist-get req :method) cb) pending)))
         result err done)
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          ;; Clean buffer vs shadow + a stored etag => the cycle leads with HEAD.
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (mindwtr-sync-once-async (current-buffer) "2026-07-24T12:00:00Z"
                                   (lambda (r e) (setq done t result r err e)))
          (should (equal (mapcar #'car pending) '("HEAD")))
          ;; The user types while the HEAD is in flight.
          (goto-char (point-max))
          (insert "edited\n")
          ;; Remote moved (etag mismatch) => the engine wants a full cycle, but
          ;; the pre-PUT tick guard must trip first.
          (funcall (cdr (pop pending))
                   '(:status 200 :headers (("ETag" . "v2")) :body ""))
          (should done)
          (should-not result)
          (should err)
          (should (string-match-p "changed during sync" (error-message-string err)))
          (should (null pending))       ; no PUT was issued
          (should (equal (mindwtr-shadow-get-etag) "v1")))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-once-signals-on-pending-async-transport ()
  "The synchronous wrapper never blocks: a transport that defers makes it
signal immediately instead of spinning."
  (let* ((dir (make-temp-file "mw-async-sync" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-api-base-url "https://mw.example/")
         (mindwtr-api-token "x")
         (mindwtr-api-http-function (lambda (_req _cb) nil)))
    (unwind-protect
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
            (org-mode))
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas nil :settings nil))
          (should-error (mindwtr-sync-once (current-buffer) "2026-07-24T12:00:00Z")))
      (delete-directory dir t))))

(ert-deftest mindwtr-sync-echoes-project-tasksortby-verbatim ()
  "Server 1.2.0's project :taskSortBy is recognized-only: an org-side edit to
the project must carry the shadow's value through to the wire untouched, so
the app-configured sort survives an Emacs rename."
  (let* ((local '(:tasks nil
                  :projects ((:id "p1" :title "Renamed" :status "active"))
                  :sections nil :areas nil :people nil))
         (shadow '(:tasks nil
                   :projects ((:id "p1" :title "Old" :status "active"
                               :taskSortBy "due" :rev 3))
                   :sections nil :areas nil :people nil
                   :settings (:syncPreferences (:initialized t))))
         (cand (mindwtr-sync-build-candidate local shadow "dev"
                                             "2026-08-16T00:00:00Z"))
         (proj (car (plist-get cand :projects))))
    (should (equal (plist-get proj :title) "Renamed"))
    (should (equal (plist-get proj :taskSortBy) "due"))
    (should (= (plist-get proj :rev) 4))))

;; --- blank-title headings ----------------------------------------------------

(ert-deftest mindwtr-sync-new-blank-title-heading-is-quarantined-not-pushed ()
  "A new heading with no title never reaches the wire (the server rejects it
with a 400 and the whole sync used to fail).  The rest of the buffer syncs,
the heading is moved to * Sync Failures, and the report says so."
  (mindwtr-test-with-sync-env
      (:server srv
       :initial '(:tasks nil :projects nil :sections nil :areas nil :settings nil)
       :shadow '(:tasks nil :projects nil :sections nil :areas nil :settings nil)
       :etag "v1")
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
                "** INBOX Real one\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: real\n:END:\n"
                "** INBOX \n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: blank1\n:END:\n")
        (org-mode))
      (let* ((r (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z"))
             (put (mindwtr-util-json-decode (mindwtr-test-server-last-put srv)))
             (ids (mapcar (lambda (e) (plist-get e :id)) (plist-get put :tasks))))
        (should (plist-get r :ok))
        (should (equal ids '("real")))
        (should (= (plist-get (plist-get r :stats) :created) 1))
        (let ((w (seq-find (lambda (w) (plist-get w :blank-title)) (plist-get r :warnings))))
          (should w)
          (should (equal (plist-get w :id) "blank1"))
          (should (eq (plist-get w :blank-title) 'quarantined))))
      (goto-char (point-min))
      (should (search-forward "* Sync Failures" nil t))
      (should (search-forward ":MW_ID: blank1" nil t)))))

(ert-deftest mindwtr-sync-blanked-title-of-existing-task-keeps-shadow-title ()
  "Blanking an existing task's title is never an intentional clear (the
server would reject it): the shadow's title is kept, the task is not
re-pushed, and the report notes the kept title."
  (mindwtr-test-with-sync-env
      (:server srv
       :initial '(:tasks ((:id "t1" :title "Keep me" :status "inbox" :rev 1
                           :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                  :projects nil :sections nil :areas nil :settings nil)
       :shadow '(:tasks ((:id "t1" :title "Keep me" :status "inbox" :rev 1
                          :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
                 :projects nil :sections nil :areas nil :settings nil)
       :etag "v1")
    (with-temp-buffer
      (let ((org-inhibit-startup t))
        (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
                "** INBOX \n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
        (org-mode))
      (let ((r (mindwtr-sync-once (current-buffer) "2026-06-01T00:00:00Z")))
        (should (plist-get r :ok))
        (should (= (plist-get (plist-get r :stats) :updated) 0))
        (let ((w (seq-find (lambda (w) (plist-get w :blank-title)) (plist-get r :warnings))))
          (should w)
          (should (equal (plist-get w :id) "t1"))
          (should (eq (plist-get w :blank-title) 'kept))
          (should (equal (plist-get w :title) "Keep me"))))
      (should (string= (plist-get (car (plist-get (mindwtr-shadow-load) :tasks)) :title)
                       "Keep me"))
      ;; A HEAD-match noop leaves the buffer untouched (the report carries the
      ;; warning); a full cycle re-renders the kept title.  Either way nothing
      ;; is lost and no Sync Failures container appears.
      (goto-char (point-min))
      (should-not (search-forward "Sync Failures" nil t)))))
