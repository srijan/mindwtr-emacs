---
title: JSON and encoding gotchas at the Emacs-to-server boundary
date: 2026-06-03
category: integration-issues
module: mindwtr-util / mindwtr-api
problem_type: integration_issue
component: tooling
symptoms:
  - "Coding-system save prompt appears on first sync with non-ASCII task titles"
  - "Shadow file written with mojibake -- a bullet (U+2022) stored as three raw UTF-8 bytes"
  - "Server 422: deletedAt must be a valid ISO timestamp when present"
  - "url.el aborts before opening the socket on a multibyte HTTP request body"
  - "Smoke round-trip passes on non-ASCII data despite on-disk corruption (false green)"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [json, encoding, utf-8, url-el, null-serialization, mojibake]
---

# JSON and encoding gotchas at the Emacs-to-server boundary

## Problem
Three independent encoding-boundary failures can all hit the same sync. They interact: fix the
buffer-corruption one without the HTTP one and the first non-ASCII PUT crashes `url.el`; fix the
null one after the charset one and you still send `"deletedAt":[]` for every absent field. Each
must be handled separately, and the read/store path and the write/send path need **opposite**
treatments.

## Symptoms
**(a) Unibyte bytes leak into a multibyte buffer.** `json-serialize` returns a *unibyte* UTF-8
byte-string; inserting it raw into a multibyte buffer turns each UTF-8 byte into a separate
`eight-bit` char. A "Select coding system" prompt appears on the first sync against data
containing `•`, curly quotes, or em-dashes, and `shadow.json` is written with mojibake (a `•` =
U+2022 lands on disk as three separate code-points). No error is raised — the corruption is
silent, at `insert` time.

**(b) `nil` scalars serialize as `[]`.** In Elisp `nil` *is* the empty list, so a nil plist
value hit the `(listp obj)` array branch in `mindwtr-util--json-prep` and became `[]`. Every
absent optional field (`:deletedAt`, `:completedAt`, `:dueDate`, `:startTime`, …) was sent as
`"deletedAt":[]`, which the server rejects with HTTP 422 "must be a valid ISO timestamp when
present." All PUTs failed.

**(c) Multibyte PUT body crashes `url.el`.** When the body contains non-ASCII chars, `url.el`
signals `Multibyte text in HTTP request` and aborts *before* opening the socket — so the server
sees nothing. Only on the `url.el` fallback path (bare Emacs without `plz.el`); `plz` handles
multibyte. This fires *even after* (a) is fixed, because the encoder now correctly returns
multibyte text — right for file I/O, still wrong as a raw HTTP body.

## What Didn't Work
- **`plz`-only testing** hid (c) entirely — `plz` accepts multibyte bodies silently, so the bug
  was invisible until a bare-Emacs (no-`plz`) environment exercised the `url.el` branch.
- **`encode-coding-string body 'us-ascii t`** (the obvious shortcut) does *not* work: the
  non-ASCII code-points are not representable in US-ASCII, so the "safe" `t` flag doesn't rescue
  them. The actual fix is a purpose-built `\uXXXX` escaper over the already-decoded text.

## Solution
**(a) Decode the unibyte output of `json-serialize` immediately** (`mindwtr-util.el:118-129`):

```elisp
(defun mindwtr-util-json-encode (obj)
  "Encode plist/list OBJ to a JSON string (multibyte text)."
  ;; json-serialize returns UNIBYTE UTF-8 bytes; decode them so the result is
  ;; text. Returning raw bytes leaks eight-bit chars into any multibyte buffer
  ;; they're inserted in -- the bug that turned a `•' into \342\200\242 on disk.
  (decode-coding-string
   (json-serialize (mindwtr-util--json-prep obj) :null-object nil :false-object :false)
   'utf-8))
```

File I/O is also pinned to UTF-8 (`mindwtr-util-read-file` binds `coding-system-for-read`,
`mindwtr-util-atomic-write` binds `coding-system-for-write`).

**(b) Guard `nil` before the array branch** in `mindwtr-util--json-prep` (`mindwtr-util.el:97-116`).
The dispatch test changed from `(and (listp obj) (not (null obj)) (keywordp (car obj)))` to
`(and (consp obj) (keywordp (car obj)))` — `consp` is false for `nil`, so a nil value never
enters the plist branch. Inside the loop, a nil value emits `[]` *only* for keys in
`mindwtr-util-json-array-fields`; every other nil scalar is dropped (absent, not `[]` or `null`):

```elisp
(cond
 (v (setq result (append result (list k (mindwtr-util--json-prep v)))))
 ((memq k mindwtr-util-json-array-fields)
  (setq result (append result (list k []))))
 (t nil))          ; drop nil scalar entirely
```

**(c) Re-escape non-ASCII for the HTTP body** via `mindwtr-util-json-ascii`
(`mindwtr-util.el:131-146`), used at both PUT sites (`mindwtr-api.el:266` async, `:306` sync).
It calls
`mindwtr-util-json-encode` (now multibyte text), then maps each char: ASCII passes through, BMP
non-ASCII emits `\uXXXX`, astral chars emit a UTF-16 surrogate pair. The result is pure ASCII
that `url.el` sends without complaint and any JSON decoder reads identically.

The two paths are deliberate inverses: `mindwtr-util-json-encode` **decodes** UTF-8 bytes to
text (for file I/O); `mindwtr-util-json-ascii` **escapes** non-ASCII to `\uXXXX` (for HTTP).
(Commits `fc31b99`, `4d585db`.)

## Why This Works
- `decode-coding-string ... 'utf-8` is the exact inverse of what `json-serialize` did — a
  lossless round-trip from UTF-8 bytes back to code-points.
- `consp` is false for `()`/`nil`, so the plist key-loop is never entered for nil; only concrete
  pairs reach it.
- `\uXXXX` escaping is valid JSON (RFC 7159 §7); server and client decode it identically to the
  original character. Pure ASCII is only needed for the `url.el` body — everywhere else
  (shadow, etag, signatures) benefits from genuine multibyte text.

## Prevention
- **Test with real non-ASCII data at every layer.** The smoke suite gave a *false green* on (a):
  the round-trip compared signatures computed over the *same* mis-encoded bytes on both sides, so
  it proved the corruption was *consistent*, not *correct*. The fix added unit tests that assert
  `(multibyte-string-p s)` directly and round-trip non-ASCII through a real temp file. A
  symmetric transform that corrupts both sides equally will pass any equality-based round-trip
  test — assert the *representation*, not just round-trip equality.
- Any new array-valued model field must be registered in `mindwtr-util-json-array-fields`, or its
  empty value will be dropped instead of emitting `[]`.

## Related Issues
- `mindwtr-util-json-array-fields` was initially incomplete; recurrence/settings array fields
  were added later. The nil-scalar guard and this registry are maintained together.
- Same `url.el` transport surface as [[url-el-synchronous-buffer-leak]]; both are `url.el`
  fallback-path footguns. Shares the signature/round-trip discipline of
  [[content-signature-allow-list-not-deny-list]].
