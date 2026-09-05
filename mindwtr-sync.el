;;; mindwtr-sync.el --- Sync engine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Change detection against the shadow and candidate-snapshot construction.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-signature)
(require 'mindwtr-shadow)
(require 'mindwtr-clock)
(require 'mindwtr-heading)

(defconst mindwtr-sync--entity-keys '(:tasks :projects :sections :areas :people))

(cl-defstruct (mindwtr-sync-cycle (:constructor mindwtr-sync-cycle--make)
                                  (:copier nil))
  "One sync cycle's state, built by `mindwtr-sync--prepare' (stage A) and
carried across the async stages (`mindwtr-sync--put-get', `--finish') --
the network callbacks cannot see a `let', so everything a later stage needs
is a slot here.

BUFFER is the main org buffer.  BASELINE is the durable state read at the
start (`mindwtr-shadow-baseline': shadow, etag, device id, latches set).
SURFACES is the per-surface plist list (main first, archive when active),
each with its post-parse :tick.  LOCAL is the parse-merged AppData and
PARSE-WARNINGS its data-quality warnings.  ARCHIVE-ACTIVE says the archive
surface took part; STRICT is the resolved strict-absence flag for the cycle
\(re-bound onto `mindwtr-sync--archive-strict' by `mindwtr-sync--with-cycle'
around every stage, so stats, change detection and candidate construction
agree on what an absent archived entity means).  CHANGED, STATS and
LOCAL-CHANGES come from prepare's single diff pass; LOCAL-DIRTY, CLOCK-DIRTY
and FORCE-BACKFILL decide whether the HEAD short-circuit may apply.  NOW is
the cycle's timestamp.  WIRE is the candidate as PUT, filled in by stage C."
  buffer baseline surfaces local parse-warnings archive-active strict
  changed stats local-changes local-dirty clock-dirty force-backfill now wire)

(defun mindwtr-sync-cycle-shadow (cycle)
  "CYCLE's Shadow (the baseline AppData)."
  (mindwtr-shadow-baseline-appdata (mindwtr-sync-cycle-baseline cycle)))

(defun mindwtr-sync-cycle-latched-p (cycle latch)
  "Non-nil when LATCH was already set when CYCLE began."
  (and (memq latch (mindwtr-shadow-baseline-latches
                    (mindwtr-sync-cycle-baseline cycle)))
       t))

(defmacro mindwtr-sync--with-cycle (cycle &rest body)
  "Run BODY in CYCLE's buffer with the cycle's strict flag in effect.
Every stage that resumes from a callback enters through here: it checks the
buffer is still alive (a killed buffer aborts the cycle), selects it, and
binds `mindwtr-sync--archive-strict' from the cycle so the dynamic flag is
set in exactly one place."
  (declare (indent 1) (debug t))
  (macroexp-let2 nil c cycle
    `(let ((buffer (mindwtr-sync-cycle-buffer ,c)))
       (unless (buffer-live-p buffer)
         (error "mindwtr: buffer killed during sync; aborting"))
       (with-current-buffer buffer
         (let ((mindwtr-sync--archive-strict (mindwtr-sync-cycle-strict ,c)))
           ,@body)))))

(defvar mindwtr-sync--archive-strict nil
  "When non-nil, archived entities follow strict absence semantics (KTD6).
Default nil makes change detection byte-identical to the pre-archive engine:
an archived entity (or one whose status maps to no render list) absent from
local state is EXCUSED, never tombstoned, and archived projects are NOT live
containers.  `mindwtr-sync-once' let-binds this to `t' (U5) only once the
archive surface provably exists on disk and the migration latch is set
(`mindwtr-shadow-latched-p' (archive)) -- the deploy-seam guard that keeps the
first post-upgrade sync from mass-deleting the as-yet-unrendered archive.  With
the mode on, an archived entity's render surface is the archive file, so its
absence there IS a user deletion and falls through to the ordinary tombstone
branch of `mindwtr-sync-build-candidate'.")

(defvar mindwtr--inhibit-save-sync nil
  "Non-nil while the engine writes the synced buffer itself.
Dynamically `let'-bound `t' (never `setq'-reset, so it auto-unwinds on any
exit) around an internal `save-buffer' so the `after-save-hook' debounce
\(`mindwtr--maybe-debounced-sync') does not re-arm a stray HEAD-only sync
~5s later for a save the engine performed.  Declared here -- the lower
layer that `mindwtr.el' requires -- so both files see it and `make compile'
stays clean under `error-on-warn'.  Mirrors the `mindwtr--sync-in-progress'
guard discipline.")

(defun mindwtr-sync--save-buffer-quietly (&optional protect-content)
  "Save the current buffer to disk without re-arming the auto-sync debounce.
Return `:skipped' when the buffer visits no file (a no-op), `t' on a
successful save, and nil when the underlying `save-buffer' signals -- the
error is caught, never thrown, because this also runs in the post-PUT
region where a throw would masquerade as a sync failure (AGENTS.md
invariant).  `save-buffer' itself no-ops when the buffer is unmodified.

Binds `mindwtr--inhibit-save-sync' to `t' so the `after-save-hook'
debounce stands down for this engine-driven save; other after-save
handlers (recentf, etc.) still run.  With PROTECT-CONTENT non-nil also
suppresses `before-save-hook' so a content-mutating hook (formatters,
trailing-whitespace cleanup) cannot churn engine-canonical reconciled
content out from under the just-passed concurrency guard."
  (if (not (buffer-file-name))
      :skipped
    (let ((mindwtr--inhibit-save-sync t))
      (condition-case err
          (progn
            (if protect-content
                (let ((before-save-hook nil)) (save-buffer))
              (save-buffer))
            t)
        (error
         (message "mindwtr: buffer save failed: %s" (error-message-string err))
         nil)))))

(defun mindwtr-sync--strip-device-local (entity)
  "Return ENTITY without device-local fields."
  (mindwtr-util-plist-omit entity mindwtr-model-device-local-fields))

(defun mindwtr-sync--empty-p (v)
  "Non-nil if content value V counts as absent (nil, empty list/string)."
  (or (null v) (and (stringp v) (string-empty-p v))))

(defun mindwtr-sync--plist-remove (pl k)
  "Return PL without key K."
  (mindwtr-util-plist-omit pl (list k)))

(defun mindwtr-sync--reattach-checklist-ids (local shadow)
  "Return LOCAL checklist items with server-assigned ids re-attached from SHADOW.
LOCAL items come from the lossy org parse and carry no :id (org checkbox
syntax cannot hold one).  Each LOCAL item is matched, greedily in order, to an
as-yet-unconsumed SHADOW item with the same :title -- completion may differ, so
a toggled item keeps its identity -- and inherits that item's :id; a LOCAL item
with no title match is genuinely new and gets a fresh uuid.  Every returned
item therefore carries an :id.

This exists because the mobile/desktop clients compare checklists for sync
conflicts BY ITEM ID (and merge the whole task as a unit): an edited checklist
pushed with id-less items never matches the client's copy, so it loses the
deterministic tie-break every cycle and the edit is silently overwritten.
Re-attaching the ids keeps each item's identity stable across the org
round-trip (a toggle reads as a completion change, not delete+add), which is
what lets a client accept the edit instead of discarding it."
  (let ((pool (copy-sequence shadow)))
    (mapcar
     (lambda (it)
       (let* ((title (plist-get it :title))
              (match (seq-find (lambda (s) (equal (plist-get s :title) title)) pool))
              (id (if match (plist-get match :id) (mindwtr-util-uuid))))
         (when match (setq pool (delq match pool)))
         (list :id id
               :title title
               :isCompleted (if (eq (plist-get it :isCompleted) t) t :false))))
     local)))

(defun mindwtr-sync--merge-content (le se &optional protected-set)
  "Overlay LE's genuinely-changed content onto SE (the full shadow entity).
LE is the lossy org projection (no checklist item ids, minute-precision
timestamps); SE carries full fidelity plus server-managed and unmapped
fields.  For each editable field, the shadow value is kept whenever LE's
canonical projection matches SE's -- so fields the user did not change
retain their item ids and sub-minute precision -- while a genuine change
adopts LE's value (clearing the field when LE emptied it).  LE's identity
and internal keys are carried through (internal keys are stripped before
the wire).

PROTECTED-SET, when non-nil, is a list of content fields whose clearing is
suppressed when LE's value is empty but SE's is not.  Used for the first
post-upgrade sync: a buffer written by an older renderer that did not emit
project/section note bodies (or the reserved boolean drawer fields) parses to
an empty value, which must not be read as the user clearing server-authored
data.  The caller passes the kind's protectable fields -- its notes field
(project `:supportNotes', section `:description') and its newly-signed booleans
-- only while the corresponding migration latch is unset (see
`mindwtr-shadow-latched-p' (notes) / `mindwtr-shadow-latched-p' (fields)); once
set, the field drops from the set and an empty value clears normally.  Note
`:mw-kind' is stripped from LE by `mindwtr-parse-buffer', so the kind cannot be
recovered here -- the caller resolves the set."
  (let ((out (copy-sequence (or se '()))))
    (dolist (k '(:id :mw-kind :mw-extra-props))
      (when (plist-member le k)
        (setq out (plist-put out k (plist-get le k)))))
    (dolist (k mindwtr-model-content-fields)
      (let ((lv (plist-get le k)) (sv (plist-get se k)))
        (unless (equal (mindwtr-signature-field-canonical k lv)
                       (mindwtr-signature-field-canonical k sv))
          (if (mindwtr-sync--empty-p lv)
              ;; `:status' is mandatory for task/project; an empty local value
              ;; means the parser could not determine it (a type-invalid or
              ;; missing keyword), never an intentional clear -- so keep SV.
              ;; PROTECTED-SET: a field the buffer could not yet render must
              ;; likewise keep SV (pre-migration), never clear.
              (unless (or (eq k :status)
                          (and (memq k protected-set)
                               (not (mindwtr-sync--empty-p sv))))
                (setq out (mindwtr-sync--plist-remove out k)))
            ;; The clients compare checklists by item id and merge the whole
            ;; task as a unit, so an adopted checklist must carry ids (the lossy
            ;; org parse strips them); re-attach the shadow's by title match so
            ;; the edit is not overwritten every sync.
            (setq out (plist-put out k
                                 (if (eq k :checklist)
                                     (mindwtr-sync--reattach-checklist-ids lv sv)
                                   lv)))))))
    out))

(defun mindwtr-sync--classify (local-entity shadow-entity)
  "Return one of `create' `update' `unchanged' for LOCAL vs SHADOW."
  (cond
   ((null shadow-entity) 'create)
   ((string= (mindwtr-signature local-entity) (mindwtr-signature shadow-entity))
    'unchanged)
   (t 'update)))

(defun mindwtr-sync--live-container-ids (shadow)
  "Return (PROJECTS . SECTIONS): hashes of SHADOW container ids that render.
A project renders unless it is tombstoned, or -- with strict mode
\(`mindwtr-sync--archive-strict') off -- archived.  Under strict mode an archived
project IS a live container: it renders as a subtree in the archive file, so its
children's absence from local state is a deletion, not an expected hidden-parent
absence (KTD6).  A section
renders only when it is not tombstoned and its parent project renders.  Used to
decide whether a shadow entity's absence from org is EXPECTED (its parent is
hidden) rather than a user deletion."
  (let ((projs (make-hash-table :test 'equal))
        (secs (make-hash-table :test 'equal)))
    (dolist (p (plist-get shadow :projects))
      (let ((id (plist-get p :id)))
        (when (and id (not (plist-get p :deletedAt))
                   (or mindwtr-sync--archive-strict
                       (not (equal (plist-get p :status) "archived"))))
          (puthash id t projs))))
    (dolist (s (plist-get shadow :sections))
      (let ((id (plist-get s :id)) (pid (plist-get s :projectId)))
        (when (and id (not (plist-get s :deletedAt)) pid (gethash pid projs))
          (puthash id t secs))))
    (cons projs secs)))

(defun mindwtr-sync--rendered-absent-p (se kind live)
  "Non-nil if shadow entity SE of KIND is EXPECTED to be absent from org.
With `mindwtr-sync--archive-strict' off (today's default): true when SE is
archived, or its parent container does not render, or (for a standalone task)
its status maps to no list.  Under strict mode the archived-status and
status-maps-to-no-list escapes stop applying -- an archived entity's render
surface is the archive file, so its absence there IS a user deletion (KTD6) --
while the parent-container test still holds (archived projects are live
containers under strict, so it naturally flips too).  A person is ALWAYS
rendered-absent (KTD1): people deletion is pull-only, so an absent person is
echoed, never tombstoned.  An entity that is
rendered-absent must not be tombstoned for being missing; it is echoed
verbatim instead.  LIVE is (PROJECTS . SECTIONS) from
`mindwtr-sync--live-container-ids'."
  (or (and (not mindwtr-sync--archive-strict)
           (equal (plist-get se :status) "archived"))
      (pcase kind
        ('task
         (let ((sid (plist-get se :sectionId)) (pid (plist-get se :projectId)))
           (cond (sid (not (gethash sid (cdr live))))
                 (pid (not (gethash pid (car live))))
                 (t (and (not mindwtr-sync--archive-strict)
                         (null (mindwtr-model-status->list (plist-get se :status))))))))
        ('section
         (let ((pid (plist-get se :projectId)))
           (not (and pid (gethash pid (car live))))))
        ;; People deletion is pull-only (KTD1): a person absent from the buffer
        ;; is always "expected absent" -- echoed verbatim, never tombstoned.
        ;; This (a) keeps the first post-upgrade sync from mass-tombstoning
        ;; server people the old buffer never rendered (R5), and (b) matches the
        ;; app-authoritative-for-people workflow (R4); app-side deletes still
        ;; reach Emacs via server tombstones (filtered by `mindwtr-render--live').
        ('person t)
        (_ nil))))

(defun mindwtr-sync--archived-count (appdata)
  "Count non-deleted entities in APPDATA whose status is \"archived\".
Used by the strict-mode safety gate to compare the archived set the archive
surface actually rendered into LOCAL against the archived set the SHADOW holds."
  (let ((n 0))
    (dolist (key mindwtr-sync--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (and (equal (plist-get e :status) "archived")
                   (not (plist-get e :deletedAt)))
          (setq n (1+ n)))))
    n))

(defun mindwtr-sync--archive-strict-safe-p (local shadow archive-warned)
  "Non-nil if strict absence semantics are safe to apply this cycle.

Strict mode reads an archived entity's absence from LOCAL as a user deletion
\(a server tombstone).  That inference is only sound when the archive surface
parsed completely.  This gate withholds strict mode -- falling back to echo for
the cycle, exactly like the missing-file fallback (KTD5) -- in two cases where
absence is more likely a parse/IO fault than a deletion:

- ARCHIVE-WARNED: the archive buffer parsed with warnings.  A quarantined or
  malformed heading (KTD9) means an archived entity may be missing from LOCAL
  for a parse reason; tombstoning it would delete live server data on a bad
  edit, not a deletion.

- Empty-shortfall: SHADOW holds archived entities but LOCAL parsed none.  An
  empty or truncated archive file (an `rm'+recreate, a save that lost its
  body) must not read as a mass deletion of the entire archived backlog.  The
  one accepted cost is that deleting the very last archived item by emptying
  the file is deferred until the next cycle that carries another archived
  heading; deleting it as a heading (leaving `* Archive' in place) is
  unaffected."
  (and (not archive-warned)
       (not (and (> (mindwtr-sync--archived-count shadow) 0)
                 (= (mindwtr-sync--archived-count local) 0)))))

(defun mindwtr-sync--ensure-status (entity kind)
  "Default a missing status on a newly created ENTITY of KIND.
A type-invalid or missing keyword left the parser omitting :status; for a
brand-new entity there is no shadow status to inherit, so fall back to a
context-aware default so validation does not abort:

  project                          -> active
  task with a project/section parent -> next
  task with no container parent     -> inbox

A keyword-less task created directly inside a project (carrying :projectId or
:sectionId from outline ancestry) is an actionable project task, so it rests at
NEXT -- inbox is the wrong resting state there (mirrors the explicit NEXT stamp
`mindwtr-commands--stamp-missing-child-keywords' applies on promote-to-project).
A keyword-less task elsewhere (the Inbox container) still rests at inbox.

This keys on parent presence ONLY, never the parent project's status: a new task
under a someday/waiting project also defaults to NEXT, and we never cascade a
project's deferred status onto its tasks (a task keeps whatever keyword it has;
the project's container placement carries the deferral).  This matches upstream,
which leaves task status untouched when a project becomes someday."
  (if (or (not (memq kind '(task project))) (plist-get entity :status))
      entity
    (plist-put (copy-sequence entity)
               :status (cond
                        ((eq kind 'project) "active")
                        ((or (plist-get entity :projectId)
                             (plist-get entity :sectionId))
                         "next")
                        (t "inbox")))))

(defun mindwtr-sync-build-candidate (local shadow device-id now
                                           &optional protect-empty-notes
                                           protect-empty-fields)
  "Build a candidate AppData from LOCAL parse and SHADOW, stamping DEVICE-ID/NOW.
PROTECT-EMPTY-NOTES and PROTECT-EMPTY-FIELDS gate the first-post-upgrade
empty-protection passed to `mindwtr-sync--merge-content'.  PROTECT-EMPTY-NOTES
guards a kind's notes field (project `:supportNotes', section `:description')
so an old renderer's note-less buffer does not clear a server-authored note
(see `mindwtr-shadow-latched-p' (notes)).  PROTECT-EMPTY-FIELDS guards a kind's
newly-signed booleans (task `:isFocusedToday'; project `:isSequential'
/`:isFocused') against the same false-empty seam (see
`mindwtr-shadow-latched-p' (fields)).  The two latches are independent; the
union of their per-kind fields is passed to `merge-content'."
  ;; Guarantee non-null settings up front: a fresh namespace has none in its
  ;; shadow yet, and the server's settings merge 500s on a null blob.
  (setq shadow (mindwtr-model-ensure-settings shadow))
  (let ((cand (list :settings (plist-get shadow :settings)))
        (live (mindwtr-sync--live-container-ids shadow)))
    (dolist (key mindwtr-sync--entity-keys)
      (let* ((shadow-idx (mindwtr-shadow-index shadow key))
             (kind (mindwtr-sync--key->kind key))
             ;; Pre-migration, protect this kind's empty values from being read
             ;; as clears: its notes field (project :supportNotes, section
             ;; :description; task notes always rendered, so never protected)
             ;; and its newly-signed booleans.  Each latch is independent, so a
             ;; client mid-migration on one but not the other still protects the
             ;; right subset.  The two contribute disjoint fields, so a plain
             ;; append is the union.
             (protected-set
              (append
               (and protect-empty-notes
                    (not (eq kind 'task))
                    (let ((nf (mindwtr-model-notes-field kind)))
                      (and nf (list nf))))
               (and protect-empty-fields
                    (mindwtr-model-protected-boolean-fields kind))))
             (seen (make-hash-table :test 'equal))
             out)
        (dolist (le (plist-get local key))
          (let* ((id (or (plist-get le :id) (mindwtr-util-uuid)))
                 (le (plist-put (copy-sequence le) :id id))
                 (se (gethash id shadow-idx))
                 (klass (mindwtr-sync--classify le se))
                 (merged
                  (pcase klass
                    ;; Unchanged: echo the shadow verbatim.  Overlaying the
                    ;; lossy parse here would silently strip checklist item
                    ;; ids and truncate sub-minute timestamps on every sync.
                    ('unchanged (copy-sequence se))
                    ('create
                     (let ((m (mindwtr-sync--ensure-status
                               (mindwtr-sync--merge-content le se protected-set) kind)))
                       (setq m (plist-put m :rev 1))
                       (setq m (plist-put m :createdAt now))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id)))
                    ('update
                     (let ((m (mindwtr-sync--merge-content le se protected-set)))
                       (setq m (plist-put m :rev (1+ (or (plist-get se :rev) 0))))
                       (setq m (plist-put m :updatedAt now))
                       (plist-put m :revBy device-id))))))
            (puthash id t seen)
            (push (mindwtr-sync--strip-device-local merged) out)))
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (mindwtr-sync--rendered-absent-p se kind live))
              (let ((tomb (copy-sequence se)))
                (setq tomb (plist-put tomb :deletedAt now))
                (setq tomb (plist-put tomb :rev (1+ (or (plist-get se :rev) 0))))
                (setq tomb (plist-put tomb :revBy device-id))
                (push (mindwtr-sync--strip-device-local tomb) out)))))
        ;; Shadow entities whose absence from org is EXPECTED -- archived, or
        ;; their parent container is hidden, or (for a standalone task) their
        ;; status maps to no list -- are echoed verbatim (not tombstoned): a
        ;; missing org heading there is not a user deletion.
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (when (and (not (gethash id seen))
                       (not (plist-get se :deletedAt))
                       (mindwtr-sync--rendered-absent-p se kind live))
              (push (mindwtr-sync--strip-device-local (copy-sequence se)) out))))
        (setq cand (plist-put cand key (nreverse out)))))
    cand))

;; --- Clock-time roll-up (see docs/plans/2026-07-24-001-...-plan.md) --------
;; The reconciliation writes each task's LOGBOOK time into the synced
;; `:timeSpentMinutes' while preserving time worked outside Emacs.  Per task:
;;   L = LOGBOOK sum (local `:mw-logbook-minutes'), B = last-synced baseline
;;   (drawer `:mw-clock-synced', KTD11), S = server total (shadow, KTD10).
;;   new = (max 0 (- S B)) + L.
;; `timeSpentMinutes' is unsigned (not in `mindwtr-model-content-fields'), so a
;; clock-only change marks nothing dirty; `mindwtr-sync--clock-dirty-p' gates
;; the HEAD-ETag noop skip (R8/KTD9) and the reconcile pass writes the push.

(defun mindwtr-sync--clock-new (le sidx)
  "Return the reconciled `timeSpentMinutes' for local task LE.
S is read from the shadow index SIDX (KTD10); B and L come from LE's
device-local `:mw-clock-synced' / `:mw-logbook-minutes' (KTD11)."
  (let ((se (gethash (plist-get le :id) sidx)))
    (mindwtr-clock--reconcile (plist-get se :timeSpentMinutes)
                              (plist-get le :mw-clock-synced)
                              (plist-get le :mw-logbook-minutes))))

(defun mindwtr-sync--clock-dirty-p (local shadow)
  "Non-nil when any live task's reconciled clock total differs from the shadow.
A clock-only change signs nothing and marks nothing dirty, so this gates the
HEAD-ETag noop skip (R8): without it the reconcile pass would never run in its
headline case.  Only tasks parsed this cycle are considered (R9)."
  (let ((sidx (mindwtr-shadow-index shadow :tasks)))
    (seq-some
     (lambda (le)
       (and (plist-get le :id)
            (let ((s (or (plist-get (gethash (plist-get le :id) sidx)
                                    :timeSpentMinutes)
                         0)))
              (/= (mindwtr-sync--clock-new le sidx) s))))
     (plist-get local :tasks))))

(defun mindwtr-sync--apply-clock-reconcile (candidate local shadow device-id now)
  "Write reconciled `timeSpentMinutes' into CANDIDATE tasks parsed this cycle.
For each task in LOCAL, compute the new total (`mindwtr-sync--clock-new'); when
it differs from the shadow value, set it on the matching CANDIDATE task and, if
that task was echoed unchanged, promote it to an update -- bump `:rev', stamp
`:updatedAt'/`:revBy' -- so the server accepts the change (KTD2).  Only tasks
present in LOCAL are touched, never a server-live task absent from the buffer
this cycle (R9).  Mutates and returns CANDIDATE."
  (let ((sidx (mindwtr-shadow-index shadow :tasks))
        (cidx (make-hash-table :test 'equal)))
    (dolist (te (plist-get candidate :tasks))
      (let ((id (plist-get te :id))) (when id (puthash id te cidx))))
    (dolist (le (plist-get local :tasks))
      (let* ((id (plist-get le :id))
             (te (and id (gethash id cidx))))
        (when (and te (not (plist-get te :deletedAt)))
          (let* ((se (gethash id sidx))
                 (s (or (plist-get se :timeSpentMinutes) 0))
                 (new (mindwtr-sync--clock-new le sidx)))
            (unless (= new s)
              (plist-put te :timeSpentMinutes new)
              ;; An echoed (unchanged) task carries the shadow's rev verbatim;
              ;; promote it to a real update so the server accepts the bump.
              (when (equal (plist-get te :rev) (plist-get se :rev))
                (plist-put te :rev (1+ (or (plist-get se :rev) 0)))
                (plist-put te :updatedAt now)
                (plist-put te :revBy device-id)))))))
    candidate))

(defun mindwtr-sync--overlay-clock-baseline (merged local)
  "Overlay each live task's LOGBOOK sum onto MERGED as `:mw-clock-synced' (KTD12).
MERGED is the server response the buffers render from; it never carries the
device-local baseline, so the new baseline (L, from LOCAL `:mw-logbook-minutes')
is overlaid here -- for every live task -- so the render persists it to the
`:MW_CLOCK_SYNCED:' drawer.  Overlaying L uniformly preserves unchanged
baselines and advances changed ones (at the fixed point L=B).  A task absent
from LOCAL keeps whatever the server sent.  Mutates and returns MERGED."
  (let ((lidx (make-hash-table :test 'equal)))
    (dolist (le (plist-get local :tasks))
      (let ((id (plist-get le :id)))
        (when id (puthash id (or (plist-get le :mw-logbook-minutes) 0) lidx))))
    (plist-put merged :tasks
               (mapcar
                (lambda (te)
                  (let ((l (gethash (plist-get te :id) lidx)))
                    (if l
                        (plist-put (copy-sequence te) :mw-clock-synced l)
                      te)))
                (plist-get merged :tasks))))
  merged)

(defun mindwtr-sync--key->kind (key)
  "Map an entity-list KEY like `:tasks' to its singular kind symbol `task'.
`:people' is irregular -- stripping a trailing `s' would yield `peopl' -- so it
is special-cased to `person' (KTD2).  No reverse kind->key derivation exists in
the engine, so this is the only site that needs the exception."
  (if (eq key :people) 'person
    (intern (substring (symbol-name key) 1 (1- (length (symbol-name key)))))))

(defun mindwtr-sync--entry-index (appdata)
  "Return a hash id -> (KIND . ENTITY) across all of APPDATA's entity lists.
KIND is the singular symbol (task/project/section/area/person).  The first
occurrence of an id wins, matching the old per-id linear scan's iteration
order over `mindwtr-sync--entity-keys'."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (key mindwtr-sync--entity-keys)
      (let ((kind (mindwtr-sync--key->kind key)))
        (dolist (e (plist-get appdata key))
          (let ((id (plist-get e :id)))
            (when (and id (not (gethash id h)))
              (puthash id (cons kind e) h))))))
    h))

(defun mindwtr-sync-detect-conflicts (candidate merged changed-ids)
  "Return lost-edit conflicts for CHANGED-IDS comparing CANDIDATE vs MERGED.
Each conflict is (:id ID :kind KIND :mine OURS :theirs SERVERS); KIND lets
the report's restore action rebuild the entity in the buffer."
  (let ((mine-idx (mindwtr-sync--entry-index candidate))
        (theirs-idx (mindwtr-sync--entry-index merged))
        conflicts)
    (dolist (id changed-ids)
      (let* ((mine-e (gethash id mine-idx))
             (theirs-e (gethash id theirs-idx))
             (mine (cdr mine-e))
             (theirs (cdr theirs-e)))
        (when (and mine theirs
                   (not (string= (mindwtr-signature mine)
                                 (mindwtr-signature theirs))))
          (push (list :id id :kind (car mine-e) :mine mine :theirs theirs)
                conflicts))))
    (nreverse conflicts)))

(defun mindwtr-sync--appdata-empty-p (appdata)
  "Non-nil when APPDATA carries no entities across any entity list."
  (catch 'found
    (dolist (key mindwtr-sync--entity-keys)
      (when (plist-get appdata key) (throw 'found nil)))
    t))

(defun mindwtr-sync--incoming-changes (wire merged shadow conflicts)
  "Return the incoming remote changes pulled by this sync.
Each element is (:id ID :kind KIND :title TITLE :change CHANGE), where CHANGE
is one of `created'/`updated'/`deleted' -- a remote change to an entity this
device did not push, surfaced so a benign merge is not silent.

WIRE is the candidate this device PUT, MERGED the server's GET result, SHADOW
the pre-sync baseline, and CONFLICTS the lost-edit set from
`mindwtr-sync-detect-conflicts'.  Returns nil on a cold start (SHADOW carries
no entities): the first sync is an initial population, not changes since a
prior sync (KTD3).

Classification per entity, in this order:
- An id already in CONFLICTS is excluded -- it is shown only as a conflict (R4).
- A delete in MERGED (`:deletedAt' set, or the entity absent entirely) is
  incoming only when this device did not also push the tombstone -- a local
  delete carries `:deletedAt' in WIRE.  This delete test runs BEFORE the
  signature gate below: a server tombstone keeps its content fields and
  `:deletedAt' is shadow-only, so a remote delete has an unchanged content
  signature and the own-edit gate would otherwise mis-skip it.
- The own-edit gate (MERGED signature == WIRE signature) then excludes the
  device's own accepted creates and updates, including its own creates, which
  are present in WIRE (R3, KTD2).
- The remaining MERGED-vs-SHADOW divergence is a remote create (absent from
  SHADOW) or a remote update.  The MERGED-vs-SHADOW comparison runs only on the
  present-in-shadow branch, so it never compares against a nil shadow entity."
  (if (mindwtr-sync--appdata-empty-p shadow)
      nil
    (let ((conflict-ids (make-hash-table :test 'equal))
          out)
      (dolist (c conflicts)
        (puthash (plist-get c :id) t conflict-ids))
      (dolist (key mindwtr-sync--entity-keys)
        (let ((kind (mindwtr-sync--key->kind key))
              (s-idx (mindwtr-shadow-index shadow key))
              (w-idx (mindwtr-shadow-index wire key))
              (seen (make-hash-table :test 'equal)))
          ;; Pass 1 -- every entity the server returned: create / update /
          ;; tombstone-delete, with the device's own accepted edits gated out.
          (dolist (m (plist-get merged key))
            (let* ((id (plist-get m :id)))
              (puthash id t seen)
              (unless (gethash id conflict-ids)
                (let* ((s (gethash id s-idx))
                       (w (gethash id w-idx))
                       (s-live (and s (not (plist-get s :deletedAt)))))
                  (cond
                   ((plist-get m :deletedAt)
                    (when (and s-live (not (and w (plist-get w :deletedAt))))
                      (push (list :id id :kind kind
                                  :title (mindwtr-model-entity-title s)
                                  :change 'deleted)
                            out)))
                   ((and w (string= (mindwtr-signature m) (mindwtr-signature w)))
                    nil)
                   ((null s)
                    (push (list :id id :kind kind
                                :title (mindwtr-model-entity-title m)
                                :change 'created)
                          out))
                   ((not (string= (mindwtr-signature m) (mindwtr-signature s)))
                    (push (list :id id :kind kind
                                :title (mindwtr-model-entity-title m)
                                :change 'updated
                                :before s :after m)
                          out)))))))
          ;; Pass 2 -- shadow entities the server dropped entirely (hard purge,
          ;; no lingering tombstone): a live shadow entity gone from MERGED is a
          ;; remote delete unless this device pushed the delete.
          (dolist (s (plist-get shadow key))
            (let ((id (plist-get s :id)))
              (when (and (not (gethash id seen))
                         (not (gethash id conflict-ids))
                         (not (plist-get s :deletedAt)))
                (let ((w (gethash id w-idx)))
                  (unless (and w (plist-get w :deletedAt))
                    (push (list :id id :kind kind
                                :title (mindwtr-model-entity-title s)
                                :change 'deleted)
                          out))))))))
      (nreverse out))))

(require 'mindwtr-parse)
(require 'mindwtr-api)
(require 'mindwtr-reconcile)
(require 'mindwtr-report)
(require 'mindwtr-render)
(require 'mindwtr-archive)

(defun mindwtr-sync--strip-internal-keys (appdata)
  "Remove internal :mw-* keys from every entity in APPDATA (for the wire)."
  (let ((out (list :settings (plist-get appdata :settings))))
    (dolist (key mindwtr-sync--entity-keys)
      (setq out (plist-put out key
                           (mapcar
                            (lambda (e)
                              (mindwtr-util-plist-omit
                               e '(:mw-kind :mw-extra-props
                                   :mw-logbook-minutes :mw-clock-synced)))
                            (plist-get appdata key)))))
    out))

(defun mindwtr-sync--local-diff (local shadow)
  "Classify LOCAL vs SHADOW in one pass: (:ids IDS :stats STATS :changes CHANGES).
IDS are the created/updated entity ids (`mindwtr-sync--changed-ids'), STATS
the (:created C :updated U :deleted D) counts (`mindwtr-sync--stats'), and
CHANGES the per-entity change list (`mindwtr-sync--local-changes').  One pass
computes all three so each entity pair is signed once per cycle instead of
once per consumer -- the three legacy accessors are thin extractors over this.
A create is a local entity not in the shadow (including a new heading that has
no id yet); an update is a local entity whose signature differs from its
shadow twin; a delete is a live shadow entity absent from LOCAL whose absence
is not explained by archival or a hidden parent.  Updated CHANGES entries
carry :before SE :after LE so the caller can show a field diff."
  (let ((created 0) (updated 0) (deleted 0)
        (live (mindwtr-sync--live-container-ids shadow))
        ids changes)
    (dolist (key mindwtr-sync--entity-keys)
      (let ((idx (mindwtr-shadow-index shadow key))
            (kind (mindwtr-sync--key->kind key))
            (seen (make-hash-table :test 'equal)))
        ;; Pass 1 -- every local entity: created or updated vs shadow.
        (dolist (le (plist-get local key))
          (let* ((id (plist-get le :id))
                 (se (and id (gethash id idx))))
            (when id (puthash id t seen))
            (pcase (mindwtr-sync--classify le se)
              ('create
               (setq created (1+ created))
               (when id (push id ids))
               (push (list :id id :kind kind
                           :title (mindwtr-model-entity-title le)
                           :change 'created)
                     changes))
              ('update
               (setq updated (1+ updated))
               (when id (push id ids))
               (push (list :id id :kind kind
                           :title (mindwtr-model-entity-title le)
                           :change 'updated
                           :before se :after le)
                     changes)))))
        ;; Pass 2 -- live shadow entities absent from local: deleted.
        (dolist (se (plist-get shadow key))
          (let ((id (plist-get se :id)))
            (unless (or (gethash id seen)
                        (plist-get se :deletedAt)
                        (mindwtr-sync--rendered-absent-p se kind live))
              (setq deleted (1+ deleted))
              (push (list :id id :kind kind
                          :title (mindwtr-model-entity-title se)
                          :change 'deleted)
                    changes))))))
    (list :ids ids
          :stats (list :created created :updated updated :deleted deleted)
          :changes (nreverse changes))))

(defun mindwtr-sync--changed-ids (local shadow)
  "Return ids of entities that are create/update vs SHADOW.
Extractor over `mindwtr-sync--local-diff'; the sync cycle itself calls the
diff once and reads all three facets from it."
  (plist-get (mindwtr-sync--local-diff local shadow) :ids))

(defun mindwtr-sync--stats (local shadow)
  "Return (:created C :updated U :deleted D) for LOCAL parse vs SHADOW.
Extractor over `mindwtr-sync--local-diff' (see it for the classification
rules); the sync cycle itself calls the diff once."
  (plist-get (mindwtr-sync--local-diff local shadow) :stats))

(defun mindwtr-sync--local-changes (local shadow)
  "Return the local proposed changes for this sync.
Each element is (:id ID :kind KIND :title TITLE :change CHANGE), updated
entries also carrying :before/:after.  Extractor over
`mindwtr-sync--local-diff', which guarantees the listed entities match what
`mindwtr-sync--stats' counts exactly -- no drift between the count line and
the detail list.  Returns nil when there are no local changes."
  (plist-get (mindwtr-sync--local-diff local shadow) :changes))

(defun mindwtr-sync--surfaces (main-buffer)
  "Return the ordered surface list for this cycle (KTD2).
Each surface is a plist (:buffer :kind :render :backup-prefix).  MAIN-BUFFER is
always first with the GTD-list renderer; the archive surface is appended when
`mindwtr-archive-buffer' resolves (the surface is inactive otherwise -- legacy
single-file behavior, R9).  Earlier surfaces win id collisions in the merge."
  (let ((surfaces (list (list :buffer main-buffer :kind 'main
                              :render #'mindwtr-render-appdata
                              :backup-prefix "mindwtr"))))
    (let ((abuf (mindwtr-archive-buffer)))
      (if (not abuf) surfaces
        (append surfaces
                (list (list :buffer abuf :kind 'archive
                            :render #'mindwtr-render-archive-appdata
                            :backup-prefix "mindwtr-archive")))))))

(defun mindwtr-sync--surface-has-unparsed-entity-p (appdata)
  "Non-nil if the current buffer has an MW_ID heading absent from APPDATA.
A heading that carries an MW_ID but produced no entity -- an untyped/quarantined
heading whose MW_TYPE was removed or mistyped, so kind inference returned nil
and the parser skipped it -- means a shadow entity may be missing from local
state for a PARSE reason, not a user deletion.  The strict-absence gate treats
this exactly like a degraded parse and refuses to tombstone (KTD5).  Scoped to
the archive surface by the caller; the main file relies on reconcile's orphan
quarantine instead."
  (let ((ids (make-hash-table :test 'equal))
        (unparsed nil))
    (dolist (key mindwtr-sync--entity-keys)
      (dolist (e (plist-get appdata key))
        (when (plist-get e :id) (puthash (plist-get e :id) t ids))))
    (mindwtr-heading-map
     (lambda ()
       (let ((id (mindwtr-heading-id)))
         (when (and id (not (gethash id ids))) (setq unparsed t)))))
    unparsed))

(defun mindwtr-sync--parse-surfaces (surfaces)
  "Parse each surface's buffer and merge the results by id (earlier wins).
Returns (:surfaces SURFACES* :appdata MERGED :warnings WARNINGS
:archive-warned BOOL :duplicates IDS): SURFACES* is SURFACES with a post-parse
:tick added to each entry (parsing may re-init org-mode and bump the tick
without a user edit, so the post-parse value is the correct concurrency-guard
baseline).  An id present in two surfaces keeps the first surface's copy; the
dropped ids are returned in :duplicates (and logged) so the caller can surface
the loss durably rather than only as a transient message.  ARCHIVE-WARNED is
non-nil when the archive surface carries a heading with an MW_ID that did NOT
parse into an entity (`mindwtr-sync--surface-has-unparsed-entity-p') -- the
degraded-parse signal the strict-mode safety gate keys on, so a quarantined
heading cannot read as a deletion.  Parse warnings are accumulated across
buffers because `mindwtr-parse--warnings' is per-run state, reset by each parse."
  (let ((merged (list :tasks nil :projects nil :sections nil :areas nil :people nil))
        (seen (make-hash-table :test 'equal))
        out-surfaces warnings archive-warned duplicates)
    (dolist (surface surfaces)
      (with-current-buffer (plist-get surface :buffer)
        (let ((ad (mindwtr-parse-buffer))
              (w (mindwtr-parse-warnings)))
          (push (plist-put (copy-sequence surface)
                           :tick (buffer-chars-modified-tick))
                out-surfaces)
          (when (and (eq (plist-get surface :kind) 'archive)
                     (mindwtr-sync--surface-has-unparsed-entity-p ad))
            (setq archive-warned t))
          (setq warnings (append warnings w))
          (dolist (key mindwtr-sync--entity-keys)
            (let (kept)
              (dolist (e (plist-get ad key))
                (let ((id (plist-get e :id)))
                  (if (and id (gethash id seen))
                      (progn
                        (push id duplicates)
                        (message "mindwtr: id %s appears in multiple surfaces; keeping the first"
                                 id))
                    (when id (puthash id t seen))
                    (push e kept))))
              (when kept
                (setq merged (plist-put merged key
                                        (append (plist-get merged key)
                                                (nreverse kept))))))))))
    (setq duplicates (nreverse duplicates))
    ;; Fold dropped cross-surface duplicates into the warnings channel so the
    ;; loss is durable in the sync report, not just a transient *Messages* line
    ;; (a user's archive-file edit to a doubly-present id is otherwise silently
    ;; discarded).  A duplicate entry is shaped (:id ID :duplicate t); the
    ;; report renderer renders it in its own group.  Duplicates do NOT set
    ;; ARCHIVE-WARNED -- the entity still rendered from the winning surface, so
    ;; this is not the degraded-parse condition the strict gate guards against.
    (list :surfaces (nreverse out-surfaces) :appdata merged
          :warnings (append warnings
                            (mapcar (lambda (id) (list :id id :duplicate t))
                                    duplicates))
          :archive-warned archive-warned :duplicates duplicates)))

(defun mindwtr-sync--prepare (buffer)
  "Parse BUFFER's surfaces and compute this cycle's decision state (stage A).
Pure CPU plus local state reads -- no network.  Returns the
`mindwtr-sync-cycle' the later async stages consume."
  (with-current-buffer buffer
    (let* ((baseline (mindwtr-shadow-baseline))
           (shadow (mindwtr-shadow-baseline-appdata baseline))
           (archive-migrated (memq 'archive (mindwtr-shadow-baseline-latches baseline)))
           (surfaces0 (mindwtr-sync--surfaces buffer))
           (archive-active (seq-find (lambda (s) (eq (plist-get s :kind) 'archive))
                                     surfaces0))
           ;; Until the archive surface has been rendered once (latch unset),
           ;; force a full cycle even on an otherwise-clean HEAD-match, so the
           ;; first sync backfills the historical archived set into the archive
           ;; file (R1) rather than deferring it to the next unrelated change.
           (force-backfill (and archive-active (not archive-migrated)))
           (parsed (mindwtr-sync--parse-surfaces surfaces0))
           (surfaces (plist-get parsed :surfaces))
           (local (plist-get parsed :appdata))
           (parse-warnings (plist-get parsed :warnings))
           ;; Strict absence semantics (KTD5/KTD6) are eligible only when the
           ;; archive surface is active, its latch is set, AND the archive file
           ;; exists on disk -- an `rm'ed file reads as not-yet-rendered (echo,
           ;; recreate), never as "everything was deleted".
           (archive-strict-eligible
            (and archive-active
                 archive-migrated
                 (let ((p (mindwtr-archive-path))) (and p (file-exists-p p)))))
           ;; ...but eligibility is not enough: an absent archived entity is
           ;; only a *deletion* when the archive surface parsed cleanly.  A
           ;; degraded parse (quarantined/malformed heading) or an empty file
           ;; would otherwise read present-but-unparsed archived entities as
           ;; mass deletions on the migrated steady state -- the seam the latch
           ;; does NOT cover.  The safety gate (computed post-parse) withholds
           ;; strict and falls back to echo for the cycle.
           (strict (and archive-strict-eligible
                        (mindwtr-sync--archive-strict-safe-p
                         local shadow (plist-get parsed :archive-warned)))))
      ;; Loudly refuse to mass-delete: eligibility passed (active, migrated,
      ;; file present) but the safety gate withheld strict mode because the
      ;; archive parsed with warnings or came back empty.  Archived absences are
      ;; echoed this cycle, not tombstoned.
      (when (and archive-strict-eligible (not strict))
        (message "mindwtr: archive file degraded or empty this cycle; archived deletions NOT applied (echoing instead)"))
      (let ((mindwtr-sync--archive-strict strict))
        ;; One diff pass yields changed ids, stats, AND the change list; each
        ;; entity pair is classified (signed) once per cycle.
        (let* ((diff (mindwtr-sync--local-diff local shadow))
               (stats (plist-get diff :stats))
               (local-dirty (> (+ (plist-get stats :created)
                                  (plist-get stats :updated)
                                  (plist-get stats :deleted))
                               0))
               ;; A clock-only change (LOGBOOK edited) signs nothing and marks
               ;; nothing dirty, so it must force a full cycle rather than be
               ;; skipped by the HEAD-ETag noop gate (R8/KTD9).
               (clock-dirty (mindwtr-sync--clock-dirty-p local shadow)))
          (mindwtr-sync-cycle--make
           :buffer buffer :baseline baseline
           :surfaces surfaces :local local :parse-warnings parse-warnings
           :archive-active (and archive-active t) :strict strict
           :changed (plist-get diff :ids) :stats stats
           :local-changes (plist-get diff :changes)
           :local-dirty local-dirty
           :clock-dirty clock-dirty :force-backfill force-backfill))))))

(defun mindwtr-sync--check-ticks (surfaces what)
  "Signal unless every surface in SURFACES is unchanged since its post-parse tick.
WHAT names the guarded window in the error message."
  (dolist (s surfaces)
    (with-current-buffer (plist-get s :buffer)
      (unless (= (plist-get s :tick) (buffer-chars-modified-tick))
        (error "mindwtr: buffer changed during sync (%s); aborting" what)))))

(defun mindwtr-sync--finish-noop (cycle)
  "Complete a HEAD-match noop cycle from CYCLE; return the result plist."
  (with-current-buffer (mindwtr-sync-cycle-buffer cycle)
    (let ((stats (mindwtr-sync-cycle-stats cycle))
          (parse-warnings (mindwtr-sync-cycle-parse-warnings cycle)))
      ;; Even when nothing needs pushing, a stray keyword should not be
      ;; silently swallowed -- surface it in the report.
      (when parse-warnings
        (mindwtr-report-show (list :stats stats :warnings parse-warnings)
                             (current-buffer)))
      ;; The migration latches are intentionally NOT set here: a noop skips
      ;; reconcile, so the buffers still hold their old render.  Migration
      ;; protection must stay on until a full cycle actually rewrites them
      ;; (the latches are set post-save in `mindwtr-sync--finish').
      ;; A HEAD-match means the server is unchanged, so nothing is incoming.
      (list :ok t :noop t :conflicts nil :stats stats :skew nil
            :warnings parse-warnings :incoming nil))))

(defun mindwtr-sync--put-get (cycle callback)
  "Run the full-cycle push (stage C) for CYCLE: build candidate, PUT, GET.
Chains into `mindwtr-sync--finish' and delivers (RESULT ERR) to CALLBACK.
Before the PUT, every surface's tick is re-checked: the async HEAD gap means
the user may have typed since the parse, and aborting HERE is completely
clean -- nothing has been committed anywhere -- whereas the post-GET guard
aborts with the server already updated."
  (mindwtr-api--guard
   callback
   (lambda ()
     (mindwtr-sync--with-cycle cycle
       (mindwtr-sync--check-ticks (mindwtr-sync-cycle-surfaces cycle) "before push")
       (let* ((local (mindwtr-sync-cycle-local cycle))
              (shadow (mindwtr-sync-cycle-shadow cycle))
              (device (mindwtr-shadow-baseline-device-id
                       (mindwtr-sync-cycle-baseline cycle)))
              (now (mindwtr-sync-cycle-now cycle))
              ;; Pre-migration protection: each latch guards its own field
              ;; set until this client has rendered it once (see
              ;; `mindwtr-shadow-latches').
              (protect-empty-notes (not (mindwtr-sync-cycle-latched-p cycle 'notes)))
              (protect-empty-fields (not (mindwtr-sync-cycle-latched-p cycle 'fields)))
              (candidate (mindwtr-sync-build-candidate local shadow device now
                                                       protect-empty-notes
                                                       protect-empty-fields))
              ;; Write reconciled `timeSpentMinutes' onto tasks parsed this
              ;; cycle, before stripping and PUT (R2/R4/R9/KTD2).
              (candidate (mindwtr-sync--apply-clock-reconcile
                          candidate local shadow device now))
              (wire (mindwtr-sync--strip-internal-keys candidate)))
         (mindwtr-model-validate-appdata wire)
         (setf (mindwtr-sync-cycle-wire cycle) wire)
         ;; The PUT response carries {ok, stats, clockSkewWarning}; the skew
         ;; warning is surfaced in `--finish' so a misconfigured device
         ;; clock is not silent.
         (mindwtr-api-put-data-async
          wire
          (lambda (put-resp err)
            (if err (funcall callback nil err)
              (mindwtr-api-get-data-async
               (lambda (got err2)
                 (if err2 (funcall callback nil err2)
                   (mindwtr-api--deliver
                    callback
                    (lambda () (mindwtr-sync--finish cycle put-resp got))))))))))))))

(defun mindwtr-sync--save-surfaces (surfaces)
  "Save every surface in SURFACES to disk; return non-nil if any save failed.
Content-protected (KTD-7) and condition-case-guarded inside the helper: a
write failure must NOT throw (post-PUT; the server already committed) -- it is
folded into the return value so the caller can raise a visible, recoverable
error state (KTD-5).  A non-file (temp-buffer) save returns :skipped, which is
not a failure."
  (let (failed)
    (dolist (s surfaces)
      (with-current-buffer (plist-get s :buffer)
        (when (null (mindwtr-sync--save-buffer-quietly t))
          (setq failed t))))
    failed))

(defun mindwtr-sync--finish (cycle put-resp got)
  "Complete a full cycle (stage E) for CYCLE from PUT-RESP and GET result GOT.
Reconciles and saves every surface, commits the shadow/etag/latches, shows
the report, and returns the result plist.  Runs synchronously (possibly from
a process sentinel on the async path)."
  (mindwtr-sync--with-cycle cycle
    (let* ((shadow (mindwtr-sync-cycle-shadow cycle))
           (local (mindwtr-sync-cycle-local cycle))
           (wire (mindwtr-sync-cycle-wire cycle))
           (surfaces (mindwtr-sync-cycle-surfaces cycle))
           (stats (mindwtr-sync-cycle-stats cycle))
           (parse-warnings (mindwtr-sync-cycle-parse-warnings cycle))
           (skew (plist-get put-resp :clockSkewWarning))
           ;; Normalize settings on the way in too: should the server ever
           ;; return a null/absent blob, keep the shadow consistent now
           ;; rather than relying on build-candidate to re-synthesize next
           ;; cycle.
           (merged (mindwtr-model-ensure-settings (plist-get got :appdata)))
           (conflicts (mindwtr-sync-detect-conflicts
                       wire merged (mindwtr-sync-cycle-changed cycle)))
           ;; Remote changes the merge pulled in for entities the user
           ;; did not edit locally -- benign merges that complete silently
           ;; today.  Computed from the same shadow/wire/merged bindings
           ;; the conflict path consumes; excludes own edits and conflicts.
           (incoming (mindwtr-sync--incoming-changes wire merged shadow conflicts))
           ;; Local changes this device proposed (local vs shadow), computed
           ;; by prepare's single diff pass so the count line and the detail
           ;; list come from the same classification.
           (local-changes (mindwtr-sync-cycle-local-changes cycle))
           (backup-file nil))
      ;; Per-surface concurrency guard: each buffer must be unchanged since
      ;; its post-parse tick (the PUT/GET window).
      (mindwtr-sync--check-ticks surfaces "after push")
      ;; Per-surface pre-reconcile backup (file-visiting surfaces only),
      ;; each under its own prefix so the two never collide.
      (dolist (s surfaces)
        (with-current-buffer (plist-get s :buffer)
          (when (buffer-file-name)
            (let ((bf (mindwtr-shadow-backup (plist-get s :backup-prefix))))
              (when (eq (plist-get s :buffer) buffer) (setq backup-file bf))))))
      (when backup-file (mindwtr-shadow-prune-backups))
      ;; Persist the clock baseline: buffers render from `merged' (server
      ;; data), which never carries the device-local baseline, so overlay
      ;; each live task's LOGBOOK sum as :mw-clock-synced first (KTD12).
      (mindwtr-sync--overlay-clock-baseline merged local)
      ;; Per-surface reconcile, each with its own render function, then
      ;; return each buffer to clean on disk (an erase+insert always marks it
      ;; modified, so this always writes on a full cycle).
      (dolist (s surfaces)
        (with-current-buffer (plist-get s :buffer)
          (mindwtr-reconcile-buffer merged (plist-get s :render))))
      (let ((save-failed (mindwtr-sync--save-surfaces surfaces)))
        ;; Commit shadow + etag, and flip the migration latches ONLY once
        ;; every surface is durably on disk.  The buffers now carry the new
        ;; render, so a future empty value is a genuine clear -- but only if
        ;; the files persisted.  If a save failed, the on-disk file may still
        ;; hold an older render; latching now would drop protection and a
        ;; later reload could clear server data via LWW.  The archive latch
        ;; flips only when the archive surface participated (KTD5): strict
        ;; absence semantics must not activate until the file is provably
        ;; on disk.
        (mindwtr-shadow-commit
         merged (plist-get got :etag)
         (unless save-failed
           (append '(notes fields)
                   (and (mindwtr-sync-cycle-archive-active cycle) '(archive)))))
        (let ((result (list :ok t :conflicts conflicts :stats stats :skew skew
                            :warnings parse-warnings :incoming incoming
                            :local-changes local-changes
                            :save-failed save-failed)))
          (mindwtr-report-show result (current-buffer) backup-file)
          result)))))

(defun mindwtr-sync-once-async (buffer now callback)
  "Run one full sync cycle for org BUFFER, stamping changes with NOW.
Iterates the surface list (main always first; the archive file appended when
active): parse-merge by id, and on a full cycle guard each surface's tick, back
each one up, reconcile each with its own render function, and save them all.

The network legs never block: with a callback-capable transport the HEAD /
PUT / GET requests run asynchronously and the CPU stages resume from their
completion callbacks (process sentinels); with a synchronous transport the
whole chain completes inline.  CALLBACK is called exactly once as
\(CALLBACK RESULT ERR): RESULT is the same (:ok t :conflicts LIST ...) plist
`mindwtr-sync-once' returns, ERR the (SYMBOL . DATA) of the signal that ended
the cycle (re-signalable via (signal (car ERR) (cdr ERR))).  Errors always
travel through ERR -- nothing signals out of a sentinel."
  (mindwtr-api--guard
   callback
   (lambda ()
     (let* ((cycle (mindwtr-sync--prepare buffer))
            (shadow-etag (mindwtr-shadow-baseline-etag
                          (mindwtr-sync-cycle-baseline cycle))))
       (setf (mindwtr-sync-cycle-now cycle) now)
       ;; Step 1 of the cycle: with nothing local to push, HEAD the server; if
       ;; its ETag still matches the shadow, neither side changed -- skip the
       ;; PUT/GET round-trip.  (When local IS dirty -- a dirty archive file
       ;; counts, since its changes fold into the combined stats -- or the
       ;; archive still needs its first render, we go straight to the full
       ;; cycle.)
       (if (and (not (mindwtr-sync-cycle-local-dirty cycle))
                (not (mindwtr-sync-cycle-force-backfill cycle))
                (not (mindwtr-sync-cycle-clock-dirty cycle))
                shadow-etag (not (string-empty-p shadow-etag)))
           (mindwtr-api-head-etag-async
            (lambda (etag err)
              (cond
               (err (funcall callback nil err))
               ((equal etag shadow-etag)
                (mindwtr-api--deliver
                 callback (lambda () (mindwtr-sync--finish-noop cycle))))
               (t (mindwtr-sync--put-get cycle callback)))))
         (mindwtr-sync--put-get cycle callback))))))

(defun mindwtr-sync-once (buffer now)
  "Synchronous `mindwtr-sync-once-async': return the result plist or signal.
Only valid with a transport that completes inline (the url.el fallback, or a
test stub); with a genuinely asynchronous transport this signals immediately
rather than blocking, so interactive callers must go through the async entry."
  (let (done res err)
    (mindwtr-sync-once-async buffer now
                             (lambda (r e) (setq done t res r err e)))
    (cond (err (signal (car err) (cdr err)))
          (done res)
          (t (error "mindwtr: async transport still pending; use `mindwtr-sync-once-async'")))))

(provide 'mindwtr-sync)
;;; mindwtr-sync.el ends here
