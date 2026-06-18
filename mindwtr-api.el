;;; mindwtr-api.el --- Mindwtr Cloud REST client -*- lexical-binding: t; -*-
;;; Commentary:
;; GET/HEAD/PUT /v1/data with an injectable transport.  The default
;; transport uses plz.el when available, else url.el.
;;; Code:

(require 'cl-lib)
(require 'mindwtr-util)

(defvar mindwtr-api-base-url nil "Base URL of the Mindwtr Cloud server (trailing slash ok).")
(defvar mindwtr-api-token nil "Bearer token for the Mindwtr Cloud server.")

(define-error 'mindwtr-api-error "Mindwtr API error")
(define-error 'mindwtr-api-auth-error "Mindwtr API authentication failed"
  'mindwtr-api-error)

(declare-function plz "plz" (method url &rest args))
(declare-function plz-error-response "plz" (error))
(declare-function plz-response-status "plz" (response))
(declare-function plz-response-headers "plz" (response))
(declare-function plz-response-body "plz" (response))

;; url.el dynamic variables used in the fallback transport
(defvar url-request-method)
(defvar url-request-extra-headers)
(defvar url-request-data)

(defun mindwtr-api--default-http (req)
  "Default transport for REQ using plz if present, else url.el.
REQ is (:method :url :headers :body).  Returns (:status :headers :body)."
  (if (require 'plz nil t)
      (let (status hdrs body)
        (plz (intern (downcase (plist-get req :method))) (plist-get req :url)
          :headers (plist-get req :headers)
          :body (plist-get req :body)
          :as 'response :then 'sync
          :else (lambda (e)
                  (let ((r (plz-error-response e)))
                    (setq status (plz-response-status r)
                          hdrs (plz-response-headers r)
                          body (plz-response-body r)))))
        (when (null status)
          (let ((r (plz (intern (downcase (plist-get req :method))) (plist-get req :url)
                     :headers (plist-get req :headers) :body (plist-get req :body)
                     :as 'response :then 'sync)))
            (setq status (plz-response-status r)
                  hdrs (plz-response-headers r)
                  body (plz-response-body r))))
        (list :status status :headers hdrs :body body))
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
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(defvar mindwtr-api-http-function #'mindwtr-api--default-http
  "Function taking a request plist and returning a response plist.")

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
  "Signal a classified error if RESP is not 2xx; else return RESP."
  (let ((status (plist-get resp :status)))
    (cond
     ((and (>= status 200) (< status 300)) resp)
     ((= status 401) (signal 'mindwtr-api-auth-error (list :status 401)))
     ((or (= status 429) (>= status 500))
      (signal 'mindwtr-api-error (list :status status :retryable t)))
     (t (signal 'mindwtr-api-error (list :status status :retryable nil
                                         :body (plist-get resp :body)))))))

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
