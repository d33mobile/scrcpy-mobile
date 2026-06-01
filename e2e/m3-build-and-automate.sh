#!/usr/bin/env bash
# m3-build-and-automate.sh — INNER driver for M3 task 4, run inside scrcpy-e2e:dev
# (with /dev/kvm), repo mounted at /workspace.
#
#   1. apt-install build tools missing from the image.
#   2. Build the native stack if libscrcpy.so is absent (reuses the cached build).
#   3. Hand off to e2e/m3-automation.sh (builds both APKs, boots both emulators,
#      connects A->B, taps A's remote surface, asserts B received each tap at the
#      expected coordinate).
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/android-sdk/ndk/27.2.12479018}"
TARGET_ABI="${TARGET_ABI:-x86_64}"

log() { printf '%s [m3-bna] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

mkdir -p "$ARTIFACTS"

log "installing build tools (make/meson/nasm/rsync/socat/pkg-config/golang)"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq make meson nasm rsync socat pkg-config golang-go >/dev/null 2>&1 || true

SDK_CMAKE_DIR="$(ls -d /opt/android-sdk/cmake/*/bin 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$SDK_CMAKE_DIR" ] && export PATH="$SDK_CMAKE_DIR:$PATH"
log "cmake=$(command -v cmake || echo none) ninja=$(command -v ninja || echo none)"

OUT="$WORKSPACE/output/android/$TARGET_ABI"
if [ -f "$OUT/libscrcpy.so" ] && [ "${FORCE_NATIVE_REBUILD:-0}" != "1" ]; then
  log "libscrcpy.so present at $OUT — skipping native build (FORCE_NATIVE_REBUILD=1 to force)"
else
  log "building native stack: make -C porting android-libs (ABI=$TARGET_ABI) — LONG"
  ( cd "$WORKSPACE/porting" && \
    ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT" TARGET_ABI="$TARGET_ABI" \
    make android-libs ) 2>&1 | tee "$ARTIFACTS/native-build.log"
  [ -f "$OUT/libscrcpy.so" ] || { log "FAILURE: libscrcpy.so not produced"; exit 1; }
fi
log "native lib: $(ls -la "$OUT/libscrcpy.so")"

log "handing off to m3-automation.sh"
exec bash "$WORKSPACE/e2e/m3-automation.sh"
