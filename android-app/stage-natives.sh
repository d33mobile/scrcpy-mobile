#!/usr/bin/env bash
#
# stage-natives.sh — copy the prebuilt native shared libraries into the Gradle
# app module's jniLibs staging dir so assembleDebug packages them into the APK.
#
# The .so are build artifacts (produced by porting/Makefile.android, gitignored)
# and are NOT committed. This script must be run BEFORE ./gradlew assembleDebug
# (the e2e/CI path invokes it first).
#
# Usage:
#   ./stage-natives.sh [OUTPUT_DIR] [ABI]
#
#   OUTPUT_DIR  dir containing the built libs (default: ../output/android/<ABI>)
#   ABI         target ABI (default: x86_64)
#
# Examples:
#   ./stage-natives.sh                              # ../output/android/x86_64
#   ./stage-natives.sh /workspace/output/android/x86_64
#   ./stage-natives.sh /workspace/output/android/arm64-v8a arm64-v8a
#
set -euo pipefail

ABI="${2:-x86_64}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-$HERE/../output/android/$ABI}"
DEST="$HERE/app/src/main/jniLibs/$ABI"

LIBS=(libscrcpy.so libSDL2.so libc++_shared.so)

echo "[stage-natives] ABI=$ABI"
echo "[stage-natives] source=$OUTPUT_DIR"
echo "[stage-natives] dest=$DEST"

missing=0
for lib in "${LIBS[@]}"; do
    if [[ ! -f "$OUTPUT_DIR/$lib" ]]; then
        echo "[stage-natives] ERROR: missing $OUTPUT_DIR/$lib" >&2
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    echo "[stage-natives] build the native stack first (make android-libs / android-scrcpy)." >&2
    exit 1
fi

mkdir -p "$DEST"
for lib in "${LIBS[@]}"; do
    cp -v "$OUTPUT_DIR/$lib" "$DEST/$lib"
done

echo "[stage-natives] DONE: staged ${#LIBS[@]} libs into $DEST"

# --- scrcpy-server asset ---------------------------------------------------
# scrcpy locates the server to push to the target via SCRCPY_SERVER_PATH (see
# server.c get_server_path). The app ships the server (v3.3.4, matching the
# client) as an APK asset, copies it to filesDir at runtime, and sets the env.
# The server binary is a build artifact — staged here from the existing
# scrcpy-app/ADBClient/scrcpy-server, NOT committed under android-app (the
# assets dir is gitignored).
SERVER_SRC="${SCRCPY_SERVER_SRC:-$HERE/../scrcpy-app/ADBClient/scrcpy-server}"
ASSET_DIR="$HERE/app/src/main/assets"
if [[ -f "$SERVER_SRC" ]]; then
    mkdir -p "$ASSET_DIR"
    cp -v "$SERVER_SRC" "$ASSET_DIR/scrcpy-server"
    echo "[stage-natives] DONE: staged scrcpy-server asset into $ASSET_DIR"
else
    echo "[stage-natives] ERROR: missing scrcpy-server at $SERVER_SRC" >&2
    exit 1
fi
