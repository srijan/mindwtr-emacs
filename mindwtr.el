;;; mindwtr.el --- Sync org-mode GTD with Mindwtr Cloud -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary

;; Author: Srijan Choudhary
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (plz "0.7"))
;; Keywords: outlines, convenience
;; URL: https://github.com/srijan/mindwtr-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; Bidirectional sync between a single org file and a self-hosted Mindwtr
;; Cloud server.  Entry command: `mindwtr-sync'.
;;; Code:

(require 'org)
(require 'auth-source)
(require 'url-parse)
(require 'mindwtr-model)
(require 'mindwtr-api)
(require 'mindwtr-sync)
(require 'mindwtr-shadow)
(require 'mindwtr-reconcile)
(require 'mindwtr-commands)
(require 'mindwtr-clarify)
(require 'mindwtr-capture)
(require 'mindwtr-archive)
(require 'mindwtr-agenda)

(defgroup mindwtr nil "Sync org with Mindwtr Cloud." :group 'org)

(defcustom mindwtr-server-url nil
  "Base URL of the Mindwtr Cloud server, e.g. https://mw.example."
  :type '(choice (const nil) string) :group 'mindwtr)

(defcustom mindwtr-auth-token nil
  "Bearer token.  If nil, looked up via auth-source for `mindwtr-server-url'."
  :type '(choice (const nil) string) :group 'mindwtr)

(defcustom mindwtr-file nil
  "Path to the org file synced with Mindwtr."
  :type '(choice (const nil) file) :group 'mindwtr)

(defcustom mindwtr-sync-idle-debounce 5
  "Seconds of idle after a save before an automatic sync fires."
  :type 'integer :group 'mindwtr)

(defcustom mindwtr-sync-interval 600
  "Seconds between periodic background syncs (nil disables)."
  :type '(choice (const nil) integer) :group 'mindwtr)

(defcustom mindwtr-backoff-initial 5
  "Initial retry delay, in seconds, after a retryable sync failure."
  :type 'integer :group 'mindwtr)

(defcustom mindwtr-backoff-max 300
  "Maximum retry delay, in seconds (the backoff is capped here)."
  :type 'integer :group 'mindwtr)

(defcustom mindwtr-backoff-max-attempts 12
  "Give up retrying after this many consecutive retryable failures."
  :type 'integer :group 'mindwtr)

(defvar mindwtr--timer nil)
(defvar mindwtr--debounce-timer nil)
(defvar mindwtr--retry-timer nil
  "Pending backoff retry timer, or nil.")
(defvar mindwtr--retry-attempts 0
  "Count of consecutive retryable sync failures.")
(defvar mindwtr--error-state nil
  "Non-nil (a message string) when sync has entered a persistent error state.")
