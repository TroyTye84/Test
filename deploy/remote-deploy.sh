#!/bin/bash
# ---------------------------------------------------------------------------
# Runs ON THE GREENGEEKS SERVER, invoked by .cpanel.yml during a cPanel
# Git Version Control deployment.
#
# Working directory is the repository clone, normally:
#   /home/<username>/repositories/<repo>
#
# It never runs on your laptop and never runs in GitHub Actions.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- load settings --------------------------------------------------------
# shellcheck source=deploy.env
source "$REPO_ROOT/deploy/deploy.env"

: "${DEPLOY_PATH:?DEPLOY_PATH is not set in deploy/deploy.env}"
: "${SOURCE_DIR:=public_html}"
: "${DELETE_REMOVED:=false}"
: "${DIR_MODE:=755}"
: "${FILE_MODE:=644}"

log() { printf '[deploy %s] %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

log "repository : $REPO_ROOT"
log "target     : $DEPLOY_PATH"
log "commit     : $(git rev-parse --short HEAD 2>/dev/null || echo unknown) on $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# --- safety rails ---------------------------------------------------------
# A typo in DEPLOY_PATH combined with DELETE_REMOVED=true could wipe a home
# directory. Refuse the obviously catastrophic targets outright.
case "$DEPLOY_PATH" in
  ""|"/"|"$HOME"|"$HOME/") log "FATAL: refusing to deploy to '$DEPLOY_PATH'"; exit 1 ;;
esac
if [ ! -d "$REPO_ROOT/$SOURCE_DIR" ]; then
  log "FATAL: source directory '$SOURCE_DIR' does not exist in the repository"
  exit 1
fi

mkdir -p "$DEPLOY_PATH"

# --- collect the managed folder list --------------------------------------
# Read once, used twice: these are excluded from rsync --delete (so a deploy
# never destroys runtime data living in them) and re-created after the sync.
MANAGED_DIRS=()
if [ -f "$REPO_ROOT/deploy/dirs.txt" ]; then
  while IFS= read -r dir; do
    dir="${dir%%#*}"                       # strip comments
    dir="$(echo "$dir" | xargs || true)"   # trim whitespace
    [ -z "$dir" ] && continue
    case "$dir" in
      /*|*..*) log "skipping unsafe path in dirs.txt: $dir"; continue ;;
    esac
    MANAGED_DIRS+=("$dir")
  done < "$REPO_ROOT/deploy/dirs.txt"
fi

# --- 1. sync files --------------------------------------------------------
# .git and the deploy machinery must never be published.
EXCLUDES=(--exclude '.git' --exclude '.gitignore' --exclude '.DS_Store')
while IFS= read -r pattern; do
  pattern="$(echo "$pattern" | xargs || true)"
  [ -z "$pattern" ] && continue
  EXCLUDES+=(--exclude "$pattern")
done <<< "${PROTECTED_PATHS:-}"
# Folders from dirs.txt hold server-side data, not repo content. Excluding
# them keeps --delete from emptying them on every deploy.
for dir in ${MANAGED_DIRS+"${MANAGED_DIRS[@]}"}; do
  EXCLUDES+=(--exclude "/$dir/")
done

if command -v rsync >/dev/null 2>&1; then
  RSYNC_ARGS=(-rlptD --human-readable "${EXCLUDES[@]}")
  if [ "$DELETE_REMOVED" = "true" ]; then
    RSYNC_ARGS+=(--delete)
    log "DELETE_REMOVED=true -- files absent from the repo will be removed"
  fi
  log "syncing with rsync..."
  # Exit 23/24 mean "some files were skipped" -- expected here, because an
  # excluded path can leave a non-empty parent that --delete cannot remove.
  # Without this, set -e would fail an otherwise successful deploy.
  rsync_status=0
  rsync "${RSYNC_ARGS[@]}" "$REPO_ROOT/$SOURCE_DIR/" "$DEPLOY_PATH/" || rsync_status=$?
  case "$rsync_status" in
    0)     ;;
    23|24) log "rsync reported skipped files (exit $rsync_status) -- expected with excludes, continuing" ;;
    *)     log "FATAL: rsync failed with exit $rsync_status"; exit "$rsync_status" ;;
  esac
else
  # GreenGeeks images normally ship rsync; this is the belt-and-braces path.
  log "rsync unavailable -- falling back to cp (DELETE_REMOVED ignored)"
  cp -R "$REPO_ROOT/$SOURCE_DIR/." "$DEPLOY_PATH/"
  rm -rf "$DEPLOY_PATH/.git"
fi

# --- 2. ensure folders exist ---------------------------------------------
# After the sync, so --delete cannot remove a folder we just created.
for dir in ${MANAGED_DIRS+"${MANAGED_DIRS[@]}"}; do
  mkdir -p "$DEPLOY_PATH/$dir"
  log "ensured folder: $dir"
done

# --- 3. permissions -------------------------------------------------------
log "normalising permissions to $DIR_MODE / $FILE_MODE"
find "$DEPLOY_PATH" -type d -exec chmod "$DIR_MODE" {} + 2>/dev/null || true
find "$DEPLOY_PATH" -type f -exec chmod "$FILE_MODE" {} + 2>/dev/null || true

# --- 4. stamp the release -------------------------------------------------
# Lets you confirm from a browser which commit is actually live.
{
  echo "commit:   $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "branch:   $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "deployed: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$DEPLOY_PATH/.deployed-version"
chmod "$FILE_MODE" "$DEPLOY_PATH/.deployed-version"

log "done."
