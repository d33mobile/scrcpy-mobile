#!/usr/bin/env bash
# Thin wrapper: rsync this repo to d-claude and run e2e/run-draw.sh (the full
# DRAWING e2e) there, then pull back the artifacts. All the real logic lives in
# e2e/run-draw.sh; this only moves the tree to the host that has /dev/kvm + the
# built scrcpy-e2e:dev image. Mirrors e2e/run-on-d-claude.sh (the tap-e2e wrapper)
# verbatim except for the script it invokes.
set -euo pipefail

HOST="${SCRCPY_E2E_HOST:-d-claude}"
REMOTE_DIR="${SCRCPY_E2E_REMOTE_DIR:-/srv/work/scrcpy-mobile-e2e}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '%s [run-draw-on-d-claude] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

log "rsync $REPO_ROOT -> $HOST:$REMOTE_DIR"
# --delete keeps the remote a faithful mirror; excludes keep the transfer small
# and avoid clobbering remote build caches / pushing local artifacts. SAME excludes
# as run-on-d-claude.sh, plus the draw-app build/.gradle so its cache persists.
ssh "$HOST" "mkdir -p '$REMOTE_DIR'"
rsync -az --delete \
  --exclude '.git/' \
  --exclude 'e2e/artifacts/' \
  --exclude 'output/' \
  --exclude 'porting/build/' \
  --exclude 'porting/libs/' \
  --exclude 'android-app/build/' \
  --exclude 'android-app/.gradle/' \
  --exclude 'android-app/app/build/' \
  --exclude 'android-app/app/src/main/jniLibs/' \
  --exclude 'android-app/app/src/main/assets/scrcpy-server' \
  --exclude 'android-app/local.properties' \
  --exclude 'e2e/target-app/build/' \
  --exclude 'e2e/target-app/.gradle/' \
  --exclude 'e2e/target-app/app/build/' \
  --exclude 'e2e/draw-app/build/' \
  --exclude 'e2e/draw-app/.gradle/' \
  --exclude 'e2e/draw-app/app/build/' \
  "$REPO_ROOT/" "$HOST:$REMOTE_DIR/"

log "invoking run-draw.sh on $HOST"
set +e
ssh "$HOST" "bash '$REMOTE_DIR/e2e/run-draw.sh'"
rc=$?
set -e
log "remote run-draw.sh exited rc=$rc"

# Pull artifacts back so they're inspectable locally.
LOCAL_ARTIFACTS="$REPO_ROOT/e2e/artifacts"
mkdir -p "$LOCAL_ARTIFACTS"
log "fetching artifacts -> $LOCAL_ARTIFACTS"
rsync -az "$HOST:$REMOTE_DIR/e2e/artifacts/" "$LOCAL_ARTIFACTS/" 2>/dev/null || true

if [ "$rc" -eq 0 ]; then
  log "SUCCESS (remote DRAWING e2e green)"
else
  log "FAILURE (remote rc=$rc) — see $LOCAL_ARTIFACTS"
fi
exit "$rc"
