;;; mindwtr.el --- Sync org-mode GTD with Mindwtr Cloud -*- lexical-binding: t; -*-
;; Author: Srijan
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (plz "0.7"))
;; Keywords: outlines, convenience
;;; Commentary:
;; Bidirectional sync between a single org file and a self-hosted Mindwtr
;; Cloud server.  Entry command: `mindwtr-sync'.
;;; Code:

(require 'org)
(require 'auth-source)
(require 'url-parse)
(require 'mindwtr-api)
(require 'mindwtr-sync)
(require 'mindwtr-shadow)
(require 'mindwtr-reconcile)

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

(defvar mindwtr--timer nil)
(defvar mindwtr--debounce-timer nil)

(defconst mindwtr--todo-keywords
  '((sequence "INBOX(i)" "NEXT(n)" "WAIT(w)" "SOMEDAY(s)" "REF(r)" "ACTIVE(a)"
              "|" "DONE(d)" "ARCH(x)")))

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
  ;; needlessly re-initialised.
  (unless (member "NEXT" org-todo-keywords-1)
    (let ((org-todo-keywords mindwtr--todo-keywords)
          (org-inhibit-startup t))
      (org-mode)))
  (setq major-mode 'mindwtr-mode
        mode-name "Mindwtr")
  (setq-local org-todo-keywords mindwtr--todo-keywords)
  (setq-local org-priority-highest ?A)
  (setq-local org-priority-lowest ?D)
  (setq-local org-priority-default ?C))

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

;;;###autoload
(defun mindwtr-sync ()
  "Run one synchronization cycle now."
  (interactive)
  (let ((buf (mindwtr--prepare)))
    (condition-case err
        (let ((res (mindwtr-sync-once buf (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))))
          (message "mindwtr: sync ok%s"
                   (if (plist-get res :conflicts)
                       (format " (%d conflict(s) — see report)"
                               (length (plist-get res :conflicts)))
                     "")))
      (mindwtr-api-auth-error (message "mindwtr: authentication failed (check token)"))
      (mindwtr-api-error (message "mindwtr: server error %s"
                                  (plist-get (cdr err) :status)))
      (error (message "mindwtr: %s" (error-message-string err))))))

;;;###autoload
(defun mindwtr-bootstrap ()
  "Fetch the remote snapshot and render a fresh `mindwtr-file' (overwrites)."
  (interactive)
  (mindwtr--prepare)
  (when (or (not (file-exists-p mindwtr-file))
            (yes-or-no-p "Overwrite local mindwtr file from server? "))
    (let* ((got (mindwtr-api-get-data))
           (appdata (plist-get got :appdata)))
      (with-current-buffer (find-file-noselect mindwtr-file)
        (erase-buffer)
        (mindwtr-mode)
        (mindwtr-reconcile-buffer appdata)
        (save-buffer))
      (mindwtr-shadow-save appdata)
      (mindwtr-shadow-set-etag (plist-get got :etag))
      (message "mindwtr: bootstrapped from server"))))

(defun mindwtr--maybe-debounced-sync ()
  "Schedule a debounced sync after saving the mindwtr file."
  (when (and mindwtr-file buffer-file-name
             (file-equal-p buffer-file-name mindwtr-file))
    (when mindwtr--debounce-timer (cancel-timer mindwtr--debounce-timer))
    (setq mindwtr--debounce-timer
          (run-with-idle-timer mindwtr-sync-idle-debounce nil #'mindwtr-sync))))

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
                                #'mindwtr--periodic-sync))))
    (remove-hook 'after-save-hook #'mindwtr--maybe-debounced-sync)
    (remove-function after-focus-change-function #'mindwtr--on-focus)
    (when mindwtr--timer (cancel-timer mindwtr--timer) (setq mindwtr--timer nil))))

(defvar mindwtr--last-focus-sync 0)
(defun mindwtr--on-focus (&rest _)
  "Sync on frame focus, throttled to 30s."
  (when (and (frame-focus-state)
             (> (- (float-time) mindwtr--last-focus-sync) 30))
    (setq mindwtr--last-focus-sync (float-time))
    (ignore-errors (mindwtr-sync))))

(defun mindwtr--periodic-sync ()
  "Periodic sync that skips work when the remote ETag is unchanged."
  (ignore-errors
    (mindwtr--prepare)
    (let ((etag (mindwtr-api-head-etag)))
      (unless (equal etag (mindwtr-shadow-get-etag))
        (mindwtr-sync)))))

(provide 'mindwtr)
;;; mindwtr.el ends here
