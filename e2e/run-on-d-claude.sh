#!/usr/bin/env bash
# Thin wrapper: rsync this repo to d-claude and run e2e/run.sh there, then pull
# back the artifacts. All the real logic lives in e2e/run.sh; this only moves the
# tree to the host that has /dev/kvm + the built scrcpy-e2e:dev image.
set -euo pipefail

HOST="${SCRCPY_E2E_HOST:-d-claude}"
REMOTE_DIR="${SCRCPY_E2E_REMOTE_DIR:-/srv/work/scrcpy-mobile-e2e}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '%s [run-on-d-claude] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

log "rsync $REPO_ROOT -> $HOST:$REMOTE_DIR"
# --delete keeps the remote a faithful mirror; excludes keep the transfer small
# and avoid clobbering remote build caches / pushing local artifacts.
ssh "$HOST" "mkdir -p '$REMOTE_DIR'"
rsync -az --delete \
  --exclude '.git/' \
  --exclude 'e2e/artifacts/' \
  --exclude 'android-app/build/' \
  --exclude 'android-app/.gradle/' \
  --exclude 'android-app/app/build/' \
  --exclude 'android-app/local.properties' \
  "$REPO_ROOT/" "$HOST:$REMOTE_DIR/"

log "invoking run.sh on $HOST"
set +e
ssh "$HOST" "bash '$REMOTE_DIR/e2e/run.sh'"
rc=$?
set -e
log "remote run.sh exited rc=$rc"

# Pull artifacts back so they're inspectable locally.
LOCAL_ARTIFACTS="$REPO_ROOT/e2e/artifacts"
mkdir -p "$LOCAL_ARTIFACTS"
log "fetching artifacts -> $LOCAL_ARTIFACTS"
rsync -az "$HOST:$REMOTE_DIR/e2e/artifacts/" "$LOCAL_ARTIFACTS/" 2>/dev/null || true

if [ "$rc" -eq 0 ]; then
  log "SUCCESS (remote e2e green)"
else
  log "FAILURE (remote rc=$rc) — see $LOCAL_ARTIFACTS"
fi
exit "$rc"
