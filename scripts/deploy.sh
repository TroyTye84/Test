#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy this repository to GreenGeeks.
#
#   ./scripts/deploy.sh              pull latest commit on cPanel, then deploy
#   ./scripts/deploy.sh --no-pull    deploy whatever cPanel has checked out
#   ./scripts/deploy.sh --branch x   pull and deploy branch x
#   ./scripts/deploy.sh --check      show config and connectivity, change nothing
#
# Works identically on your machine and in GitHub Actions.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

DO_PULL=true
CHECK_ONLY=false
BRANCH_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) DO_PULL=false; shift ;;
    --check)   CHECK_ONLY=true; shift ;;
    --branch)  BRANCH_OVERRIDE="${2:-}"; [ -z "$BRANCH_OVERRIDE" ] && die "--branch needs a value"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown option: $1 (try --help)" ;;
  esac
done

load_config "$REPO_ROOT"
[ -n "$BRANCH_OVERRIDE" ] && DEPLOY_BRANCH="$BRANCH_OVERRIDE"

info "GreenGeeks deploy"
dim  "  host        ${CPANEL_HOST}:${CPANEL_PORT}"
dim  "  cpanel user ${CPANEL_USER}"
dim  "  repo root   ${CPANEL_REPO_ROOT}"
dim  "  branch      ${DEPLOY_BRANCH}"

if [ "$CHECK_ONLY" = true ]; then
  info "checking credentials and repository..."
  response="$(cpanel_api "VersionControl/retrieve")"
  if printf '%s' "$response" | grep -qF "$CPANEL_REPO_ROOT"; then
    info "cPanel knows this repository. Configuration looks good."
  else
    warn "connected fine, but cPanel does not list a repository at:"
    warn "  $CPANEL_REPO_ROOT"
    warn "Check CPANEL_REPO_ROOT against cPanel > Git Version Control."
    exit 1
  fi
  exit 0
fi

# --- 1. pull -------------------------------------------------------------
# Tells cPanel's clone to fetch the newest commit from GitHub. Skipped by
# --no-pull when you only want to redeploy the current checkout.
if [ "$DO_PULL" = true ]; then
  info "pulling '${DEPLOY_BRANCH}' from GitHub into the cPanel clone..."
  cpanel_api "VersionControl/update" \
    "repository_root=${CPANEL_REPO_ROOT}" \
    "branch=${DEPLOY_BRANCH}" > /dev/null
  info "pull requested"
else
  warn "skipping pull (--no-pull): deploying whatever cPanel currently has"
fi

# --- 2. deploy -----------------------------------------------------------
# Queues a deployment; cPanel then runs the tasks in .cpanel.yml, which is
# the single call into deploy/remote-deploy.sh.
info "queueing deployment..."
deploy_response="$(cpanel_api "VersionControlDeployment/create" \
  "repository_root=${CPANEL_REPO_ROOT}")"
info "deployment queued"

# --- 3. wait for the result ----------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found -- cannot poll for the result."
  warn "The deployment is queued; check cPanel > Git Version Control > Manage > Pull or Deploy."
  exit 0
fi

info "waiting for cPanel to finish..."
deadline=$(( $(date +%s) + 300 ))
attempt=0

while :; do
  attempt=$((attempt + 1))
  status_json="$(cpanel_api "VersionControlDeployment/retrieve")" || true

  # The deployment record schema varies between cPanel versions, so read it
  # defensively: find our repository, then look for a terminal timestamp.
  result="$(REPO_ROOT_MATCH="$CPANEL_REPO_ROOT" python3 -c '
import json, os, sys
want = os.environ["REPO_ROOT_MATCH"].rstrip("/")
try:
    items = json.load(sys.stdin).get("data") or []
except Exception:
    print("unknown|"); sys.exit(0)
if isinstance(items, dict):
    items = [items]
mine = [i for i in items if isinstance(i, dict)
        and str(i.get("repository_root", "")).rstrip("/") == want]
if not mine:
    print("unknown|"); sys.exit(0)

def when(rec):
    ts = rec.get("timestamps") or {}
    vals = [v for v in ts.values() if isinstance(v, (int, float))]
    return max(vals) if vals else 0

rec = max(mine, key=when)
ts = rec.get("timestamps") or {}
log = rec.get("log_path") or ""
if ts.get("failed"):      print("failed|"      + str(log))
elif ts.get("succeeded"): print("succeeded|"   + str(log))
elif ts.get("active"):    print("active|"      + str(log))
elif ts.get("queued"):    print("queued|"      + str(log))
else:                     print("unknown|"     + str(log))
' <<< "$status_json")" || result="unknown|"

  state="${result%%|*}"
  logpath="${result#*|}"

  case "$state" in
    succeeded)
      info "${C_GRN}deployment succeeded${C_OFF}"
      [ -n "$logpath" ] && dim "  log: $logpath"
      exit 0 ;;
    failed)
      [ -n "$logpath" ] && dim "  log: $logpath"
      die "deployment FAILED. Read the log above on the server, or check
     cPanel > Git Version Control > Manage > Pull or Deploy." ;;
    unknown)
      # Older cPanel builds expose no queryable history. The deploy itself
      # was accepted, so treat this as "submitted" rather than an error.
      if [ "$attempt" -ge 3 ]; then
        warn "cPanel is not reporting deployment history for this repository."
        warn "The deployment was accepted -- verify it in cPanel, or by fetching"
        warn "  https://<your-domain>/.deployed-version"
        exit 0
      fi ;;
    *)
      dim "  state: $state" ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    warn "still '$state' after 5 minutes -- giving up waiting."
    warn "The deployment may still complete. Run scripts/status.sh to check."
    exit 0
  fi
  sleep 5
done
