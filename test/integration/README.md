# Dockerized integration test

Runs the committed Emacs smoke suite (`smoke/`) against a **real Mindwtr cloud
sync server** in Docker, then cross-validates the same `/v1/data` wire with an
independent, non-Emacs **curl** client.

This is the end-to-end counterpart to `make smoke` (which needs you to point at
an already-running server): here the server is provisioned, exercised, and torn
down for you, against a version you choose.

## Quick start

```sh
make smoke-docker                            # test the pinned default version
MINDWTR_CLOUD_TAG=0.9.9 make smoke-docker    # validate a different version
MINDWTR_CLOUD_TAG=latest make smoke-docker   # test the floating latest tag
MINDWTR_SKIP_WRITE=1 make smoke-docker       # read-only phases only (no PUTs)
```

The pinned default version lives in one place: `DEFAULT_CLOUD_TAG` in
`run.sh`. `compose.yaml` and the CI workflow derive from it, so a version bump
is a one-line change there.

Or directly: `test/integration/run.sh`.

## What it does

1. **Preflight** — checks for Docker (daemon reachable), the Compose plugin,
   Emacs, `curl`, and `jq`. If Docker or Emacs is missing it **SKIPs** (exit 0)
   so a runner without Docker isn't red; set `MINDWTR_DOCKER_REQUIRE=1` to make a
   missing prerequisite a hard failure instead.
2. **Provision** — `docker compose up -d` of `ghcr.io/dongdongbh/mindwtr-cloud`
   (port `8787`, `/v1/data` + `/health`), with a freshly generated 50-char
   bearer token shared by the server and both clients, and an ephemeral named
   volume so every run starts from an empty namespace. Waits on `/health`.
3. **Emacs client** — runs `make smoke-write` (connectivity, snapshot+validate,
   schema-coverage drift check, render/parse round-trip, and the self-cleaning
   inbox→next→done→delete write lifecycle) against the live server.
4. **curl client (second, independent client)** — asserts auth is enforced
   (no-token GET → 401/403), the authenticated `GET /v1/data` returns a
   well-formed AppData (`tasks`/`projects`/`sections`/`areas`), reports whether
   `HEAD` serves an `ETag`, then **PUTs a foreign task** and confirms the server
   merged and persisted it.
5. **Cross-client agreement** — re-runs the Emacs read-only smoke so the Emacs
   model ingests and round-trips the curl-written entity. Two independent
   clients, same wire, same server.
6. **Teardown** (always, via trap) — dumps the last server logs and runs
   `docker compose down -v`, removing the container and data volume.

Exit status is non-zero on any failure (`set -euo pipefail`); a failed Emacs
phase or curl assertion fails the whole run, teardown still happens.

## Knobs

| Env var | Default | Meaning |
|---|---|---|
| `MINDWTR_CLOUD_TAG` | _pinned in `run.sh`_ | Image tag to test. Pinned (`DEFAULT_CLOUD_TAG`) so runs are reproducible; set `latest` or another version to override. |
| `MINDWTR_CLOUD_IMAGE` | — | Full image ref override. |
| `MINDWTR_DOCKER_PORT` | `8787` | Host port to bind. |
| `MINDWTR_SKIP_WRITE` | unset | `1` = read-only phases only (no PUTs). |
| `MINDWTR_DOCKER_REQUIRE` | unset | `1` = FAIL instead of SKIP on missing Docker/Emacs. |
| `EMACS` | `emacs` | Emacs binary. |

Pulling the image requires network access to `ghcr.io`; in a locked-down
environment the server start step will fail with a clear message.

## Why curl, not the `mindwtr` CLI

The original ask was to cross-validate with "the standard mindwtr CLI." That
isn't possible against this server, by design:

- The Mindwtr **CLI** (and MCP server) drive the **local desktop API** on
  `127.0.0.1` (`/local/*`) — the automation surface of a running desktop app.
- This Docker container is the **cloud sync server**, which speaks the
  **`/v1/data`** sync API. That is the surface the Emacs client uses.

These are different APIs, so the CLI cannot be pointed at the cloud server.
`curl` is therefore the faithful "second client": it speaks the exact same
`/v1/data` wire as Emacs, which is what we want to cross-validate.

If you want a *full* second-client check with real Mindwtr code, run the desktop
app or PWA configured to **sync** to this server (`docker/compose.yaml` in the
upstream repo also ships the PWA), let it pull the data, then use the CLI
against *that desktop app*. That needs a GUI/PWA and is out of scope for this
headless test.

## Local cleartext HTTP is fine here

Mindwtr ≥ 0.9.1 blocks **public** cleartext-HTTP sync targets but still allows
**local/private** ones. `127.0.0.1` is private, so this test runs over plain
HTTP. (If you sync to a *public* host, use HTTPS — see the upstream
`docker/compose.https.yaml`.)
