#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for talking to the cPanel UAPI on GreenGeeks.
# Sourced by scripts/deploy.sh and scripts/status.sh. Not run directly.
# ---------------------------------------------------------------------------

# Colours only when attached to a terminal, so CI logs stay clean.
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# --- configuration --------------------------------------------------------
# Values come from the environment first (that is how GitHub Actions supplies
# them), falling back to a local .env file that is never committed.
load_config() {
  local repo_root="$1"
  if [ -f "$repo_root/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$repo_root/.env"
    set +a
  fi

  CPANEL_PORT="${CPANEL_PORT:-2083}"
  DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

  local missing=()
  [ -z "${CPANEL_HOST:-}" ]      && missing+=("CPANEL_HOST")
  [ -z "${CPANEL_USER:-}" ]      && missing+=("CPANEL_USER")
  [ -z "${CPANEL_TOKEN:-}" ]     && missing+=("CPANEL_TOKEN")
  [ -z "${CPANEL_REPO_ROOT:-}" ] && missing+=("CPANEL_REPO_ROOT")
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing required setting(s): ${missing[*]}
     Locally : copy .env.example to .env and fill it in.
     In CI   : add them as repository secrets (see README)."
  fi
}

# --- JSON ------------------------------------------------------------------
# jq if present, python3 otherwise. Both are common enough that requiring
# either (rather than a specific one) keeps this portable.
json_query() {
  local expr="$1" json="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$expr"
  elif command -v python3 >/dev/null 2>&1; then
    JSON_EXPR="$expr" python3 -c '
import json, os, sys
expr = os.environ["JSON_EXPR"]
try:
    doc = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
# Only the handful of jq expressions this script actually uses.
cur = doc
for part in expr.lstrip(".").split("."):
    if not part or cur is None:
        break
    cur = cur.get(part) if isinstance(cur, dict) else None
print("" if cur is None else (json.dumps(cur) if isinstance(cur, (dict, list)) else cur))
' <<< "$json"
  else
    die "need either jq or python3 installed to read cPanel responses"
  fi
}

# --- UAPI ------------------------------------------------------------------
# GET https://HOST:PORT/execute/<Module>/<function>?<params>
# Auth is a cPanel API token, not your cPanel password.
cpanel_api() {
  local endpoint="$1"; shift
  local url="https://${CPANEL_HOST}:${CPANEL_PORT}/execute/${endpoint}"
  local args=(--silent --show-error --get --max-time 180
              --header "Authorization: cpanel ${CPANEL_USER}:${CPANEL_TOKEN}")
  local p
  for p in "$@"; do args+=(--data-urlencode "$p"); done

  local response
  if ! response="$(curl "${args[@]}" "$url" 2>&1)"; then
    die "could not reach ${CPANEL_HOST}:${CPANEL_PORT} -- $response
     Check CPANEL_HOST, and that your network can reach port ${CPANEL_PORT}."
  fi

  # cPanel answers 200 even for application errors, so status must be read
  # out of the body rather than inferred from the HTTP code.
  local status errors
  status="$(json_query '.status' "$response")"
  if [ "$status" != "1" ]; then
    errors="$(json_query '.errors' "$response")"
    [ -z "$errors" ] && errors="$response"
    die "cPanel rejected ${endpoint}: ${errors}"
  fi
  printf '%s' "$response"
}
