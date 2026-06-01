#!/bin/bash
#
# make-libsdl-android.sh — cross-compile SDL2 for Android using the NDK.
#
# Android counterpart of scripts/make-libsdl.sh. The iOS script is NEVER touched:
# this driver retargets the SAME SDL2 version (2.32.8 — must match make-libsdl.sh)
# to the Android NDK clang toolchain resolved by scripts/android-defines.sh.
#
# On Android, SDL2 is a SHARED library `libSDL2.so` loaded at runtime by SDL's
# Java glue (org.libsdl.app.SDLActivity). This task builds the NATIVE
# `libSDL2.so` using SDL2's own CMake build with the NDK android.toolchain.cmake
# (Android backend — NOT the iOS UIKit path). The Java glue is vendored for M2.
#
# What it produces (per ABI, default x86_64):
#   output/android/$TARGET_ABI/libSDL2.so   Android shared lib (the Android norm)
#   output/android/$TARGET_ABI/include/SDL2 SDL2 public headers (iOS-compatible
#                                           layout: libscrcpy #include <SDL.h>)
#   porting/vendor/sdl-android-java/org/libsdl/app/*.java
#                                           SDL's Android Activity Java glue,
#                                           vendored from the SDL source tree so
#                                           M2 can wire it into the Android app.
#
# Knobs (env):
#   TARGET_ABI   x86_64 (default) | arm64-v8a   — forwarded to android-defines.sh
#   ANDROID_API  default 26
#   OUTPUT       optional override; default = output/android/$TARGET_ABI
#   SDL_VERSION  SDL2 release (default 2.32.8, matches make-libsdl.sh)
#   JOBS         parallel build jobs (default: nproc)
#
# Build tool: SDL2's CMake build driven through the NDK toolchain file. Uses the
# Ninja generator if available, else Unix Makefiles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve the Android NDK toolchain (exports ANDROID_*, TARGET_ABI, ...) --------
# android-defines.sh probes optional env vars that may be unset; relax nounset
# only while sourcing it (same pattern as make-ffmpeg-android.sh).
# shellcheck source=/dev/null
set +u
. "$SCRIPT_DIR/android-defines.sh" >/dev/null
set -u

SDL_VERSION="${SDL_VERSION:-2.32.8}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# --- Locate cmake (+ bundled ninja) ----------------------------------------------
# scrcpy-e2e:dev ships the Android SDK cmake (3.22.1) under
# $ANDROID_SDK_ROOT/cmake/<ver>/bin but does NOT put it on PATH. Prepend the
# newest SDK cmake dir so both `cmake` and the ninja it bundles are usable. A
# system cmake on PATH (if any) still wins because we only PREPEND when absent.
if ! command -v cmake >/dev/null 2>&1; then
	_sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
	if [[ -n "$_sdk_root" && -d "$_sdk_root/cmake" ]]; then
		_sdk_cmake_bin="$(find "$_sdk_root/cmake" -maxdepth 3 -name cmake -type f 2>/dev/null \
			| sort -V | tail -n1)"
		if [[ -n "$_sdk_cmake_bin" ]]; then
			PATH="$(dirname "$_sdk_cmake_bin"):$PATH"
			export PATH
			echo "[libsdl-android] using SDK cmake: $_sdk_cmake_bin"
		fi
	fi
fi
command -v cmake >/dev/null 2>&1 || {
	echo "** ERROR: cmake not found (not on PATH, none under \$ANDROID_SDK_ROOT/cmake)." >&2
	exit 1
}

# Output dir: honour caller's OUTPUT, else the android-defines default.
OUTPUT="${OUTPUT:-$ANDROID_OUTPUT}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# Build scratch (cached source so re-runs are fast).
BUILD_DIR="$SOURCE_ROOT/porting/build/libsdl-android"
SRC_DIR="$BUILD_DIR/SDL2-$SDL_VERSION"
WORK_DIR="$BUILD_DIR/$TARGET_ABI"
mkdir -p "$BUILD_DIR"

# Where the SDL Android Java glue is vendored for M2 (NOT under porting/libs,
# which .gitignore swallows — keep it tracked under porting/vendor).
JAVA_VENDOR_DIR="$SOURCE_ROOT/porting/vendor/sdl-android-java"

echo "=================================================================="
echo " SDL2 (Android) cross-compile"
echo "   SDL2 version: $SDL_VERSION"
echo "   TARGET_ABI:   $TARGET_ABI"
echo "   Android API:  $ANDROID_API"
echo "   NDK:          $ANDROID_NDK_ROOT_RESOLVED"
echo "   Toolchain:    $ANDROID_CMAKE_TOOLCHAIN_FILE"
echo "   Output:       $OUTPUT"
echo "   Jobs:         $JOBS"
echo "=================================================================="

