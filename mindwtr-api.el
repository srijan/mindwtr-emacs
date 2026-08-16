;;; mindwtr-api.el --- Mindwtr Cloud REST client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Srijan Choudhary
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.
;; This program comes with ABSOLUTELY NO WARRANTY.  It is free software
;; under the GNU General Public License v3 or later; see the LICENSE file
;; in the project root, or <https://www.gnu.org/licenses/>.

;;; Commentary:
;; GET/HEAD/PUT /v1/data with an injectable transport.  The default
;; transport uses plz.el when available, else url.el.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)

(defvar mindwtr-api-base-url nil "Base URL of the Mindwtr Cloud server (trailing slash ok).")
(defvar mindwtr-api-token nil "Bearer token for the Mindwtr Cloud server.")

(defcustom mindwtr-api-timeout 60
  "Seconds before an in-flight request to the Mindwtr server is abandoned.
Bounds every plz request (sync and async).  The async sync pipeline relies on
this to guarantee its completion callback always fires -- a hung request must
time out and error rather than leave `mindwtr--sync-in-progress' wedged."
  :type 'integer :group 'mindwtr)

(define-error 'mindwtr-api-error "Mindwtr API error")
(define-error 'mindwtr-api-auth-error "Mindwtr API authentication failed"
  'mindwtr-api-error)

(declare-function plz "plz" (method url &rest args))
(declare-function plz-error-response "plz" (error))
(declare-function plz-error-p "plz" (object))
(declare-function plz-response-status "plz" (response))
(declare-function plz-response-headers "plz" (response))
(declare-function plz-response-body "plz" (response))

;; url.el dynamic variables used in the fallback transport
(defvar url-request-method)
(defvar url-request-extra-headers)
(defvar url-request-data)

(defun mindwtr-api--plz-resp (r)
  "Convert a plz-response struct R to the transport's (:status :headers :body)."
  (list :status (plz-response-status r)
        :headers (plz-response-headers r)
        :body (plz-response-body r)))

(defun mindwtr-api--plz-error-resp (e)
  "Response plist for plz-error struct E.
An HTTP-level failure carries the server's real response; a curl-level
failure (network down, timeout, dead socket) has none and maps to status 0,
which `mindwtr-api--check' classifies as a retryable transport failure."
  (let ((r (and e (plz-error-response e))))
    (if r (mindwtr-api--plz-resp r)
      '(:status 0 :headers nil :body nil))))

(defun mindwtr-api--url-http (req)
  "Synchronous url.el transport for REQ (the no-plz fallback)."
  (let ((url-request-method (plist-get req :method))
        (url-request-extra-headers (plist-get req :headers))
        (url-request-data (when (plist-get req :body)
                            (encode-coding-string (plist-get req :body) 'utf-8))))
    (let ((buf (url-retrieve-synchronously (plist-get req :url) t)))
      ;; A dropped connection (e.g. a dead TLS socket after the laptop
      ;; resumes from sleep) makes url-retrieve-synchronously return nil.
      ;; Treat that as a retryable transport failure so the backoff path
      ;; handles it, rather than crashing on `with-current-buffer nil'.
      (unless buf
        (signal 'mindwtr-api-error (list :status 0 :retryable t)))
      ;; url-retrieve-synchronously hands back a fresh *http HOST:PORT*
      ;; buffer that the caller owns; kill it so requests don't leak.
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (let* ((status (progn (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                                  (string-to-number (or (match-string 1) "0"))))
                   (etag (progn (goto-char (point-min))
                                (when (re-search-forward "^ETag: *\\(.*\\)$" nil t)
                                  (string-trim (match-string 1)))))
                   (body (progn (goto-char (point-min))
                                (when (re-search-forward "\n\n" nil t)
                                  (buffer-substring-no-properties (point) (point-max))))))
              (list :status status :headers (when etag (list (cons "ETag" etag)))
                    :body body)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(defun mindwtr-api--default-http (req &optional callback)
  "Default transport for REQ using plz if present, else url.el.
REQ is (:method :url :headers :body).  With no CALLBACK, block and return
\(:status :headers :body).  With CALLBACK, deliver that plist by calling
\(CALLBACK RESP) instead -- asynchronously via plz when available, so the
request never blocks Emacs; the url.el fallback has no reliable async mode
and completes inline (callback called before this returns).

Every plz request is bounded by `mindwtr-api-timeout', so an async CALLBACK
is guaranteed to fire (a timed-out request errors through the status-0 path).
Non-2xx responses are returned/delivered as data, never signaled -- the plz
sync branch converts plz's own signal back into a response plist so the
caller's `mindwtr-api--check' owns classification for both transports."
  (if (require 'plz nil t)
      (let ((method (intern (downcase (plist-get req :method)))))
        (if callback
            (plz method (plist-get req :url)
              :headers (plist-get req :headers)
              :body (plist-get req :body)
              :as 'response :timeout mindwtr-api-timeout
              :then (lambda (r) (funcall callback (mindwtr-api--plz-resp r)))
              :else (lambda (e) (funcall callback (mindwtr-api--plz-error-resp e))))
          (condition-case e
              (mindwtr-api--plz-resp
               (plz method (plist-get req :url)
                 :headers (plist-get req :headers)
                 :body (plist-get req :body)
                 :as 'response :timeout mindwtr-api-timeout :then 'sync))
            ;; In sync mode plz IGNORES :else and signals instead; recover the
            ;; plz-error struct from the signal data (position-independently --
            ;; its slot in the data list has moved across plz versions) and
            ;; fold it back into a response plist.
            ((plz-error plz-curl-error plz-http-error)
             (mindwtr-api--plz-error-resp (seq-find #'plz-error-p (cdr e)))))))
    (let ((resp (mindwtr-api--url-http req)))
      (if callback (funcall callback resp) resp))))

(defvar mindwtr-api-http-function #'mindwtr-api--default-http
  "Transport function: (REQ) -> response plist, both (:status :headers :body).
May optionally accept a second CALLBACK argument; when called with one, the
transport must deliver the response via (CALLBACK RESP) -- possibly inline --
instead of returning it.  `mindwtr-api--request-async' probes the function's
arity, so a plain single-argument transport (tests, simple stubs) is still
valid: it is simply invoked inline on the async path.")

(defun mindwtr-api--url (path)
  "Build the full URL for PATH against `mindwtr-api-base-url'."
  (concat (string-trim-right mindwtr-api-base-url "/") path))

(defun mindwtr-api--headers (&optional with-content-type)
  "Build request headers.  Include Content-Type when WITH-CONTENT-TYPE is non-nil."
  (append (list (cons "Authorization" (concat "Bearer " mindwtr-api-token)))
          (when with-content-type '(("Content-Type" . "application/json")))))

(defun mindwtr-api--header (resp name)
  "Return header NAME from response RESP, case-insensitively."
  (cdr (assoc-string name (plist-get resp :headers) t)))

(defun mindwtr-api--check (resp)
  "Signal a classified error if RESP is not 2xx; else return RESP.
Status 0 is the transports' \"no HTTP response at all\" marker (curl-level
failure, timeout, dead socket) and classifies as retryable, like 429/5xx."
  (let ((status (plist-get resp :status)))
    (cond
     ((and (>= status 200) (< status 300)) resp)
     ((= status 401) (signal 'mindwtr-api-auth-error (list :status 401)))
     ((or (= status 0) (= status 429) (>= status 500))
      (signal 'mindwtr-api-error (list :status status :retryable t)))
     (t (signal 'mindwtr-api-error (list :status status :retryable nil
                                         :body (plist-get resp :body)))))))

;;; Async request layer ---------------------------------------------------------
;;
;; Callback convention: every async entry point takes a CALLBACK called exactly
;; once as (CALLBACK RESULT ERR).  ERR is nil on success; on failure it is the
;; (SYMBOL . DATA) a `condition-case' captured, so a caller can dispatch on the
;; error's conditions or re-signal it verbatim with (signal (car err) (cdr err)).
;; Nothing in this layer signals out of a callback: process sentinels are no
;; place for an unhandled signal, so errors always travel through ERR.
;;
;; With a transport that completes inline (a plain 1-argument stub, the url.el
;; fallback), the whole chain runs synchronously and CALLBACK has fired before
;; the entry point returns -- which is what lets the synchronous engine wrapper
;; and the existing test suite keep working unchanged.

(defun mindwtr-api--transport-async-p (f)
  "Non-nil when transport function F accepts a completion-callback 2nd argument."
  (let ((max (cdr (func-arity f))))
    (or (eq max 'many) (and (numberp max) (>= max 2)))))

(defun mindwtr-api--deliver (callback thunk)
  "Call THUNK and deliver its value to CALLBACK as (RESULT nil).
A signal from THUNK is captured and delivered as (nil ERR) instead, keeping
the async convention that errors travel through the callback, never raw out
of a process sentinel."
  (let (res err)
    (condition-case e (setq res (funcall thunk))
      (error (setq err e)))
    (funcall callback res err)))

(defun mindwtr-api--guard (callback thunk)
  "Run THUNK, routing a signal to CALLBACK as (nil ERR).
Unlike `mindwtr-api--deliver', a normal return delivers NOTHING: THUNK is a
stage prologue expected to have launched further async work that owns the
eventual delivery.  Only its failure short-circuits to CALLBACK."
  (condition-case e (funcall thunk)
    (error (funcall callback nil e))))

(defun mindwtr-api--request-async (req callback)
  "Issue REQ through `mindwtr-api-http-function'; deliver (CHECKED-RESP ERR).
A callback-capable transport (arity >= 2) is handed a completion callback and
may complete asynchronously; a single-argument transport runs inline.  The
response is classified by `mindwtr-api--check' either way, inside the
delivery, so a non-2xx arrives as ERR rather than a signal."
  (let ((f mindwtr-api-http-function))
    (if (mindwtr-api--transport-async-p f)
        (funcall f req (lambda (resp)
                         (mindwtr-api--deliver
                          callback (lambda () (mindwtr-api--check resp)))))
      (mindwtr-api--deliver
       callback (lambda () (mindwtr-api--check (funcall f req)))))))

(defun mindwtr-api-head-etag-async (callback)
  "HEAD /v1/data asynchronously; CALLBACK gets (ETAG-or-nil ERR)."
  (mindwtr-api--request-async
   (list :method "HEAD" :url (mindwtr-api--url "/v1/data")
         :headers (mindwtr-api--headers))
   (lambda (resp err)
     (if err (funcall callback nil err)
       (mindwtr-api--deliver
        callback (lambda () (mindwtr-api--header resp "ETag")))))))

(defun mindwtr-api-get-data-async (callback)
  "GET /v1/data asynchronously; CALLBACK gets ((:appdata PLIST :etag STRING) ERR)."
  (mindwtr-api--request-async
   (list :method "GET" :url (mindwtr-api--url "/v1/data")
         :headers (mindwtr-api--headers))
   (lambda (resp err)
     (if err (funcall callback nil err)
       (mindwtr-api--deliver
        callback
        (lambda ()
          (list :appdata (mindwtr-util-json-decode (plist-get resp :body))
                :etag (mindwtr-api--header resp "ETag"))))))))

(defun mindwtr-api-put-data-async (appdata callback)
  "PUT /v1/data with APPDATA asynchronously; CALLBACK gets (DECODED-or-nil ERR).
Body handling mirrors `mindwtr-api-put-data': an empty 200/204 body (some
self-hosted deployments) delivers nil rather than a JSON parse error."
  (mindwtr-api--request-async
   (list :method "PUT" :url (mindwtr-api--url "/v1/data")
         :headers (mindwtr-api--headers t)
         :body (mindwtr-util-json-ascii appdata))
   (lambda (resp err)
     (if err (funcall callback nil err)
       (mindwtr-api--deliver
        callback
        (lambda ()
          (let ((body (plist-get resp :body)))
            (unless (or (null body) (string-empty-p (string-trim body)))
              (mindwtr-util-json-decode body)))))))))

(defun mindwtr-api-get-data ()
  "GET /v1/data.  Return (:appdata PLIST :etag STRING)."
  (let* ((resp (mindwtr-api--check
                (funcall mindwtr-api-http-function
                         (list :method "GET" :url (mindwtr-api--url "/v1/data")
                               :headers (mindwtr-api--headers)))))
         (body (plist-get resp :body)))
    (list :appdata (mindwtr-util-json-decode body)
          :etag (mindwtr-api--header resp "ETag"))))

(defun mindwtr-api-head-etag ()
  "HEAD /v1/data.  Return the ETag string (or nil)."
  (let ((resp (mindwtr-api--check
               (funcall mindwtr-api-http-function
                        (list :method "HEAD" :url (mindwtr-api--url "/v1/data")
                              :headers (mindwtr-api--headers))))))
    (mindwtr-api--header resp "ETag")))

(defun mindwtr-api-put-data (appdata)
  "PUT /v1/data with APPDATA.  Return the decoded response plist, or nil.
The Cloud server returns {ok, stats, clockSkewWarning}, but a self-hosted
deployment may answer 200/204 with an empty body; tolerate that (return
nil) rather than signalling a JSON-end-of-file error on the sync path."
  (let* ((resp (mindwtr-api--check
                (funcall mindwtr-api-http-function
                         (list :method "PUT" :url (mindwtr-api--url "/v1/data")
                               :headers (mindwtr-api--headers t)
                               ;; ASCII-only body: keeps the request unibyte so
                               ;; the url.el transport won't choke on non-ASCII
                               ;; content (descriptions, unicode in titles).
                               :body (mindwtr-util-json-ascii appdata)))))
         (body (plist-get resp :body)))
    (unless (or (null body) (string-empty-p (string-trim body)))
      (mindwtr-util-json-decode body))))

(provide 'mindwtr-api)
;;; mindwtr-api.el ends here
