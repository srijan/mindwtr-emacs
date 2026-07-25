;;; mindwtr-clock-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'mindwtr-clock)

(defmacro mindwtr-clock-test--at (text &rest body)
  "Insert TEXT in an org buffer, move to the first heading, run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       (unless (org-at-heading-p) (org-next-visible-heading 1))
       ,@body)))

;;; -- mindwtr-clock--reconcile (pure) -------------------------------------

(ert-deftest mindwtr-clock-reconcile-fixed-point ()
  "At the fixed point (L=B, S=outside+B) the value is unchanged: new=S."
  (should (= (mindwtr-clock--reconcile 90 30 30) 90)))

(ert-deftest mindwtr-clock-reconcile-outside-work-added ()
  "Outside work (S rises above B) is captured and preserved."
  ;; server rose 30 -> 100 (outside +70); B=30, L=30 -> 70 + 30
  (should (= (mindwtr-clock--reconcile 100 30 30) 100)))

(ert-deftest mindwtr-clock-reconcile-logbook-deleted-lowers-total ()
  "Deleting LOGBOOK entries (L<B) lowers the total by exactly the removed amount."
  ;; outside = max(0, 90-60) = 30; L dropped to 10 -> 40
  (should (= (mindwtr-clock--reconcile 90 60 10) 40)))

(ert-deftest mindwtr-clock-reconcile-underflow-floors-at-zero ()
  "Server below baseline floors outside at 0; we re-assert our own L."
  (should (= (mindwtr-clock--reconcile 20 60 30) 30)))

(ert-deftest mindwtr-clock-reconcile-first-run-adds-history ()
  "First activation (B absent => 0) adds all LOGBOOK history atop the server value."
  (should (= (mindwtr-clock--reconcile 30 0 60) 90)))

(ert-deftest mindwtr-clock-reconcile-nil-coercion ()
  "Any nil argument is treated as 0."
  (should (= (mindwtr-clock--reconcile nil nil 60) 60))
  (should (= (mindwtr-clock--reconcile 30 nil nil) 30))
  (should (= (mindwtr-clock--reconcile nil 30 nil) 0))
  (should (= (mindwtr-clock--reconcile nil nil nil) 0)))

;;; -- mindwtr-clock--logbook-minutes (buffer scan) -----------------------

(ert-deftest mindwtr-clock-logbook-minutes-sums-closed-clocks ()
  "Multiple closed CLOCK lines sum their `=> H:MM' totals."
  (mindwtr-clock-test--at
      "* NEXT Task
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
:LOGBOOK:
CLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 10:30] =>  0:30
CLOCK: [2026-07-24 Thu 11:00]--[2026-07-24 Thu 12:00] =>  1:00
:END:
"
    (should (= (mindwtr-clock--logbook-minutes) 90))))

(ert-deftest mindwtr-clock-logbook-minutes-parses-hours-and-minutes ()
  "A `=> 1:30' total is 90 minutes."
  (mindwtr-clock-test--at
      "* NEXT Task
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
:LOGBOOK:
CLOCK: [2026-07-24 Thu 09:00]--[2026-07-24 Thu 10:30] =>  1:30
:END:
"
    (should (= (mindwtr-clock--logbook-minutes) 90))))

(ert-deftest mindwtr-clock-logbook-minutes-excludes-running-clock ()
  "A running (open) clock line has no `=>' total and is not counted."
  (mindwtr-clock-test--at
      "* NEXT Task
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
:LOGBOOK:
CLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 10:30] =>  0:30
CLOCK: [2026-07-24 Thu 13:00]
:END:
"
    (should (= (mindwtr-clock--logbook-minutes) 30))))

(ert-deftest mindwtr-clock-logbook-minutes-no-logbook-is-zero ()
  "A task with no LOGBOOK sums to 0."
  (mindwtr-clock-test--at
      "* NEXT Task
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
Some body prose, no clock.
"
    (should (= (mindwtr-clock--logbook-minutes) 0))))

(ert-deftest mindwtr-clock-logbook-minutes-own-body-only ()
  "A descendant heading's CLOCK is not counted (own body only)."
  (mindwtr-clock-test--at
      "* NEXT Parent
:PROPERTIES:
:MW_TYPE: task
:MW_ID: t1
:END:
:LOGBOOK:
CLOCK: [2026-07-24 Thu 10:00]--[2026-07-24 Thu 10:30] =>  0:30
:END:
** NEXT Child
:LOGBOOK:
CLOCK: [2026-07-24 Thu 11:00]--[2026-07-24 Thu 16:00] =>  5:00
:END:
"
    (should (= (mindwtr-clock--logbook-minutes) 30))))

(provide 'mindwtr-clock-test)
;;; mindwtr-clock-test.el ends here
