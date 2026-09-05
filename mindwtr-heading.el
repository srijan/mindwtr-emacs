;;; mindwtr-heading.el --- Read access to mindwtr org headings -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The one place that knows how to read a mindwtr heading out of an org
;; buffer: its PROPERTIES drawer, its identity (`:MW_ID:', `:MW_LIST:'),
;; its outline ancestry, its extent, and how to iterate headings safely.
;; Every other module (parse, reconcile, commands, clarify, archive,
;; agenda, capture, sync) asks this module instead of scanning drawer
;; lines itself, so the scan discipline -- a literal drawer scan instead
;; of `org-entry-get', blank-as-absent, the per-buffer memo, and the
;; `org-map-entries' bindings -- is an obligation enforced once.
;;
;; Reads only.  Writes go through org's own API (`org-set-property',
;; `org-todo'); fold state and drawer byte-splicing live with reconcile
;; and render.
;;
;; Why not `org-entry-get'?  It fails to associate a property drawer
;; with its heading when more than one planning line (e.g. SCHEDULED
;; and DEADLINE on separate lines) precedes the drawer, and it routes
;; the special CATEGORY property through the buffer/filename fallback
;; instead of returning nil.  The literal scan here does neither.
;;
;; Minimum platform is Emacs 28.1 / Org 9.5, so nothing here touches the
;; org-element API.

;;; Code:

(require 'org)

;;; Property drawer

(defvar-local mindwtr-heading--drawer-cache nil
  "Per-buffer memo for `mindwtr-heading-properties': (TICK . HASH pos->alist).
Callers read a heading's drawer once per property, which without a memo
re-scans the same entry ~15-20 times per heading -- the dominant CPU cost
of a parse.  The hash maps a heading's start position to its scanned alist;
the whole hash is discarded whenever `buffer-chars-modified-tick' moves, so
any edit invalidates every entry (a position-keyed memo would otherwise go
stale as text shifts).  An entry with no drawer caches the sentinel `none'
\(nil would read as a miss).")

(defun mindwtr-heading-entry-end ()
  "Return the position where the entry at point ends (the next heading, or eob).
Point may be anywhere inside the entry."
  (save-excursion (outline-next-heading) (point)))

(defun mindwtr-heading--scan-drawer ()
  "Scan and return this entry's PROPERTIES drawer alist (uncached).
Point must be at the heading.  Keys and values are trimmed strings; a
property with no value maps to \"\"."
  (save-excursion
    (let ((end (mindwtr-heading-entry-end))
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

(defun mindwtr-heading-properties ()
  "Return the PROPERTIES drawer of the entry at point as an alist (KEY . VALUE).
Point may be anywhere inside the entry.  Memoized per (buffer tick, heading
position) -- see `mindwtr-heading--drawer-cache'."
  (save-excursion
    (org-back-to-heading t)
    (let ((tick (buffer-chars-modified-tick)))
      (unless (and mindwtr-heading--drawer-cache
                   (= (car mindwtr-heading--drawer-cache) tick))
        (setq mindwtr-heading--drawer-cache
              (cons tick (make-hash-table :test 'eql))))
      (let* ((h (cdr mindwtr-heading--drawer-cache))
             (cached (gethash (point) h)))
        (cond
         ((eq cached 'none) nil)
         (cached cached)
         (t (let ((props (mindwtr-heading--scan-drawer)))
              (puthash (point) (or props 'none) h)
              props)))))))

(defun mindwtr-heading-prop (key)
  "Return the raw value of drawer property KEY for the entry at point, or nil.
A property present with no value returns \"\"; see
`mindwtr-heading-prop-nonblank' to treat that as absent."
  (cdr (assoc key (mindwtr-heading-properties))))

(defun mindwtr-heading-prop-nonblank (key)
  "Return drawer property KEY for the entry at point, or nil when absent OR blank.
A blank value (a raw edit that left `:KEY:' with nothing after it) reads as
absent, so e.g. a blank `:MW_TYPE:' routes through kind inference rather than
interning to the empty symbol."
  (let ((v (mindwtr-heading-prop key)))
    (and v (not (string-empty-p v)) v)))

(defun mindwtr-heading-type ()
  "Return the entry's `:MW_TYPE:' as a string, or nil when absent or blank."
  (mindwtr-heading-prop-nonblank "MW_TYPE"))

(defun mindwtr-heading-kind ()
  "Return the entry's `:MW_TYPE:' as a symbol, or nil when absent or blank."
  (let ((ty (mindwtr-heading-type)))
    (and ty (intern ty))))

(defun mindwtr-heading-id ()
  "Return the entry's `:MW_ID:', or nil."
  (mindwtr-heading-prop "MW_ID"))

(defun mindwtr-heading-list-role ()
  "Return the entry's own `:MW_LIST:' container role, or nil when absent or blank."
  (mindwtr-heading-prop-nonblank "MW_LIST"))

;;; Lookup by identity

(defun mindwtr-heading--find-drawer-line (re)
  "Return the heading-start position of the first entry whose drawer matches RE.
RE must anchor a whole drawer line.  Side-effect free; nil when absent."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (when (re-search-forward re nil t)
        (org-back-to-heading t)
        (point)))))

(defun mindwtr-heading-find-id (id)
  "Return the heading-start position of the entry whose `:MW_ID:' is ID, or nil.
A direct drawer-line search rather than a whole-buffer `org-map-entries'
pass: the latter costs a full scan per lookup and, if it returns markers,
leaves one live on every heading until GC."
  (mindwtr-heading--find-drawer-line
   (format "^[ \t]*:MW_ID:[ \t]*%s[ \t]*$" (regexp-quote id))))

(defun mindwtr-heading-find-role (role)
  "Return the heading-start position of the container whose `:MW_LIST:' is ROLE."
  (mindwtr-heading--find-drawer-line
   (format "^[ \t]*:MW_LIST:[ \t]*%s[ \t]*$" (regexp-quote role))))

(defun mindwtr-heading-find-key (key)
  "Return the heading-start position of the entry whose MW_ID or MW_LIST is KEY.
Entity ids (UUIDs) and container roles share no values, so one search handles
both -- letting callers key on containers, not just entities.  Nil when KEY is
nil or absent."
  (and key
       (mindwtr-heading--find-drawer-line
        (format "^[ \t]*:MW_\\(?:ID\\|LIST\\):[ \t]*%s[ \t]*$" (regexp-quote key)))))

(defun mindwtr-heading-goto-key (key)
  "Move point to the heading whose `:MW_ID:' or `:MW_LIST:' is KEY.
Return the new position, or nil (point unchanged) when KEY is nil or absent."
  (let ((pos (mindwtr-heading-find-key key)))
    (when pos (goto-char pos))))

;;; Ancestry

(defun mindwtr-heading-ancestor-id (kind)
  "Return the `:MW_ID:' of the nearest strict ancestor whose `:MW_TYPE:' is KIND.
KIND is a symbol.  Point may be anywhere inside the entry.  Nil when none."
  (save-excursion
    (org-back-to-heading t)
    (let ((want (symbol-name kind)) found)
      (while (and (not found) (org-up-heading-safe))
        (when (equal (mindwtr-heading-prop "MW_TYPE") want)
          (setq found (mindwtr-heading-id))))
      found)))

(defun mindwtr-heading-ancestor-pos (kind &optional include-self)
  "Return the position of the nearest ancestor heading whose `:MW_TYPE:' is KIND.
With INCLUDE-SELF, the heading at point itself counts.  Nil when none."
  (save-excursion
    (org-back-to-heading t)
    (let ((want (symbol-name kind)))
      (catch 'found
        (when (and include-self (equal (mindwtr-heading-prop "MW_TYPE") want))
          (throw 'found (point)))
        (while (org-up-heading-safe)
          (when (equal (mindwtr-heading-prop "MW_TYPE") want)
            (throw 'found (point))))
        nil))))

(defun mindwtr-heading-container-role ()
  "Return the `:MW_LIST:' role of the nearest container ancestor of point, or nil.
The first ancestor with `:MW_TYPE: container' decides: its blank or missing
`:MW_LIST:' reads as nil (\"no container\"), and no further ancestor is
consulted.  Point may sit anywhere within an entry."
  (save-excursion
    (org-back-to-heading t)
    (let (role)
      (while (and (not role) (org-up-heading-safe))
        (when (equal (mindwtr-heading-prop "MW_TYPE") "container")
          (setq role (or (mindwtr-heading-prop "MW_LIST") ""))))
      (and role (not (string-empty-p role)) role))))

(defun mindwtr-heading-nearest-id-pos ()
  "Return (ID . POS) for the heading at or above point that carries an `:MW_ID:'.
The heading at point counts first.  Nil when neither it nor any ancestor has
an id.  Point may be anywhere inside the entry."
  (save-excursion
    (org-back-to-heading t)
    (catch 'found
      (let ((id (mindwtr-heading-id)))
        (when id (throw 'found (cons id (point)))))
      (while (org-up-heading-safe)
        (let ((id (mindwtr-heading-id)))
          (when id (throw 'found (cons id (point))))))
      nil)))

(defun mindwtr-heading-inherited-prop (key)
  "Return the nearest non-blank value of drawer property KEY at or above point.
Walks from the heading at point up through its ancestors and returns the
first non-blank value; nil when no heading on the path carries KEY.  Reads
the literal drawer line, so for CATEGORY this never yields org's
buffer/filename fallback."
  (save-excursion
    (org-back-to-heading t)
    (catch 'found
      (let ((v (mindwtr-heading-prop-nonblank key)))
        (when v (throw 'found v)))
      (while (org-up-heading-safe)
        (let ((v (mindwtr-heading-prop-nonblank key)))
          (when v (throw 'found v))))
      nil)))

;;; Extent

(defun mindwtr-heading-body-start ()
  "Return the position just after the entry's PROPERTIES drawer.
Falls back to the line after the heading when there is no drawer, so a body
scan always has a start.  Point may be anywhere inside the entry."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (mindwtr-heading-entry-end))
          (case-fold-search nil))
      (if (and (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
               (re-search-forward "^[ \t]*:END:[ \t]*$" end t))
          (min (1+ (point)) end)
        (org-back-to-heading t)
        (forward-line 1)
        (point)))))

;;; Iteration

(defun mindwtr-heading-map (func &rest args)
  "Run `org-map-entries' with FUNC and ARGS under two scan bindings.

`buffer-file-name' is bound nil because `org-map-entries' (nil scope)
otherwise hands this buffer's file to Org's agenda-file check, which prompts
\"Non-existent agenda file ...  [R]emove from list or [A]bort?\" -- a hang
under `--batch', a stray prompt interactively -- whenever the file is not yet
on disk (e.g. parsing or rebuilding the live buffer on a first sync, before
its initial save).  Our scans read only buffer text, so hiding the file name
leaves their results unchanged.

`org-element-use-cache' is bound nil to keep the scan off the buffer's
long-lived org-element cache.  `org-scan-tags' otherwise walks headings via
`org-element-cache-map', and in a long-lived session that cache has been
observed to degrade catastrophically, turning a scan that costs well under a
second into minutes of 100% CPU inside `org-element--cache-find' /
`org-element--parse-to'.  Because these scans run from the
`mindwtr-auto-sync-mode' timer they are not interruptible by ordinary means,
so the freeze presents as a wedged Emacs recoverable only with
\\[keyboard-quit].  What the binding buys depends on the Org version:

  Org 9.5   `org-scan-tags' never uses the cache; the binding is inert.
  Org 9.6   `org-scan-tags' checks `org-element--cache-active-p' and falls
            back to a plain regexp outline walk -- cost bounded by buffer size.
  Org 9.7+  `org-scan-tags' always calls `org-element-cache-map', which wraps
            the walk in `org-element-with-enabled-cache': with the cache
            disabled it builds a FRESH throwaway cache for the scan and
            restores the buffer's own cache state afterwards.  The scan pays a
            full parse (~0.09s on a 110KB archive) but never touches, and can
            never be wedged by, the long-lived cache.

Either way the worst case is bounded by buffer size rather than by the
health of a cache that has been mutating for days.  Every call site is a
structural read that never inserts or deletes characters (the fold-restore
scan in `mindwtr-reconcile--restore-view' changes visibility only), so the
buffer's cache stays consistent across the scan.

Binding both here, around just the scan, keeps each suppression a single
enforced obligation rather than a comment repeated at each call site."
  (let ((buffer-file-name nil)
        (org-element-use-cache nil))
    (apply #'org-map-entries func args)))

(provide 'mindwtr-heading)
;;; mindwtr-heading.el ends here
