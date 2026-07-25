;;; mindwtr-clock.el --- Roll up org-clock LOGBOOK time -*- lexical-binding: t; -*-
;;; Commentary:
;; Two pure computations behind the clock-time roll-up (see
;; docs/plans/2026-07-24-001-feat-clock-time-rollup-plan.md):
;;
;;   `mindwtr-clock--logbook-minutes' -- sum a task's closed CLOCK durations.
;;   `mindwtr-clock--reconcile'       -- fold the server total, the persisted
;;                                       baseline, and the LOGBOOK sum into the
;;                                       new `timeSpentMinutes' value.
;;
;; No sidecar I/O: the reconciliation baseline lives in the task's own
;; `:MW_CLOCK_SYNCED:' drawer property (wired in mindwtr-parse/mindwtr-render),
;; so this module holds only the arithmetic and the buffer scan.
;;; Code:

(require 'org)
(require 'org-duration)

(defun mindwtr-clock--logbook-minutes ()
  "Return the sum, in minutes, of closed CLOCK durations in the entry at point.
Point must be on the task heading.  Sums the `=> TOTAL' of each closed CLOCK
line in the heading's own body region \(up to the next heading, so descendant
clocks are not counted -- tasks do not nest).  A running \(open) clock line has
no `=>' total and is excluded by construction, so a task being clocked does not
perturb the sum \(KTD5).  Returns 0 when there is no LOGBOOK.

The total after `=>' is parsed with `org-duration-to-minutes' rather than a
hand-rolled H:MM scan, so it honors `org-duration-format' -- notably a clock of
24h or more, which org renders under the default format as `Nd H:MM' (e.g.
`4d 4:00' for 100h) and a raw H:MM regex would silently drop to 0."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (case-fold-search nil)
          (total 0))
      (forward-line 1)
      (while (re-search-forward
              "^[ \t]*CLOCK:.*?=>[ \t]*\\(.+?\\)[ \t]*$" end t)
        (setq total (+ total (condition-case nil
                                 (round (org-duration-to-minutes (match-string 1)))
                               (error 0)))))
      total)))

(defun mindwtr-clock--reconcile (s b l)
  "Reconcile server total S, baseline B, and LOGBOOK sum L into a new total.
Any nil argument is treated as 0.  Returns (+ (max 0 (- S B)) L): the
`outside' portion max(0, S-B) -- time worked outside Emacs, which must be
preserved and kept growing -- plus the current LOGBOOK sum L, re-asserted
each cycle so a deleted CLOCK entry lowers the total by exactly its amount."
  (let ((s (or s 0)) (b (or b 0)) (l (or l 0)))
    (+ (max 0 (- s b)) l)))

(provide 'mindwtr-clock)
;;; mindwtr-clock.el ends here
