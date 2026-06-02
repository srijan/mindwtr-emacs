;;; mindwtr-parse.el --- org buffer -> appdata content -*- lexical-binding: t; -*-
;;; Commentary:
;; Parse org headings into Mindwtr entity content plists.  Sync metadata
;; and shadow-only fields are NOT produced here; they are merged from the
;; shadow later.  Each parsed entity carries internal keys:
;;   :mw-kind  -> one of area|project|section|task
;;   :mw-extra-props -> plist of unknown PROPERTIES keys to preserve
;;; Code:

(require 'org)
(require 'org-element)
(require 'mindwtr-model)
(require 'mindwtr-util)

(defconst mindwtr-parse--known-props
  '("MW_TYPE" "MW_ID" "MW_ENERGY" "MW_TIME_ESTIMATE" "MW_RECURRENCE"
    "MW_ASSIGNED_TO" "MW_FOCUS_TODAY" "MW_REVIEW_AT" "MW_LOCATION"
    "MW_TASK_MODE" "MW_SEQUENTIAL" "MW_FOCUSED" "MW_AREA_ID" "MW_AREA" "MW_ATTACH"
    "MW_CREATED" "MW_UPDATED" "MW_TAGS" "MW_CONTEXTS")
  "PROPERTIES keys the parser interprets; all others are preserved verbatim.")

(defun mindwtr-parse-ensure-keywords ()
  "Make sure the Mindwtr TODO keywords are recognized in this buffer.
Org only registers keywords from `org-todo-keywords' during mode
initialization, so when parsing a buffer that was put into plain
`org-mode' (e.g. tests, or a file opened under a personal org config) we
rebind the keywords and re-init org once.

We must check that the *whole* sequence is present, not just one keyword:
a personal GTD config commonly defines NEXT but not SOMEDAY/REF/etc., and
trusting NEXT alone left those unrecognized -- their headings then parsed
to a nil status, leaking the keyword into the title and aborting the sync."
  (unless (seq-every-p (lambda (k) (member k org-todo-keywords-1))
                       mindwtr-model-todo-keyword-names)
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (org-mode))))

(defun mindwtr-parse--drawer-alist ()
  "Return an alist (KEY . VALUE) of the PROPERTIES drawer for this entry.
This scans the heading body directly rather than relying on
`org-entry-get', because the latter fails to associate a property
drawer with its heading when more than one planning line (e.g. both
SCHEDULED and DEADLINE on separate lines) precedes the drawer."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (case-fold-search nil)
          props)
      (forward-line 1)
      (when (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
        (forward-line 1)
        (while (and (< (point) end)
                    (not (looking-at-p "^[ \t]*:END:[ \t]*$")))
          (when (looking-at "^[ \t]*:\\([^:\n]+\\):[ \t]*\\(.*?\\)[ \t]*$")
            (push (cons (match-string-no-properties 1)
                        (match-string-no-properties 2))
                  props))
          (forward-line 1)))
      (nreverse props))))

(defun mindwtr-parse--prop (key)
  "Return raw value of property KEY for this entry, or nil."
  (cdr (assoc key (mindwtr-parse--drawer-alist))))

(defun mindwtr-parse--split-tags (tags)
  "Split org TAGS list into (contexts . hashtags) per the @-convention."
  (let (contexts hashtags)
    (dolist (tg tags)
      (if (string-prefix-p "@" tg)
          (push tg contexts)
        (push (concat "#" tg) hashtags)))
    (cons (nreverse contexts) (nreverse hashtags))))

(defun mindwtr-parse--planning-iso (regexp)
  "Return ISO timestamp for a planning line matching REGEXP in this entry."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (when (re-search-forward regexp end t)
        (mindwtr-util-org->iso (match-string 1))))))

(defun mindwtr-parse--body ()
  "Return (description . checklist) for the entry at point.
Description is the prose body minus planning, drawers, and checklist items."
  (save-excursion
    (org-back-to-heading t)
    (let* ((el (org-element-at-point))
           (cbeg (org-element-property :contents-begin el))
           (end (save-excursion (outline-next-heading) (point)))
           (lines (when cbeg
                    (split-string (buffer-substring-no-properties cbeg end) "\n")))
           prose checklist (in-drawer nil))
      (dolist (ln lines)
        (cond
         ((string-match-p "^[ \t]*:END:[ \t]*$" ln) (setq in-drawer nil))
         ((string-match-p "^[ \t]*:[A-Za-z0-9_]+:[ \t]*$" ln) (setq in-drawer t))
         (in-drawer nil)
         ((string-match-p "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):" ln) nil)
         ((string-match "^[ \t]*- \\[\\([ X]\\)\\] \\(.*\\)$" ln)
          (push (list :title (match-string 2 ln)
                      :isCompleted (if (string= (match-string 1 ln) "X") t :false))
                checklist))
         (t (push ln prose))))
      (cons (string-trim (mapconcat #'identity (nreverse prose) "\n"))
            (nreverse checklist)))))

(defun mindwtr-parse--extra-props ()
  "Return a plist (string key -> value) of unknown PROPERTIES at point."
  (let (extra)
    (pcase-dolist (`(,k . ,v) (mindwtr-parse--drawer-alist))
      (unless (member k mindwtr-parse--known-props)
        (setq extra (plist-put extra k v))))
    extra))

