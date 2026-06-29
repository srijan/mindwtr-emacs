#!/usr/bin/env bash
# Integration test: run the Emacs smoke suite against a REAL Mindwtr cloud sync
# server running in Docker, then cross-validate the same /v1/data wire with an
# independent (non-Emacs) curl client.
#
# Why curl and not the official `mindwtr` CLI: the Mindwtr CLI drives the *local
# desktop* REST API (127.0.0.1, /local/*), not the *cloud sync* API (/v1/data)
# that this Docker server and the Emacs client speak -- so the CLI cannot be
# pointed at the cloud server.  curl is therefore the faithful "second client"
# that exercises the exact same wire.  See test/integration/README.md.
#
# Usage:
#   test/integration/run.sh
#   MINDWTR_CLOUD_TAG=latest test/integration/run.sh   # validate a target version
#
# Knobs (environment):
#   MINDWTR_CLOUD_TAG        image tag to test           (default: DEFAULT_CLOUD_TAG)
#   MINDWTR_CLOUD_IMAGE      full image ref override      (default: ghcr.io/dongdongbh/mindwtr-cloud:<tag>)
#   MINDWTR_DOCKER_PORT      host port to bind            (default: 8787)
#   MINDWTR_SKIP_WRITE=1     skip the Emacs write lifecycle (read-only phases only)
#   MINDWTR_DOCKER_REQUIRE=1 FAIL instead of SKIP when docker/emacs are unavailable
#   EMACS                    emacs binary                 (default: emacs)
#
# Exit status: 0 on success (or on a clean SKIP); non-zero on any failure.
set -euo pipefail

# --- locate the repo (this script lives in <repo>/test/integration) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"

PORT="${MINDWTR_DOCKER_PORT:-8787}"
BASE_URL="http://127.0.0.1:${PORT}"
EMACS_BIN="${EMACS:-emacs}"
PROJECT="mindwtr-itest"
export COMPOSE_PROJECT_NAME="$PROJECT"

# Single source of truth for the server version under test.  compose.yaml and
# the CI workflow both derive from this -- run.sh exports it, compose *requires*
# it (like the auth token) -- so the version is bumped in exactly one place.
# `:latest' floats ahead of this, so we pin by default for reproducibility;
# override per run with MINDWTR_CLOUD_TAG=... (e.g. =0.9.9, =latest) or
# MINDWTR_CLOUD_IMAGE for the whole ref.
# Renovate bumps this line automatically (see renovate.json); a new tag opens a
# PR whose CI runs the smoke suite against that version before it can merge.
# renovate: datasource=docker depName=ghcr.io/dongdongbh/mindwtr-cloud
DEFAULT_CLOUD_TAG="1.0.5"
export MINDWTR_CLOUD_TAG="${MINDWTR_CLOUD_TAG:-$DEFAULT_CLOUD_TAG}"
CLOUD_IMAGE="${MINDWTR_CLOUD_IMAGE:-ghcr.io/dongdongbh/mindwtr-cloud:${MINDWTR_CLOUD_TAG}}"

