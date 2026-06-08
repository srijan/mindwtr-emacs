;;; mindwtr-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'mindwtr)

(defun mindwtr-test--kill-file-buffer (f)
  "Kill the buffer visiting F without a modified-buffer prompt."
  (when (get-file-buffer f)
    (with-current-buffer (get-file-buffer f) (set-buffer-modified-p nil))
    (kill-buffer (get-file-buffer f))))

(ert-deftest mindwtr-mode-sets-todo-keywords ()
  (with-temp-buffer
    (mindwtr-mode)
    (should (member "NEXT" (mapcar #'car org-todo-kwd-alist)))
    (should (member "ACTIVE" (mapcar #'car org-todo-kwd-alist)))))

(ert-deftest mindwtr-token-prefers-explicit-var ()
  (let ((mindwtr-auth-token "explicit"))
    (should (string= (mindwtr--resolve-token) "explicit"))))

(ert-deftest mindwtr-sync-command-is-interactive ()
  (should (commandp 'mindwtr-sync)))

(ert-deftest mindwtr-backoff-delay-is-exponential-and-capped ()
  (let ((mindwtr-backoff-initial 5) (mindwtr-backoff-max 300))
    (should (= (mindwtr--backoff-delay 1) 5))
    (should (= (mindwtr--backoff-delay 2) 10))
    (should (= (mindwtr--backoff-delay 3) 20))
    (should (= (mindwtr--backoff-delay 6) 160))
    (should (= (mindwtr--backoff-delay 7) 300))    ; 5*64=320, capped to 300
    (should (= (mindwtr--backoff-delay 12) 300))))

(ert-deftest mindwtr-backoff-gives-up-after-max-attempts ()
  "At the attempt ceiling, schedule-retry surfaces a persistent error and
does NOT arm another timer."
  (let ((mindwtr-backoff-max-attempts 3)
        (mindwtr--retry-attempts 3)
        (mindwtr--retry-timer nil)
        (mindwtr--error-state nil))
    (mindwtr--schedule-retry)
    (should mindwtr--error-state)
    (should-not mindwtr--retry-timer)))

(ert-deftest mindwtr-backoff-arms-timer-when-not-exhausted ()
  (let ((mindwtr-backoff-max-attempts 12)
        (mindwtr--retry-attempts 1)
        (mindwtr--retry-timer nil)
        (mindwtr--error-state nil))
    (unwind-protect
        (progn
          (mindwtr--schedule-retry)
          (should (timerp mindwtr--retry-timer))
          (should-not mindwtr--error-state))
      (when (timerp mindwtr--retry-timer) (cancel-timer mindwtr--retry-timer)))))

(ert-deftest mindwtr-retryable-error-triggers-backoff ()
  "A 503 from the server increments the attempt count and arms a retry timer
\(rather than failing the sync outright)."
  (let* ((f (make-temp-file "mw-sync" nil ".org"))
         (dir (make-temp-file "mw-bk" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr-file f)
         (mindwtr--retry-attempts 0)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (mindwtr-api-http-function
          (lambda (_req) '(:status 503 :headers nil :body "boom"))))
    (unwind-protect
        (progn
          (with-temp-file f (insert ""))
          (mindwtr--sync-attempt)
          (should (= mindwtr--retry-attempts 1))
          (should (timerp mindwtr--retry-timer)))
      (when (timerp mindwtr--retry-timer) (cancel-timer mindwtr--retry-timer))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-auto-sync-defers-while-in-progress ()
  "A trigger that fires re-entrantly (e.g. a timer inside a blocked HTTP
call) must not launch a second sync cycle."
  (let ((mindwtr--sync-in-progress t)
        (mindwtr--retry-timer nil)
        (mindwtr--error-state nil)
        (called nil)
        (mindwtr-api-http-function
         (lambda (_r) (setq called t) '(:status 200 :headers nil :body ""))))
    (mindwtr--auto-sync)
    (should-not called)))

(ert-deftest mindwtr-auto-sync-defers-after-give-up ()
  "Once sync has given up (persistent error), passive triggers stop
hammering the server; only a manual sync resumes."
  (let ((mindwtr--sync-in-progress nil)
        (mindwtr--retry-timer nil)
        (mindwtr--error-state "dead")
        (called nil)
        (mindwtr-api-http-function
         (lambda (_r) (setq called t) '(:status 200 :headers nil :body ""))))
    (mindwtr--auto-sync)
    (should-not called)))

(ert-deftest mindwtr-backoff-caps-attempts-at-ceiling ()
  "At the ceiling, another retryable failure does not grow the counter past
the max and gives up (no further timer)."
  (let* ((f (make-temp-file "mw-cap" nil ".org"))
         (dir (make-temp-file "mw-cap-bk" t))
         (mindwtr-shadow-directory dir)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr-file f)
         (mindwtr-backoff-max-attempts 3)
         (mindwtr--retry-attempts 3)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (mindwtr--sync-in-progress nil)
         (mindwtr-api-http-function
          (lambda (_req) '(:status 503 :headers nil :body "boom"))))
    (unwind-protect
        (progn
          (with-temp-file f (insert ""))
          (mindwtr--sync-attempt)
          (should (= mindwtr--retry-attempts 3))   ; capped, not 4
          (should mindwtr--error-state)
          (should-not mindwtr--retry-timer))
      (when (timerp mindwtr--retry-timer) (cancel-timer mindwtr--retry-timer))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f)
      (delete-directory dir t))))

(ert-deftest mindwtr-mode-binds-type-aware-status-keys ()
  "mindwtr-mode shadows C-c C-t and S-arrow with the type-aware commands."
  (with-temp-buffer
    (mindwtr-mode)
    (should (eq (lookup-key mindwtr-mode-map (kbd "C-c C-t")) #'mindwtr-set-status))
    (should (eq (lookup-key mindwtr-mode-map (kbd "S-<right>")) #'mindwtr-cycle-status-forward))
    (should (eq (lookup-key mindwtr-mode-map (kbd "S-<left>")) #'mindwtr-cycle-status-backward))))

(ert-deftest mindwtr-success-clears-backoff-state ()
  "A successful (no-op) sync resets the attempt counter and clears the
persistent error."
  (let* ((dir (make-temp-file "mw-ok" t))
         (f (make-temp-file "mw-ok-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr-file f)
         (mindwtr--retry-attempts 4)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state "stale error")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              (m (error "unexpected %s" m))))))
    (unwind-protect
        (progn
          (with-temp-file f (insert ""))
          (mindwtr-shadow-save '(:tasks nil :projects nil :sections nil
                                 :areas nil :settings nil))
          (mindwtr-shadow-set-etag "v1")
          (mindwtr--sync-attempt)
          (should (= mindwtr--retry-attempts 0))
          (should-not mindwtr--error-state))
      (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
      (delete-file f)
      (delete-directory dir t))))

;;; U3: gate auto-sync on unsaved buffer edits -------------------------------

(ert-deftest mindwtr-auto-sync-stands-down-on-unsaved-edits ()
  "With the synced file open and modified, an automatic trigger does not
launch a sync cycle (a rebuild would erase the in-progress edit)."
  (let* ((f (make-temp-file "mw-gate" nil ".org"))
         (mindwtr-file f)
         (mindwtr--sync-in-progress nil)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (called nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (insert "edit\n")
          (should (buffer-modified-p))
          (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                     (lambda () (setq called t))))
            (mindwtr--auto-sync))
          (should-not called))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-auto-sync-runs-when-buffer-clean ()
  "With the synced file open and clean, an automatic trigger runs."
  (let* ((f (make-temp-file "mw-gate2" nil ".org"))
         (mindwtr-file f)
         (mindwtr--sync-in-progress nil)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (called nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (should-not (buffer-modified-p))
          (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                     (lambda () (setq called t))))
            (mindwtr--auto-sync))
          (should called))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-auto-sync-runs-when-file-not-open ()
  "When the synced file is not open in any buffer, an automatic trigger runs
freely -- there are no in-memory edits to disturb."
  (let* ((f (make-temp-file "mw-gate3" nil ".org"))
         (mindwtr-file f)
         (mindwtr--sync-in-progress nil)
         (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (called nil))
    (unwind-protect
        (progn
          (should-not (find-buffer-visiting f))
          (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                     (lambda () (setq called t))))
            (mindwtr--auto-sync))
          (should called))
      (delete-file f))))

(ert-deftest mindwtr-auto-sync-existing-guards-still-short-circuit ()
  "The pre-existing guards (in-progress / armed retry / error-state) skip the
cycle regardless of buffer state -- the new gate is additive, not a
replacement."
  (let* ((f (make-temp-file "mw-gate4" nil ".org"))
         (mindwtr-file f))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          ;; clean buffer (the gate would allow), but each existing guard set
          (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                     (lambda () (error "should not run"))))
            (let ((mindwtr--sync-in-progress t)
                  (mindwtr--retry-timer nil) (mindwtr--error-state nil))
              (should-not (mindwtr--auto-sync)))
            (let ((mindwtr--sync-in-progress nil)
                  (mindwtr--retry-timer (run-with-idle-timer 9999 nil #'ignore))
                  (mindwtr--error-state nil))
              (unwind-protect (should-not (mindwtr--auto-sync))
                (cancel-timer mindwtr--retry-timer)))
            (let ((mindwtr--sync-in-progress nil)
                  (mindwtr--retry-timer nil) (mindwtr--error-state "dead"))
              (should-not (mindwtr--auto-sync)))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-buffer-has-unsaved-edits-truth-table ()
  "nil when mindwtr-file unset; nil when not open; nil when open+clean; t when
open+modified."
  (let ((f (make-temp-file "mw-tt" nil ".org")))
    (unwind-protect
        (progn
          (let ((mindwtr-file nil))
            (should-not (mindwtr--buffer-has-unsaved-edits-p)))
          (let ((mindwtr-file f))
            (should-not (mindwtr--buffer-has-unsaved-edits-p))       ; not open
            (with-current-buffer (find-file-noselect f)
              (should-not (mindwtr--buffer-has-unsaved-edits-p))     ; open + clean
              (insert "x\n")
              (should (mindwtr--buffer-has-unsaved-edits-p)))))      ; open + modified
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

;;; U2: sync-attempt raises a persistent error on a failed buffer save -------

(ert-deftest mindwtr-sync-attempt-flags-error-state-on-save-failure ()
  "A successful sync whose buffer save fails raises mindwtr--error-state, which
then stands down auto-sync until a manual sync clears it."
  (let* ((dir (make-temp-file "mw-sf2" t))
         (f (make-temp-file "mw-sf2-org" nil ".org"))
         (mindwtr-shadow-directory dir)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr-file f)
         (mindwtr--error-state nil)
         (mindwtr--sync-in-progress nil)
         (mindwtr--retry-timer nil)
         (put-body nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("HEAD" '(:status 200 :headers (("ETag" . "v1")) :body ""))
              ("PUT" (setq put-body (plist-get req :body))
                     '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))
              ("GET" (list :status 200 :headers '(("ETag" . "v2")) :body put-body))))))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* Work\n:PROPERTIES:\n:MW_TYPE: area\n:MW_ID: a1\n:END:\n"
                    "** NEXT do it\n:PROPERTIES:\n:MW_TYPE: task\n:MW_ID: t1\n:END:\n"))
          (mindwtr-shadow-save
           '(:tasks ((:id "t1" :title "old" :status "next" :rev 1
                      :createdAt "2026-01-01T00:00:00Z" :updatedAt "U"))
             :projects nil :sections nil
             :areas ((:id "a1" :name "Work" :rev 1)) :settings nil))
          (cl-letf (((symbol-function 'save-buffer)
                     (lambda (&rest _) (error "disk full"))))
            (mindwtr--sync-attempt))
          (should mindwtr--error-state)
          ;; the error-state now stands a passive trigger down
          (let ((called nil))
            (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                       (lambda () (setq called t))))
              (mindwtr--auto-sync)
              (should-not called))))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f)
      (delete-directory dir t))))

;;; U4: manual mindwtr-sync is save-then-sync --------------------------------

(ert-deftest mindwtr-sync-saves-buffer-before-syncing ()
  "A manual sync on a dirty buffer saves it first, so the buffer is clean by
the time the cycle runs."
  (let* ((f (make-temp-file "mw-mansave" nil ".org"))
         (mindwtr-file f)
         (mindwtr--retry-attempts 0) (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (clean-when-attempted nil) (attempted nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (insert "edit\n")
          (should (buffer-modified-p))
          (cl-letf (((symbol-function 'mindwtr--sync-attempt)
                     (lambda ()
                       (setq attempted t
                             clean-when-attempted
                             (not (buffer-modified-p (get-file-buffer f)))))))
            (mindwtr-sync))
          (should attempted)
          (should clean-when-attempted)
          (should-not (buffer-modified-p)))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-sync-manual-presave-suppresses-debounce ()
  "The manual pre-save is echo-suppressed: it arms no debounce timer."
  (let* ((f (make-temp-file "mw-manecho" nil ".org"))
         (mindwtr-file f)
         (mindwtr--debounce-timer nil)
         (mindwtr--retry-attempts 0) (mindwtr--retry-timer nil)
         (mindwtr--error-state nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (insert "edit\n")
          (let ((after-save-hook (cons #'mindwtr--maybe-debounced-sync after-save-hook)))
            (cl-letf (((symbol-function 'mindwtr--sync-attempt) #'ignore))
              (mindwtr-sync)))
          (should-not mindwtr--debounce-timer))
      (when (timerp mindwtr--debounce-timer) (cancel-timer mindwtr--debounce-timer))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-sync-clean-buffer-no-redundant-save ()
  "A manual sync on an already-clean buffer performs no save and proceeds."
  (let* ((f (make-temp-file "mw-manclean" nil ".org"))
         (mindwtr-file f)
         (mindwtr--retry-attempts 0) (mindwtr--retry-timer nil)
         (mindwtr--error-state nil)
         (saved nil) (attempted nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (should-not (buffer-modified-p))
          (cl-letf (((symbol-function 'mindwtr-sync--save-buffer-quietly)
                     (lambda (&rest _) (setq saved t)))
                    ((symbol-function 'mindwtr--sync-attempt)
                     (lambda () (setq attempted t))))
            (mindwtr-sync))
          (should-not saved)
          (should attempted))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

(ert-deftest mindwtr-sync-manual-still-resets-backoff ()
  "Manual sync remains the backoff escape hatch: it clears retry state."
  (let* ((f (make-temp-file "mw-manbk" nil ".org"))
         (mindwtr-file f)
         (mindwtr--retry-attempts 4)
         (mindwtr--retry-timer (run-with-idle-timer 9999 nil #'ignore))
         (mindwtr--error-state "stale"))
    (unwind-protect
        (with-current-buffer (find-file-noselect f)
          (cl-letf (((symbol-function 'mindwtr--sync-attempt) #'ignore))
            (mindwtr-sync))
          (should (= mindwtr--retry-attempts 0))
          (should-not mindwtr--error-state)
          (should-not mindwtr--retry-timer))
      (when (timerp mindwtr--retry-timer) (cancel-timer mindwtr--retry-timer))
      (mindwtr-test--kill-file-buffer f)
      (delete-file f))))

;;; U5: bootstrap routes its save through the quiet helper -------------------

(ert-deftest mindwtr-bootstrap-saves-and-suppresses-echo ()
  "Bootstrap leaves the file saved (buffer unmodified) and arms no debounce
echo, even with mindwtr--maybe-debounced-sync live on after-save-hook."
  (let* ((dir (make-temp-file "mw-boot" t))
         (mindwtr-shadow-directory dir)
         (f (expand-file-name "mw-boot.org" dir))   ; does not exist yet
         (mindwtr-file f)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr--debounce-timer nil)
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ("GET" (list :status 200 :headers '(("ETag" . "v1"))
                           :body (concat "{\"tasks\":[],\"projects\":[],"
                                         "\"sections\":[],\"areas\":["
                                         "{\"id\":\"a1\",\"name\":\"Work\",\"rev\":1}],"
                                         "\"settings\":{}}")))
              (m (error "mindwtr: unexpected %s on bootstrap" m))))))
    (unwind-protect
        (let ((after-save-hook (cons #'mindwtr--maybe-debounced-sync after-save-hook)))
          (mindwtr-bootstrap)
          (should (file-exists-p f))
          (with-current-buffer (find-file-noselect f)
            (should-not (buffer-modified-p)))
          (should-not mindwtr--debounce-timer))
      (when (timerp mindwtr--debounce-timer) (cancel-timer mindwtr--debounce-timer))
      (mindwtr-test--kill-file-buffer f)
      (when (file-exists-p f) (delete-file f))
      (delete-directory dir t))))

(ert-deftest mindwtr-bootstrap-synthesizes-initial-settings-when-server-has-none ()
  "A freshly provisioned namespace returns no `settings'; bootstrap must
synthesize a non-null blob into the shadow so the first sync's settings merge
is never handed a null value (the Cloud server 500s on that).  Guards the
`else' arm of the settings synthesis in `mindwtr-bootstrap'."
  (let* ((dir (make-temp-file "mw-boot-settings" t))
         (mindwtr-shadow-directory dir)
         (f (expand-file-name "mw-boot.org" dir))   ; does not exist yet
         (mindwtr-file f)
         (mindwtr-server-url "https://mw.example/")
         (mindwtr-auth-token "x")
         (mindwtr-api-http-function
          (lambda (req)
            (pcase (plist-get req :method)
              ;; No `settings' key at all -- the fresh-namespace case.
              ("GET" (list :status 200 :headers '(("ETag" . "v1"))
                           :body (concat "{\"tasks\":[],\"projects\":[],"
                                         "\"sections\":[],\"areas\":[]}")))
              (m (error "mindwtr: unexpected %s on bootstrap" m))))))
    (unwind-protect
        (progn
          (mindwtr-bootstrap)
          (let ((settings (plist-get (mindwtr-shadow-load) :settings)))
            (should settings)
            (should (plist-get settings :syncPreferences))))
      (mindwtr-test--kill-file-buffer f)
      (when (file-exists-p f) (delete-file f))
      (delete-directory dir t))))
