;;; mindwtr-reconcile-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-reconcile)

(defun mindwtr-reconcile-test--show-children ()
  "Reveal the immediate child headings at point (cross-version test helper).
Mirrors the `mindwtr-reconcile--hide-subtree'/`--show-entry' wrappers so test
setup never inlines an `fboundp' fold branch of its own."
  (if (fboundp 'org-fold-show-children)
      (org-fold-show-children)
    (org-show-children)))

(ert-deftest mindwtr-reconcile-updates-existing-title ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT old title :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "new title" :status "next"
                             :areaId "a1" :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work" :rev 1)) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "new title" nil t))
      (should-not (save-excursion (search-forward "old title" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "done" :areaId "a1"
                             :rev 6 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "KEEPME" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "DONE" nil t))))))

(ert-deftest mindwtr-reconcile-removes-tombstoned ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT gone :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "gone" :status "next" :areaId "a1"
                             :deletedAt "2026-06-01T00:00:00Z" :rev 2))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should-not (search-forward "gone" nil t)))))

(ert-deftest mindwtr-reconcile-inserts-remote-new ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t2" :title "fresh" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-06-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "fresh" nil t)))))

(ert-deftest mindwtr-reconcile-update-reflects-new-deadline ()
  "A server-changed dueDate must appear on an EXISTING heading.
Regression: the partial in-place update left the old planning line in
place, so the next sync re-parsed the stale date and PUT it back,
silently reverting the remote edit."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\nDEADLINE: <2026-01-01 Thu>\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :contexts ("@x") :dueDate "2099-12-31"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "2099-12-31" nil t))
      ;; the old DEADLINE active timestamp must be gone (MW_CREATED keeps an
      ;; inactive [2026-01-01...], so match the active "<2026-01-01" form).
      (should-not (save-excursion (search-forward "<2026-01-01" nil t))))))

(ert-deftest mindwtr-reconcile-update-removes-dropped-schedule ()
  "When the server clears startTime, the SCHEDULED line is removed."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\nSCHEDULED: <2026-02-09 Mon>\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should-not (search-forward "SCHEDULED" nil t)))))

(ert-deftest mindwtr-reconcile-update-reflects-new-description ()
  "A server-changed description replaces the old prose on an existing heading."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "old body prose\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "fresh body prose"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "fresh body prose" nil t))
      (should-not (save-excursion (search-forward "old body prose" nil t))))))

(ert-deftest mindwtr-reconcile-update-reflects-new-checklist ()
  "A server-changed checklist replaces the old checkbox items."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "- [ ] one\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :checklist ((:title "one" :isCompleted t)
                                         (:title "two" :isCompleted :false))
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "- [X] one" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "- [ ] two" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-logbook-through-body-change ()
  "A full-content update keeps org-only drawers (LOGBOOK) while rewriting prose."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n"
              "stale prose\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "brand new prose"
                             :rev 7 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "KEEPME" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "brand new prose" nil t)))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "stale prose" nil t))))))

(ert-deftest mindwtr-reconcile-update-preserves-unknown-properties ()
  "An unknown PROPERTIES key survives a full-content update."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n"
              ":CUSTOM_KEY: keepme\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "renamed" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "keepme" nil t))))))

(defun mindwtr-reconcile-test--count (needle)
  "Return the number of occurrences of NEEDLE in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward needle nil t) (setq n (1+ n)))
      n)))

(ert-deftest mindwtr-reconcile-update-preserves-project-prose ()
  "Renaming a project carries its notes through the rebuild, emitted exactly
once.  Project notes now round-trip via :supportNotes (rendered by the sole
serializer), so the merged entity -- not a verbatim-preserved body -- is the
source of the prose, and render must not double-graft it with preserved-body."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "Important planning notes.\nSecond line.\n")
      (org-mode))
    (let ((merged '(:tasks nil
                    :projects ((:id "p1" :title "Renamed Proj" :status "active"
                                :areaId "a1" :supportNotes "Important planning notes.\nSecond line."
                                :rev 4 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "Renamed Proj")))
      ;; the note appears exactly once -- no double-graft from preserved-body
      (should (= 1 (mindwtr-reconcile-test--count "Important planning notes.")))
      (should (= 1 (mindwtr-reconcile-test--count "Second line.")))
      (should (= 0 (mindwtr-reconcile-test--count "ACTIVE Proj\n"))))))

(ert-deftest mindwtr-reconcile-project-logbook-and-notes-coexist ()
  "Covers R10 / AE3.  A project heading with a LOGBOOK drawer and notes: after a
rebuild the drawer survives intact and the notes (from :supportNotes) render
once -- the drawer is preserved org-only content, the prose is regenerated."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n"
              "Old note text.\n")
      (org-mode))
    (let ((merged '(:tasks nil
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :supportNotes "Updated note text."
                                :rev 4 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "KEEPME")))
      (should (= 1 (mindwtr-reconcile-test--count "Updated note text.")))
      ;; the stale buffer prose was replaced by the merged note, not duplicated
      (should (= 0 (mindwtr-reconcile-test--count "Old note text."))))))

(ert-deftest mindwtr-reconcile-area-body-preserved-verbatim ()
  "Regression: an area has no notes field, so its entire free-prose body is
still preserved verbatim across a rebuild (the area branch is unchanged)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Areas of Focus\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: areas\n:END:\n"
              "** Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "Free-form area reference notes.\n- [ ] even a checkbox\n")
      (org-mode))
    (let ((merged '(:tasks nil :projects nil :sections nil
                    :areas ((:id "a1" :name "Work" :rev 2
                             :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "Free-form area reference notes.")))
      (should (= 1 (mindwtr-reconcile-test--count "- [ ] even a checkbox"))))))

(ert-deftest mindwtr-reconcile-person-note-and-logbook-coexist ()
  "A person's :note round-trips through a rebuild emitted exactly once (the
merged entity is the prose source, so render must not double-graft it with
preserved-body), while a LOGBOOK drawer survives as org-only content."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* People\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: people\n:END:\n"
              "** Alex\n:PROPERTIES:\n:MW_TYPE: person\n:MW_ID: pe1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n"
              "Old note text.\n")
      (org-mode))
    (let ((merged '(:tasks nil :projects nil :sections nil :areas nil
                    :people ((:id "pe1" :name "Alexandra"
                              :note "Updated note text."
                              :referenceLink "https://example.com/a"
                              :rev 4 :createdAt "2026-01-01T00:00:00Z"
                              :updatedAt "2026-06-01T00:00:00Z"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "Alexandra")))
      (should (= 1 (mindwtr-reconcile-test--count "Updated note text.")))
      (should (= 1 (mindwtr-reconcile-test--count "KEEPME")))
      (should (= 1 (mindwtr-reconcile-test--count ":MW_REFERENCE_LINK: https://example.com/a")))
      ;; the stale buffer prose was replaced by the merged note, not duplicated
      (should (= 0 (mindwtr-reconcile-test--count "Old note text."))))))

(ert-deftest mindwtr-reconcile-project-note-no-double-graft-across-two-syncs ()
  "Covers R12 (no-double-graft).  Two reconciles in a row leave the project note
emitted exactly once.  After the first reconcile the note is in the buffer as
rendered prose; the second reconcile must NOT re-capture it as org-only and graft
a second copy -- preserved-body skips prose for note-bearing kinds, so the note
is re-rendered from the merged entity, not duplicated."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks nil
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :supportNotes "Persistent project note."
                                :rev 4 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "Persistent project note.")))
      (mindwtr-reconcile-buffer merged)
      (should (= 1 (mindwtr-reconcile-test--count "Persistent project note."))))))

(ert-deftest mindwtr-reconcile-growing-note-keeps-anchor-row ()
  "View-state regression: when a project note grows by several lines, the heading
the cursor was on returns to its exact prior screen row.  The :anchor-line
screen-row path (earlier PRs) re-derives the heading after the rebuild and
recenters, so it absorbs the body-length change from the inline note above it."
  (let ((buf (generate-new-buffer " *mw-note-reflow*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (let ((org-inhibit-startup t))
              (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
                      "** ACTIVE P1\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
                      "short note.\n"
                      "** ACTIVE P2\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p2\n:END:\n")
              (org-mode))
            (let ((win (get-buffer-window buf)))
              (skip-unless (window-live-p win))
              (set-window-start win (point-min))
              ;; cursor on P2, which sits below P1's note and would shift down
              ;; as the note grows if the row anchor did not absorb it.
              (mindwtr-heading-goto-key "p2")
              (let ((row-before (count-screen-lines (window-start win)
                                                    (line-beginning-position) nil win))
                    (merged '(:tasks nil
                              :projects ((:id "p1" :title "P1" :status "active"
                                          :supportNotes "line a\nline b\nline c\nline d\nline e"
                                          :order 0 :rev 2 :createdAt "2026-01-01T00:00:00Z"
                                          :updatedAt "2026-06-01T00:00:00Z")
                                         (:id "p2" :title "P2" :status "active" :order 1
                                          :rev 2 :createdAt "2026-01-01T00:00:00Z"
                                          :updatedAt "2026-06-01T00:00:00Z"))
                              :sections nil :areas nil :settings nil)))
                (mindwtr-reconcile-buffer merged)
                ;; P2 grew its distance from buffer top (5-line note vs 1) but its
                ;; SCREEN row is unchanged -- the anchor absorbed the reflow.
                (mindwtr-heading-goto-key "p2")
                (should (= row-before
                           (count-screen-lines (window-start win)
                                               (line-beginning-position) nil win)))))))
      (kill-buffer buf))))

(ert-deftest mindwtr-reconcile-update-preserves-bare-clock ()
  "A bare CLOCK line (org-clock-into-drawer disabled) survives a task rebuild."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "new prose"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "CLOCK: [2026-01-01 Thu 10:00]" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "new prose" nil t))))))

(ert-deftest mindwtr-reconcile-no-duplicate-when-logbook-precedes-properties ()
  "A heading whose LOGBOOK drawer sits ABOVE its PROPERTIES drawer is still
matched by id (no spurious duplicate insert)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:LOGBOOK:\n- note KEEPME\n:END:\n"
              ":PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "renamed" :status "next" :areaId "a1"
                             :rev 5 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      ;; exactly one task heading for t1 -- no duplicate appended
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^\\*\\* .* renamed$" nil t) (setq n (1+ n)))
        (should (= n 1))))))

(ert-deftest mindwtr-reconcile-keeps-running-clock-state ()
  "A running clock (`org-clock-in') keeps its markers pointing at the clocked
entry after a full buffer rebuild, so the user can still clock out.  The CLOCK
text is preserved as org-only body, but the in-memory clock markers must be
re-pointed at the rebuilt entry too (`erase-buffer' detaches them)."
  (require 'org-clock)
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT do a thing\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (search-forward "do a thing")
    (org-back-to-heading t)
    (let ((org-clock-into-drawer t) (org-log-into-drawer nil))
      (org-clock-in))
    (unwind-protect
        (let ((merged '(:tasks ((:id "t1" :title "do a thing" :status "next" :areaId "a1"
                                 :description "new prose"
                                 :rev 5 :createdAt "2026-01-01T00:00:00Z"
                                 :updatedAt "2026-06-01T00:00:00Z"))
                        :projects nil :sections nil
                        :areas ((:id "a1" :name "Work")) :settings nil)))
          (mindwtr-reconcile-buffer merged)
          ;; hd-marker still resolves to the t1 heading, not point-min garbage.
          (should (eq (marker-buffer org-clock-hd-marker) (current-buffer)))
          (should (string-match-p
                   "do a thing"
                   (save-excursion (goto-char org-clock-hd-marker)
                                   (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position)))))
          ;; clock-marker sits on the open CLOCK line (so org-clock-out lands there).
          (should (string-match-p
                   "^[ \t]*CLOCK: \\[[^]]*\\][ \t]*$"
                   (save-excursion (goto-char org-clock-marker)
                                   (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position))))))
      (when (org-clock-is-active) (org-clock-out nil t)))))

(ert-deftest mindwtr-reconcile-restore-entity-keeps-running-clock-state ()
  "The in-place single-heading rebuild (`mindwtr-reconcile-restore-entity', used
by the conflict-restore action) also keeps a running clock's markers pointing at
the entry -- insert + delete-region detaches them just like a full rebuild."
  (require 'org-clock)
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT theirs\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (search-forward "theirs")
    (org-back-to-heading t)
    (let ((org-clock-into-drawer t) (org-log-into-drawer nil))
      (org-clock-in))
    (unwind-protect
        (let ((mine '(:id "t1" :title "mine" :status "next" :areaId "a1"
                      :rev 9 :createdAt "2026-01-01T00:00:00Z"
                      :updatedAt "2026-06-01T00:00:00Z")))
          (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'restored))
          (should (eq (marker-buffer org-clock-hd-marker) (current-buffer)))
          (should (string-match-p
                   "mine"
                   (save-excursion (goto-char org-clock-hd-marker)
                                   (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position)))))
          (should (string-match-p
                   "^[ \t]*CLOCK: \\[[^]]*\\][ \t]*$"
                   (save-excursion (goto-char org-clock-marker)
                                   (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position))))))
      (when (org-clock-is-active) (org-clock-out nil t)))))

