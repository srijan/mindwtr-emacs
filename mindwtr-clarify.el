;;; mindwtr-clarify.el --- Guided inbox triage (clarify workflow) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; The org-gtd clarify/organize workflow, rebuilt on mindwtr's data model.
;; `mindwtr-clarify' walks the `* Inbox' items one at a time.  Each item is
;; copied into a dedicated WIP buffer (`mindwtr-clarify-mode', an org-mode
;; derivative) where it can be reworded and fleshed out freely -- the copy
;; in the synced buffer stays untouched until a decision is made.  `C-c C-c'
;; then asks the one clarify question -- what IS this thing? -- with the GTD
;; flowchart's leaf outcomes as the answers:
;;
;;   q  quick action: already done (the two-minute rule) -> DONE
;;   n  next action -> NEXT, into Single Actions
;;   d  delegate -> who + check-in date -> WAIT
;;   t  tickler: defer to a date (incl. calendar items) -> NEXT + SCHEDULED
;;   p  new project (`mindwtr-promote-to-project'; the task keeps its MW_ID)
;;   a  add to an existing project (native `org-refile', project targets)
;;   s  someday/maybe -> SOMEDAY
;;   r  reference -> REF
;;   x  trash -> ARCH (dropped from the file on the next sync)
;;
;; A decision writes the WIP edits back to the source item (matched by
;; MW_ID), runs the outcome's own prompts, then the shared post-decision
;; prompts (contexts always; area when the item has none), sets the keyword,
;; and relocates the item to its status bucket.  The WIP buffer then loads
;; the next inbox item.  `C-c C-n' skips an item (WIP edits discarded);
;; `C-c C-k' stops the pass.  `mindwtr-clarify-this-item' runs the same flow
;; for just the inbox item at point.
;;
;; Deliberately absent from the menu: habit (needs MW_RECURRENCE, still
;; read-only), and a separate calendar outcome -- in this model both
;; "happens at a date" and "resurface on a date" are NEXT + SCHEDULED, so
;; tickler covers them.  Tickler is plain NEXT + future SCHEDULED rather
;; than a dormant state, since the model has no writable review-at yet.
;;; Code:

(require 'org)
(require 'org-refile)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-commands)
(require 'mindwtr-archive)

(defconst mindwtr-clarify--wip-buffer-name "*mindwtr-clarify*"
  "Name of the clarify WIP buffer.  Its liveness marks an active session.")

(defvar mindwtr-clarify--pending nil
  "MW_IDs of the inbox items still to clarify in the current session.
IDs, not markers: the write-back replaces an item's subtree up to the next
heading, and a marker sitting on that boundary collapses onto the replaced
item -- an outcome that leaves the item in place (trash) would then be
re-opened instead of the real next item.")

(defvar mindwtr-clarify--source nil
  "The synced buffer the current clarify session walks.")

(defvar mindwtr-clarify--window-config nil
  "Window configuration to restore when the clarify session ends.")

(defvar-local mindwtr-clarify--source-buffer nil
  "The synced buffer the WIP buffer's item came from.")

(defvar-local mindwtr-clarify--source-id nil
  "MW_ID of the source item the WIP buffer holds a copy of.")

(defconst mindwtr-clarify--outcome-keys '(?q ?n ?d ?t ?p ?a ?s ?r ?x))

(defconst mindwtr-clarify--outcome-menu
  (concat "What is it?  [q]uick done  [n]ext action  [d]elegate  [t]ickler  "
          "[p]roject  [a]dd to project  |  [s]omeday  [r]eference  "
          "[x] trash "))

(defun mindwtr-clarify--show-entry ()
  "Reveal the body of the heading at point (cross-version).
The `org-fold-*' namespace only exists in Org 9.6+; the project floor is
Emacs 28.1 / Org 9.5, where legacy `outline-*' is the equivalent."
  (if (fboundp 'org-fold-show-entry)
      (org-fold-show-entry)
    (outline-show-entry)))

(defun mindwtr-clarify--show-all ()
  "Unfold the whole buffer (cross-version, same floor as `--show-entry')."
  (if (fboundp 'org-fold-show-all)
      (org-fold-show-all)
    (outline-show-all)))

(defun mindwtr-clarify--inbox-items ()
  "Return markers at each direct child heading of the inbox container, in order.
Signals a `user-error' when the buffer has no inbox container."
  (let ((inbox (mindwtr-commands--container-marker "inbox")))
    (unless inbox
      (user-error "mindwtr-clarify: no Inbox container in this buffer"))
    (unwind-protect
        (save-excursion
          (goto-char inbox)
          (let ((parent-level (org-current-level))
                (end (save-excursion (org-end-of-subtree t t) (point)))
                items)
            (while (and (outline-next-heading) (< (point) end))
              (when (= (org-current-level) (1+ parent-level))
                (push (point-marker) items)))
            (nreverse items)))
      (set-marker inbox nil))))

(defun mindwtr-clarify--in-inbox-p ()
  "Non-nil when the heading at point still sits under the inbox container."
  (equal (mindwtr-commands--parent-list-role) "inbox"))

(defun mindwtr-clarify--project-target-p ()
  "Non-nil when the heading at point is a mindwtr project heading.
The `org-refile-target-verify-function' that scopes refiling to projects."
  (eq (mindwtr-commands--kind-at-point) 'project))

(defun mindwtr-clarify--refile ()
  "Refile the item at point under a project, via native `org-refile'.
Binds `org-refile-targets' to the current buffer with project headings as
the only valid destinations -- the minimal refile-target wiring the clarify
flow needs, without touching the user's global refile config."
  (let ((org-refile-targets '((nil :maxlevel . 9)))
        (org-refile-target-verify-function #'mindwtr-clarify--project-target-p)
        (org-refile-use-cache nil))
    (org-refile)))

;;; WIP buffer

(define-derived-mode mindwtr-clarify-mode org-mode "Mw-Clarify"
  "Major mode for the clarify WIP buffer: one inbox item, freely editable.
\\<mindwtr-clarify-mode-map>Decide what the item is with \
\\[mindwtr-clarify-decide], skip it with \\[mindwtr-clarify-skip], or stop \
the pass with \\[mindwtr-clarify-stop]."
  (setq header-line-format
        (substitute-command-keys
         (concat "Clarify item: edit freely · "
                 "\\[mindwtr-clarify-decide] decide · "
                 "\\[mindwtr-clarify-skip] skip · "
                 "\\[mindwtr-clarify-stop] stop"))))

(define-key mindwtr-clarify-mode-map (kbd "C-c C-c") #'mindwtr-clarify-decide)
(define-key mindwtr-clarify-mode-map (kbd "C-c C-n") #'mindwtr-clarify-skip)
(define-key mindwtr-clarify-mode-map (kbd "C-c C-k") #'mindwtr-clarify-stop)

(defun mindwtr-clarify--open-wip (id pos)
  "Load the inbox item with MW_ID ID at POS (in the session's source buffer)
into the WIP buffer and display it."
  (let ((source mindwtr-clarify--source)
        text)
    (with-current-buffer source
      (save-excursion
        (goto-char pos)
        (org-back-to-heading t)
        (setq text (buffer-substring-no-properties
                    (point)
                    (save-excursion (org-end-of-subtree t t) (point))))))
    (let ((buf (get-buffer-create mindwtr-clarify--wip-buffer-name)))
      (with-current-buffer buf
        (erase-buffer)
        ;; The keyword line makes org recognize INBOX/NEXT/... in the WIP
        ;; buffer exactly as the rendered file does (same single source).
        (insert (mindwtr-model-todo-keyword-line) "\n")
        (mindwtr-clarify-mode)
        (goto-char (point-max))
        (org-paste-subtree 1 text)
        (setq mindwtr-clarify--source-buffer source
              mindwtr-clarify--source-id id)
        (goto-char (point-min))
        (outline-next-heading)
        (mindwtr-clarify--show-all)
        (set-buffer-modified-p nil))
      (pop-to-buffer buf))))

(defun mindwtr-clarify--wip-text ()
  "Return the WIP buffer's item subtree as a string (sans the #+TODO line).
Signals a `user-error' when the buffer no longer holds a heading."
  (save-excursion
    (goto-char (point-min))
    (unless (org-at-heading-p) (outline-next-heading))
    (unless (org-at-heading-p)
      (user-error "mindwtr-clarify: the WIP buffer has no heading left"))
    (buffer-substring-no-properties (point) (point-max))))

(defun mindwtr-clarify--find-heading-by-id (id)
  "Return the position of the heading whose MW_ID is ID, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((re (format "^[ \t]*:MW_ID:[ \t]*%s[ \t]*$" (regexp-quote id))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)
        (point)))))

(defun mindwtr-clarify--write-back (id text)
  "Replace the subtree of the heading with MW_ID ID by TEXT (level-adjusted).
Leaves point on the replaced heading.  Signals a `user-error' when no
heading carries ID anymore."
  (let ((pos (mindwtr-clarify--find-heading-by-id id)))
    (unless pos
      (user-error "mindwtr-clarify: the item vanished from the source buffer"))
    (goto-char pos)
    (let ((level (org-current-level)))
      (delete-region (point)
                     (save-excursion (org-end-of-subtree t t) (point)))
      (org-paste-subtree level text))
    (goto-char pos)
    (org-back-to-heading t)))

;;; Session plumbing

(defun mindwtr-clarify--finish (msg)
  "End the clarify session: drop the queue, kill the WIP, restore windows."
  (setq mindwtr-clarify--pending nil
        mindwtr-clarify--source nil)
  (let ((buf (get-buffer mindwtr-clarify--wip-buffer-name)))
    (when buf (kill-buffer buf)))
  (when mindwtr-clarify--window-config
    (set-window-configuration mindwtr-clarify--window-config)
    (setq mindwtr-clarify--window-config nil))
  (message "mindwtr-clarify: %s" msg))

(defun mindwtr-clarify--advance ()
  "Open the WIP for the next pending inbox item, or end the session.
A pending id whose heading vanished or already left the inbox (clarified
by other means meanwhile) is dropped silently."
  (let (found)
    (while (and mindwtr-clarify--pending (not found))
      (let ((id (pop mindwtr-clarify--pending)))
        (when (buffer-live-p mindwtr-clarify--source)
          (with-current-buffer mindwtr-clarify--source
            (let ((pos (mindwtr-clarify--find-heading-by-id id)))
              (when (and pos
                         (save-excursion
                           (goto-char pos)
                           (mindwtr-clarify--in-inbox-p)))
                (setq found (cons id pos))))))))
    (if (not found)
        (mindwtr-clarify--finish "done")
      (mindwtr-clarify--open-wip (car found) (cdr found)))))

(defun mindwtr-clarify--start (markers)
  "Begin a clarify session over MARKERS (inbox item positions, in order).
The queue is kept as MW_IDs (see `mindwtr-clarify--pending'); an item that
has none yet is stamped one here -- a hand-written heading would get an id
on the next sync anyway, and the session needs a handle that survives the
buffer rewrites between items."
  (when (get-buffer mindwtr-clarify--wip-buffer-name)
    (user-error "mindwtr-clarify: a session is already in progress (C-c C-k in %s to stop)"
                mindwtr-clarify--wip-buffer-name))
  (setq mindwtr-clarify--source (and markers (marker-buffer (car markers)))
        mindwtr-clarify--pending
        (mapcar (lambda (m)
                  (prog1
                      (with-current-buffer (marker-buffer m)
                        (save-excursion
                          (goto-char m)
                          (org-back-to-heading t)
                          (or (mindwtr-parse--prop "MW_ID")
                              (let ((new (mindwtr-util-uuid)))
                                (org-set-property "MW_ID" new)
                                new))))
                    (set-marker m nil)))
                markers)
        mindwtr-clarify--window-config (current-window-configuration))
  (mindwtr-clarify--advance))

;;; Outcomes

(defun mindwtr-clarify--finalize (keyword)
  "Set KEYWORD on the task at point and relocate it to its status bucket.
DONE gets a CLOSED stamp regardless of the user's `org-log-done' (the app
records a completion time on done tasks; quick actions should sync one)."
  (let ((org-log-done (and (string= keyword "DONE") 'time)))
    (org-todo keyword))
  (mindwtr-commands--relocate 'task))

(defun mindwtr-clarify--post-prompts (&optional contexts-only)
  "Shared prompts after an actionable decision: contexts, then area.
Contexts are always offered (RET keeps them; completion over the buffer's
@contexts); an org-unrepresentable existing value is reported, not fatal.
The area prompt fires only when the item has no area yet, sits outside
any project, and the buffer defines areas at all.  CONTEXTS-ONLY skips it --
used before refiling under a project, where the task's area comes from the
project."
  (condition-case err
      (mindwtr-set-context)
    (user-error (message "%s" (error-message-string err)) (sit-for 1)))
  (unless (or contexts-only
              ;; Area lives in `:CATEGORY:' now; the legacy `:MW_AREA:' fallback
              ;; keeps a pre-upgrade item from being re-prompted before its
              ;; buffer rebuilds (mirrors the parser's read, KTD3).
              (mindwtr-parse--prop "CATEGORY")
              (mindwtr-parse--prop "MW_AREA")
              (mindwtr-commands--in-project-p)
              (null (mindwtr-set-area--names)))
    (mindwtr-set-area)))

(defun mindwtr-clarify--apply-outcome (ch)
  "Apply outcome CH (a `mindwtr-clarify--outcome-keys' char) to the heading
at point in the source buffer.  Point is on the freshly written-back item."
  (pcase ch
    ;; Quick action: it took under two minutes and is already done.
    (?q (mindwtr-clarify--finalize "DONE"))
    (?n (mindwtr-clarify--post-prompts)
        (mindwtr-clarify--finalize "NEXT"))
    (?d (let ((who (string-trim (read-string "Delegate to: "))))
          (unless (string-empty-p who)
            (org-set-property "MW_ASSIGNED_TO" who)))
        ;; The check-in date rides on DEADLINE (dueDate): "when do I chase
        ;; this up" is the one date a waiting-for item needs.
        (org-deadline nil)
        (mindwtr-clarify--post-prompts)
        (mindwtr-clarify--finalize "WAIT"))
    ;; Tickler: NEXT plus SCHEDULED (startTime).  Covers calendar items
    ;; too -- "happens AT the date" and "resurface FROM the date" are the
    ;; same shape in this model.  No writable review-at yet, so the tickler
    ;; is a plain deferred next action rather than a dormant state.
    (?t (org-schedule nil)
        (mindwtr-clarify--post-prompts)
        (mindwtr-clarify--finalize "NEXT"))
    (?p (mindwtr-promote-to-project))
    ;; Contexts-only post prompts: a task under a project takes its area
    ;; from the project, so the area question would be noise here.  NEXT is
    ;; the resting state for a project task (mirrors
    ;; `mindwtr-promote-to-project'); set it before the refile moves the
    ;; heading out from under point, so the task does not linger as INBOX.
    (?a (mindwtr-clarify--post-prompts t)
        (save-excursion (org-back-to-heading t) (org-todo "NEXT"))
        ;; Sketched child sub-headings ride along as the project's tasks;
        ;; stamp the keyword-less ones NEXT now (mirrors
        ;; `mindwtr-promote-to-project') so the buffer shows them as project
        ;; tasks immediately, not only after sync's `ensure-status'.
        (mindwtr-commands--stamp-missing-child-keywords)
        (mindwtr-clarify--refile))
    (?s (mindwtr-clarify--finalize "SOMEDAY"))
    (?r (mindwtr-clarify--finalize "REF"))
    ;; Trash: ARCH.  With the archive surface active the heading refiles into
    ;; the archive file right now (R5); the id-based session queue skips the
    ;; vanished heading rather than re-presenting it.  Best-effort (R7): on
    ;; failure the keyword stays ARCH and the next sync files it.  With the
    ;; surface inactive, fall back to the legacy in-place finalize -- the
    ;; heading keeps its place until the next sync drops archived tasks.
    (?x (if (mindwtr-archive-path)
            (progn
              (save-excursion (org-back-to-heading t) (org-todo "ARCH"))
              (mindwtr-archive-refile-best-effort))
          (mindwtr-clarify--finalize "ARCH")))))

;;; Commands

(defun mindwtr-clarify-decide ()
  "Decide what the WIP buffer's item is and file it accordingly.
Asks the clarify question (see `mindwtr-clarify--outcome-menu'), writes the
WIP edits back onto the source item, applies the chosen outcome with its
prompts, and advances to the next inbox item.  An outcome that fails (say,
promoting with no `* Projects' container) keeps the WIP buffer open so the
item can be re-decided; the written-back edits are kept either way."
  (interactive)
  (unless (derived-mode-p 'mindwtr-clarify-mode)
    (user-error "mindwtr-clarify-decide: not in a clarify WIP buffer"))
  (let ((source mindwtr-clarify--source-buffer)
        (id mindwtr-clarify--source-id)
        (text (mindwtr-clarify--wip-text))
        (ch (read-char-choice mindwtr-clarify--outcome-menu
                              mindwtr-clarify--outcome-keys))
        (ok t))
    (unless (buffer-live-p source)
      (user-error "mindwtr-clarify: the source buffer is gone"))
    (with-current-buffer source
      (mindwtr-clarify--write-back id text)
      (condition-case err
          (mindwtr-clarify--apply-outcome ch)
        (error (setq ok nil)
               (message "%s" (error-message-string err))
               (sit-for 1))))
    (when ok (mindwtr-clarify--advance))))

(defun mindwtr-clarify-skip ()
  "Skip the WIP buffer's item: discard the WIP edits, move to the next one."
  (interactive)
  (unless (derived-mode-p 'mindwtr-clarify-mode)
    (user-error "mindwtr-clarify-skip: not in a clarify WIP buffer"))
  (mindwtr-clarify--advance))

(defun mindwtr-clarify-stop ()
  "Stop the clarify pass: discard the WIP edits, leave the rest of the inbox."
  (interactive)
  (unless (derived-mode-p 'mindwtr-clarify-mode)
    (user-error "mindwtr-clarify-stop: not in a clarify WIP buffer"))
  (mindwtr-clarify--finish "stopped"))

;;;###autoload
(defun mindwtr-clarify ()
  "Triage the inbox: clarify the `* Inbox' items one by one in a WIP buffer.
Each item is copied into a `mindwtr-clarify-mode' buffer for free-form
editing; `\\<mindwtr-clarify-mode-map>\\[mindwtr-clarify-decide]' then asks \
what the item is:

  q  quick action, already done       -> DONE
  n  next action                      -> NEXT
  d  delegate (who, check-in date)    -> WAIT
  t  tickler (defer to a date)        -> NEXT + SCHEDULED
  p  new project (`mindwtr-promote-to-project')
  a  add to an existing project (refile)
  s  someday/maybe                    -> SOMEDAY
  r  reference                        -> REF
  x  trash                            -> ARCH

Actionable outcomes are followed by the shared prompts: contexts, and an
area when the item has none.  The decided item relocates to its status
bucket and the next inbox item loads.  `\\[mindwtr-clarify-skip]' skips an
item; `\\[mindwtr-clarify-stop]' stops the pass.  To triage a single item,
use `mindwtr-clarify-this-item'."
  (interactive)
  (let ((items (mindwtr-clarify--inbox-items)))
    (if (null items)
        (message "mindwtr-clarify: inbox is empty")
      (mindwtr-clarify--start items))))

(defun mindwtr-clarify--goto-inbox-item ()
  "Move point to the inbox item containing point.
The inbox item is the direct child of the inbox container; from a heading
nested deeper inside one, the walk climbs up to it.  Signals a `user-error'
when point is not within an inbox item."
  (org-back-to-heading t)
  (unless (mindwtr-clarify--in-inbox-p)
    (user-error "mindwtr-clarify: point is not on an inbox item"))
  (while (not (save-excursion
                (and (org-up-heading-safe)
                     (equal (mindwtr-parse--prop "MW_LIST") "inbox"))))
    (org-up-heading-safe)))

;;;###autoload
(defun mindwtr-clarify-this-item ()
  "Clarify just the inbox item at point, in the same WIP-buffer flow as
`mindwtr-clarify'.  From a heading nested inside an item, acts on the
containing item."
  (interactive)
  (mindwtr-clarify--goto-inbox-item)
  (mindwtr-clarify--start (list (point-marker))))

(provide 'mindwtr-clarify)
;;; mindwtr-clarify.el ends here
