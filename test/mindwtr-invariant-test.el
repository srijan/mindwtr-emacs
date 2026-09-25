;;; mindwtr-invariant-test.el --- Push invariants from STRATEGY.md -*- lexical-binding: t; -*-

;;; Commentary:
;; The two key metrics in STRATEGY.md, as offline gates:
;;
;;   No push without a local edit -- after pulling another client's change,
;;   the next sync proposes nothing.  The archived-area loss (PR #67) broke
;;   exactly this: an archive that arrived from the phone was rendered into the
;;   archive file, and the following sync pushed `areaId -> (empty)' with no
;;   edit on the desk.
;;
;;   Every pushed change traces to a local edit -- see the per-edit tests at
;;   the end of this file.
;;
;; Each case runs a real file-backed cycle (main file + archive surface)
;; against the in-memory server in `mindwtr-test-helpers'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'mindwtr)
(require 'mindwtr-sync)
(require 'mindwtr-render)
(require 'mindwtr-test-helpers)

(defconst mindwtr-invariant-test--base
  '(:areas ((:id "a1" :name "Work" :order 0 :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z")
            (:id "a2" :name "Home" :order 1 :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"))
    :projects ((:id "p1" :title "Launch" :status "active" :areaId "a1" :order 0
                :supportNotes "Why we launch." :rev 1
                :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"))
    :sections ((:id "s1" :title "Prep" :projectId "p1" :order 0 :rev 1
                :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"))
    :tasks ((:id "t1" :title "Draft plan" :status "next" :projectId "p1"
             :sectionId "s1" :order 0 :contexts ("@computer") :tags ("#deep")
             :description "See [the doc](https://example.com/doc)."
             :checklist ((:id "c1" :title "outline" :isCompleted t)
                         (:id "c2" :title "review" :isCompleted :false))
             :dueDate "2026-07-01" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z")
            (:id "t2" :title "Fix tap" :status "inbox" :areaId "a2" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z")
            (:id "t3" :title "Quote from Sam" :status "waiting" :assignedTo "Sam"
             :areaId "a1" :rev 1
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z")
            (:id "t4" :title "Old errand" :status "archived" :areaId "a2" :rev 1
             :completedAt "2026-02-01T00:00:00Z"
             :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-02-01T00:00:00Z"))
    :people ((:id "pe1" :name "Sam" :rev 1
              :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-01-01T00:00:00Z"))
    :settings (:syncPreferences (:initialized t)))
  "A synced state touching every surface and container the render emits.")

(defun mindwtr-invariant-test--wire (appdata)
  "APPDATA as it comes back over the wire (nil/false/[] normalized)."
  (mindwtr-util-json-decode (mindwtr-util-json-encode appdata)))

(defun mindwtr-invariant-test--remote-edit (appdata key id &rest changes)
  "Return APPDATA with entity ID under KEY changed by CHANGES, as the phone would.
A nil ID appends CHANGES as a new entity.  The edit bumps rev and stamps revBy."
  (let* ((new (copy-tree appdata))
         (stamp (list :revBy "phone" :updatedAt "2026-06-10T00:00:00Z")))
    (if (null id)
        (setq new (plist-put new key (append (plist-get new key)
                                             (list (append changes (list :rev 1) stamp)))))
      (setq new
            (plist-put new key
                       (mapcar (lambda (e)
                                 (if (not (equal (plist-get e :id) id)) e
                                   (let ((e (copy-sequence e)))
                                     (cl-loop for (k v) on changes by #'cddr
                                              do (setq e (plist-put e k v)))
                                     (setq e (plist-put e :rev (1+ (plist-get e :rev))))
                                     (cl-loop for (k v) on stamp by #'cddr
                                              do (setq e (plist-put e k v)))
                                     e)))
                               (plist-get new key)))))
    new))

(defmacro mindwtr-invariant-test--with-synced (spec &rest body)
  "Run BODY with the main file visited in a buffer, in step with the server.
SPEC is (SERVER-VAR) or (SERVER-VAR APPDATA).  The main and archive files
are rendered from APPDATA (default `mindwtr-invariant-test--base') and the
server, shadow and every migration latch agree with them, as after a long
run of clean syncs."
  (declare (indent 1))
  (let ((srv (car spec)) (appdata (or (cadr spec) 'mindwtr-invariant-test--base)))
    `(let* ((root (make-temp-file "mw-invariant" t))
            (mindwtr-file (expand-file-name "tasks.org" root))
            (mindwtr-archive-file nil)
            (state (mindwtr-invariant-test--wire ,appdata))
            (org-inhibit-startup t))
       (unwind-protect
           (mindwtr-test-with-sync-env
               (:server ,srv :initial state :shadow state :etag "v1"
                :latches '(notes fields archive cancel))
             (with-temp-file mindwtr-file
               (insert (mindwtr-render-appdata state)))
             (with-temp-file (mindwtr-archive-path)
               (insert (mindwtr-render-archive-appdata state)))
             (with-current-buffer (find-file-noselect mindwtr-file)
               ,@body))
         (mindwtr-test--kill-file-buffer mindwtr-file)
         (mindwtr-test--kill-file-buffer (expand-file-name "mindwtr_archive.org" root))
         (delete-directory root t)))))

(defun mindwtr-invariant-test--sync (srv)
  "Run one cycle; return (RESULT . METHODS) with the server's request log."
  (setf (mindwtr-test-server-requests srv) nil)
  (let ((r (mindwtr-sync-once (current-buffer) "2026-06-11T00:00:00Z")))
    (cons r (reverse (mindwtr-test-server-requests srv)))))

(defun mindwtr-invariant-test--proposed (result)
  "The changes RESULT says this device proposed, as (ID . FIELDS) pairs."
  (mapcar (lambda (c) (cons (plist-get c :id)
                            (sort (mapcar #'car (mindwtr-report--field-diff
                                                 (plist-get c :before)
                                                 (plist-get c :after)))
                                  #'string<)))
          (plist-get result :local-changes)))

;;; No push without a local edit

(ert-deftest mindwtr-invariant-fixture-is-in-step ()
  "The fixture itself is stable: syncing it with no change anywhere is a
HEAD-only noop.  Every other case below builds on this."
  (mindwtr-invariant-test--with-synced (srv)
    (let ((got (mindwtr-invariant-test--sync srv)))
      (should (plist-get (car got) :noop))
      (should (equal (cdr got) '("HEAD"))))))

(defconst mindwtr-invariant-test--remote-cases
  `(("archive a task that has an area (PR #67)"
     :tasks "t2" :status "archived" :completedAt "2026-06-10T00:00:00Z")
    ("archive a project task" :tasks "t1" :status "archived")
    ("un-archive a task" :tasks "t4" :status "next")
    ("complete a delegated task"
     :tasks "t3" :status "done" :completedAt "2026-06-10T00:00:00Z")
    ("move a task into a project section"
     :tasks "t2" :projectId "p1" :sectionId "s1" :areaId nil)
    ("edit a task's notes and checklist"
     :tasks "t1" :description "- first\n- [link](https://example.com)\n\nDone."
     :checklist ((:id "c1" :title "outline" :isCompleted t)
                 (:id "c2" :title "review" :isCompleted t)
                 (:id "c3" :title "ship" :isCompleted :false)))
    ("rename an area" :areas "a1" :name "Office")
    ("move a project to another area" :projects "p1" :areaId "a2")
    ("park a project" :projects "p1" :status "someday")
    ("cancel a task" :tasks "t3" :status "archived" :cancelledAt "2026-06-10T00:00:00Z")
    ("cancel a project" :projects "p1" :status "archived"
     :cancelledAt "2026-06-10T00:00:00Z")
    ("delete a task" :tasks "t3" :deletedAt "2026-06-10T00:00:00Z")
    ("capture a task with area and contexts" :tasks nil
     :id "t9" :title "Call the bank" :status "inbox" :areaId "a1"
     :contexts ("@phone") :createdAt "2026-06-10T00:00:00Z")
    ("add a person" :people nil
     :id "pe2" :name "Ana" :createdAt "2026-06-10T00:00:00Z"))
  "One change per case, made on another client: (LABEL KEY ID . CHANGES).")

(ert-deftest mindwtr-invariant-no-push-after-pulling-a-remote-change ()
  "After a change made on another client is pulled and rendered, the next
sync with no edit on the desk is a HEAD-only noop.  A case that fails names
the change and the fields this device tried to push."
  (dolist (case mindwtr-invariant-test--remote-cases)
    (mindwtr-invariant-test--with-synced (srv)
      (setf (mindwtr-test-server-state srv)
            (mindwtr-invariant-test--wire
             (apply #'mindwtr-invariant-test--remote-edit
                    (mindwtr-test-server-state srv) (cdr case)))
            (mindwtr-test-server-etag srv) "v2")
      (let ((pull (mindwtr-invariant-test--sync srv)))
        (should (plist-get (car pull) :ok))
        (should-not (plist-get (car pull) :noop)))
      (let ((idle (mindwtr-invariant-test--sync srv)))
        (should (equal (list (car case) (mindwtr-invariant-test--proposed (car idle))
                             (cdr idle))
                       (list (car case) nil '("HEAD"))))))))

;;; The report flag: a push nobody made is named, not hidden

(defun mindwtr-invariant-test--flag (result)
  "The ids RESULT flags as proposed with no local edit, or nil."
  (let ((w (seq-find (lambda (w) (plist-member w :no-local-edit))
                     (plist-get result :warnings))))
    (plist-get w :no-local-edit)))

(ert-deftest mindwtr-invariant-flags-a-push-with-no-local-edit ()
  "When a cycle proposes a change but no synced buffer was edited since the
last cycle, the result and the report name it -- the shape of the
archived-area loss, where the report showed an ordinary proposed change."
  (mindwtr-invariant-test--with-synced (srv)
    (should (plist-get (car (mindwtr-invariant-test--sync srv)) :noop))
    ;; Make the engine disagree with an untouched buffer, as a parse or
    ;; render bug would: the Shadow now says t2 has another title.
    (mindwtr-shadow-save
     (mindwtr-invariant-test--remote-edit (mindwtr-shadow-load) :tasks "t2"
                                          :title "Something else"))
    (let ((r (car (mindwtr-invariant-test--sync srv))))
      (should (equal (mindwtr-invariant-test--flag r) '("t2")))
      (with-current-buffer "*Mindwtr Sync Report*"
        (goto-char (point-min))
        (should (search-forward "proposed with no edit since the last sync" nil t))))))

(ert-deftest mindwtr-invariant-does-not-flag-a-real-edit ()
  "An edit made on the desk is pushed without the flag."
  (mindwtr-invariant-test--with-synced (srv)
    (should (plist-get (car (mindwtr-invariant-test--sync srv)) :noop))
    (goto-char (point-min))
    (search-forward "Fix tap")
    (replace-match "Fix the tap")
    (let ((r (car (mindwtr-invariant-test--sync srv))))
      (should (equal (mindwtr-invariant-test--proposed r) '(("t2" :title))))
      (should-not (mindwtr-invariant-test--flag r)))))

;;; Every pushed change traces to a local edit

(defun mindwtr-invariant-test--edit (srv title fn)
  "From a settled state, run FN on the heading titled TITLE, then sync.
Return the changes this device proposed, as (ID . FIELDS) sorted by id."
  (should (plist-get (car (mindwtr-invariant-test--sync srv)) :noop))
  (goto-char (point-min))
  (re-search-forward (format "^\\*+ [A-Z]+ %s$" (regexp-quote title)))
  (org-back-to-heading t)
  (funcall fn)
  (set-buffer (get-file-buffer mindwtr-file))
  (let ((r (car (mindwtr-invariant-test--sync srv))))
    (should (plist-get r :ok))
    (should-not (mindwtr-invariant-test--flag r))
    (sort (mindwtr-invariant-test--proposed r)
          (lambda (a b) (string< (car a) (car b))))))

(ert-deftest mindwtr-invariant-status-change-pushes-only-status ()
  "Moving a delegated task back to NEXT pushes its status and nothing else."
  (mindwtr-invariant-test--with-synced (srv)
    (should (equal (mindwtr-invariant-test--edit
                    srv "Quote from Sam"
                    (lambda ()
                      (cl-letf (((symbol-function 'mindwtr-commands--read-keyword)
                                 (lambda (&rest _) "NEXT")))
                        (mindwtr-set-status))))
                   '(("t3" :status))))))

(ert-deftest mindwtr-invariant-archive-pushes-only-status ()
  "Archiving a task that has an area pushes the archive and keeps the area --
the edit the archived-area loss (PR #67) turned into an area wipe."
  (mindwtr-invariant-test--with-synced (srv)
    (should (equal (mindwtr-invariant-test--edit
                    srv "Fix tap" #'mindwtr-archive-item-at-point)
                   '(("t2" :status))))))

(ert-deftest mindwtr-invariant-refile-pushes-only-containment ()
  "Refiling a standalone task into a project pushes the new project and the
cleared area (a task in a project has no area), nothing else."
  (mindwtr-invariant-test--with-synced (srv)
    (should (equal (mindwtr-invariant-test--edit
                    srv "Fix tap"
                    (lambda ()
                      (let ((target (save-excursion
                                      (goto-char (point-min))
                                      (re-search-forward "^\\*+ ACTIVE Launch$")
                                      (line-beginning-position))))
                        (org-refile nil nil (list "Launch" mindwtr-file nil target)))))
                   '(("t2" :areaId :projectId))))))

(ert-deftest mindwtr-invariant-clarify-outcome-pushes-only-its-fields ()
  "A clarify outcome (the two-minute quick action) pushes the done status and
its completion time, nothing else."
  (mindwtr-invariant-test--with-synced (srv)
    (should (equal (mindwtr-invariant-test--edit
                    srv "Fix tap"
                    (lambda ()
                      (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?q))
                                ((symbol-function 'sit-for) (lambda (&rest _) t)))
                        (mindwtr-clarify)
                        (with-current-buffer mindwtr-clarify--wip-buffer-name
                          (mindwtr-clarify-decide)))))
                   '(("t2" :completedAt :status))))))

(ert-deftest mindwtr-invariant-cancel-pushes-only-status-and-time ()
  "Cancelling a task pushes archived and its cancellation time, nothing else --
with org stamping CLOSED, and with `org-log-done' off (sync stamps it)."
  (dolist (log-done '(time nil))
    (mindwtr-invariant-test--with-synced (srv)
      (should (equal (mindwtr-invariant-test--edit
                      srv "Quote from Sam"
                      (lambda () (let ((org-log-done log-done)) (org-todo "CANCELLED"))))
                     '(("t3" :cancelledAt :status))))
      (let ((t3 (seq-find (lambda (e) (equal (plist-get e :id) "t3"))
                          (plist-get (mindwtr-test-server-state srv) :tasks))))
        (should (equal (plist-get t3 :status) "archived"))
        (should (stringp (plist-get t3 :cancelledAt)))))))

(defconst mindwtr-invariant-test--cancelled
  (mindwtr-invariant-test--remote-edit mindwtr-invariant-test--base :tasks "t4"
                                       :completedAt nil
                                       :cancelledAt "2026-02-01T08:00:00Z")
  "The base state with archived t4 cancelled rather than completed.")

(defun mindwtr-invariant-test--server-task (srv id)
  (seq-find (lambda (e) (equal (plist-get e :id) id))
            (plist-get (mindwtr-test-server-state srv) :tasks)))

(ert-deftest mindwtr-invariant-cancelled-without-closed-keeps-its-time ()
  "Deleting a cancelled item's CLOSED line is not an edit: sync keeps the
cancellation time it already had and renders the line back."
  (mindwtr-invariant-test--with-synced (srv mindwtr-invariant-test--cancelled)
    (with-current-buffer (mindwtr-archive-buffer)
      (goto-char (point-min))
      (re-search-forward "^\\*+ CANCELLED Old errand\n")
      (should (looking-at "CLOSED: .*\n"))
      (replace-match "")
      (save-buffer))
    (let ((r (mindwtr-invariant-test--sync srv)))
      (should (plist-get (car r) :noop)))))

(ert-deftest mindwtr-invariant-cancel-latch-protects-old-renders ()
  "Before the cancel latch is set, a cancelled item an older render showed as
plain ARCH (no cancellation) must not clear the server's cancellation; the
first full cycle renders CANCELLED and sets the latch."
  (mindwtr-invariant-test--with-synced (srv mindwtr-invariant-test--cancelled)
    (mindwtr-shadow--delete "cancel-migrated")
    (with-temp-file (mindwtr-archive-path)
      (insert (mindwtr-render-archive-appdata
               (mindwtr-invariant-test--remote-edit
                (mindwtr-test-server-state srv) :tasks "t4" :cancelledAt nil))))
    (should (plist-get (car (mindwtr-invariant-test--sync srv)) :ok))
    (should (equal (plist-get (mindwtr-invariant-test--server-task srv "t4") :cancelledAt)
                   "2026-02-01T08:00:00Z"))
    (should (memq 'cancel (mindwtr-shadow-latched-names)))
    (with-current-buffer (mindwtr-archive-buffer)
      (goto-char (point-min))
      (should (re-search-forward "^\\*+ CANCELLED Old errand$" nil t)))))

(provide 'mindwtr-invariant-test)
;;; mindwtr-invariant-test.el ends here
