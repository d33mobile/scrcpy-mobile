#!/usr/bin/env bash
#
# make-scrcpy-android.sh — cross-compile libscrcpy.so for Android via the NDK.
#
# Android counterpart of porting/scripts/make-scrcpy.sh (the iOS Xcode/cmake
# build). Mirrors the iOS porting/cmake source list but targets the NDK and
# links the prebuilt android deps under output/android/<abi>/. The iOS build is
# untouched.
#
# Inputs (env, all optional — defaults via android-defines.sh):
#   TARGET_ABI   android ABI (default x86_64)
#   ANDROID_API  android API level (default 26)
#   OUTPUT       output dir (default output/android/<abi>)  [from Makefile.android]
#
# Output: output/android/<abi>/libscrcpy.so
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTING_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="$(cd "$PORTING_ROOT/.." && pwd)"

# Resolve the NDK toolchain (exports ANDROID_*; honours TARGET_ABI/ANDROID_API).
# shellcheck source=android-defines.sh
. "$SCRIPT_DIR/android-defines.sh"

DEPS_DIR="${OUTPUT:-$ANDROID_OUTPUT}"
BUILD_DIR="$PORTING_ROOT/build/scrcpy-android/$TARGET_ABI"

echo "==> libscrcpy android build"
echo "    ABI=$TARGET_ABI API=$ANDROID_API"
echo "    deps=$DEPS_DIR"
echo "    build=$BUILD_DIR"

# Sanity: the prebuilt deps must already be in place (tasks 2-5).
for lib in libavcodec.a libavformat.a libavutil.a libswscale.a libswresample.a \
           libssl.a libcrypto.a libadb-full.a libSDL2.so; do
    if [[ ! -f "$DEPS_DIR/$lib" ]]; then
        echo "** ERROR: missing prebuilt dep $DEPS_DIR/$lib — run android-{ffmpeg,libsdl,openssl,adb-mobile} first." >&2
        exit 1
    fi
done

# Locate cmake + ninja. The image's Android-SDK cmake (3.22.1) is not on PATH;
# fall back to it (same trick as make-libsdl-android.sh / make-adb-mobile-android.sh).
if ! command -v cmake >/dev/null 2>&1; then
    _sdk_cmake_dir="$(ls -d "${ANDROID_SDK_ROOT:-$ANDROID_HOME}"/cmake/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "$_sdk_cmake_dir" && -x "$_sdk_cmake_dir/cmake" ]]; then
        export PATH="$_sdk_cmake_dir:$PATH"
        echo "    using SDK cmake at $_sdk_cmake_dir"
    fi
fi
command -v cmake >/dev/null 2>&1 || { echo "** ERROR: cmake not found" >&2; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# cmake -S expects a CMakeLists.txt; our file is scrcpy-android-CMakeLists.txt.
# Stage a tiny source dir that just includes it (keeps the repo file uniquely
# named so it cannot collide with scrcpy's own CMakeLists / the iOS one).
SRC_STAGE="$BUILD_DIR/cmake-src"
mkdir -p "$SRC_STAGE"
cp "$SCRIPT_DIR/scrcpy-android-CMakeLists.txt" "$SRC_STAGE/CMakeLists.txt"

cmake -S "$SRC_STAGE" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$TARGET_ABI" \
    -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release \
    -DSCRCPY_MOBILE_ROOT="$SOURCE_ROOT" \
    -DANDROID_DEPS_DIR="$DEPS_DIR" \
    -Wno-dev

cmake --build "$BUILD_DIR" --target scrcpy -j"$(nproc)"

# Install the .so next to the deps.
SO="$(find "$BUILD_DIR" -name 'libscrcpy.so' -print -quit)"
if [[ -z "$SO" ]]; then
    echo "** ERROR: libscrcpy.so not produced" >&2
    exit 1
fi
cp -v "$SO" "$DEPS_DIR/libscrcpy.so"

# Stage the NDK's libc++_shared.so next to it (ANDROID_STL=c++_shared makes
# libscrcpy.so NEEDED it at runtime; the M2 app must also bundle it in the APK).
LIBCXX="$ANDROID_SYSROOT/usr/lib/${ANDROID_TRIPLE}/libc++_shared.so"
if [[ -f "$LIBCXX" ]]; then
    cp -v "$LIBCXX" "$DEPS_DIR/libc++_shared.so"
else
    echo "** WARNING: libc++_shared.so not found at $LIBCXX" >&2
fi

echo "==> DONE: $DEPS_DIR/libscrcpy.so"
ls -l "$DEPS_DIR/libscrcpy.so"
