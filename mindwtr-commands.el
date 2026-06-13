;;; mindwtr-commands.el --- Interactive type-aware status commands -*- lexical-binding: t; -*-
;;; Commentary:
;; Mode-scoped commands bound in `mindwtr-mode-map': a type-aware replacement
;; for `org-todo' that offers only the valid keywords for the entity at point,
;; type-aware status cycling, and eager relocation of a standalone task or a
;; project to the container matching its new status.  Re-parenting into/out of
;; a project stays on native `org-refile'.
;;; Code:

(require 'cl-lib)
(require 'org)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-parse)
(require 'mindwtr-render)
(require 'mindwtr-archive)

(defun mindwtr-commands--kind-at-point ()
  "Return the MW_TYPE symbol of the heading at point, or nil."
  (save-excursion
    (when (ignore-errors (org-back-to-heading t) t)
      (let ((type (mindwtr-parse--prop "MW_TYPE")))
        (and type (intern type))))))

(defun mindwtr-commands--read-keyword (kind choices)
  "Prompt for one of CHOICES (list of (KEYWORD . CHAR)) for KIND.
Return the chosen keyword string, or nil on quit."
  (let* ((prompt (concat (format "%s status: " kind)
                         (mapconcat (lambda (c) (format "[%c]%s" (cdr c) (car c)))
                                    choices "  ")))
         (ch (read-char-choice prompt (mapcar #'cdr choices))))
    (car (rassq ch choices))))

;;;###autoload
(defun mindwtr-commands--route-after-keyword (kind keyword)
  "Place the KIND entity at point after its keyword changed to KEYWORD.
ARCH with the archive surface active refiles the heading into the archive file
now (R5, best-effort per R7); any other keyword -- or ARCH with the surface
inactive -- relocates within the main file.  The single home for this routing,
so every keyword-setting command (`mindwtr-set-status' and
`mindwtr-commands--cycle') stays in lockstep instead of each re-deciding where
an ARCH'd heading goes."
  (if (and (string= keyword "ARCH") (mindwtr-archive-path))
      (mindwtr-archive-refile-best-effort)
    (mindwtr-commands--relocate kind)))

(defun mindwtr-set-status ()
  "Set the TODO status of the entity at point, offering only type-valid keywords.
Shadows `org-todo' in `mindwtr-mode'.  After setting, relocate a standalone
task or a project to the container matching its new status."
  (interactive)
  (let ((kind (or (mindwtr-commands--kind-at-point)
                  (ignore-errors (mindwtr-parse--infer-kind)))))
    (if (not (memq kind '(task project)))
        (call-interactively #'org-todo)
      (let ((kw (mindwtr-commands--read-keyword
                 kind (mindwtr-model-status-choices kind))))
        (when kw
          (save-excursion (org-back-to-heading t) (org-todo kw))
          (mindwtr-commands--route-after-keyword kind kw))))))

(defun mindwtr-set-area--names ()
  "Return the area names defined in the current buffer (for completion)."
  (let (names)
    (maphash (lambda (k _v) (push k names))
             (mindwtr-parse--build-area-names))
    (nreverse names)))

;;;###autoload
(defun mindwtr-set-area ()
  "Set the area of the task or project at point, choosing an existing area.
Prompts with `completing-read' over the buffer's area names (require-match) and
writes the chosen name to the MW_AREA property; `:areaId' already round-trips,
so there is no sync-seam work.  Creating a new area is out of scope.

Refuses on a task that already sits under a project or section: `MW_AREA' is
stamped to `:areaId' unconditionally for every kind, while a task's `:projectId'
comes from outline nesting, so setting an area there would parse the task with
BOTH a project and an area -- the dual-container over-stamp that silently
re-parents on the next PUT.  No-ops off a task/project heading."
  (interactive)
  (let ((kind (or (mindwtr-commands--kind-at-point)
                  (ignore-errors (mindwtr-parse--infer-kind)))))
    (cond
     ((not (memq kind '(task project)))
      (message "mindwtr-set-area: point is not on a task or project"))
     ((and (eq kind 'task) (mindwtr-commands--in-project-p))
      (message "mindwtr-set-area: a task under a project takes its area from the project; not setting"))
     (t
      (let ((names (mindwtr-set-area--names)))
        (if (null names)
            (message "mindwtr-set-area: no areas defined in this buffer")
          (let ((name (completing-read "Area: " names nil t)))
            (when (and name (not (string-empty-p name)))
              (save-excursion
                (org-back-to-heading t)
                (org-set-property "MW_AREA" name))))))))))

(defun mindwtr-set-context--candidates ()
  "Return every @context used as an org tag in the current buffer, sorted."
  (let (out)
    (dolist (tg (org-get-buffer-tags))
      (when (string-prefix-p "@" (car tg))
        (push (car tg) out)))
    (sort out #'string<)))

(defun mindwtr-set-context--normalize (values)
  "Normalize VALUES into context tags: trim, drop empties, ensure `@' prefix.
Signals a `user-error' on a value org tags cannot represent (the chars
outside `mindwtr-render--org-tag-re')."
  (let (out)
    (dolist (v values)
      (let* ((v (string-trim v))
             (v (cond ((string-empty-p v) nil)
                      ((string-prefix-p "@" v) v)
                      (t (concat "@" v)))))
        (when v
          (unless (string-match-p mindwtr-render--org-tag-re v)
            (user-error "mindwtr-set-context: %S cannot be an org tag (allowed: alphanumerics and _ @ # %%)" v))
          (push v out))))
    (delete-dups (nreverse out))))

;;;###autoload
(defun mindwtr-set-context ()
  "Set the contexts of the task at point (the `@'-prefixed org tags).
Prompts with `completing-read-multiple' (comma-separated) over every
@context already used in the buffer, prefilled with the task's current
contexts.  New contexts can be typed freely (a missing `@' prefix is
added); an empty input clears the contexts.  Hashtag tags on the heading
are preserved untouched.

A task whose MW_CONTEXTS fallback drawer holds a value org tags cannot
represent (spaces, dashes, ...) is refused -- replacing such values here
would corrupt contexts only the app can faithfully edit.  A representable
MW_CONTEXTS is lifted onto the native tag line and the drawer key removed,
so the edit is authoritative on the next parse.  No-ops off a task heading:
contexts are task-only in the model."
  (interactive)
  (let ((kind (or (mindwtr-commands--kind-at-point)
                  (ignore-errors (mindwtr-parse--infer-kind)))))
    (if (not (eq kind 'task))
        (message "mindwtr-set-context: point is not on a task")
      (save-excursion
        (org-back-to-heading t)
        (let* ((mw (mindwtr-parse--prop "MW_CONTEXTS"))
               (mw-vals (and mw (mindwtr-util-json-decode mw))))
          (if (and mw-vals
                   (not (seq-every-p
                         (lambda (s)
                           (string-match-p mindwtr-render--org-tag-re s))
                         mw-vals)))
              (message "mindwtr-set-context: contexts hold values org tags can't represent; edit them in the app")
            (let* ((split (mindwtr-parse--split-tags (org-get-tags nil t)))
                   (current (or mw-vals (car split)))
                   ;; The splitter returns hashtags in model form ("#shop");
                   ;; the org tag line stores them bare ("shop"), mirroring
                   ;; `mindwtr-render--org-tag-tokens'.
                   (hashtags (mapcar (lambda (s) (string-remove-prefix "#" s))
                                     (cdr split)))
                   (cands (delete-dups
                           (append (copy-sequence current)
                                   (mindwtr-set-context--candidates))))
                   (chosen (mindwtr-set-context--normalize
                            (completing-read-multiple
                             "Contexts (comma-separated): " cands nil nil
                             (and current (string-join current ","))))))
              (org-set-tags (append chosen hashtags))
              (when mw (org-entry-delete nil "MW_CONTEXTS")))))))))

(defun mindwtr-commands--status-at-point (kind)
  "Status string for the KIND entity at point, derived from its TODO keyword."
  (let ((kw (save-excursion (org-back-to-heading t) (org-get-todo-state))))
    (and kw (mindwtr-model-keyword->status-safe kind kw))))

(defun mindwtr-commands--in-project-p ()
  "Non-nil if the heading at point has a project or section ancestor."
  (or (mindwtr-parse--ancestor-id 'section)
      (mindwtr-parse--ancestor-id 'project)))

(defun mindwtr-commands--target-role (kind)
  "Container role the KIND entity at point should live under, or nil for no move.
Only standalone tasks and projects relocate; archived statuses have no role."
  (pcase kind
    ('task
     (unless (mindwtr-commands--in-project-p)
       (mindwtr-model-status->list (mindwtr-commands--status-at-point 'task))))
    ('project
     (mindwtr-model-project-status->list (mindwtr-commands--status-at-point 'project)))
    (_ nil)))

(defun mindwtr-commands--parent-list-role ()
  "Return the MW_LIST role of the nearest container ancestor of point, or nil.
Thin alias over the parser's own walk (the lower layer commands already depends
on) so the two stay in lockstep."
  (mindwtr-parse--ancestor-list-role))

(defun mindwtr-commands--container-marker (role)
  "Return a marker at the container heading whose MW_LIST is ROLE, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((re (format "^[ \t]*:MW_LIST:[ \t]*%s[ \t]*$" (regexp-quote role))))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)
        (point-marker)))))

(defun mindwtr-commands--relocate (kind)
  "Move the KIND entity at point under the container matching its current status.
No-op when the target role is nil (archived / project task / section) or the
entity already sits directly under the target container."
  (let ((role (mindwtr-commands--target-role kind)))
    (when (and role (not (equal (mindwtr-commands--parent-list-role) role)))
      (let ((target (mindwtr-commands--container-marker role)))
        (when target
          (unwind-protect
              ;; No `save-excursion': leave point on the moved heading so the
              ;; cursor follows the entity the user just re-statused.
              (progn
                (org-back-to-heading t)
                ;; Pass the cut text to `org-paste-subtree' explicitly rather
                ;; than letting it read `(current-kill 0)': `org-cut-subtree'
                ;; (-> `kill-region') APPENDS to the kill-ring head when
                ;; `last-command' is `kill-region', which the command loop
                ;; leaves set after a prior relocation -- so a kill-ring paste
                ;; would re-insert every previously-moved subtree (duplicating
                ;; them) on consecutive relocations.
                (let* ((level (1+ (save-excursion (goto-char target) (org-current-level))))
                       (text (org-cut-subtree)))
                  (goto-char target)
                  ;; To the start of the heading after this container's subtree
                  ;; (or end of buffer) -- a clean line boundary -- then paste as
                  ;; the container's last child at the computed level.
                  (org-end-of-subtree t t)
                  (org-paste-subtree level text)))
            (set-marker target nil)))))))

(defun mindwtr-commands--cycle (dir)
  "Cycle the entity at point by DIR (+1/-1) through its type-valid keywords,
then relocate.  Falls back to plain org shift-cycling off Mindwtr headings."
  (let ((kind (mindwtr-commands--kind-at-point)))
    (if (not (memq kind '(task project)))
        (call-interactively (if (> dir 0) #'org-shiftright #'org-shiftleft))
      (let* ((kws (mapcar #'car (mindwtr-model-status-choices kind)))
             (cur (save-excursion (org-back-to-heading t) (org-get-todo-state)))
             (idx (and cur (cl-position cur kws :test #'string=)))
             (next (cond ((null idx) (if (> dir 0) 0 (1- (length kws))))
                         (t (mod (+ idx dir) (length kws)))))
             (kw (nth next kws)))
        (save-excursion (org-back-to-heading t) (org-todo kw))
        (mindwtr-commands--route-after-keyword kind kw)))))

(defun mindwtr-commands--stamp-missing-child-keywords ()
  "Give NEXT to every descendant heading of the subtree at point lacking a keyword.
Used when a task's sketched sub-headings become project tasks: a keyword-less
new task would otherwise default to status inbox at sync time
\(`mindwtr-sync--ensure-status'), which is the wrong resting state for a
project task.  Existing keywords are preserved."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point-marker))))
      (unwind-protect
          (while (and (outline-next-heading) (< (point) end))
            (unless (org-get-todo-state)
              (org-todo "NEXT")))
        (set-marker end nil)))))

(defun mindwtr-commands--has-child-heading-p ()
  "Non-nil when the heading at point has at least one descendant heading."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point))))
      (and (outline-next-heading) (< (point) end)))))

(defun mindwtr-commands--find-project-by-title (title)
  "Return a marker at the first project heading titled TITLE, or nil.
The comparison is case-insensitive, mirroring the app's reuse of an
existing same-titled project on convert-to-project."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found)
                  (re-search-forward "^[ \t]*:MW_TYPE:[ \t]*project[ \t]*$" nil t))
        (save-excursion
          (org-back-to-heading t)
          (when (string= (downcase (org-get-heading t t t t)) (downcase title))
            (setq found (point-marker)))))
      found)))

(defun mindwtr-commands--create-project-heading (title)
  "Insert an ACTIVE project heading TITLE as the last child of `* Projects'.
Mints its MW_ID eagerly: type inference and the `:projectId' derivation
both key on the ancestor's id, so an id-less project would misclassify the
tasks beneath it on the next parse.  Returns a marker at the new heading,
or nil when the buffer has no projects container."
  (let ((target (mindwtr-commands--container-marker "projects")))
    (when target
      (unwind-protect
          (save-excursion
            (goto-char target)
            (let ((level (1+ (org-current-level))))
              (org-end-of-subtree t t)
              (unless (bolp) (insert "\n"))
              (let ((beg (point)))
                (insert (make-string level ?*) " ACTIVE " title "\n"
                        ":PROPERTIES:\n:MW_TYPE: project\n:MW_ID: "
                        (mindwtr-util-uuid) "\n:END:\n")
                (goto-char beg)
                (point-marker))))
        (set-marker target nil)))))

(defun mindwtr-commands--move-subtree-under (target)
  "Move the subtree at point to be the last child of the heading at TARGET.
Leaves point on the moved heading."
  (org-back-to-heading t)
  ;; Explicit `text' so the paste never reads a kill-ring head that
  ;; `org-cut-subtree' may have APPENDED to (see `mindwtr-commands--relocate').
  (let* ((level (1+ (save-excursion (goto-char target) (org-current-level))))
         (text (org-cut-subtree)))
    (goto-char target)
    (org-end-of-subtree t t)
    (org-paste-subtree level text)))

;;;###autoload
(defun mindwtr-promote-to-project ()
  "Make the task at point the first NEXT action of a new project.
Mirrors the app's \"make this a project\" (its inbox-processing wizard):
the task KEEPS its MW_ID -- updated in place, never tombstoned, so its
server history survives and pending edits from other devices still land on
a live task -- and becomes a NEXT action under a freshly created ACTIVE
project.  Prompts for the project title (prefilled with the task's title);
when a project with that title already exists (case-insensitive), the task
moves under it instead of creating a duplicate -- also the app's behavior.

A childless task is then prompted for a next-action retitle (RET keeps the
current title): its old title usually names the outcome, which just became
the project's name, not the first action.  A task with sketched child
headings skips that prompt -- the children are the actions; they ride
along, keyword-less ones stamped NEXT, and parse as the project's tasks
(`mindwtr-parse--ancestor-id' skips intermediate task headings, and the
next reconcile renders them flat under the project).

Refuses on anything but a task heading, and on a task that already belongs
to a project or section (lift it out with `org-refile' first)."
  (interactive)
  (org-back-to-heading t)
  (let ((kind (or (mindwtr-commands--kind-at-point)
                  (mindwtr-parse--infer-kind))))
    (cond
     ((not (eq kind 'task))
      (user-error "mindwtr-promote-to-project: point is not on a task heading"))
     ((mindwtr-commands--in-project-p)
      (user-error "mindwtr-promote-to-project: task already belongs to a project; refile it out first"))
     (t
      (let* ((task-title (org-get-heading t t t t))
             (children-p (mindwtr-commands--has-child-heading-p))
             (ptitle (string-trim (read-string "Project title: " task-title))))
        (when (string-empty-p ptitle)
          (user-error "mindwtr-promote-to-project: a project title is required"))
        ;; Validate the destination before any mutation: a missing
        ;; `* Projects' container must not leave the task half-promoted
        ;; (retitled and stamped NEXT with no project to land under).
        (let ((dest (or (mindwtr-commands--find-project-by-title ptitle)
                        (mindwtr-commands--container-marker "projects"))))
          (if dest
              (set-marker dest nil)
            (user-error "mindwtr-promote-to-project: no `* Projects' container in this buffer")))
        (unless children-p
          (let ((action (string-trim (read-string "Next action: " task-title))))
            (when (and (not (string-empty-p action))
                       (not (string= action task-title)))
              (org-edit-headline action))))
        (org-todo "NEXT")
        (mindwtr-commands--stamp-missing-child-keywords)
        (let ((target (or (mindwtr-commands--find-project-by-title ptitle)
                          (mindwtr-commands--create-project-heading ptitle))))
          (unless target
            (user-error "mindwtr-promote-to-project: no `* Projects' container in this buffer"))
          (unwind-protect
              (mindwtr-commands--move-subtree-under target)
            (set-marker target nil)))
        (message "mindwtr: task is now the next action of project %S" ptitle))))))

;;;###autoload
(defun mindwtr-cycle-status-forward ()
  "Cycle the entity at point to its next type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle 1))

;;;###autoload
(defun mindwtr-cycle-status-backward ()
  "Cycle the entity at point to its previous type-valid status, then relocate."
  (interactive)
  (mindwtr-commands--cycle -1))

(provide 'mindwtr-commands)
;;; mindwtr-commands.el ends here