(ert-deftest mindwtr-reconcile-restore-entity-keeps-external-buffer-markers-valid ()
  "The in-place conflict-restore rebuild also keeps a marker another buffer
holds onto the rebuilt entry -- an open `org-agenda' line, say -- resolving to
that entry, instead of drifting onto the following heading.  `insert'+
`delete-region' moved an insertion-type-t marker off the entry; `org-agenda'
markers carry that insertion type (`org-agenda-new-marker'), so reproduce it."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT first\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "** NEXT second\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\n")
      (org-mode))
    (goto-char (point-min))
    (search-forward "first")
    (org-back-to-heading t)
    (let ((agenda-marker (copy-marker (point) t))
          (mine '(:id "t1" :title "first edited" :status "next" :areaId "a1"
                  :rev 9 :createdAt "2026-01-01T00:00:00Z"
                  :updatedAt "2026-06-01T00:00:00Z")))
      (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'restored))
      (should (equal (org-with-point-at agenda-marker (org-get-heading t t t t))
                     "first edited")))))

(ert-deftest mindwtr-reconcile-keeps-external-buffer-markers-valid ()
  "A marker another buffer holds into a task -- e.g. an open `org-agenda' line --
still resolves to that task after a full buffer rebuild, instead of collapsing
to the file's trailing heading.  The canonical layout ends with `Areas of
Focus', so a marker destroyed by the rebuild (`erase-buffer'+`insert' moved
every live marker to point-max) sent agenda clock-in/schedule to the last area
heading.  `org-agenda' markers carry insertion-type t (`org-agenda-new-marker'),
so reproduce that here."
  (let ((appdata '(:areas ((:id "a1" :name "Work"))
                   :projects nil :sections nil
                   :tasks ((:id "t1" :title "Send the report" :status "next"
                            :areaId "a1" :rev 5
                            :createdAt "2026-01-01T00:00:00Z"
                            :updatedAt "2026-06-01T00:00:00Z"))
                   :settings nil)))
    (with-temp-buffer
      (let ((org-inhibit-startup t)
            (org-todo-keywords mindwtr-model-todo-keywords))
        (insert (mindwtr-render-appdata appdata))
        (org-mode))
      (goto-char (point-min))
      (search-forward "Send the report")
      (org-back-to-heading t)
      (let ((agenda-marker (copy-marker (point) t)))
        (mindwtr-reconcile-buffer appdata)
        (should (equal (org-with-point-at agenda-marker
                         (org-get-heading t t t t))
                       "Send the report"))))))

