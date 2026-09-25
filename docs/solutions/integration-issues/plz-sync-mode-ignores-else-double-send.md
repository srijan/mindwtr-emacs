---
title: "plz sync mode ignores :else, so the old transport sent every successful request twice and never classified HTTP errors"
date: 2026-09-25
category: integration-issues
module: mindwtr-api
problem_type: integration_issue
component: tooling
symptoms:
  - "Every successful HEAD/GET/PUT through the plz transport reached the server twice (the first response was discarded)"
  - "A 401 surfaced as a raw plz error through the generic handler instead of the authentication-failed message"
  - "429/5xx and curl-level failures (network down, dead socket) never entered retry backoff on the plz path"
  - "The ERT suite stayed green throughout, because every test stubs the transport and never runs real plz"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags:
  - plz
  - transport
  - http-error-classification
  - retry-backoff
  - sync-vs-async
---

# plz sync mode ignores :else, so the old transport sent every successful request twice and never classified HTTP errors

## Problem

From the first API commit until 2039bfa (merged in PR #39), the plz branch of
`mindwtr-api--default-http` assumed plz calls `:else` on a failed synchronous request. It does
not. In sync mode (`:then 'sync`) plz discards `:else` and `:finally` and signals instead. The
transport was written around that wrong assumption, and the result was two opposite failures:
successful requests went out twice, and failed requests escaped as raw plz signals that the
sync loop's error classification never saw.

## Symptoms

- Each successful request hit the server twice, including the PUT of `/v1/data`. Nothing
  visible happened client-side; the duplicate was only observable on the wire or in server logs.
- A non-2xx response (401, 429, 5xx) or a curl-level failure surfaced as a `plz-http-error` /
  `plz-curl-error` caught by the generic `error` clause of the sync loop. That clause resets
  backoff and prints the raw message, so auth failures did not say "check token" and transient
  failures were not retried.
- `make test` never caught either failure. The suite injects `mindwtr-api-http-function` stubs,
  so the real plz branch has no unit coverage.

## What Didn't Work

The pre-fix transport (parent of 2039bfa, `mindwtr-api.el`):

```elisp
(let (status hdrs body)
  (plz method url ... :as 'response :then 'sync
    :else (lambda (e)                       ; never called in sync mode
            (let ((r (plz-error-response e)))
              (setq status (plz-response-status r) ...))))
  (when (null status)                       ; always true after a success
    (let ((r (plz method url ... :as 'response :then 'sync)))
      (setq status (plz-response-status r) ...)))
  (list :status status :headers hdrs :body body))
```

Read against real plz semantics:

- **Success.** The first `plz` call returns the response, but its return value is thrown away.
  `status` is still nil, so the fallback branch issues the same request a second time and
  uses that second response.
- **Non-2xx or curl failure.** The first call signals `plz-http-error` / `plz-curl-error`
  straight out of the `let`. The `:else` lambda never runs, the second call is never reached,
  and `mindwtr-api--check` never sees a status to classify.

The code reads as "try with an error handler, fall back if nothing happened". It is a natural
shape if you assume `:else` works the same in both modes, which is why it survived review.

## Solution

2039bfa split the plz branch by mode and made both modes return a response plist, never a
signal, so `mindwtr-api--check` classifies status codes for plz and url.el alike
(`mindwtr-api.el:90-125`):

- **Async (CALLBACK given):** `:then` and `:else` both deliver a response plist to the
  callback. `:else` is honoured in async mode.
- **Sync (no CALLBACK):** one `plz` call with `:then 'sync`, wrapped in `condition-case` on
  `(plz-error plz-curl-error plz-http-error)`. The handler recovers the `plz-error` struct with
  `(seq-find #'plz-error-p (cdr e))` and folds it back into a response plist.
- `mindwtr-api--plz-error-resp` (`mindwtr-api.el:51-58`) maps a plz-error with a response to
  that response's status, headers and body. A curl-level failure has no response and maps to
  `(:status 0 ...)`.
- `mindwtr-api--check` (`mindwtr-api.el:148-160`) classifies status 0 as retryable alongside
  429 and 5xx, so curl failures and timeouts reach backoff on the plz path too.
- Every plz call carries `:timeout mindwtr-api-timeout` (60 s), which turns a hung request into
  a curl timeout and so into the status-0 path.

The sync branch is still live after the async rewrite. `mindwtr-bootstrap` calls
`mindwtr-api-get-data` (`mindwtr.el:424`), which goes through the transport without a callback.

## Why This Works

The behaviour is in plz itself (installed plz 0.10-pre, elpaca source `plz.el`):

The docstring says `:else` and `:finally` do not apply to sync requests:

```
ELSE is an optional callback function called when the request
fails ...  If ELSE is nil, a `plz-curl-error' or
`plz-http-error' is signaled when the request fails ...  For synchronous
requests, this argument is ignored.
```

The implementation overwrites whatever `:else` was passed:

```elisp
(when (eq 'sync then)
  (setf sync-p t
        then (lambda (result)
               (process-put process :plz-result result))
        else nil))
```

With `else` nil, the sentinel stores the `plz-error` as the result, and the sync wait loop
re-signals it:

```elisp
((and (pred plz-error-p) data)
 (if (plz-error-response data)
     (signal 'plz-http-error (list "HTTP error" data))
   (signal 'plz-curl-error (list "Curl error" data))))
```

The struct is the second element of the signal data in this version. The current handler
finds it with `seq-find` instead of `(nth 1 ...)`; per the comment in `mindwtr-api.el`, its
position has moved across plz versions.

A successful sync call returns the response from `plz` directly. The old code ignored that
return value, and that caused the second send.

## Prevention

- **With plz, pick the error channel by mode.** Async: `:then` plus `:else`. Sync: the return
  value plus `condition-case` on `plz-error` (and the two legacy subtypes). Never pass `:else`
  or `:finally` alongside `:then 'sync` expecting them to run.
- **Use the return value of a sync `plz` call.** A "did the handler set anything?" check after
  a sync call is the pattern that caused the double send.
- **Keep status classification in one place.** Transports return `(:status :headers :body)`,
  with status 0 meaning no HTTP response. Only `mindwtr-api--check` decides auth vs retryable
  vs fatal. A transport that lets a library-specific error escape skips the backoff and
  auth-message paths in `mindwtr.el`.
- **Stub-based tests cannot see this class of bug.** The unit suite replaces
  `mindwtr-api-http-function`, so changes to the plz branch itself need a check against real
  plz: `make smoke-docker`, or a batch run of `mindwtr-api--default-http` against a local
  server returning 200 and 503, counting requests on the server side.
- **Watch plz upgrades.** The plz sentinel carries a TODO that a future version may pass
  non-2xx responses to THEN when `:as 'response`. The current transport tolerates that
  (a response reaching THEN or the sync return value still goes through `mindwtr-api--check`),
  but re-read `plz`'s THEN/ELSE docstring after a plz bump.

## Related

- `docs/solutions/runtime-errors/url-retrieve-synchronously-nil-buffer-crash-on-tls-drop.md`
  covers the same status-0 retryable contract on the url.el fallback.
- `docs/solutions/integration-issues/url-el-synchronous-buffer-leak.md` covers the other
  transport branch.
- `docs/solutions/design-patterns/sync-reentrancy-in-flight-guard.md` depends on
  `mindwtr-api-timeout` guaranteeing the async callback fires.