(defvar mindwtr-parse--area-names nil
  "Hash name->id for resolving :MW_AREA:.
Dynamically bound by `mindwtr-parse-buffer'.")

(defun mindwtr-parse--build-area-names ()
  "Scan the current buffer for area headings, returning a name->id hash.
Warns on a duplicate name (keeps the first id)."
  (let ((h (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") "area")
         (let ((name (org-get-heading t t t t)) (id (mindwtr-parse--prop "MW_ID")))
           (when (and name id)
             (if (gethash name h)
                 (message "mindwtr: duplicate area name %S; keeping first" name)
               (puthash name id h)))))))
    h))

(defun mindwtr-parse--area-id (entity-area-name)
  "Resolve an :MW_AREA: ENTITY-AREA-NAME to an area id, or nil."
  (and entity-area-name mindwtr-parse--area-names
       (gethash entity-area-name mindwtr-parse--area-names)))

(defun mindwtr-parse-heading ()
  "Parse the org heading at point into a Mindwtr entity content plist."
  (save-excursion (mindwtr-parse-ensure-keywords))
  (org-back-to-heading t)
  (let* ((kind (intern (or (mindwtr-parse--prop "MW_TYPE")
                           (error "Heading has no MW_TYPE: %s"
                                  (org-get-heading t t t t)))))
         (id (mindwtr-parse--prop "MW_ID"))
         (title (org-get-heading t t t t))
         (todo (org-get-todo-state))
         (tags (org-get-tags nil t))
         (split (mindwtr-parse--split-tags tags))
         (e (list :id id :mw-kind kind
                  :mw-extra-props (mindwtr-parse--extra-props))))
    (pcase kind
      ('area (setq e (plist-put e :name title)))
      ((or 'project 'section 'task) (setq e (plist-put e :title title))))
    (when (and todo (memq kind '(task project)))
      (setq e (plist-put e :status (mindwtr-model-keyword->status kind todo))))
    (when (eq kind 'task)
      (let* ((body (mindwtr-parse--body))
             (pr (nth 3 (org-heading-components))))
        (setq e (plist-put e :priority (mindwtr-model-cookie->priority pr)))
        ;; MW_CONTEXTS/MW_TAGS are the exact-fidelity fallback for values
        ;; org tags can't hold; when present they are authoritative and the
        ;; native `:tags:' line (suppressed by render in that case) is
        ;; ignored for the corresponding list.
        (let ((mw-contexts (mindwtr-parse--prop "MW_CONTEXTS"))
              (mw-tags (mindwtr-parse--prop "MW_TAGS")))
          (setq e (plist-put e :contexts
                             (if mw-contexts
                                 (mindwtr-util-json-decode mw-contexts)
                               (car split))))
          (setq e (plist-put e :tags
                             (if mw-tags
                                 (mindwtr-util-json-decode mw-tags)
                               (cdr split)))))
        (setq e (plist-put e :description (car body)))
        (when (cdr body) (setq e (plist-put e :checklist (cdr body))))
        (let ((s (mindwtr-parse--planning-iso "SCHEDULED: *\\(<[^>]+>\\)"))
              (d (mindwtr-parse--planning-iso "DEADLINE: *\\(<[^>]+>\\)"))
              (c (mindwtr-parse--planning-iso "CLOSED: *\\(\\[[^]]+\\]\\)")))
          (when s (setq e (plist-put e :startTime s)))
          (when d (setq e (plist-put e :dueDate d)))
          (when c (setq e (plist-put e :completedAt c))))
        (dolist (p '(("MW_ENERGY" . :energyLevel) ("MW_TIME_ESTIMATE" . :timeEstimate)
                     ("MW_ASSIGNED_TO" . :assignedTo) ("MW_LOCATION" . :location)
                     ("MW_TASK_MODE" . :taskMode)))
          (let ((v (mindwtr-parse--prop (car p))))
            (when v (setq e (plist-put e (cdr p) v)))))))
    (let ((aid (mindwtr-parse--area-id (mindwtr-parse--prop "MW_AREA"))))
      (when aid (setq e (plist-put e :areaId aid))))
    e))