(ert-deftest mindwtr-reconcile-restore-roundtrips-field-edit ()
  "Restoring a simple field edit reproduces it exactly -> `restored'."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT theirs\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((mine '(:id "t1" :title "mine" :status "next" :areaId "a1"
                  :rev 9 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z")))
      (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'restored))
      (goto-char (point-min))
      (should (search-forward "mine" nil t)))))

(ert-deftest mindwtr-reconcile-restore-refile-is-partial ()
  "Restoring a refile (containment) edit cannot move the heading in place,
so it must report `partial' (honest) rather than falsely claim success."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE PA\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: pA\n:END:\n"
              "** ACTIVE PB\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: pB\n:END:\n"
              "*** NEXT thing\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    ;; the task currently sits under pB; the lost edit moved it to pA
    (let ((mine '(:id "t1" :title "thing" :status "next" :projectId "pA"
                  :rev 9 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z")))
      (should (eq (mindwtr-reconcile-restore-entity mine 'task) 'partial)))))

(ert-deftest mindwtr-reconcile-restore-missing-heading-returns-nil ()
  "Restoring an entity that is no longer in the buffer (remote delete) is nil."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
      (org-mode))
    (should (null (mindwtr-reconcile-restore-entity
                   '(:id "gone" :title "x" :status "next") 'task)))))

(ert-deftest mindwtr-reconcile-builds-list-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas ((:id "a1" :name "Personal" :order 0))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"))
                    :sections nil
                    :tasks ((:id "t1" :title "loose next" :status "next")
                            (:id "t2" :title "child" :status "next" :projectId "p1"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "* Single Actions" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "loose next" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Projects" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "child" nil t)))
      (should (save-excursion (goto-char (point-min)) (search-forward "* Areas of Focus" nil t))))))

(ert-deftest mindwtr-reconcile-preserves-logbook-into-new-layout ()
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      ;; an existing buffer (any layout) with a LOGBOOK under task t1
      (insert "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              ":LOGBOOK:\n- note KEEPME\n:END:\n")
      (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "renamed" :status "next"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "renamed" nil t))
      (should (save-excursion (goto-char (point-min)) (search-forward "KEEPME" nil t))))))

(ert-deftest mindwtr-reconcile-archived-not-rendered ()
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert "") (org-mode))
    (let ((merged '(:areas nil :projects nil :sections nil
                    :tasks ((:id "t1" :title "keep me" :status "next")
                            (:id "t2" :title "archived one" :status "archived"))
                    :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "keep me" nil t))
      (should-not (save-excursion (goto-char (point-min)) (search-forward "archived one" nil t))))))

(ert-deftest mindwtr-reconcile-low-priority-does-not-crash ()
  "Updating a task to :priority \"low\" writes [#D] without erroring."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :priority "low"
                             :areaId "a1" :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "[#D]" nil t)))))

;;; View-state preservation across reconcile -- fold state (U1)

(ert-deftest mindwtr-reconcile-keeps-folded-heading-folded ()
  "R1: a folded entity heading stays folded after a reconcile that changes
an unrelated entity.  Detection asserts via `org-invisible-p' so the test
runs identically on Org 9.5 and 9.8."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT task one\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "body of one\n"
              "** NEXT task two\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\n")
      (org-mode))
    (mindwtr-heading-goto-key "t1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position))) ; sanity: folded before
    (let ((merged '(:tasks ((:id "t1" :title "task one" :status "next" :areaId "a1"
                             :description "body of one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z")
                            (:id "t2" :title "task two RENAMED" :status "next" :areaId "a1"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (search-forward "task two RENAMED" nil t)) ; the unrelated change landed
      (mindwtr-heading-goto-key "t1")
      (should (org-invisible-p (line-end-position)))))) ; still folded after

