#!/usr/bin/env bash
# Start a Runbook checklist run via the Runbook API and optionally wait until it is completed.
#
# Used by action.yml (GitHub / Forgejo Actions), but it works in any CI that has bash, curl and jq.
# All configuration comes from environment variables:
#
#   RUNBOOK_API_TOKEN      required  API token (rb_...), from Settings -> API tokens
#   RUNBOOK_TEMPLATE       required  template id (digits), slug (e.g. release-checklist) or name (case-insensitive)
#   RUNBOOK_TITLE          optional  run title (default: the template name, variables filled in)
#   RUNBOOK_VARIABLES      optional  key=value per line (whitespace around key and value is trimmed;
#                                    blank lines and # comments are ignored)
#   RUNBOOK_DUE_DATE       optional  YYYY-MM-DD
#   RUNBOOK_BASE_URL       optional  default https://runbook.metastic.ch
#   RUNBOOK_WAIT           optional  "true" to wait until the run is completed (default false)
#   RUNBOOK_TIMEOUT        optional  seconds to wait (default 3600)
#   RUNBOOK_POLL_INTERVAL  optional  seconds between status checks (default 30, minimum 2)
#   RUNBOOK_IDEMPOTENCY_KEY optional Idempotency-Key for POST /api/v1/runs (action default:
#                                    "<run_id>-<run_attempt>"). A short hash of the request is appended,
#                                    so several Runbook steps in one workflow run do not collide. With a
#                                    key, a failed POST (network error, 429, 5xx) is retried up to 3 times
#                                    without risking a duplicate run. Empty: no key, no retry.
#
# Outputs (written to $GITHUB_OUTPUT if set, always printed): run-id, run-url, status.
# Exit codes: 0 ok, 1 API/HTTP error, 2 invalid input or missing tool, 3 timed out waiting,
#             4 the run was cancelled (while waiting).
#
# API reference: POST /api/v1/runs and GET /api/v1/runs/{id} (see the Runbook API docs).

set -euo pipefail

readonly UA="runbook-start-run/1.1"

log() { printf '%s\n' "$*" >&2; }

in_actions() { [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${FORGEJO_ACTIONS:-}" ] || [ -n "${GITEA_ACTIONS:-}" ]; }

fail() { # fail <exit-code> <message>
  if in_actions; then
    local msg="${2//%/%25}"
    printf '::error title=Runbook::%s\n' "$msg"
  else
    printf 'error: %s\n' "$2" >&2
  fi
  exit "$1"
}

set_output() { # set_output <name> <value>
  printf '%s=%s\n' "$1" "$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail 2 "'$tool' is required but not installed on this runner"
done

token="${RUNBOOK_API_TOKEN:-}"
template="${RUNBOOK_TEMPLATE:-}"
title="${RUNBOOK_TITLE:-}"
variables="${RUNBOOK_VARIABLES:-}"
due_date="${RUNBOOK_DUE_DATE:-}"
base_url="${RUNBOOK_BASE_URL:-https://runbook.metastic.ch}"
wait="${RUNBOOK_WAIT:-false}"
timeout="${RUNBOOK_TIMEOUT:-3600}"
interval="${RUNBOOK_POLL_INTERVAL:-30}"
idem_key="${RUNBOOK_IDEMPOTENCY_KEY:-}"

# --- validate input ---------------------------------------------------------------------------
token="$(printf '%s' "$token" | tr -d '[:space:]')"
[ -n "$token" ] || fail 2 "api-token is empty. Store a Runbook API token as a secret and pass it as api-token."
case "$token" in rb_*) ;; *) fail 2 "api-token does not look like a Runbook token (expected it to start with rb_)" ;; esac
if in_actions; then printf '::add-mask::%s\n' "$token"; fi

template="$(printf '%s' "$template" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$template" ] || fail 2 "template is empty. Pass a template id or the exact template name."

base_url="${base_url%/}"
case "$base_url" in
  https://*) ;;
  http://localhost | http://localhost:* | http://127.0.0.1 | http://127.0.0.1:* | http://\[::1\]*) ;;
  *) fail 2 "base-url must use https:// (got '$base_url')" ;;
