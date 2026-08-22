#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Show what cPanel currently has: the repository it tracks, the commit it has
# checked out, and the most recent deployments. Read-only.
#
#   ./scripts/status.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
load_config "$REPO_ROOT"

info "repository on ${CPANEL_HOST}"
repos_json="$(cpanel_api "VersionControl/retrieve")"

if command -v python3 >/dev/null 2>&1; then
  REPO_ROOT_MATCH="$CPANEL_REPO_ROOT" python3 -c '
import json, os, sys
want = os.environ["REPO_ROOT_MATCH"].rstrip("/")
items = json.load(sys.stdin).get("data") or []
if isinstance(items, dict): items = [items]
mine = [i for i in items if str(i.get("repository_root","")).rstrip("/") == want]
if not mine:
    print("  no repository registered at", want)
    print("  known repositories:")
    for i in items:
        print("   -", i.get("repository_root"))
    sys.exit(0)
r = mine[0]
print("  path    :", r.get("repository_root"))
print("  branch  :", (r.get("branch") or {}).get("name") if isinstance(r.get("branch"), dict) else r.get("branch"))
head = r.get("last_update") or r.get("head_commit") or {}
if isinstance(head, dict):
    for k in ("identifier","commit_sha","sha"):
        if head.get(k): print("  commit  :", str(head[k])[:12]); break
for url in (r.get("source_repository") or {}).get("remote_url", None), r.get("clone_urls"):
    if url: print("  remote  :", url); break
' <<< "$repos_json"
else
  printf '%s\n' "$repos_json"
fi

echo
info "recent deployments"
deploy_json="$(cpanel_api "VersionControlDeployment/retrieve")"

if command -v python3 >/dev/null 2>&1; then
  REPO_ROOT_MATCH="$CPANEL_REPO_ROOT" python3 -c '
import json, os, sys, datetime
want = os.environ["REPO_ROOT_MATCH"].rstrip("/")
items = json.load(sys.stdin).get("data") or []
if isinstance(items, dict): items = [items]
mine = [i for i in items if str(i.get("repository_root","")).rstrip("/") == want]
if not mine:
    print("  cPanel is not reporting any deployment history for this repository.")
    print("  That is normal on some cPanel versions -- check the cPanel UI instead.")
    sys.exit(0)
def when(r):
    ts = r.get("timestamps") or {}
    v = [x for x in ts.values() if isinstance(x,(int,float))]
    return max(v) if v else 0
def fmt(t):
    try: return datetime.datetime.utcfromtimestamp(t).strftime("%Y-%m-%d %H:%M:%SZ")
    except Exception: return "?"
for r in sorted(mine, key=when, reverse=True)[:5]:
    ts = r.get("timestamps") or {}
    state = ("failed" if ts.get("failed") else "succeeded" if ts.get("succeeded")
             else "active" if ts.get("active") else "queued")
    print("  %-10s %s  %s" % (state, fmt(when(r)), str(r.get("sha") or r.get("deploy_id") or "")[:12]))
    if r.get("log_path"): print("             log:", r["log_path"])
' <<< "$deploy_json"
else
  printf '%s\n' "$deploy_json"
fi
