;;; mindwtr-api-test.el --- -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-api)

(defmacro mindwtr-api-test--stub (response &rest body)
  "Bind the transport to return RESPONSE (a plist) and capture the request."
  (declare (indent 1))
  `(let* ((captured nil)
          (mindwtr-api-base-url "https://mw.example/")
          (mindwtr-api-token "secret")
          (mindwtr-api-http-function
           (lambda (req) (setq captured req) ,response)))
     (cl-flet ((req () captured)) ,@body)))

(ert-deftest mindwtr-api-get-data-parses-and-returns-etag ()
  (mindwtr-api-test--stub
      '(:status 200 :headers (("ETag" . "v9"))
        :body "{\"tasks\":[{\"id\":\"t1\"}],\"projects\":[],\"sections\":[],\"areas\":[],\"settings\":{}}")
    (let ((res (mindwtr-api-get-data)))
      (should (string= (plist-get res :etag) "v9"))
      (should (string= (plist-get (car (plist-get (plist-get res :appdata) :tasks)) :id)
                       "t1"))
      (should (string= (plist-get (req) :method) "GET"))
      (should (string= (plist-get (req) :url) "https://mw.example/v1/data"))
      (should (string= (cdr (assoc "Authorization" (plist-get (req) :headers)))
                       "Bearer secret")))))

(ert-deftest mindwtr-api-head-returns-etag ()
  (mindwtr-api-test--stub
      '(:status 200 :headers (("ETag" . "v9")) :body "")
    (should (string= (mindwtr-api-head-etag) "v9"))
    (should (string= (plist-get (req) :method) "HEAD"))))

(ert-deftest mindwtr-api-put-sends-json-body ()
  (mindwtr-api-test--stub
      '(:status 200 :headers nil :body "{\"ok\":true,\"stats\":{}}")
    (let ((res (mindwtr-api-put-data
                '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))
      (should (eq (plist-get res :ok) t))
      (should (string= (plist-get (req) :method) "PUT"))
      (should (string-match-p "\"tasks\"" (plist-get (req) :body))))))

(ert-deftest mindwtr-api-put-tolerates-empty-response-body ()
  "A server that returns 200/204 with an empty body must not crash the decode."
  (mindwtr-api-test--stub
      '(:status 200 :headers nil :body "")
    (should (null (mindwtr-api-put-data
                   '(:tasks nil :projects nil :sections nil :areas nil :settings nil))))))

(ert-deftest mindwtr-api-classifies-401 ()
  (mindwtr-api-test--stub
      '(:status 401 :headers nil :body "unauthorized")
    (should-error (mindwtr-api-get-data) :type 'mindwtr-api-auth-error)))

(ert-deftest mindwtr-api-classifies-429-retryable ()
  (mindwtr-api-test--stub
      '(:status 429 :headers nil :body "slow down")
    (condition-case err (mindwtr-api-get-data)
      (mindwtr-api-error (should (plist-get (cdr err) :retryable))))))

(ert-deftest mindwtr-api-url-transport-nil-buffer-is-retryable ()
  "A dropped connection makes `url-retrieve-synchronously' return nil
\(e.g. after the laptop resumes from sleep and the TLS socket is dead).
The url.el transport must turn that into a retryable `mindwtr-api-error'
so backoff handles it, rather than crashing on `with-current-buffer nil'
with `wrong-type-argument stringp nil'."
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _) nil)))
    (let ((req '(:method "GET" :url "https://mw.example/v1/data" :headers nil)))
      ;; Must not signal the cryptic wrong-type-argument error.
      (should-not
       (condition-case err (progn (mindwtr-api--default-http req) nil)
         (wrong-type-argument t)
         (mindwtr-api-error nil)))
      ;; Must signal a retryable mindwtr-api-error instead.
      (condition-case err (mindwtr-api--default-http req)
        (mindwtr-api-error (should (plist-get (cdr err) :retryable)))))))

;;; plz transport --------------------------------------------------------------
;;
;; plz is not on the load path under `make test', so these run the plz branch
;; of `mindwtr-api--default-http' against a fake: `features' is `dlet'-bound so
;; `(require 'plz nil t)' succeeds for the test body only, and the plz calls
;; the transport makes are stubbed.  A fake response is a plist and a fake
;; plz-error is (fake-plz-error RESPONSE-OR-NIL).  See
;; docs/solutions/integration-issues/plz-sync-mode-ignores-else-double-send.md.

(dolist (e '(plz-error plz-curl-error plz-http-error))
  (unless (get e 'error-conditions)
    (define-error e (format "Fake %s" e))))

(defmacro mindwtr-api-test--with-fake-plz (plz-fn &rest body)
  "Run BODY with the plz branch active and `plz' bound to PLZ-FN."
  (declare (indent 1))
  `(dlet ((features (cons 'plz features)))
     (cl-letf (((symbol-function 'plz) ,plz-fn)
               ((symbol-function 'plz-error-p)
                (lambda (x) (eq (car-safe x) 'fake-plz-error)))
               ((symbol-function 'plz-error-response) #'cadr)
               ((symbol-function 'plz-response-status)
                (lambda (r) (plist-get r :status)))
               ((symbol-function 'plz-response-headers)
                (lambda (r) (plist-get r :headers)))
               ((symbol-function 'plz-response-body)
                (lambda (r) (plist-get r :body))))
       ,@body)))

(defconst mindwtr-api-test--req
  '(:method "PUT" :url "https://mw.example/v1/data" :headers nil :body "{}"))

(ert-deftest mindwtr-api-plz-sync-success-sends-once ()
  "A successful sync request reaches plz exactly once, bounded by the
timeout.  The old code discarded plz's return value and re-sent the request,
PUT included."
  (let ((calls 0) args)
    (mindwtr-api-test--with-fake-plz
        (lambda (&rest a)
          (cl-incf calls) (setq args a)
          '(:status 200 :headers (("ETag" . "v2")) :body "ok"))
      (should (equal (mindwtr-api--default-http mindwtr-api-test--req)
                     '(:status 200 :headers (("ETag" . "v2")) :body "ok"))))
    (should (= calls 1))
    (should (eq (car args) 'put))
    (should (eq (plist-get (cddr args) :then) 'sync))
    (should (eql (plist-get (cddr args) :timeout) mindwtr-api-timeout))))

(ert-deftest mindwtr-api-plz-sync-http-error-is-classified ()
  "plz signals on non-2xx in sync mode (it ignores :else).  The transport
must return the real response so `mindwtr-api--check' classifies it: a 401 is
an auth error, a 503 is retryable.  The error struct is found wherever it sits
in the signal data."
  (dolist (case '((401 . mindwtr-api-auth-error) (503 . mindwtr-api-error)))
    (let ((resp (list :status (car case) :headers nil :body "no")))
      (mindwtr-api-test--with-fake-plz
          (lambda (&rest _)
            (signal 'plz-http-error
                    (list "HTTP error" 'extra (list 'fake-plz-error resp))))
        (let ((got (mindwtr-api--default-http mindwtr-api-test--req)))
          (should (equal got resp))
          (condition-case err (progn (mindwtr-api--check got) (should nil))
            (error
             (should (eq (car err) (cdr case)))
             (when (= (car case) 503)
               (should (plist-get (cdr err) :retryable))))))))))

