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