note()  { printf '\n=== %s ===\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
die()   { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

skip_or_fail() {
  # Loudly SKIP (exit 0) by default so a CI runner without Docker is not red;
  # set MINDWTR_DOCKER_REQUIRE=1 to turn a missing prerequisite into a failure.
  local msg="$1"
  if [ "${MINDWTR_DOCKER_REQUIRE:-0}" = "1" ]; then
    die "$msg (MINDWTR_DOCKER_REQUIRE=1)"
  fi
  printf '\n[SKIP] %s\n' "$msg"
  printf '       (set MINDWTR_DOCKER_REQUIRE=1 to make this a hard failure)\n'
  exit 0
}

# --- preflight ----------------------------------------------------------------
note "preflight"
command -v docker  >/dev/null 2>&1 || skip_or_fail "docker not installed"
docker compose version >/dev/null 2>&1 || skip_or_fail "docker compose plugin not available"
docker info >/dev/null 2>&1 || skip_or_fail "docker daemon not reachable"
command -v "$EMACS_BIN" >/dev/null 2>&1 || skip_or_fail "emacs not installed (set EMACS=...)"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq   >/dev/null 2>&1 || die "jq is required for the cross-check assertions"
info "docker: $(docker --version)"
info "emacs:  $("$EMACS_BIN" --version | head -1)"
info "image:  ${CLOUD_IMAGE}"
info "port:   ${PORT}"

# --- secrets / config ---------------------------------------------------------
# A fresh 50-char token per run, used by BOTH the server and the two clients.
# Keep `|| true` so the SIGPIPE `head' delivers to `tr' does not trip pipefail;
# then validate strictly -- fail loudly rather than fall back to a guessable
# low-entropy token if the entropy source ever comes up short.
TOKEN="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 50 || true)"
[ "${#TOKEN}" -ge 40 ] || die "could not generate a random token (/dev/urandom unavailable?)"
export MINDWTR_CLOUD_AUTH_TOKENS="$TOKEN"
export MINDWTR_CLOUD_CORS_ORIGIN="http://localhost:5173"

dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

cleanup() {
  note "teardown"
  dc logs --no-color --tail 40 mindwtr-cloud 2>&1 || true
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  info "removed containers + data volume for project '$PROJECT'"
}
trap cleanup EXIT

# Pre-clean any leftovers from an aborted previous run (scoped to our project).
dc down -v --remove-orphans >/dev/null 2>&1 || true

# --- bring up the server ------------------------------------------------------
note "start mindwtr-cloud"
if ! dc up -d; then
  die "could not start the server (image pull may be blocked by the network policy, or the port is in use)"
fi

note "wait for /health"
ready=0
for i in $(seq 1 90); do
  if curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
    ready=1; info "healthy after ${i}s"; break
  fi
  sleep 1
done
[ "$ready" = "1" ] || die "server did not become healthy at ${BASE_URL}/health within 90s"

# --- seed the namespace -------------------------------------------------------
# A fresh server has no namespace yet, so a bare `HEAD /v1/data` -- the first
# request the Emacs connectivity phase issues -- 404s.  An authenticated GET
# auto-creates the empty snapshot (per the cloud API), after which HEAD/GET/PUT
# all resolve.  A real client reaches this state via `mindwtr-bootstrap', whose
# GET runs before any HEAD; the smoke suite leads with HEAD, so seed explicitly.
note "seed namespace (authenticated GET auto-creates the empty snapshot)"
# `|| true' keeps a curl transport failure from tripping set -e; curl then
# reports 000, which we treat distinctly from a reachable-but-bad status.
seed_code="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/v1/data" || true)"
case "$seed_code" in
  2*)  info "GET /v1/data -> $seed_code (namespace ready)";;
  000) die "seed GET /v1/data got no HTTP response (curl could not reach ${BASE_URL}; server crashed or port closed?)";;
  *)   die "seed GET /v1/data returned '$seed_code' (expected 2xx); cannot initialize namespace";;
esac

# --- client config for the Emacs smoke suite ---------------------------------
export MINDWTR_URL="$BASE_URL"
export MINDWTR_TOKEN="$TOKEN"

run_make() {  # run a Makefile target from the repo root with smoke env present
  ( cd "$REPO_ROOT" && EMACS="$EMACS_BIN" make "$@" )
}

# --- Phase 1: Emacs client, full smoke (read-only + opt-in write lifecycle) ---
if [ "${MINDWTR_SKIP_WRITE:-0}" = "1" ]; then
  note "Emacs smoke (read-only) against the live server"
  run_make smoke || die "Emacs read-only smoke phases failed"
else
  note "Emacs smoke + write lifecycle against the live server"
  run_make smoke-write || die "Emacs smoke/write-lifecycle failed"
fi

# --- Phase 2: independent curl client -- auth + wire-shape checks -------------
note "curl cross-check: auth + endpoint contract"

