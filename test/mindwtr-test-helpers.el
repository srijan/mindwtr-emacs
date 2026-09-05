;;; mindwtr-test-helpers.el --- Shared fakes for the ERT suites -*- lexical-binding: t; -*-

;;; Commentary:
;; The two adapters a full sync cycle needs in a test, in one place: an
;; in-memory Mindwtr Cloud at the HTTP seam (`mindwtr-test-server') and the
;; in-memory store at the shadow seam, wired together by
;; `mindwtr-test-with-sync-env'.  A cycle run inside the macro touches no
;; files and no network.  Not a *-test.el file, so the Makefile glob does not
;; load it as a suite; suites `require' it.

;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)
(require 'mindwtr-model)
(require 'mindwtr-shadow)
(require 'mindwtr-api)

;;; In-memory server

(cl-defstruct (mindwtr-test-server (:constructor mindwtr-test-server--make)
                                   (:copier nil))
  "An in-memory Mindwtr Cloud.
STATE is the current AppData plist (what GET returns, re-encoded through
JSON so nil/false/[] normalize as on the wire).  ETAG is the current tag,
\"v1\", \"v2\", ... advancing on every PUT.  LAST-PUT is the raw body of the
most recent PUT (nil before any), REQUESTS the methods seen, newest first."
  state etag last-put requests)

(defun mindwtr-test-server (&optional initial)
  "Return a fresh server holding INITIAL (default: an empty AppData) at tag v1."
  (mindwtr-test-server--make
   :state (copy-tree (or initial (mindwtr-model-ensure-settings
                                  '(:tasks nil :projects nil :sections nil
                                    :areas nil :people nil))))
   :etag "v1"))

(defun mindwtr-test-server-http (server)
  "Return the `mindwtr-api-http-function' adapter for SERVER.
A PUT replaces the whole state (full-replace, like the real server) and
advances the tag; HEAD and GET report the current tag."
  (lambda (req)
    (push (plist-get req :method) (mindwtr-test-server-requests server))
    (pcase (plist-get req :method)
      ("HEAD" (list :status 200
                    :headers (list (cons "ETag" (mindwtr-test-server-etag server)))
                    :body ""))
      ("GET" (list :status 200
                   :headers (list (cons "ETag" (mindwtr-test-server-etag server)))
                   :body (mindwtr-util-json-ascii (mindwtr-test-server-state server))))
      ("PUT" (let ((body (plist-get req :body)))
               (setf (mindwtr-test-server-last-put server) body
                     (mindwtr-test-server-state server) (mindwtr-util-json-decode body)
                     (mindwtr-test-server-etag server)
                     (format "v%d" (1+ (string-to-number
                                        (substring (mindwtr-test-server-etag server) 1)))))
               (list :status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}"))))))

;;; One-form sync environment

(defmacro mindwtr-test-with-sync-env (spec &rest body)
  "Run BODY with an in-memory server and an in-memory shadow store in place.
SPEC is a plist:
  :server SYM      bind SYM to the `mindwtr-test-server' (optional)
  :initial APPDATA the server's starting state (default empty)
  :shadow APPDATA  seed the Shadow (default: nothing seeded)
  :etag STRING     seed the recorded etag
  :latches LIST    latch names to pre-set
The API base URL and token are bound to dummies; `mindwtr-shadow-directory'
is untouched and never read."
  (declare (indent 1) (debug t))
  (let* ((sym (or (plist-get spec :server) (make-symbol "server"))))
    `(let* ((,sym (mindwtr-test-server ,(plist-get spec :initial)))
            (mindwtr-shadow-store (mindwtr-shadow-memory-store))
            (mindwtr-api-base-url "https://mw.example/")
            (mindwtr-api-token "x")
            (mindwtr-api-http-function (mindwtr-test-server-http ,sym)))
       ,@(when (plist-member spec :shadow)
           `((mindwtr-shadow-save ,(plist-get spec :shadow))))
       ,@(when (plist-member spec :etag)
           `((mindwtr-shadow-set-etag ,(plist-get spec :etag))))
       ,@(when (plist-member spec :latches)
           `((dolist (l ,(plist-get spec :latches)) (mindwtr-shadow-latch l))))
       ,@body)))

;;; Buffers

(defun mindwtr-test--kill-file-buffer (f)
  "Kill the buffer visiting F without a modified-buffer prompt."
  (when (get-file-buffer f)
    (with-current-buffer (get-file-buffer f) (set-buffer-modified-p nil))
    (kill-buffer (get-file-buffer f))))

(provide 'mindwtr-test-helpers)
;;; mindwtr-test-helpers.el ends here
