---
title: "url.el nil response buffer crashes mindwtr sync after a TLS socket drops on resume"
date: 2026-06-18
category: runtime-errors
module: mindwtr-api
problem_type: runtime_error
component: tooling
symptoms:
  - "`mindwtr: Wrong type argument: stringp, nil [3 times]` printed after resuming the laptop from sleep"
  - "Emacs-internal noise alongside it: `gnutls.el: (err=[-54] Error in the pull function.)`"
  - "`error in process sentinel: open-gnutls-stream: GnuTLS error ... -54`"
  - "Cryptic raw error surfaced through the generic handler instead of the normal retry message"
  - "Transient drop did not self-recover; sync crashed instead of backing off"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags:
  - url-el
  - tls
  - gnutls
  - resume-from-sleep
  - retry-backoff
  - with-current-buffer
  - nil-buffer
  - transport
---

# url.el nil response buffer crashes mindwtr sync after a TLS socket drops on resume

## Problem

After resuming the laptop from sleep, mindwtr-emacs flooded the echo area with a
cryptic, unactionable error instead of quietly retrying the sync. The underlying
condition is benign and transient: on resume the TLS socket to the Mindwtr Cloud
server is dead. The expected behavior is that the existing exponential-backoff
machinery reconnects and the user sees, at most, a friendly "server
busy/unreachable; retrying in Ns" notice. Instead a raw `wrong-type-argument`
error leaked out, which looks like a bug in the package rather than a recoverable
network blip.

## Symptoms

```
mindwtr: Wrong type argument: stringp, nil [3 times]
gnutls.el: (err=[-54] Error in the pull function.) boot: ...
error in process sentinel: open-gnutls-stream: GnuTLS error: #<process mw.example<1>>, -54
error in process sentinel: GnuTLS error: #<process mw.example<1>>, -54
mindwtr: Wrong type argument: stringp, nil [3 times]
```

- `mindwtr: Wrong type argument: stringp, nil` in the echo area / `*Messages*`,
  typically immediately after waking the machine from sleep.
- The `[3 times]` suffix is Emacs echo-area deduplication collapsing several
  identical occurrences. Multiple sync triggers fire around reconnect time, and
  each one hits the same failing code path.
- Interleaved Emacs-internal noise: `gnutls.el: (err=[-54] ...)` and
  `error in process sentinel: ... GnuTLS error: ..., -54`. These come from
  Emacs's TLS layer and the url.el process sentinel reacting to the dead socket
  — they are NOT mindwtr code and not the fixable bug. They are the ambient
  signature of a dropped connection.
- No backoff retry message ("retrying in Ns") appeared, even though the failure
  was exactly the transient kind backoff exists to handle — a tell that the
  error was bypassing the classified-error path.

## What Didn't Work

- **Treating the GnuTLS -54 / process-sentinel lines as the bug.** These are
  Emacs internals emitted by the TLS stack and url.el's async sentinel when the
  socket is dead. They are noise around the real failure, not something mindwtr
  can catch or fix. Chasing them leads nowhere.
- **Relying on the existing API test suite to catch it.** Every test in
  `test/mindwtr-api-test.el` stubs the injectable transport via
  `mindwtr-api-http-function`, so they never exercise the real
  `mindwtr-api--default-http` and never touch `url-retrieve-synchronously`. The
  whole class of transport-layer failures was invisible to the suite.
- **Assuming the generic `error` handler would render something sensible.** In
  `mindwtr--sync-handle-error` (`mindwtr.el:283-285`) the catch-all branch just does
  `(message "mindwtr: %s" (error-message-string err))`. Because the failure
  surfaced as a raw `wrong-type-argument` rather than the package's classified
  `mindwtr-api-error`, it fell through to this branch and printed the cryptic
  message verbatim — and, critically, did NOT arm a retry.

## Solution

The root cause is in the url.el fallback branch of the transport. When `plz` is
not installed, `mindwtr-api--default-http` delegates to `mindwtr-api--url-http`,
which calls `url-retrieve-synchronously`,
which returns `nil` on a failed connection. The next line then did
`(with-current-buffer buf ...)` with `buf` = nil, which is effectively
`(set-buffer nil)` and signals `(wrong-type-argument stringp nil)`.

Confirmed in isolation:

```
emacs -Q --batch --eval '(with-current-buffer nil (point))'
;; => Wrong type argument: stringp, nil
```

The fix (`mindwtr-api.el:66-72`, commit `bcc94dc`, an earlier PR) guards the nil buffer
and converts it into the transport's existing classified, retryable error:

Before:

```elisp
(let ((buf (url-retrieve-synchronously (plist-get req :url) t)))
  ;; url-retrieve-synchronously hands back a fresh *http HOST:PORT*
  ;; buffer that the caller owns; kill it so requests don't leak.
  (unwind-protect
      (with-current-buffer buf
        ...)))
```

After:

```elisp
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
        ...)))
```

The `(:status 0 :retryable t)` payload matches the convention in
`mindwtr-api--check` (`mindwtr-api.el:148-159`), which signals
`mindwtr-api-error` with `:retryable t` for status 0 (no HTTP response), 429
and 5xx.

A regression test was added in `test/mindwtr-api-test.el`,
`mindwtr-api-url-transport-nil-buffer-is-retryable`. It stubs
`url-retrieve-synchronously` (via `cl-letf`) to return nil and asserts that
`mindwtr-api--default-http` signals a retryable `mindwtr-api-error` and NOT
`wrong-type-argument`. This deliberately drives the real transport rather than
stubbing `mindwtr-api-http-function`, closing the coverage gap that let the bug
ship. Full suite: 481/481 pass; byte-compile clean.

## Why This Works

Once the dropped connection is signalled as `mindwtr-api-error` with
`:retryable t`, it flows into the retryable branch of `mindwtr--sync-handle-error`
(`mindwtr.el:268-274`, called from the cycle's completion callback in
`mindwtr--sync-attempt`) instead of the catch-all branch. That handler
checks `(plist-get (cdr err) :retryable)`, increments `mindwtr--retry-attempts`
(capped at `mindwtr-backoff-max-attempts`), and calls `mindwtr--schedule-retry`.
The result is the friendly, actionable message from `mindwtr.el:199-200`:

```
mindwtr: server busy/unreachable; retrying in 4s (attempt 2/12)
```

and an armed backoff timer. If the connection stays down past the ceiling,
`mindwtr--schedule-retry` (`mindwtr.el:186-196`) gives up gracefully with a
persistent, recoverable error state ("sync still failing after N attempts;
giving up — M-x mindwtr-sync to retry") rather than spamming raw type errors. In
short: the fix routes a transient network condition through the code path that
already knows how to handle transient network conditions.

## Prevention

- **`url-retrieve-synchronously` returns nil on connection failure.** It does not
  signal — it hands back nil. Any code that does
  `(with-current-buffer (url-retrieve-synchronously ...))` (or otherwise treats
  the result as a live buffer) must guard for nil first, or it will crash with
  `wrong-type-argument stringp nil`. Treat a nil result as a transient transport
  failure, not a programmer error.
- **Convert raw/low-level errors into the package's classified error vocabulary
  at the boundary.** mindwtr already has `mindwtr-api-error` with a `:retryable`
  contract and a `:status 0` sentinel for transport-level (non-HTTP) failures.
  New failure modes in the transport should be mapped onto that contract so the
  existing backoff/auth handlers can react, instead of leaking through the
  catch-all `error` branch as opaque text.
- **Test the real transport, not just the injectable seam.** Stubbing
  `mindwtr-api-http-function` is the right tool for testing higher-level sync
  logic, but it means `mindwtr-api--default-http` (the plz/url.el code that
  actually talks to the network) is never exercised. For transport-layer
  concerns, stub the lower primitive instead — e.g. `cl-letf` over
  `url-retrieve-synchronously` (the plz path's equivalent is
  `mindwtr-api--plz-error-resp`, `mindwtr-api.el:51-58`, which maps a curl-level
  failure to status 0) — so failure modes like
  nil buffers, malformed responses, and dropped sockets are covered. The new
  `mindwtr-api-url-transport-nil-buffer-is-retryable` test is the reference
  pattern.
- **Distinguish Emacs-internal noise from package bugs when triaging.** GnuTLS
  `err=[-54]` and `error in process sentinel: ... GnuTLS error` lines are Emacs's
  TLS/url.el internals reacting to a dead socket. When they appear alongside a
  package error, the package-side fix is to make the package's own code path
  resilient to the resulting failure (here, the nil buffer), not to try to
  suppress the internal lines.

## Related Issues

- The other half of the nil-buffer story on the same lines
  (`mindwtr-api.el:66-88`): [[url-el-synchronous-buffer-leak]] kills the
  response buffer in an `unwind-protect` cleanup, which the nil buffer never
  reaches now; this doc guards the *read* path (`with-current-buffer nil`) against the
  same nil and turns it into a retryable error.
- The backoff/retry machinery this fix hands off to is the subject of
  [[sync-reentrancy-in-flight-guard]].
- Same `url.el` fallback transport surface as
  [[json-encoding-gotchas-emacs-server-boundary]] (the multibyte-body crash).