(ert-deftest mindwtr-reconcile-keeps-unfolded-heading-unfolded ()
  "R1: an unfolded heading is still unfolded after reconcile (no over-folding)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT task one\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "body of one\n")
      (org-mode))
    ;; leave everything unfolded
    (let ((merged '(:tasks ((:id "t1" :title "task one" :status "next" :areaId "a1"
                             :description "body of one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-heading-goto-key "t1")
      (should-not (org-invisible-p (line-end-position))))))

(ert-deftest mindwtr-reconcile-fold-follows-status-relocation ()
  "R6: a folded task that changes bucket (loose next -> under a project) is
folded again in its new location, because fold state is keyed by MW_ID."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT relocate me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "some body\n")
      (org-mode))
    (mindwtr-heading-goto-key "t1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position)))
    (let ((merged '(:tasks ((:id "t1" :title "relocate me" :status "next" :projectId "p1"
                             :description "some body"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :rev 1 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-heading-goto-key "t1")
      ;; it now lives under the project subtree; still folded
      (should (org-invisible-p (line-end-position))))))

(ert-deftest mindwtr-reconcile-restore-view-no-window-no-error ()
  "R4: reconcile completes without error with no live window (batch path) even
after folding, and the buffer is correctly rebuilt -- proves the
`condition-case' guard and the no-window path do not break the sync."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-heading-goto-key "t1")
    (mindwtr-reconcile--hide-subtree)
    (let ((merged '(:tasks ((:id "t1" :title "renamed t" :status "next" :areaId "a1"
                             :rev 2 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (goto-char (point-min))
      (should (search-forward "renamed t" nil t)))))

(ert-deftest mindwtr-reconcile-folded-ancestor-does-not-error ()
  "Edge: a child entity hidden under a folded ancestor -- reconcile does not
error, and the ancestor's own fold state is preserved (documents the known
ancestor-skip limitation: only the ancestor's record drives restoration)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** ACTIVE Proj\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n"
              "*** NEXT child\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"
              "child body\n")
      (org-mode))
    ;; fold the ancestor (project); the child is hidden only because of it
    (mindwtr-heading-goto-key "p1")
    (mindwtr-reconcile--hide-subtree)
    (should (org-invisible-p (line-end-position)))
    (let ((merged '(:tasks ((:id "t1" :title "child" :status "next" :projectId "p1"
                             :description "child body"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects ((:id "p1" :title "Proj" :status "active" :areaId "a1"
                                :rev 1 :createdAt "2026-01-01T00:00:00Z"
                                :updatedAt "2026-06-01T00:00:00Z"))
                    :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (mindwtr-heading-goto-key "p1")
      (should (org-invisible-p (line-end-position)))))) ; ancestor still folded

;;; View-state preservation -- global cycle state + scroll anchor (U2)

(ert-deftest mindwtr-reconcile-overview-state-stays-collapsed ()
  "R2: an overview-collapsed buffer comes back collapsed -- restored precisely
per heading (containers keyed by MW_LIST), with no `org-overview' backdrop.
Each top-level container heading stays visible but folded, and the task under
it stays hidden, faithfully reproducing overview without a backdrop call."
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "deep task" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      ;; Render the canonical layout, then collapse it to overview.
      (mindwtr-reconcile-buffer merged)
      (org-overview)
      ;; Sync again: the overview state is snapshotted and must be reproduced.
      (mindwtr-reconcile-buffer merged)
      ;; the container heading stays visible but folded...
      (goto-char (point-min))
      (should (re-search-forward "^\\* Single Actions" nil t))
      (beginning-of-line)
      (should-not (org-invisible-p (line-beginning-position)))
      (should (org-invisible-p (line-end-position)))
      ;; ...and the task under it stays hidden.
      (mindwtr-heading-goto-key "t1")
      (should (org-invisible-p (line-beginning-position))))))