unauth_code="$(curl -s -o /dev/null -w '%{http_code}' "${BASE_URL}/v1/data" || true)"
case "$unauth_code" in
  401|403) info "no-token GET -> $unauth_code (auth enforced)  [PASS]";;
  *)       die "no-token GET expected 401/403, got '$unauth_code' (auth not enforced?)";;
esac

auth=(-H "Authorization: Bearer ${TOKEN}")

snapshot="$(curl -fsS "${auth[@]}" "${BASE_URL}/v1/data")" \
  || die "authenticated GET /v1/data failed"
echo "$snapshot" | jq -e 'has("tasks") and has("projects") and has("sections") and has("areas")' >/dev/null \
  || die "GET body missing one of the expected top-level arrays (tasks/projects/sections/areas)"
info "authenticated GET -> 200, well-formed AppData  [PASS]"
info "snapshot: $(echo "$snapshot" | jq -c '{tasks:(.tasks|length),projects:(.projects|length),sections:(.sections|length),areas:(.areas|length)}')"

# HEAD is what the Emacs no-op fast path and connectivity check rely on; report
# its status + whether an ETag is served (informational -- the Emacs smoke
# already gates on HEAD, so this just localizes the diagnosis if it regresses).
head_out="$(curl -sS -I "${auth[@]}" "${BASE_URL}/v1/data" || true)"
head_code="$(printf '%s' "$head_out" | awk 'NR==1{print $2}')"
if printf '%s' "$head_out" | grep -qi '^etag:'; then
  info "HEAD /v1/data -> ${head_code:-?}, ETag present  [PASS]"
else
  info "HEAD /v1/data -> ${head_code:-?}, no ETag header (sync still works; no-op fast path just won't trigger)"
fi

# --- Phase 3: foreign write via curl, then confirm BOTH clients agree --------
note "curl cross-check: foreign write round-trips through the server"
# Linux exposes /proc; macOS/dev boxes have uuidgen; python3 is the last resort.
# `|| true' so an all-sources-missing case dies with a clear message, not set -e.
ITEST_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
  || uuidgen 2>/dev/null \
  || python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || true)"
[ -n "$ITEST_ID" ] || die "could not generate a UUID (need /proc, uuidgen, or python3)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload="$(jq -nc --arg id "$ITEST_ID" --arg now "$NOW" '{
  tasks:    [ { id:$id, title:"[itest] curl-written task", status:"inbox",
               rev:1, createdAt:$now, updatedAt:$now, revBy:"itest-curl",
               contexts:[], tags:[] } ],
  projects: [], sections: [], areas: [],
  # Non-null settings: the server merge dereferences settings.syncPreferences
  # without a null guard and 500s on a null blob (same reason the Emacs client
  # synthesizes initial settings). Mirror that here.
  settings: { syncPreferences: { initialized: true } }
}')"

put_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${auth[@]}" \
  -H 'Content-Type: application/json' --data "$payload" "${BASE_URL}/v1/data" || true)"
case "$put_code" in
  2*) info "curl PUT /v1/data -> $put_code  [PASS]";;
  *)  die "curl PUT expected 2xx, got '$put_code'";;
esac

after="$(curl -fsS "${auth[@]}" "${BASE_URL}/v1/data")" || die "GET after curl PUT failed"
echo "$after" | jq -e --arg id "$ITEST_ID" \
  '.tasks | map(select(.id==$id and (.deletedAt|not))) | length == 1' >/dev/null \
  || die "curl-written task $ITEST_ID not found live after PUT (merge/persist failed)"
info "server merged + persisted the foreign task  [PASS]"

# The strongest cross-client proof: re-run the Emacs READ-ONLY smoke now that a
# DIFFERENT client populated the server.  The snapshot+validate and the
# render/parse round-trip phases will ingest the curl-written task through the
# Emacs model -- proving the two independent clients agree on the wire.
note "Emacs re-reads the foreign-written data (cross-client agreement)"
run_make smoke || die "Emacs failed to ingest/round-trip the curl-written entity"

note "ALL CHECKS PASSED"
info "Emacs client and curl client both exercised /v1/data on the same"
info "${CLOUD_IMAGE} server, and agree on the wire."