esac

if [ -n "$due_date" ]; then
  printf '%s' "$due_date" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || fail 2 "due-date must be YYYY-MM-DD (got '$due_date')"
fi

case "$wait" in
  true | True | TRUE | yes | 1) wait=true ;;
  false | False | FALSE | no | 0 | '') wait=false ;;
  *) fail 2 "wait-for-completion must be true or false (got '$wait')" ;;
esac
is_uint "$timeout" || fail 2 "timeout must be a whole number of seconds (got '$timeout')"
is_uint "$interval" || fail 2 "poll-interval must be a whole number of seconds (got '$interval')"
[ "$interval" -ge 2 ] || interval=2
idem_key="$(printf '%s' "$idem_key" | tr -d '\r\n')"
if [ -n "$idem_key" ]; then
  printf '%s' "$idem_key" | LC_ALL=C grep -Eq '^[ -~]{1,200}$' || fail 2 "idempotency-key must be 1 to 200 printable ASCII characters"
fi

# variables: key=value per line -> JSON object
vars_json='{}'
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')"
  case "$trimmed" in '' | '#'*) continue ;; esac
  case "$trimmed" in *=*) ;; *) fail 2 "variables: expected key=value, got '$trimmed'" ;; esac
  key="${trimmed%%=*}"
  key="$(printf '%s' "$key" | sed -e 's/[[:space:]]*$//')"
  value="$(printf '%s' "${trimmed#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]{0,40}$' || fail 2 "variables: invalid variable name '$key'"
  vars_json="$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$vars_json")"
done <<<"$variables"

if is_uint "$template"; then
  body="$(jq -cn --argjson id "$template" '{template_id: $id}')"
else
  body="$(jq -cn --arg t "$template" '{template: $t}')"
fi
body="$(jq -c --argjson vars "$vars_json" --arg title "$title" --arg due "$due_date" \
  '. + {variables: $vars} + (if $title != "" then {title: $title} else {} end) + (if $due != "" then {due_date: $due} else {} end)' \
  <<<"$body")"

sha256_hex() { # sha256_hex <string>: lowercase hex digest, empty if no tool is available
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
  fi
}
if [ -n "$idem_key" ]; then
  fp="$(sha256_hex "$body")"
  [ -z "$fp" ] || idem_key="$idem_key-${fp:0:12}"
fi

# --- HTTP helpers ---------------------------------------------------------------------------
# The token goes into a private header file, so it never shows up in the process list.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077
printf 'Authorization: Bearer %s\n' "$token" >"$workdir/auth"

# api <method> <path> [json-body] [idempotency-key]: sets $http_status and writes the response body to $workdir/resp.
api() {
  local method="$1" path="$2" data="${3:-}" key="${4:-}" args rc=0
  args=(-sS -X "$method" -o "$workdir/resp" -w '%{http_code}' --connect-timeout 10 --max-time 30
    -H @"$workdir/auth" -H "Accept: application/json" -A "$UA")
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$data")
  fi
  if [ -n "$key" ]; then
    args+=(-H "Idempotency-Key: $key")
  fi
  http_status="$(curl "${args[@]}" "$base_url$path" 2>"$workdir/curl_err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    http_status=000
    curl_error="$(tr '\n' ' ' <"$workdir/curl_err")"
  fi
}

api_error_message() { # human-readable explanation for a failed response
  local msg
  msg="$(jq -r '.error // empty' "$workdir/resp" 2>/dev/null || true)"
  [ -n "$msg" ] || msg="$(head -c 200 "$workdir/resp" 2>/dev/null | tr '\n' ' ' || true)"
  case "$http_status" in
    000) printf 'could not reach %s: %s' "$base_url" "${curl_error:-network error}" ;;
    400) printf 'Runbook rejected the request (400): %s' "$msg" ;;
    401) printf 'Runbook rejected the API token (401: %s). Check that the secret is set and the token is not revoked.' "$msg" ;;
    402)
      local quota
      quota="$(jq -r 'if .limit != null and .used != null then " (\(.resource // "quota"): \(.used)/\(.limit) on the \(.plan_name // .plan) plan\(if .resets_at then ", resets \(.resets_at)" else "" end))" else "" end' "$workdir/resp" 2>/dev/null || true)"
      printf 'plan limit reached (402): %s%s. Upgrade the plan or wait for the next month.' "$msg" "$quota" ;;
    404) printf 'not found (404): %s. Check the template id, slug or exact name.' "$msg" ;;
    422) printf 'validation failed (422): %s' "$msg" ;;
    429) printf 'rate limited by Runbook (429): %s' "$msg" ;;
    5*) printf 'Runbook server error (%s): %s' "$http_status" "$msg" ;;
    *) printf 'unexpected HTTP status %s: %s' "$http_status" "$msg" ;;
  esac
}

