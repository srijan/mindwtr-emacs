---
title: url.el synchronous request leaks one *http* buffer per call
date: 2026-06-03
category: integration-issues
module: mindwtr-api
problem_type: integration_issue
component: tooling
symptoms:
  - "Buffer list accumulates *http HOST:PORT* buffers after each GET/HEAD/PUT"
  - "Buffers are uniquified with a numeric suffix: *http HOST:PORT-161737*, etc."
  - "Memory grows proportionally to the number of sync operations in a long session"
  - "A crash mid-response-parse leaves an orphan buffer with no cleanup path"
root_cause: memory_leak
resolution_type: code_fix
severity: medium
tags: [url-el, buffer-leak, resource-management, unwind-protect]
---

# url.el synchronous request leaks one *http* buffer per call

## Problem
`url-retrieve-synchronously` differs from most Emacs I/O: it does **not** manage the lifetime of
its response buffer. It creates a buffer named `*http HOST:PORT*`, fills it with the raw HTTP
response, and returns the live buffer to the caller — who now owns it and must kill it. Nothing
errors if the buffer is abandoned, so the leak is silent.

## Symptoms
- After a `mindwtr-sync-once`/`mindwtr-bootstrap` (GET + optional HEAD + PUT), extra `*http ...*`
  buffers appear in `buffer-list`.
- A long interactive session with periodic sync accumulates dozens, uniquified:
  `*http mw.example:443*`, `*http mw.example:443-161737*`, …
- A parse error inside the response-read leaves an orphan buffer, because the error unwinds
  through `with-current-buffer` without cleanup.

## What Didn't Work
The original code wrapped the whole response-read in
`(with-current-buffer (url-retrieve-synchronously ...) ...)`. That idiom selects the buffer as
current but does **not** kill it on exit — unlike `with-temp-buffer`, there is no `url.el`
wrapper that auto-kills the response buffer.

## Solution
Capture the buffer in a variable and wrap the read in `unwind-protect` (`mindwtr-api.el:54-70`,
commit `74383fb`):

```elisp
(let ((buf (url-retrieve-synchronously (plist-get req :url) t)))
  ;; url-retrieve-synchronously hands back a fresh *http HOST:PORT* buffer the
  ;; caller owns; kill it so requests don't leak.
  (unwind-protect
      (with-current-buffer buf
        (goto-char (point-min))
        (let* ((status (progn (re-search-forward "HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                              (string-to-number (or (match-string 1) "0"))))
               (etag   (progn (goto-char (point-min))
                              (when (re-search-forward "^ETag: *\\(.*\\)$" nil t)
                                (string-trim (match-string 1)))))
               (body   (progn (goto-char (point-min))
                              (when (re-search-forward "\n\n" nil t)
                                (buffer-substring-no-properties (point) (point-max))))))
          (list :status status :headers (when etag (list (cons "ETag" etag))) :body body)))
    (when (buffer-live-p buf) (kill-buffer buf))))
```

The `(buffer-live-p buf)` guard is defensive: if `url-retrieve-synchronously` returned nil (e.g.
a TLS error preventing buffer creation), the cleanup doesn't raise a second error that masks the
first.

## Why This Works
`unwind-protect` runs the cleanup regardless of how control leaves the protected form — normal
return, `throw`, `signal`, or non-local exit. The body extracts everything into Lisp values
before exit, so the buffer can be killed immediately; nothing holds a reference.

## Prevention
- General `url.el` ownership rule: unlike `url-retrieve` (async, callback-managed),
  `url-retrieve-synchronously` returns the buffer to the synchronous caller. **Every** call site
  must pair it with a `kill-buffer` in an `unwind-protect`. Do not use `with-current-buffer` on
  the return value as a shorthand — it never kills.
- This path is the bare-Emacs fallback; when `plz.el` is available (`mindwtr-api--default-http`
  tries `(require 'plz nil t)` first) it isn't taken at all.

## Related Issues
- Same `url.el` transport surface as [[json-encoding-gotchas-emacs-server-boundary]] (the
  multibyte-body crash). Both are `url.el` fallback-path footguns.
- The synchronous transport's nested-event-loop behavior is the subject of
  [[sync-reentrancy-in-flight-guard]].