(ert-deftest mindwtr-reconcile-contents-state-preserved-per-heading ()
  "R2: a `contents' fold (bodies hidden, sub-headings shown) is preserved
precisely per heading -- the ancestor's body is re-hidden via `--hide-entry'
so its child heading stays visible, and the child's own body stays folded.
The old code reproduced this with an `org-content' backdrop; this proves the
no-backdrop path keeps the child heading from collapsing."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\nwork note\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n")
      (org-mode))
    (org-content)
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :description "body"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      ;; the ancestor's child heading remained visible (not collapsed)
      (mindwtr-heading-goto-key "t1")
      (should-not (org-invisible-p (line-beginning-position))) ; heading visible
      (should (org-invisible-p (line-end-position))))))        ; body folded

(ert-deftest mindwtr-reconcile-restores-mixed-fold-state ()
  "R1 + R2: a mixed fold state round-trips precisely with no backdrop.  Work
shows its children (bodies folded); the user expands t1's body but leaves t2
folded.  After reconcile t1's body is shown and t2's stays collapsed -- each
heading restored from its own recorded state."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t1\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody one\n"
              "** NEXT t2\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\nbody two\n")
      (org-mode))
    (org-overview)
    ;; reveal Work's immediate children (t1/t2 headings show, bodies folded)
    (mindwtr-heading-goto-key "a1")
    (mindwtr-reconcile-test--show-children)
    ;; user expands t1's body only; t2 stays folded
    (mindwtr-heading-goto-key "t1")
    (mindwtr-reconcile--show-entry)
    (let ((merged '(:tasks ((:id "t1" :title "t1" :status "next" :areaId "a1"
                             :description "body one"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z")
                            (:id "t2" :title "t2" :status "next" :areaId "a1"
                             :description "body two"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged)
      (mindwtr-heading-goto-key "t1")
      (should-not (org-invisible-p (line-end-position))) ; reopened
      (mindwtr-heading-goto-key "t2")
      (should (org-invisible-p (line-end-position)))))) ; still folded

(ert-deftest mindwtr-reconcile-no-window-skips-scroll-anchor ()
  "R3: with no live window both scroll anchors (:top-id and :anchor-line) are
nil and reconcile restores without attempting (or erroring on) a window scroll."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((snap (mindwtr-reconcile--snapshot-view)))
      (should (null (plist-get snap :top-id)))
      (should (null (plist-get snap :anchor-line))))
    (let ((merged '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (mindwtr-reconcile-buffer merged) ; must not signal
      (goto-char (point-min))
      (should (search-forward "* Single Actions" nil t)))))

(ert-deftest mindwtr-reconcile-restore-view-tolerates-unresolved-anchor ()
  "R4: restoring a snapshot whose :top-id and some recorded keys no longer
resolve after the rebuild does not throw, and a still-resolving recorded fold
is applied -- proving restore ran to completion past the unresolved entry
rather than being swallowed at the start."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((view (list :folds (let ((h (make-hash-table :test 'equal)))
                               (puthash "ghost" 'folded h)
                               (puthash "single-actions" 'folded h) h)
                      :top-id "ghost" :anchor-line nil)))
      (should (null (mindwtr-reconcile--restore-view view))) ; no throw
      (goto-char (point-min))
      (should-not (org-invisible-p (line-beginning-position))) ; container line shown
      (mindwtr-heading-goto-key "t1")
      (should (org-invisible-p (line-beginning-position)))))) ; folded under container

(ert-deftest mindwtr-reconcile-restore-view-preserves-modified-flag ()
  "R5: restore touches only visual state (fold overlays), so it must not flip
`buffer-modified-p' -- folding an entry happens, yet the buffer stays clean."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
              "** NEXT t\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n")
      (org-mode))
    (set-buffer-modified-p nil)
    (let ((view (list :folds (let ((h (make-hash-table :test 'equal)))
                               (puthash "t1" 'folded h) h)
                      :top-id nil :anchor-line nil)))
      (mindwtr-reconcile--restore-view view)
      (mindwtr-heading-goto-key "t1")
      (should (org-invisible-p (line-end-position))) ; the fold was applied
      (should-not (buffer-modified-p)))))            ; but the flag is untouched

(ert-deftest mindwtr-reconcile-windowed-recenter-anchors-heading-row ()
  "R1/R2: the recenter branch returns point's heading to the recorded screen row
in a live window.  `count-screen-lines' (snapshot) and `recenter' (restore) use
the same 0-based row index, so a captured N round-trips to N.  Validated at the
`--restore-view' level -- deterministic in -Q batch (a displayed buffer yields a
live window and `recenter' moves `window-start' predictably, verified below).
Full reconcile-buffer recenter is verified manually per the plan's batch-window
determinism note."
  (let ((buf (generate-new-buffer " *mw-recenter*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (dotimes (i 8)
                (insert (format (concat "** NEXT t%d\n:PROPERTIES:\n:MW_TYPE: task\n"
                                        ":MW_ID: id%d\n:END:\nbody %d\n")
                                i i i)))
              (org-mode))
            (let ((win (get-buffer-window buf)))
              (skip-unless (window-live-p win))
              (set-window-start win (point-min))
              ;; point on the at-id heading, as reconcile-buffer leaves it
              (mindwtr-heading-goto-key "id3")
              ;; anchor-line non-nil -> recenter branch (no :top-id needed)
              (should (null (mindwtr-reconcile--restore-view (list :anchor-line 4))))
              (should (= 4 (count-screen-lines (window-start win)
                                               (line-beginning-position) nil win))))))
      (kill-buffer buf))))