# --- start the run --------------------------------------------------------------------------
log "Starting a Runbook run from template '$template' at $base_url"
# Without an Idempotency-Key the POST is not retried: a 5xx after the run was created would open a
# duplicate run. With a key, the server returns the original run (200) for a repeated request.
attempt=1
while :; do
  api POST /api/v1/runs "$body" "$idem_key"
  case "$http_status" in
    201 | 200) break ;;
    000 | 429 | 5*)
      if [ -n "$idem_key" ] && [ "$attempt" -le 3 ]; then
        log "warning: starting the run failed ($(api_error_message)), retry $attempt/3"
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
        continue
      fi
      fail 1 "$(api_error_message)"
      ;;
    *) fail 1 "$(api_error_message)" ;;
  esac
done
[ "$http_status" = 201 ] || log "Runbook returned the run created earlier for this Idempotency-Key"

run_id="$(jq -r '.id // empty' "$workdir/resp")"
run_url="$(jq -r '.url // empty' "$workdir/resp")"
status="$(jq -r '.status // empty' "$workdir/resp")"
run_title="$(jq -r '.title // empty' "$workdir/resp")"
is_uint "$run_id" || fail 1 "unexpected response from Runbook: no run id"

set_output run-id "$run_id"
set_output run-url "$run_url"
set_output status "$status"
log "Run #$run_id opened: $run_url"
summary "### Runbook: [${run_title:-run #$run_id}]($run_url) opened"

[ "$wait" = true ] || exit 0

# --- wait for completion --------------------------------------------------------------------
log "Waiting up to ${timeout}s for run #$run_id to be completed (checking every ${interval}s)"
start="$(date +%s)"
errors=0
while :; do
  if [ "$status" = cancelled ]; then
    set_output status cancelled
    reason="$(jq -r '.cancel_reason // empty' "$workdir/resp" 2>/dev/null || true)"
    summary "Run #$run_id was cancelled${reason:+: $reason}."
    fail 4 "run #$run_id was cancelled${reason:+ ($reason)}. Open $run_url"
  fi
  if [ "$status" = completed ]; then
    set_output status completed
    log "Run #$run_id is completed."
    summary "Run #$run_id completed: all required steps were checked."
    exit 0
  fi
  now="$(date +%s)"
  elapsed=$((now - start))
  if [ "$elapsed" -ge "$timeout" ]; then
    set_output status "$status"
    summary "Run #$run_id was not completed within ${timeout}s."
    fail 3 "run #$run_id was not completed within ${timeout}s (status: $status). Open $run_url"
  fi
  remaining=$((timeout - elapsed))
  if [ "$interval" -lt "$remaining" ]; then sleep "$interval"; else sleep "$remaining"; fi

  api GET "/api/v1/runs/$run_id"
  case "$http_status" in
    200)
      errors=0
      status="$(jq -r '.status // empty' "$workdir/resp")"
      log "Run #$run_id: $status, $(jq -r '"\(.items_checked)/\(.items_total) items checked, \(.required_open) required open"' "$workdir/resp")"
      ;;
    000 | 429 | 5*)
      # Transient: keep polling, but give up after 5 failures in a row.
      errors=$((errors + 1))
      log "warning: status check failed ($(api_error_message)), attempt $errors/5"
      [ "$errors" -lt 5 ] || fail 1 "$(api_error_message)"
      ;;
    *) fail 1 "$(api_error_message)" ;;
  esac
done
