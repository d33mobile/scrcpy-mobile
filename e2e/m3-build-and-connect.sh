#!/usr/bin/env bash
# m3-build-and-connect.sh — INNER driver for M3 task 3, run inside scrcpy-e2e:dev
# (with /dev/kvm), repo mounted at /workspace.
#
#   1. apt-install build tools missing from the image.
#   2. Build the full native stack: make -C porting android-libs (clones ffmpeg/
#      SDL/openssl/adb sources, cross-compiles, links libscrcpy.so with our JNI
#      bridge changes).
#   3. Hand off to e2e/m3-connect.sh (builds APK incl. scrcpy-server asset, boots
#      both emulators, drives Connect, asserts Connected + server on B).
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/android-sdk/ndk/27.2.12479018}"
TARGET_ABI="${TARGET_ABI:-x86_64}"

log() { printf '%s [m3-bnc] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

mkdir -p "$ARTIFACTS"

log "installing build tools (make/meson/nasm/rsync/socat/pkg-config)"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq make meson nasm rsync socat pkg-config golang-go >/dev/null 2>&1 || true

# Put SDK cmake/ninja on PATH (the deps scripts also fall back to this).
SDK_CMAKE_DIR="$(ls -d /opt/android-sdk/cmake/*/bin 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$SDK_CMAKE_DIR" ] && export PATH="$SDK_CMAKE_DIR:$PATH"
log "cmake=$(command -v cmake || echo none) ninja=$(command -v ninja || echo none)"

OUT="$WORKSPACE/output/android/$TARGET_ABI"
if [ -f "$OUT/libscrcpy.so" ] && [ "${FORCE_NATIVE_REBUILD:-0}" != "1" ]; then
  log "libscrcpy.so already present at $OUT — skipping native build (set FORCE_NATIVE_REBUILD=1 to force)"
else
  log "building full native stack: make -C porting android-libs (ABI=$TARGET_ABI) — this is LONG"
  ( cd "$WORKSPACE/porting" && \
    ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT" TARGET_ABI="$TARGET_ABI" \
    make android-libs ) 2>&1 | tee "$ARTIFACTS/native-build.log"
  [ -f "$OUT/libscrcpy.so" ] || { log "FAILURE: libscrcpy.so not produced"; exit 1; }
  log "native build OK: $(ls -la "$OUT/libscrcpy.so")"
fi

log "handing off to m3-connect.sh"
exec bash "$WORKSPACE/e2e/m3-connect.sh"