(ert-deftest mindwtr-reconcile-recenter-uses-buffer-point-not-stale-window-point ()
  "R1 regression: a background sync fires while the buffer's window is NOT the
selected window.  Selecting it resets buffer point to that window's OWN stored
window-point -- stale, since reconcile set buffer point while the window was
unselected -- so restore must re-assert the `at-id' heading before recentering.
Without that, `recenter' would center on the stale point, not the heading."
  (let ((buf (generate-new-buffer " *mw-recenter-bg*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer buf
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (dotimes (i 8)
                (insert (format (concat "** NEXT t%d\n:PROPERTIES:\n:MW_TYPE: task\n"
                                        ":MW_ID: id%d\n:END:\nbody %d\n")
                                i i i)))
              (org-mode)))
          ;; Display buf in a window that is NOT the selected one.
          (let ((win (split-window (selected-window))))
            (set-window-buffer win buf)
            (skip-unless (and (window-live-p win) (not (eq win (selected-window)))))
            (with-current-buffer buf
              (set-window-start win (point-min))
              (set-window-point win (point-min)) ; stale window-point at the top
              ;; reconcile sets BUFFER point to the at-id heading (window unselected)
              (mindwtr-heading-goto-key "id3")
              (should (null (mindwtr-reconcile--restore-view (list :anchor-line 4))))
              ;; the id3 heading -- not the stale top -- sits at row 4
              (with-selected-window win
                (should (= 4 (count-screen-lines (window-start win)
                                                 (line-beginning-position) nil win)))))))
      (kill-buffer buf))))

(ert-deftest mindwtr-reconcile-windowed-offscreen-anchor-uses-top-id ()
  "R2b: when point's anchor heading is above `window-start' (a background sync
fired after the user scrolled away), snapshot records :anchor-line nil and a
non-nil :top-id, and restore anchors the window via the :top-id
`set-window-start' fallback -- it does NOT recenter on the off-screen point."
  (let ((buf (generate-new-buffer " *mw-offscreen*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (let ((org-inhibit-startup t))
              (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n")
              (dotimes (i 8)
                (insert (format (concat "** NEXT t%d\n:PROPERTIES:\n:MW_TYPE: task\n"
                                        ":MW_ID: id%d\n:END:\nbody %d\n")
                                i i i)))
              (org-mode))
            (let ((win (get-buffer-window buf)))
              (skip-unless (window-live-p win))
              ;; scroll so id5's BODY is the viewport top: :top-id resolves to the
              ;; next heading forward (id6), distinct from the initial start, so a
              ;; successful fallback visibly moves `window-start'.
              (mindwtr-heading-goto-key "id5")
              (forward-line 5)            ; onto id5's body line
              (set-window-start win (line-beginning-position))
              ;; point sits on id1, far above window-start -> off-screen anchor
              (mindwtr-heading-goto-key "id1")
              (let ((snap (mindwtr-reconcile--snapshot-view)))
                (should (null (plist-get snap :anchor-line)))  ; off-screen: no recenter
                (should (equal "id6" (plist-get snap :top-id))) ; viewport-top heading
                (should (null (mindwtr-reconcile--restore-view snap)))
                (save-excursion
                  (mindwtr-heading-goto-key "id6")
                  ;; window-start was moved by the :top-id fallback onto id6's line
                  (should (= (window-start win) (line-beginning-position))))))))
      (kill-buffer buf))))

