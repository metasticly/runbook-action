#!/usr/bin/env bash
# Tests for scripts/start-run.sh against tests/mock_server.py. Needs bash, curl, jq and python3.
# Usage: tests/run-tests.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/start-run.sh"
tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/requests"
python3 -I "$here/mock_server.py" "$tmp/port" "$tmp/requests" &
server_pid=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || { echo "mock server did not start"; exit 1; }
base="http://127.0.0.1:$(cat "$tmp/port")"

passed=0
failed=0
ok() { passed=$((passed + 1)); printf '  ok   %s\n' "$1"; }
not_ok() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# run_case <name> [VAR=value ...]: runs the script with a clean environment plus the given variables.
# Afterwards: $code, $out (stdout+stderr), $gh_output (contents of GITHUB_OUTPUT), $last_req (last request JSON).
run_case() {
  local name="$1"
  shift
  rm -f "$tmp"/requests/*.json "$tmp/gh_output" "$tmp/summary"
  : >"$tmp/gh_output"
  code=0
  out="$(env -i PATH="$PATH" HOME="$tmp" RUNBOOK_BASE_URL="$base" GITHUB_OUTPUT="$tmp/gh_output" \
    GITHUB_STEP_SUMMARY="$tmp/summary" "$@" bash "$script" 2>&1)" || code=$?
  gh_output="$(cat "$tmp/gh_output")"
  local last
  last="$(find "$tmp/requests" -name '*.json' | sort | tail -n 1)"
  if [ -n "$last" ]; then last_req="$(cat "$last")"; else last_req=""; fi
  current="$name"
}

expect_code() { if [ "$code" = "$1" ]; then ok "$current: exit $1"; else not_ok "$current: exit $1 (got $code)" "$out"; fi; }
expect_out() { if printf '%s' "$out" | grep -qF -- "$1"; then ok "$current: output has '$1'"; else not_ok "$current: output has '$1'" "$out"; fi; }
expect_ghout() { if printf '%s\n' "$gh_output" | grep -qxF -- "$1"; then ok "$current: GITHUB_OUTPUT has '$1'"; else not_ok "$current: GITHUB_OUTPUT has '$1'" "$gh_output"; fi; }
expect_req() { # expect_req <jq-filter> <expected>
  local got
  got="$(printf '%s' "$last_req" | jq -c "$1" 2>/dev/null)"
  if [ "$got" = "$2" ]; then ok "$current: request $1 == $2"; else not_ok "$current: request $1 == $2 (got $got)" "$last_req"; fi
}
expect_requests() { # expect_requests <count>
  local n
  n="$(find "$tmp/requests" -name '*.json' | wc -l | tr -d ' ')"
  if [ "$n" = "$1" ]; then ok "$current: $1 request(s) sent"; else not_ok "$current: $1 request(s) sent (got $n)"; fi
}

echo "start-run.sh tests (mock server at $base)"

vars=$'version=v1.2.3\n\n# a comment\n  env = production\r\nnote=a=b "quoted" $(not run)'
run_case "success by name" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE="Release {{version}}" RUNBOOK_TITLE="Release v1.2.3" \
  RUNBOOK_VARIABLES="$vars" RUNBOOK_DUE_DATE=2026-12-01
expect_code 0
expect_ghout "run-id=7"
expect_ghout "run-url=https://runbook.example/runs/7"
expect_ghout "status=open"
expect_requests 1
expect_req '.method' '"POST"'
expect_req '.path' '"/api/v1/runs"'
expect_req '.authorization' '"Bearer rb_ok"'
expect_req '.content_type' '"application/json"'
# shellcheck disable=SC2016 # the literal $(not run) must reach the API unexpanded
expect_req '.body' '{"template":"Release {{version}}","variables":{"version":"v1.2.3","env":"production","note":"a=b \"quoted\" $(not run)"},"title":"Release v1.2.3","due_date":"2026-12-01"}'
if grep -q "Release v1.2.3" "$tmp/summary" 2>/dev/null; then ok "$current: step summary written"; else not_ok "$current: step summary written"; fi

run_case "success by id, no optional fields" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=" 12 "
expect_code 0
expect_req '.body' '{"template_id":12,"variables":{}}'

run_case "token is not passed on the command line" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=12
if printf '%s' "$out" | grep -q 'rb_ok'; then not_ok "$current: token not echoed" "$out"; else ok "$current: token not echoed"; fi

run_case "401 invalid token" RUNBOOK_API_TOKEN=rb_bad RUNBOOK_TEMPLATE=Release
expect_code 1
expect_out "rejected the API token (401: invalid or revoked token)"
if [ -z "$gh_output" ]; then ok "$current: no outputs set"; else not_ok "$current: no outputs set" "$gh_output"; fi

run_case "500 server error is not retried" RUNBOOK_API_TOKEN=rb_5xx RUNBOOK_TEMPLATE=Release
expect_code 1
expect_out "Runbook server error (500): internal error"
expect_requests 1

run_case "402 plan limit" RUNBOOK_API_TOKEN=rb_limit RUNBOOK_TEMPLATE=Release
expect_code 1
expect_out "plan limit reached (402)"
expect_out "(api_runs: 10/10 on the Free plan, resets 2026-12-01T00:00:00Z)"

run_case "404 template" RUNBOOK_API_TOKEN=rb_missing RUNBOOK_TEMPLATE=Nope
expect_code 1
expect_out "not found (404): template not found"

run_case "GitHub error annotation" GITHUB_ACTIONS=true RUNBOOK_API_TOKEN=rb_bad RUNBOOK_TEMPLATE=Release
expect_out "::error title=Runbook::Runbook rejected the API token"
expect_out "::add-mask::rb_bad"

run_case "wait until completed" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_WAIT=true RUNBOOK_POLL_INTERVAL=2 RUNBOOK_TIMEOUT=30
expect_code 0
expect_requests 4
expect_req '.path' '"/api/v1/runs/7"'
expect_req '.method' '"GET"'
expect_ghout "status=completed"
expect_out "2/5 items checked, 3 required open"

run_case "wait survives a transient 503" RUNBOOK_API_TOKEN=rb_flaky RUNBOOK_TEMPLATE=Release RUNBOOK_WAIT=true RUNBOOK_POLL_INTERVAL=2 RUNBOOK_TIMEOUT=30
expect_code 0
expect_out "status check failed (Runbook server error (503)"
expect_ghout "status=completed"

run_case "wait times out" RUNBOOK_API_TOKEN=rb_open RUNBOOK_TEMPLATE=Release RUNBOOK_WAIT=true RUNBOOK_POLL_INTERVAL=2 RUNBOOK_TIMEOUT=3
expect_code 3
expect_out "was not completed within 3s"
expect_ghout "run-id=8"

run_case "template by slug" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=" release-checklist "
expect_code 0
expect_req '.body' '{"template":"release-checklist","variables":{}}'
expect_req '.idempotency_key' 'null'

run_case "idempotency key with request fingerprint" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=release-checklist RUNBOOK_IDEMPOTENCY_KEY=4711-1
expect_code 0
key1="$(printf '%s' "$last_req" | jq -r '.idempotency_key')"
if printf '%s' "$key1" | grep -Eq '^4711-1-[0-9a-f]{12}$'; then ok "$current: key is <key>-<12 hex>"; else not_ok "$current: key is <key>-<12 hex>" "$key1"; fi

run_case "same key and request again: replayed run" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=release-checklist RUNBOOK_IDEMPOTENCY_KEY=4711-1
expect_code 0
expect_ghout "run-id=7"
expect_out "returned the run created earlier"
expect_req '.idempotency_key' "\"$key1\""

run_case "same key, other template: different key" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=hotfix RUNBOOK_IDEMPOTENCY_KEY=4711-1
expect_code 0
key2="$(printf '%s' "$last_req" | jq -r '.idempotency_key')"
if [ "$key2" != "$key1" ] && [ "${key2%-*}" = "4711-1" ]; then ok "$current: keys differ per request"; else not_ok "$current: keys differ per request" "$key1 / $key2"; fi

run_case "replay (200) is success" RUNBOOK_API_TOKEN=rb_replay RUNBOOK_TEMPLATE=Release RUNBOOK_IDEMPOTENCY_KEY=1-1
expect_code 0
expect_ghout "run-id=11"
expect_ghout "status=open"

run_case "with a key, a 503 on POST is retried" RUNBOOK_API_TOKEN=rb_flakypost RUNBOOK_TEMPLATE=Release RUNBOOK_IDEMPOTENCY_KEY=2-1
expect_code 0
expect_requests 2
expect_out "retry 1/3"
first_key="$(jq -r '.idempotency_key' "$(find "$tmp/requests" -name '*.json' | sort | head -n 1)")"
expect_req '.idempotency_key' "\"$first_key\""

run_case "with a key, POST gives up after 3 retries" RUNBOOK_API_TOKEN=rb_down RUNBOOK_TEMPLATE=Release RUNBOOK_IDEMPOTENCY_KEY=3-1
expect_code 1
expect_requests 4
expect_out "Runbook server error (503)"

run_case "invalid idempotency key" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_IDEMPOTENCY_KEY="$(printf 'k\001')"
expect_code 2
expect_out "idempotency-key must be"
expect_requests 0

run_case "wait: cancelled run fails the step" RUNBOOK_API_TOKEN=rb_cancel RUNBOOK_TEMPLATE=Release RUNBOOK_WAIT=true RUNBOOK_POLL_INTERVAL=2 RUNBOOK_TIMEOUT=30
expect_code 4
expect_ghout "status=cancelled"
expect_out "run #10 was cancelled (release postponed)"
if grep -q "was cancelled: release postponed" "$tmp/summary" 2>/dev/null; then ok "$current: step summary says cancelled"; else not_ok "$current: step summary says cancelled"; fi

run_case "unreachable server" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_BASE_URL=http://127.0.0.1:9
expect_code 1
expect_out "could not reach http://127.0.0.1:9"

run_case "missing token" RUNBOOK_TEMPLATE=Release
expect_code 2
expect_out "api-token is empty"
expect_requests 0

run_case "plain http rejected" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_BASE_URL=http://runbook.example
expect_code 2
expect_out "base-url must use https://"

run_case "bad variable line" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_VARIABLES="just-text"
expect_code 2
expect_out "expected key=value"

run_case "bad variable name" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_VARIABLES="my-var=1"
expect_code 2
expect_out "invalid variable name 'my-var'"

run_case "bad due date" RUNBOOK_API_TOKEN=rb_ok RUNBOOK_TEMPLATE=Release RUNBOOK_DUE_DATE=tomorrow
expect_code 2
expect_out "due-date must be YYYY-MM-DD"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