(defconst mindwtr-parse--internal-keys '(:mw-kind :mw-extra-props :mw-ancestors)
  "Keys used during parsing that must be stripped from output entities.")

(defun mindwtr-parse--strip-internal (e)
  "Return E without internal :mw-* keys (but keep :mw-extra-props in metadata)."
  (let (out (i 0))
    (while (< i (length e))
      (unless (memq (nth i e) '(:mw-kind :mw-ancestors))
        (setq out (plist-put out (nth i e) (nth (1+ i) e))))
      (setq i (+ i 2)))
    out))

(defun mindwtr-parse--ancestor-id (kind)
  "Return MW_ID of the nearest ancestor heading whose MW_TYPE is KIND, or nil."
  (save-excursion
    (let (found)
      (while (and (not found) (org-up-heading-safe))
        (when (string= (or (mindwtr-parse--prop "MW_TYPE") "") (symbol-name kind))
          (setq found (mindwtr-parse--prop "MW_ID"))))
      found)))

(defun mindwtr-parse-buffer ()
  "Parse the current org buffer into a content appdata plist."
  (mindwtr-parse-ensure-keywords)
  (let ((mindwtr-parse--area-names (mindwtr-parse--build-area-names))
        tasks projects sections areas)
    (org-map-entries
     (lambda ()
       (let ((kind (mindwtr-parse--prop "MW_TYPE")))
         (when (and kind (not (string= kind "container")))
           (let ((e (mindwtr-parse-heading)))
             (pcase (intern kind)
               ('area (push (mindwtr-parse--strip-internal e) areas))
               ('project (push (mindwtr-parse--strip-internal e) projects))
               ('section
                (let ((pid (mindwtr-parse--ancestor-id 'project)))
                  (when pid (setq e (plist-put e :projectId pid))))
                (push (mindwtr-parse--strip-internal e) sections))
               ('task
                (let ((sid (mindwtr-parse--ancestor-id 'section))
                      (pid (mindwtr-parse--ancestor-id 'project)))
                  (cond (sid (setq e (plist-put e :sectionId sid)))
                        (pid (setq e (plist-put e :projectId pid)))))
                (push (mindwtr-parse--strip-internal e) tasks))))))))
    (list :tasks (nreverse tasks) :projects (nreverse projects)
          :sections (nreverse sections) :areas (nreverse areas))))

(provide 'mindwtr-parse)
;;; mindwtr-parse.el ends here
