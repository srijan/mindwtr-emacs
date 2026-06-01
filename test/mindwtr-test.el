;;; mindwtr-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr)

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