(ert-deftest mindwtr-reconcile-deleted-anchor-does-not-jump-to-top ()
  "R1/R2b regression: when the entity the cursor is on is deleted by THIS sync,
`--goto-id at-id' fails and strands point at `point-min'.  The snapshot recorded
an :anchor-line for it (on-screen pre-rebuild), so `mindwtr-reconcile-buffer'
must drop that field, letting restore fall back to the :top-id window-start
anchor instead of recentering on the stranded point-min -- which would yank the
viewport to the buffer top, the very jump this change exists to prevent."
  (let ((buf (generate-new-buffer " *mw-deleted-anchor*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer buf
            (let ((org-inhibit-startup t))
              (insert "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
                      "** NEXT t1\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody1\n"
                      "** NEXT t2\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\nbody2\n"
                      "** NEXT t3\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t3\n:END:\nbody3\n")
              (org-mode)))
          (set-window-buffer (selected-window) buf)
          (let ((win (get-buffer-window buf)))
            (skip-unless (window-live-p win))
            (with-current-buffer buf
              ;; viewport top is t2 (survives the sync); cursor is on t3 (deleted)
              (mindwtr-heading-goto-key "t2")
              (set-window-start win (line-beginning-position))
              (mindwtr-heading-goto-key "t3")
              (let ((snap (mindwtr-reconcile--snapshot-view)))
                (should (plist-get snap :anchor-line))       ; t3 on-screen -> recorded
                (should (equal "t2" (plist-get snap :top-id)))) ; viewport-top anchor
              (mindwtr-reconcile-buffer
               '(:tasks ((:id "t1" :title "t1" :status "next" :areaId "a1"
                          :rev 1 :createdAt "2026-01-01T00:00:00Z"
                          :updatedAt "2026-06-01T00:00:00Z")
                         (:id "t2" :title "t2" :status "next" :areaId "a1"
                          :rev 1 :createdAt "2026-01-01T00:00:00Z"
                          :updatedAt "2026-06-01T00:00:00Z"))
                 :projects nil :sections nil
                 :areas ((:id "a1" :name "Work")) :settings nil))
              ;; t3 is gone, and the viewport did NOT collapse to the buffer top
              ;; (the surviving :top-id t2 renders well below point-min).
              (should (/= (window-start win) (point-min)))
              (should-not (mindwtr-heading-goto-key "t3")))))
      (kill-buffer buf))))

(ert-deftest mindwtr-reconcile-expanded-buffer-survives-repeated-sync ()
  "Regression (#22): a fully expanded buffer must NOT collapse after a sync,
even when `org-cycle-global-status' is a stale `overview' (the trap that made
the old `org-overview' backdrop fire).  And it must stay expanded across
consecutive syncs -- the old code degraded the buffer further each sync."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT deep task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n")
      (org-mode))
    ;; The buffer is fully expanded, but the global flag is stale at `overview'
    ;; (e.g. opened via `org-startup-folded' then TAB'd open) -- the exact
    ;; condition under which the old backdrop wrongly re-collapsed everything.
    (setq-local org-cycle-global-status 'overview)
    (let ((merged '(:tasks ((:id "t1" :title "deep task" :status "next" :areaId "a1"
                             :description "body"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil
                    :areas ((:id "a1" :name "Work")) :settings nil)))
      (dotimes (_ 2)
        (mindwtr-reconcile-buffer merged)
        (mindwtr-heading-goto-key "t1")
        (should-not (org-invisible-p (line-beginning-position)))   ; heading shown
        (should-not (org-invisible-p (line-end-position)))))))     ; body shown

(ert-deftest mindwtr-reconcile-folded-container-stays-folded-across-syncs ()
  "Regression (#22): a container the user folded stays folded -- keyed by its
stable MW_LIST role -- across consecutive syncs, while a sibling container the
user left open stays open.  No drift in either direction (the degrade loop)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** TODO captured\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\nbody\n"
              "* Single Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: single-actions\n:END:\n"
              "** NEXT sa\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t2\n:END:\nbody\n")
      (org-mode))
    ;; User folds Inbox only; Single Actions stays fully expanded.
    (goto-char (point-min))
    (re-search-forward "^\\* Inbox")
    (mindwtr-reconcile--hide-subtree)
    (let ((merged '(:tasks ((:id "t1" :title "captured" :status "inbox"
                             :description "body" :rev 1
                             :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z")
                            (:id "t2" :title "sa" :status "next"
                             :description "body" :rev 1
                             :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil :areas nil :settings nil)))
      (dotimes (_ 2)
        (mindwtr-reconcile-buffer merged)
        ;; Inbox's task stays hidden under the re-folded container...
        (mindwtr-heading-goto-key "t1")
        (should (org-invisible-p (line-beginning-position)))
        ;; ...while the open container's task stays fully shown.
        (mindwtr-heading-goto-key "t2")
        (should-not (org-invisible-p (line-beginning-position)))
        (should-not (org-invisible-p (line-end-position)))))))

;;; Point restoration -- entities and containers

(ert-deftest mindwtr-reconcile-id-at-point-falls-back-to-container-role ()
  "`--id-at-point' returns the MW_ID for an entity but the MW_LIST role when
point is on a container heading (no MW_ID), so the cursor location is a stable
key in both cases."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Projects\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: projects\n:END:\n"
              "** ACTIVE p\n:PROPERTIES:\n:MW_TYPE: project\n:MW_ID: p1\n:END:\n")
      (org-mode))
    ;; on the container heading -> its role
    (goto-char (point-min))
    (should (string= (mindwtr-reconcile--id-at-point) "projects"))
    ;; on the entity heading -> its id
    (mindwtr-heading-goto-key "p1")
    (should (string= (mindwtr-reconcile--id-at-point) "p1"))))

(ert-deftest mindwtr-reconcile-restores-point-on-container ()
  "Regression: with the cursor parked on a container heading (no MW_ID), the
rebuild keeps point on that container instead of dropping it to point-min."
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (org-mode))
    (let ((merged '(:tasks ((:id "t1" :title "captured" :status "inbox"
                             :rev 1 :createdAt "2026-01-01T00:00:00Z"
                             :updatedAt "2026-06-01T00:00:00Z"))
                    :projects nil :sections nil :areas nil :settings nil)))
      ;; Render the canonical layout, then park point on the Projects container.
      (mindwtr-reconcile-buffer merged)
      (goto-char (point-min))
      (should (re-search-forward "^\\* Projects" nil t))
      (beginning-of-line)
      (mindwtr-reconcile-buffer merged)
      ;; point landed back on the Projects container, not at point-min
      (should (org-at-heading-p))
      (should (string= (mindwtr-parse--prop "MW_LIST") "projects")))))

(ert-deftest mindwtr-reconcile-render-error-leaves-buffer-intact ()
  "If rendering the merged appdata errors, the buffer is NOT wiped.
Regression: erase-buffer ran before insert, so a bad server status
emptied the user's file."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Next Actions\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: next-actions\n:END:\n"
              "** NEXT keep me\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (let ((before (buffer-string))
          ;; a task with an unknown status under a project makes
          ;; mindwtr-render-appdata signal (project-subtree renders its child
          ;; tasks unconditionally, so status->keyword aborts on "bogus")
          (merged '(:areas nil :projects ((:id "p1" :title "P" :status "active"))
                    :sections nil
                    :tasks ((:id "t1" :title "x" :status "bogus" :projectId "p1"))
                    :settings nil)))
      (should-error (mindwtr-reconcile-buffer merged))
      ;; buffer content is unchanged -- nothing was erased
      (should (string= (buffer-string) before)))))