(ert-deftest mindwtr-api-plz-sync-curl-error-is-retryable ()
  "A curl-level failure (network down, timeout) has no HTTP response; it
maps to status 0, which `mindwtr-api--check' treats as retryable."
  (mindwtr-api-test--with-fake-plz
      (lambda (&rest _)
        (signal 'plz-curl-error (list "Curl error" (list 'fake-plz-error nil))))
    (let ((got (mindwtr-api--default-http mindwtr-api-test--req)))
      (should (equal got '(:status 0 :headers nil :body nil)))
      (condition-case err (progn (mindwtr-api--check got) (should nil))
        (mindwtr-api-error (should (plist-get (cdr err) :retryable)))))))

(ert-deftest mindwtr-api-plz-async-delivers-success-and-errors ()
  "The async branch passes :then and :else, and both deliver a response
plist through the callback instead of signaling."
  (let (then else got)
    (mindwtr-api-test--with-fake-plz
        (lambda (&rest a)
          (setq then (plist-get (cddr a) :then)
                else (plist-get (cddr a) :else))
          nil)
      (mindwtr-api--default-http mindwtr-api-test--req
                                 (lambda (r) (push r got)))
      (should (functionp then))
      (should (functionp else))
      (funcall then '(:status 200 :headers nil :body "ok"))
      (funcall else (list 'fake-plz-error '(:status 401 :headers nil :body "x")))
      (funcall else (list 'fake-plz-error nil)))
    (should (equal (nreverse got)
                   '((:status 200 :headers nil :body "ok")
                     (:status 401 :headers nil :body "x")
                     (:status 0 :headers nil :body nil))))))

;;; Async request layer --------------------------------------------------------

(ert-deftest mindwtr-api-request-async-inline-stub-and-classification ()
  "A single-argument transport runs inline on the async path, and non-2xx /
status-0 responses arrive as classified ERR values, never as raw signals."
  (let ((mindwtr-api-base-url "https://mw.example/")
        (mindwtr-api-token "x"))
    ;; 2xx: result delivered, no error.
    (let ((mindwtr-api-http-function
           (lambda (_req) '(:status 200 :headers (("ETag" . "e1")) :body "")))
          got)
      (mindwtr-api-head-etag-async (lambda (r e) (setq got (list r e))))
      (should (equal got '("e1" nil))))
    ;; 503: retryable mindwtr-api-error through ERR.
    (let ((mindwtr-api-http-function
           (lambda (_req) '(:status 503 :headers nil :body "")))
          got)
      (mindwtr-api-head-etag-async (lambda (r e) (setq got (list r e))))
      (should (null (nth 0 got)))
      (should (eq (car (nth 1 got)) 'mindwtr-api-error))
      (should (plist-get (cdr (nth 1 got)) :retryable)))
    ;; Status 0 (curl-level failure / timeout): retryable too.
    (let ((mindwtr-api-http-function
           (lambda (_req) '(:status 0 :headers nil :body nil)))
          got)
      (mindwtr-api-head-etag-async (lambda (r e) (setq got (list r e))))
      (should (plist-get (cdr (nth 1 got)) :retryable)))
    ;; 401: auth error through ERR.
    (let ((mindwtr-api-http-function
           (lambda (_req) '(:status 401 :headers nil :body "")))
          got)
      (mindwtr-api-head-etag-async (lambda (r e) (setq got (list r e))))
      (should (memq 'mindwtr-api-auth-error
                    (get (car (nth 1 got)) 'error-conditions))))))

;; --- server error detail --------------------------------------------------

(ert-deftest mindwtr-api-error-detail-reads-json-error-field ()
  "A JSON body with an \"error\" field yields that field as the detail."
  (should (string= (mindwtr-api-error-detail
                    '(:status 400 :retryable nil
                      :body "{\n  \"error\": \"Invalid data: each task must be an object with string id and title\"\n}"))
                   "Invalid data: each task must be an object with string id and title")))

(ert-deftest mindwtr-api-error-detail-falls-back-to-trimmed-body ()
  "A non-JSON body is returned trimmed; an empty or absent body yields nil."
  (should (string= (mindwtr-api-error-detail '(:status 400 :body " Bad Request \n"))
                   "Bad Request"))
  (should-not (mindwtr-api-error-detail '(:status 400 :body "")))
  (should-not (mindwtr-api-error-detail '(:status 400))))

(ert-deftest mindwtr-api-error-detail-truncates-long-bodies ()
  "A long body (an HTML error page) is cut so it fits the echo area."
  (let ((d (mindwtr-api-error-detail
            (list :status 502 :body (make-string 1000 ?x)))))
    (should (<= (length d) 200))))