# --- Fetch source (cached) --------------------------------------------------------
# HERMETICITY: prefer a pre-staged tarball baked into the build image (the e2e
# Docker image drops $NATIVE_SRC_DIR/SDL2-$SDL_VERSION.tar.gz at IMAGE-build time,
# when the network is available). Extracting from there lets a cold native rebuild
# run fully offline (`--network none`). The curl download is kept only as a fallback
# for dev outside the image, so behaviour is unchanged when no pre-staged tarball
# exists.
NATIVE_SRC_DIR="${NATIVE_SRC_DIR:-/opt/native-src}"
PRESTAGED_SDL_TARBALL="$NATIVE_SRC_DIR/SDL2-$SDL_VERSION.tar.gz"
if [[ ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
	echo "[libsdl-android] downloading SDL2-$SDL_VERSION ..."
	rm -rf "$SRC_DIR"
	TARBALL="$BUILD_DIR/SDL2-$SDL_VERSION.tar.gz"
	if [[ ! -f "$TARBALL" ]]; then
		if [[ -f "$PRESTAGED_SDL_TARBALL" ]]; then
			echo "[libsdl-android] using pre-staged tarball $PRESTAGED_SDL_TARBALL (offline)"
			cp "$PRESTAGED_SDL_TARBALL" "$TARBALL"
		else
			curl -fL -o "$TARBALL" "https://www.libsdl.org/release/SDL2-$SDL_VERSION.tar.gz"
		fi
	fi
	tar xzf "$TARBALL" -C "$BUILD_DIR"
else
	echo "[libsdl-android] reusing cached source at $SRC_DIR"
fi

# --- Pick a CMake generator -------------------------------------------------------
if command -v ninja >/dev/null 2>&1; then
	GENERATOR="Ninja"
	echo "[libsdl-android] using Ninja generator"
else
	GENERATOR="Unix Makefiles"
	echo "[libsdl-android] ninja not found -> Unix Makefiles generator"
fi

# --- Configure SDL2 via the NDK CMake toolchain (Android backend) -----------------
# SDL2's CMakeLists auto-selects the Android video/audio backends when the NDK
# toolchain file sets ANDROID. We build a SHARED libSDL2.so (the Android norm) and
# disable the static lib + tests. We do NOT build SDL2main here (the Android app
# provides the SDLActivity Java entry point in M2).
echo "[libsdl-android] preparing build tree $WORK_DIR ..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

PREFIX="$WORK_DIR/_install"

cmake -S "$SRC_DIR" -B "$WORK_DIR" -G "$GENERATOR" \
	-DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
	-DANDROID_ABI="$TARGET_ABI" \
	-DANDROID_PLATFORM="android-$ANDROID_API" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DSDL_SHARED=ON \
	-DSDL_STATIC=OFF \
	-DSDL_TEST=OFF \
	-DSDL_TESTS=OFF

echo "[libsdl-android] configure OK; building (-j$JOBS) ..."
cmake --build "$WORK_DIR" --parallel "$JOBS"
cmake --install "$WORK_DIR"

# --- Stage outputs ----------------------------------------------------------------
# libSDL2.so flat into OUTPUT (mirrors how the iOS build drops libSDL2.a flat) and
# headers into OUTPUT/include/SDL2 (matches make-libsdl.sh's include layout so
# libscrcpy can #include <SDL.h>).
echo "[libsdl-android] staging libSDL2.so + headers into $OUTPUT ..."
SO_PATH="$(find "$PREFIX" "$WORK_DIR" -name 'libSDL2.so' -type f 2>/dev/null | head -n1)"
if [[ -z "$SO_PATH" ]]; then
	echo "** ERROR: libSDL2.so not found after build." >&2
	exit 1
fi
cp -v "$SO_PATH" "$OUTPUT/libSDL2.so"

mkdir -p "$OUTPUT/include/SDL2"
# Prefer the installed headers (they include the generated SDL_config.h); fall
# back to the source include/ tree.
if [[ -d "$PREFIX/include/SDL2" ]]; then
	cp -v "$PREFIX"/include/SDL2/*.h "$OUTPUT/include/SDL2/"
else
	cp -v "$SRC_DIR"/include/*.h "$OUTPUT/include/SDL2/"
fi

# --- Vendor the SDL Android Java glue for M2 --------------------------------------
# SDL ships its Android Activity glue at android-project/app/src/main/java/org/
# libsdl/app/*.java. M2 imports these into the Android app to load libSDL2.so.
SDL_JAVA_SRC="$SRC_DIR/android-project/app/src/main/java/org/libsdl/app"
if [[ -d "$SDL_JAVA_SRC" ]]; then
	echo "[libsdl-android] vendoring SDL Android Java glue -> $JAVA_VENDOR_DIR ..."
	rm -rf "$JAVA_VENDOR_DIR/org"
	mkdir -p "$JAVA_VENDOR_DIR/org/libsdl/app"
	cp -v "$SDL_JAVA_SRC"/*.java "$JAVA_VENDOR_DIR/org/libsdl/app/"
	# Record provenance for M2.
	cat > "$JAVA_VENDOR_DIR/SOURCE.txt" <<EOF
SDL Android Activity Java glue, vendored for M2 (Android app wiring).

Source: SDL2-$SDL_VERSION
Path in tarball: android-project/app/src/main/java/org/libsdl/app/*.java
Vendored by: porting/scripts/make-libsdl-android.sh

These classes (SDLActivity, SDLSurface, SDLAudioManager, HIDDevice*, ...) are
the Java side of SDL2's Android backend. SDLActivity.loadLibraries() loads
libSDL2.so and the app's native lib at runtime. M2 imports this package into the
Android client app so the SDL Android backend can run.
EOF
else
	echo "[libsdl-android] WARNING: SDL Android Java glue not found at $SDL_JAVA_SRC" >&2
fi

echo "=================================================================="
echo "[libsdl-android] DONE. libSDL2.so in: $OUTPUT"
ls -lh "$OUTPUT/libSDL2.so"
echo "[libsdl-android] headers: $OUTPUT/include/SDL2 ($(ls "$OUTPUT/include/SDL2" | wc -l) files)"
echo "[libsdl-android] java glue: $JAVA_VENDOR_DIR/org/libsdl/app ($(ls "$JAVA_VENDOR_DIR/org/libsdl/app" 2>/dev/null | wc -l) files)"
echo "=================================================================="