;;; Quarantine guard -- untyped/un-inferable headings (U2) -------------------

(defun mindwtr-reconcile-test--count (s)
  "Count literal occurrences of S in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0)) (while (search-forward s nil t) (setq n (1+ n))) n)))

(defconst mindwtr-reconcile-test--empty
  '(:tasks nil :projects nil :sections nil :areas nil :settings nil)
  "Merged appdata with no entities (renders only the canonical containers).")

(ert-deftest mindwtr-reconcile-quarantines-untyped-orphan ()
  "A top-level heading with no MW_TYPE and no inferable context is preserved
under a * Sync Failures container instead of being erased (R2)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray thought\n:PROPERTIES:\n:ID: xyz\n:END:\nremember this body\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray thought" nil t)))
    (should (save-excursion (goto-char (point-min)) (search-forward "remember this body" nil t)))))

(ert-deftest mindwtr-reconcile-quarantine-carries-annotation ()
  "Each quarantined heading carries a reason note so it is actionable (R2)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:ID: xyz\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (save-excursion (goto-char (point-min))
                            (search-forward "couldn't determine type" nil t)))))

(ert-deftest mindwtr-reconcile-quarantine-is-idempotent ()
  "Two reconciles with the same persistent orphan yield ONE container and ONE
copy of the orphan -- no nesting, no duplication (R3)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray thought\n:PROPERTIES:\n:ID: xyz\n:END:\nbody\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (= 1 (mindwtr-reconcile-test--count "Stray thought")))))

(ert-deftest mindwtr-reconcile-does-not-quarantine-inferable-heading ()
  "An untyped heading under a recognized container is inferable, so it is NOT
quarantined; the merged data renders it in its bucket and no container appears."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Inbox\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: inbox\n:END:\n"
              "** INBOX Captured\n:PROPERTIES:\n:ID: x\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "Captured" :status "inbox" :rev 1
                :createdAt "2026-06-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil :areas nil :settings nil))
    (should (= 0 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Captured" nil t)))))

(ert-deftest mindwtr-reconcile-clean-buffer-has-no-quarantine ()
  "A buffer of only typed entities reconciles with no * Sync Failures heading (R4)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
              "** NEXT t :@x:\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "t" :status "next" :areaId "a1" :contexts ("@x")
                :rev 5 :createdAt "2026-01-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil
       :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
    (should (= 0 (mindwtr-reconcile-test--count "Sync Failures")))))

(ert-deftest mindwtr-reconcile-collect-orphans-reads-current-buffer ()
  "Orphan collection reads the live buffer (so it runs before erase -- R7)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:ID: x\n:END:\nbody text\n")
      (org-mode))
    (let ((orphans (mindwtr-reconcile--collect-orphans)))
      (should (= 1 (length orphans)))
      (should (string-match-p "Stray" (car orphans)))
      (should (string-match-p "body text" (car orphans))))))

(ert-deftest mindwtr-reconcile-collect-orphans-unwraps-existing-quarantine ()
  "An existing * Sync Failures container is unwrapped: its children are
re-collected and the wrapper itself is discarded (R3, no-nesting)."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Sync Failures\n:PROPERTIES:\n:MW_TYPE: container\n:MW_LIST: sync-failures\n:END:\n"
              "** Stray child\n:PROPERTIES:\n:ID: x\n:END:\nbody\n")
      (org-mode))
    (let ((orphans (mindwtr-reconcile--collect-orphans)))
      (should (= 1 (length orphans)))
      (should (string-match-p "Stray child" (car orphans)))
      (should-not (string-match-p "Sync Failures" (car orphans))))))

(ert-deftest mindwtr-reconcile-quarantine-excludes-typed-descendants ()
  "A typed (real) entity nested under an untyped orphan is NOT swallowed into
the quarantine text -- it round-trips via the server and renders in its bucket
exactly once, with no duplicate MW_ID."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray note\n:PROPERTIES:\n:ID: xyz\n:END:\nnote body\n"
              "** NEXT Real task\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n")
      (org-mode))
    (mindwtr-reconcile-buffer
     '(:tasks ((:id "t1" :title "Real task" :status "next" :rev 1
                :createdAt "2026-06-01T00:00:00Z" :updatedAt "2026-06-01T00:00:00Z"))
       :projects nil :sections nil :areas nil :settings nil))
    ;; the orphan parent is preserved under quarantine...
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray note" nil t)))
    ;; ...but the typed task is NOT duplicated: it appears once (its bucket only)
    (should (= 1 (mindwtr-reconcile-test--count ":MW_ID: t1")))
    (should (= 1 (mindwtr-reconcile-test--count "Real task")))))

(ert-deftest mindwtr-reconcile-quarantines-blank-mw-type-orphan ()
  "A stray heading whose :MW_TYPE: value is blank (neither a real kind nor
inferable) is quarantined, not silently erased."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert "* Stray\n:PROPERTIES:\n:MW_TYPE:\n:END:\nbody\n")
      (org-mode))
    (mindwtr-reconcile-buffer mindwtr-reconcile-test--empty)
    (should (= 1 (mindwtr-reconcile-test--count "Sync Failures")))
    (should (save-excursion (goto-char (point-min)) (search-forward "Stray" nil t)))))