(defvar mindwtr--sync-in-progress nil
  "Non-nil while a sync cycle is in flight.
Set when a cycle is launched and cleared in its completion callback -- the
cycle's network legs run asynchronously, so \"in flight\" spans real editor
time now, not just a nested event loop.  Any trigger (timer, focus, debounce,
manual) that fires while set is ignored so two cycles never run concurrently.
`mindwtr--sync-busy-p' owns the read: it also reclaims the guard when the
in-flight cycle is stale (see `mindwtr--sync-stale-seconds').")

(defvar mindwtr--sync-started-at nil
  "`float-time' when the in-flight sync cycle was launched, or nil.
Watchdog input for `mindwtr--sync-busy-p''s staleness check.")

(defconst mindwtr--sync-stale-seconds 300
  "Age after which an in-flight sync cycle is presumed wedged and reclaimed.
Every request is bounded by `mindwtr-api-timeout', so the completion callback
always fires in normal operation; this backstop only matters if a bug loses
the callback, and it turns that worst case into a delayed recovery instead of
auto-sync silently standing down forever.")

;;;###autoload
(define-derived-mode mindwtr-mode org-mode "Mindwtr"
  "Major mode for the Mindwtr-synced org file."
  ;; Org only registers TODO keywords from `org-todo-keywords' during its
  ;; own mode initialization, and that runs in the parent `org-mode' body
  ;; *before* this derived-mode body, so a plain `setq-local' here would
  ;; never reach `org-todo-kwd-alist'.  The canonical re-apply call,
  ;; `org-mode-restart', recurses infinitely from inside a derived mode
  ;; (it re-invokes `major-mode', i.e. `mindwtr-mode').  So we mirror the
  ;; proven pattern from `mindwtr-parse-ensure-keywords': dynamically bind
  ;; `org-todo-keywords' and re-run `org-mode' once, which rebuilds
  ;; `org-todo-kwd-alist' from those keywords.  That call resets
  ;; `major-mode' back to `org-mode', so we re-stamp the derived identity
  ;; afterward.  Guarded so a buffer already carrying the keywords is not
  ;; needlessly re-initialised.  We check the *whole* sequence, not just
  ;; NEXT: a personal config defining NEXT but not SOMEDAY/REF/etc. would
  ;; otherwise pass the guard and leave those keywords unregistered.
  (unless (seq-every-p (lambda (k) (member k org-todo-keywords-1))
                       mindwtr-model-todo-keyword-names)
    (let ((org-todo-keywords mindwtr-model-todo-keywords)
          (org-inhibit-startup t))
      (org-mode)))
  (setq major-mode 'mindwtr-mode
        mode-name "Mindwtr")
  (setq-local org-todo-keywords mindwtr-model-todo-keywords)
  (setq-local org-priority-highest ?A)
  (setq-local org-priority-lowest ?D)
  (setq-local org-priority-default ?C))

(define-key mindwtr-mode-map (kbd "C-c C-t") #'mindwtr-set-status)
(define-key mindwtr-mode-map (kbd "C-c C-a") #'mindwtr-set-area)
(define-key mindwtr-mode-map (kbd "C-c C-q") #'mindwtr-set-context)
;; C-c C-y shadows the obscure `org-evaluate-time-range' only inside
;; mindwtr-mode (never general org buffers); the KTD6 fallbacks were worse --
;; C-c C-u shadows the useful `org-up-heading' and C-c C-h collides with the
;; help character.
(define-key mindwtr-mode-map (kbd "C-c C-y") #'mindwtr-set-assignee)
(define-key mindwtr-mode-map (kbd "S-<right>") #'mindwtr-cycle-status-forward)
(define-key mindwtr-mode-map (kbd "S-<left>") #'mindwtr-cycle-status-backward)

(defun mindwtr--resolve-token ()
  "Return the bearer token from `mindwtr-auth-token' or auth-source."
  (or mindwtr-auth-token
      (let* ((host (url-host (url-generic-parse-url mindwtr-server-url)))
             (found (car (auth-source-search :host host :require '(:secret)))))
        (when found
          (let ((s (plist-get found :secret)))
            (if (functionp s) (funcall s) s))))
      (error "mindwtr: no auth token (set mindwtr-auth-token or auth-source)")))

(defun mindwtr--prepare ()
  "Validate config and bind API vars; return the sync buffer."
  (unless mindwtr-server-url (error "mindwtr: set `mindwtr-server-url'"))
  (unless mindwtr-file (error "mindwtr: set `mindwtr-file'"))
  (setq mindwtr-api-base-url mindwtr-server-url
        mindwtr-api-token (mindwtr--resolve-token))
  (find-file-noselect mindwtr-file))

(defun mindwtr--backoff-delay (attempt)
  "Return the backoff delay in seconds for ATTEMPT (1-based).
Exponential from `mindwtr-backoff-initial', capped at `mindwtr-backoff-max'."
  (min mindwtr-backoff-max
       (* mindwtr-backoff-initial (expt 2 (1- attempt)))))

(defun mindwtr--cancel-retry ()
  "Cancel any pending backoff retry timer."
  (when (timerp mindwtr--retry-timer)
    (cancel-timer mindwtr--retry-timer))
  (setq mindwtr--retry-timer nil))

(defun mindwtr--reset-backoff ()
  "Clear all backoff state after a success or a non-retryable failure."
  (mindwtr--cancel-retry)
  (setq mindwtr--retry-attempts 0
        mindwtr--error-state nil))

(defun mindwtr--schedule-retry ()
  "Arm the next backoff retry, or surface a persistent error if exhausted.
Assumes `mindwtr--retry-attempts' has already been incremented for the
failure being handled."
  (mindwtr--cancel-retry)
  (if (>= mindwtr--retry-attempts mindwtr-backoff-max-attempts)
      (progn
        (setq mindwtr--error-state
              (format "mindwtr: sync still failing after %d attempts; giving up (M-x mindwtr-sync to retry)"
                      mindwtr--retry-attempts))
        (message "%s" mindwtr--error-state))
    (let ((delay (mindwtr--backoff-delay mindwtr--retry-attempts)))
      (setq mindwtr--retry-timer (run-with-timer delay nil #'mindwtr--retry-sync))
      (message "mindwtr: server busy/unreachable; retrying in %ds (attempt %d/%d)"
               delay mindwtr--retry-attempts mindwtr-backoff-max-attempts))))

(defun mindwtr--retry-sync ()
  "Timer entry for a backoff retry: run one attempt, preserving the count."
  (setq mindwtr--retry-timer nil)
  (mindwtr--sync-attempt))

(defun mindwtr--sync-busy-p ()
  "Non-nil while a launched sync cycle is still legitimately in flight.
A cycle older than `mindwtr--sync-stale-seconds' is presumed wedged (its
completion callback was lost); the guard is reclaimed -- loudly -- and nil
returned so the caller may launch a fresh cycle."
  (cond
   ((not mindwtr--sync-in-progress) nil)
   ((and mindwtr--sync-started-at
         (> (- (float-time) mindwtr--sync-started-at)
            mindwtr--sync-stale-seconds))
    (message "mindwtr: previous sync never completed; reclaiming")
    (setq mindwtr--sync-in-progress nil
          mindwtr--sync-started-at nil)
    nil)
   (t t)))

(defun mindwtr--sync-handle-result (res)
  "Handle a completed sync cycle's result plist RES: reset backoff, report."
  (mindwtr--reset-backoff)
  (cond
   ;; The sync succeeded but writing the rebuilt buffer to disk
   ;; failed: the shadow/etag have advanced, so the on-disk file is
   ;; now stale and the unsaved-edits gate would stand down every
   ;; future tick silently.  Reuse the persistent error-state
   ;; machinery to make that divergence visible and recoverable --
   ;; it surfaces a standing message, itself stands down auto-sync,
   ;; and is cleared only by a manual `mindwtr-sync' (which
   ;; save-then-syncs and recovers).  (KTD-5)
   ((plist-get res :save-failed)
    (setq mindwtr--error-state
          "mindwtr: synced, but saving the file failed — disk is stale vs server (M-x mindwtr-sync to retry)")
    (message "%s" mindwtr--error-state))
   ((plist-get res :noop) (message "mindwtr: up to date"))
   (t (message "mindwtr: sync ok%s"
               (if (plist-get res :conflicts)
                   (format " (%d conflict(s) — see report)"
                           (length (plist-get res :conflicts)))
                 "")))))

(defun mindwtr--sync-handle-error (err)
  "Dispatch a failed sync cycle's ERR, a (SYMBOL . DATA) signal capture.
The async twin of the old synchronous attempt's `condition-case' arms:
retryable server errors (transport failure/429/5xx) arm the exponential
backoff; every other outcome resets it.  On any failure org and the shadow
are left untouched (the engine only writes them on success)."
  (let ((conds (get (car err) 'error-conditions))
        (data (cdr err)))
    (cond
     ((memq 'mindwtr-api-auth-error conds)
      (mindwtr--reset-backoff)
      (message "mindwtr: authentication failed (check token)"))
     ((and (memq 'mindwtr-api-error conds) (plist-get data :retryable))
      ;; Cap the counter at the ceiling so persistent failures don't
      ;; grow it unbounded across repeated triggers.
      (setq mindwtr--retry-attempts
            (min mindwtr-backoff-max-attempts
                 (1+ mindwtr--retry-attempts)))
      (mindwtr--schedule-retry))
     ((memq 'mindwtr-api-error conds)
      (mindwtr--reset-backoff)
      (message "mindwtr: server error %s" (plist-get data :status)))
     (t
      (mindwtr--reset-backoff)
      (message "mindwtr: %s" (error-message-string err))))))

(defun mindwtr--sync-attempt ()
  "Launch one sync cycle; backoff and reporting run in its completion callback.
With plz available the cycle's network legs are asynchronous: this returns as
soon as the cycle is launched and Emacs stays responsive for the round trips.
With a synchronous transport (tests, the url.el fallback) the whole cycle --
completion callback included -- finishes before this returns, preserving the
old blocking semantics.  Triggers while a cycle is in flight are ignored so
two cycles never run concurrently (`mindwtr--sync-busy-p', which also
reclaims a wedged guard).  A config error from `mindwtr--prepare' still
signals synchronously, before the in-flight guard is taken."
  (unless (mindwtr--sync-busy-p)
    (let ((buf (mindwtr--prepare)))
      (setq mindwtr--sync-in-progress t
            mindwtr--sync-started-at (float-time))
      (condition-case err
          (mindwtr-sync-once-async
           buf (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
           (lambda (res cb-err)
             (setq mindwtr--sync-in-progress nil
                   mindwtr--sync-started-at nil)
             (if cb-err
                 (mindwtr--sync-handle-error cb-err)
               (mindwtr--sync-handle-result res))))
        ;; The async entry routes cycle errors through the callback and cannot
        ;; itself signal -- except a `quit' (C-g mid-launch) or a signal from
        ;; the handlers above.  Release the guard rather than wedging it, then
        ;; re-raise.  (Releasing after the callback already ran is a no-op.)
        ((error quit)
         (setq mindwtr--sync-in-progress nil
               mindwtr--sync-started-at nil)
         (signal (car err) (cdr err)))))))

(defun mindwtr--file-buffer-dirty-p (path)
  "Non-nil when PATH is open in a buffer with unsaved edits.
Nil when PATH is nil or not visited.  `find-buffer-visiting' gives
truename/symlink-safe matching."
  (and path
       (let ((buf (find-buffer-visiting path)))
         (and buf (buffer-modified-p buf)))))

(defun mindwtr--buffer-has-unsaved-edits-p ()
  "Non-nil when the tasks file OR the archive file has unsaved edits open.
Both are full rebuild targets, so either one dirty must stand down a background
sync (R10).  Nil when neither is open-and-modified (no buffer means no
in-progress edits, so an automatic sync is free to run and rebuild)."
  (or (mindwtr--file-buffer-dirty-p mindwtr-file)
      (mindwtr--file-buffer-dirty-p (mindwtr-archive-path))))

(defun mindwtr--auto-sync ()
  "Entry point for automatic triggers (save/focus/periodic).
A no-op while a cycle is in progress, while a backoff retry is armed, after
sync has given up, or while the synced buffer has unsaved edits -- so a
background rebuild never erases the user's in-progress work, backoff fully
owns the retry cadence, and overlapping triggers never pile on.  A manual
`mindwtr-sync' is the escape hatch that resets this state and saves first."
  (unless (or (mindwtr--sync-busy-p)
              (timerp mindwtr--retry-timer)
              mindwtr--error-state
              (mindwtr--buffer-has-unsaved-edits-p))
    (mindwtr--sync-attempt)))

;;;###autoload
(defun mindwtr-sync ()
  "Run one synchronization cycle now.
A manual sync clears any pending backoff, saves the synced buffer first when
it has unsaved edits, then starts a fresh attempt.  An explicit sync never
refuses on a dirty buffer (it bypasses the unsaved-edits gate), and making
\"save = commit point\" means a manual sync always leaves the buffer clean."
  (interactive)
  (mindwtr--reset-backoff)
  ;; Save-then-sync.  Echo-suppressed (the cycle is about to run, so the
  ;; pre-save must not separately arm the debounce) but WITHOUT content
  ;; protection: a manual sync is an ordinary user save, so the user's
  ;; before-save-hooks run, exactly as a real `C-x C-s' would (KTD-7).
  (dolist (path (list mindwtr-file (mindwtr-archive-path)))
    (when path
      (let ((buf (find-buffer-visiting path)))
        (when (and buf (buffer-modified-p buf))
          (with-current-buffer buf
            (mindwtr-sync--save-buffer-quietly))))))
  ;; The cycle completes asynchronously (its own message follows); say the
  ;; launch happened so an explicit M-x sync is not silent in the meantime.
  (message "mindwtr: syncing...")
  (mindwtr--sync-attempt))

;;;###autoload
(defun mindwtr-bootstrap ()
  "Fetch the remote snapshot and render a fresh `mindwtr-file' (overwrites)."
  (interactive)
  (mindwtr--prepare)
  (when (or (not (file-exists-p mindwtr-file))
            (yes-or-no-p "Overwrite local mindwtr file from server? "))
    (let* ((got (mindwtr-api-get-data))
           ;; Create initial settings when a freshly provisioned namespace has
           ;; none, so the first sync's settings merge is never handed a null
           ;; blob (the Cloud server 500s on that).
           (appdata (mindwtr-model-ensure-settings (plist-get got :appdata))))
      (with-current-buffer (find-file-noselect mindwtr-file)
        (erase-buffer)
        (mindwtr-mode)
        (mindwtr-reconcile-buffer appdata)
        ;; Quiet-save (content-protected, like the engine save) so this
        ;; deliberate overwrite does not echo a stray HEAD-only sync ~5s
        ;; later when `mindwtr-auto-sync-mode' is on.
        (mindwtr-sync--save-buffer-quietly t))
      (mindwtr-shadow-save appdata)
      (mindwtr-shadow-set-etag (plist-get got :etag))
      (message "mindwtr: bootstrapped from server"))))

(defun mindwtr--maybe-debounced-sync ()
  "Schedule a debounced auto-sync after saving the tasks OR the archive file.
Both are synced rebuild targets, so a save of either arms the debounce (R10);
a save of any other file is ignored.  A save the engine itself performed
(`mindwtr--inhibit-save-sync' bound) is ignored outright: it leaves any pending
debounce timer untouched, so the engine's own writes never echo a stray
HEAD-only sync ~5s later."
  (unless mindwtr--inhibit-save-sync
    (when (and buffer-file-name
               (or (and mindwtr-file (file-equal-p buffer-file-name mindwtr-file))
                   (let ((ap (mindwtr-archive-path)))
                     (and ap (file-equal-p buffer-file-name ap)))))
      (when mindwtr--debounce-timer (cancel-timer mindwtr--debounce-timer))
      (setq mindwtr--debounce-timer
            (run-with-idle-timer mindwtr-sync-idle-debounce nil #'mindwtr--auto-sync)))))

;;;###autoload
(define-minor-mode mindwtr-auto-sync-mode
  "Globally enable automatic Mindwtr syncing (save-debounce + periodic + focus)."
  :global t :group 'mindwtr
  (if mindwtr-auto-sync-mode
      (progn
        (add-hook 'after-save-hook #'mindwtr--maybe-debounced-sync)
        (add-function :after after-focus-change-function #'mindwtr--on-focus)
        (when mindwtr-sync-interval
          (setq mindwtr--timer
                (run-with-timer mindwtr-sync-interval mindwtr-sync-interval
                                #'mindwtr--auto-sync))))
    (remove-hook 'after-save-hook #'mindwtr--maybe-debounced-sync)
    (remove-function after-focus-change-function #'mindwtr--on-focus)
    (when mindwtr--timer (cancel-timer mindwtr--timer) (setq mindwtr--timer nil))
    ;; Don't leave a backoff retry firing after auto-sync is turned off.
    (mindwtr--cancel-retry)))

(defvar mindwtr--last-focus-sync 0)
(defun mindwtr--on-focus (&rest _)
  "Auto-sync on frame focus, throttled to 30s.
The engine HEAD-guards a clean buffer, so a focus with nothing to do is a
single cheap HEAD request."
  (when (and (frame-focus-state)
             (> (- (float-time) mindwtr--last-focus-sync) 30))
    (setq mindwtr--last-focus-sync (float-time))
    (mindwtr--auto-sync)))

(provide 'mindwtr)
;;; mindwtr.el ends here
