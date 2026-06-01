#!/bin/bash
# Cross-compile wsvn53/adb-mobile's libadb-full.a for Android via the NDK.
#
# APPROACH (b) from the M1 plan: drive adb-mobile's vendored sources through the NDK
# cmake toolchain (from android-defines.sh) instead of patching adb-mobile's own
# iOS/ios-cmake build. The iOS targets in external/adb-mobile are left untouched.
#
# We use a small standalone CMakeLists (adb-mobile-android-CMakeLists.txt, next to
# this script) that compiles exactly the static-lib target set the iOS make-adb.sh
# builds, against the same vendored Android sources + the porting/ client overrides,
# pulling boringssl in as a subdirectory. See that file's header for the rationale.
#
# Steps:
#   1. host protoc (28.3) built from the pinned external/protobuf source — needed to
#      generate adb's *.pb.{cc,h}. (apt protobuf-compiler is the wrong version.)
#   2. generate adb proto sources with host protoc.
#   3. cross-compile libprotobuf (Android) — the generated .pb.cc need it.
#   4. cmake-configure + build the standalone project through the NDK toolchain.
#   5. bundle every produced .a into output/android/$ABI/libadb-full.a and copy
#      adb_public.h into the android include dir.
#
# Inputs (env): TARGET_ABI (x86_64|arm64-v8a), ANDROID_API, OUTPUT (android out dir).
# Requires on the build host: cmake, ninja, make, go (boringssl codegen), a C/C++
# compiler for the host protoc. Install transiently in the build invocation.
# NOTE: no `set -u` — android-defines.sh probes optionally-unset env vars
# ($ANDROID_NDK_ROOT/$ANDROID_HOME) with [[ -n ... ]], which trips nounset.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTING_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PORTING_ROOT/.." && pwd)"

# adb-mobile's vendored AOSP libbase (unique_fd.h) hard-#if-gates the fdsan API on
# __ANDROID_API__ >= 29 (android_fdsan_* are weak but only DECLARED at API 29+). The
# adb host runs on the emulator (API 30), so floor this stack at API 29 regardless of
# the repo-wide default (26). The symbols are weak, so the resulting lib still loads
# on <29 too. This only affects the adb-mobile build, not ffmpeg/sdl/openssl.
ANDROID_API="${ANDROID_API_ADB:-29}"   # forced floor (ignores the inherited 26)
export ANDROID_API

# NDK toolchain plumbing (sets ANDROID_*, ANDROID_CMAKE_TOOLCHAIN_FILE, TARGET_ABI...)
. "$SCRIPT_DIR/android-defines.sh" >/dev/null

OUTPUT="${OUTPUT:-$ANDROID_OUTPUT}"
mkdir -p "$OUTPUT" "$OUTPUT/include"

ADB_MOBILE_ROOT="$REPO_ROOT/external/adb-mobile"
AT_ROOT="$ADB_MOBILE_ROOT/android-tools"
VENDOR="$AT_ROOT/vendor"
PORTING_ADB="$ADB_MOBILE_ROOT/porting/adb"
PROTOBUF_SRC="$ADB_MOBILE_ROOT/external/protobuf"

BUILD_ROOT="$PORTING_ROOT/build/adb-mobile-android/$TARGET_ABI"
mkdir -p "$BUILD_ROOT"

echo "==[adb-mobile-android] ABI=$TARGET_ABI API=$ANDROID_API"
echo "==[adb-mobile-android] adb-mobile root: $ADB_MOBILE_ROOT"

# Locate cmake/ninja. The image's Android-SDK cmake is not on PATH; add it (same
# trick as make-libsdl-android.sh).
if ! command -v cmake >/dev/null 2>&1; then
  for c in "$ANDROID_SDK_ROOT"/cmake/*/bin "$ANDROID_HOME"/cmake/*/bin; do
    [[ -d "$c" ]] && PATH="$c:$PATH"
  done
fi
export PATH
command -v cmake >/dev/null 2>&1 || { echo "** ERROR: cmake not found"; exit 1; }
command -v go    >/dev/null 2>&1 || { echo "** ERROR: go not found (boringssl needs it)"; exit 1; }
echo "==[adb-mobile-android] cmake: $(command -v cmake) ($(cmake --version | head -1))"
echo "==[adb-mobile-android] go:    $(command -v go) ($(go version))"

# --- overlay porting client files onto the vendor adb tree ----------------------
# The iOS make-adb.sh does exactly this: `cp porting/adb/client/* vendor/adb/client/`.
# It is REQUIRED so path-qualified includes (e.g. `#include "client/file_sync_client.h"`)
# resolve to the porting overrides (in-process server, extended do_sync_pull signature)
# instead of the upstream vendor headers. We reset the vendor adb tree first so re-runs
# start clean, then overlay + apply the two functional patches the porting layer needs.
echo "==[adb-mobile-android] overlaying vendor/adb/client ..."
# Overlay porting client overrides (skip the empty usb_*.cpp stubs — we have no libusb;
# the porting main.cpp disables usb, and libadb's usb_libusb.cpp is not in our sources).
# Idempotent: cp always restores the porting versions over whatever is there.
for f in "$PORTING_ADB"/client/*; do
  bn="$(basename "$f")"
  case "$bn" in usb_libusb.cpp|usb_osx.cpp) continue;; esac
  cp -a "$f" "$VENDOR/adb/client/$bn"
done

# The porting main.cpp amalgamates BOTH fdevent_poll.cpp and fdevent_epoll.cpp. On
# iOS that is fine (epoll is #if defined(__linux__)-guarded → excluded, poll wins).
# Android IS __linux__, so both compile → 'fdevent_interrupt' redefinition. Android
# has epoll, so exclude the poll backend here by guarding its include out on Linux.
# (Idempotent: the cp above re-laid main.cpp first, so we always re-edit a clean copy.)
sed -i 's@^#include "fdevent/fdevent_poll.cpp"@#if !defined(__linux__)\n#include "fdevent/fdevent_poll.cpp"\n#endif@' \
  "$VENDOR/adb/client/main.cpp"

# Apply the functional adb patches the porting build relies on (bionic-safe subset).
# Uses GNU `patch --forward` (idempotent, no git metadata required — the rsync'd tree
# on the build host has no .git):
#  0007 — guard the sysdeps `write` macro so it doesn't clobber std::ostream::write
#         (abseil str_format pulls <ostream> in).
#  0013 — disable fastdeploy: guards fastdeploy.h's proto include behind
#         ENABLE_FASTDEPLOY (which we never define) so ApkEntry.pb.h isn't required.
#         (The porting adb_install.cpp/commandline.cpp already #if-guard their bodies.)
command -v patch >/dev/null 2>&1 || { echo "** ERROR: GNU patch not found"; exit 1; }
for patch in 0007-adb-Fix-unknown-__xx_write-member-in-std-ostream \
             0013-adb-disable-fastdeploy-support; do
  pf="$AT_ROOT/patches/adb/${patch}.patch"
  [[ -f "$pf" ]] || { echo "** WARN: patch $pf missing"; continue; }
  # --forward: skip hunks already applied; -r /dev/null: don't write .rej files.
  if patch -p1 -d "$VENDOR/adb" --forward --no-backup-if-mismatch -r /dev/null < "$pf" \
       > "$BUILD_ROOT/patch-${patch}.log" 2>&1; then
    echo "  applied $patch"
  else
    if grep -q "previously applied\|Reversed (or previously applied)" "$BUILD_ROOT/patch-${patch}.log"; then
      echo "  (skip $patch — already applied)"
    else
      echo "** ERROR applying $patch:"; cat "$BUILD_ROOT/patch-${patch}.log"; exit 1
    fi
  fi
done

# --- generated headers adb.cpp pulls in (<build/version.h>, <platform_tools_version.h>)
# The upstream cmake does configure_file() into vendor/build/version.h and
# vendor/platform_tools_version.h. We reproduce that so $VENDOR is the include root.
mkdir -p "$VENDOR/build"
sed -e 's/@ANDROID_VENDOR@/android-tools/g' "$AT_ROOT/version.h.in" \
  > "$VENDOR/build/version.h"
sed -e 's/@ANDROID_VERSION@/35.0.2/g' "$AT_ROOT/platform_tools_version.h.in" \
  > "$VENDOR/platform_tools_version.h"

# ================================================================================
# 1. Host protoc (28.3) — built once, cached.
# ================================================================================
HOST_PROTOC_BUILD="$PORTING_ROOT/build/adb-mobile-android/host-protoc"
HOST_PROTOC="$HOST_PROTOC_BUILD/protoc"
if [[ ! -x "$HOST_PROTOC" ]]; then
  echo "==[adb-mobile-android] building host protoc (28.3) ..."
  mkdir -p "$HOST_PROTOC_BUILD"
  cmake -S "$PROTOBUF_SRC" -B "$HOST_PROTOC_BUILD/cmake" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=ON \
    -Dprotobuf_ABSL_PROVIDER=module \
    -Dprotobuf_BUILD_LIBUPB=OFF \
    -DABSL_PROPAGATE_CXX_STD=ON
  cmake --build "$HOST_PROTOC_BUILD/cmake" --target protoc --parallel "$(nproc)"
  # protoc is built as protoc-<ver> with a `protoc` symlink; -L follows links.
  src_protoc="$(find -L "$HOST_PROTOC_BUILD/cmake" -name 'protoc-*' -type f -executable | head -1)"
  [[ -n "$src_protoc" ]] || src_protoc="$(find -L "$HOST_PROTOC_BUILD/cmake" -name protoc -type f | head -1)"
  cp -v "$src_protoc" "$HOST_PROTOC"
fi
echo "==[adb-mobile-android] host protoc: $("$HOST_PROTOC" --version)"

# ================================================================================
# 2. Generate adb proto sources with host protoc.
# ================================================================================
PROTO_GEN="$BUILD_ROOT/proto-gen"
mkdir -p "$PROTO_GEN"
ADB_PROTO_DIR="$VENDOR/adb/proto"
ADB_PROTOS="app_processes adb_host key_type adb_known_hosts pairing"
ADB_PROTO_SRCS=""
for p in $ADB_PROTOS; do
  "$HOST_PROTOC" -I "$ADB_PROTO_DIR" --cpp_out="$PROTO_GEN" "$ADB_PROTO_DIR/$p.proto"
  ADB_PROTO_SRCS="$ADB_PROTO_SRCS;$PROTO_GEN/$p.pb.cc"
done
ADB_PROTO_SRCS="${ADB_PROTO_SRCS#;}"
echo "==[adb-mobile-android] generated proto sources in $PROTO_GEN"

# ================================================================================
# 3. Cross-compile libprotobuf (Android) — for the generated .pb.cc.
# ================================================================================
PB_BUILD="$BUILD_ROOT/protobuf-android"
PB_LIB="$PB_BUILD/libprotobuf.a"
if [[ ! -f "$PB_LIB" ]]; then
  echo "==[adb-mobile-android] cross-compiling libprotobuf (Android $TARGET_ABI) ..."
  cmake -S "$PROTOBUF_SRC" -B "$PB_BUILD/cmake" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$TARGET_ABI" \
    -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_LIBPROTOC=OFF \
    -Dprotobuf_ABSL_PROVIDER=module \
    -Dprotobuf_BUILD_LIBUPB=OFF \
    -DABSL_PROPAGATE_CXX_STD=ON
  cmake --build "$PB_BUILD/cmake" --target libprotobuf --parallel "$(nproc)"
  cp -v "$(find "$PB_BUILD/cmake" -name 'libprotobuf.a' | head -1)" "$PB_LIB"
fi
echo "==[adb-mobile-android] android libprotobuf: $PB_LIB"

# ================================================================================
# 3b. Cross-compile lz4 / zstd / brotli (Android) — adb's transport + incremental
#     server pull them in (compression). Static .a, bundled into libadb-full.a.
# ================================================================================
_cc_cmake() { # <name> <srcdir> <build-subdir> <extra-cmake-args...> <target> -> echoes .a paths
  :
}
COMPRESS_LIBS=()

# lz4 (contrib/cmake_unofficial)
LZ4_BUILD="$BUILD_ROOT/lz4-android"
if ! ls "$LZ4_BUILD"/*.a >/dev/null 2>&1; then
  echo "==[adb-mobile-android] cross-compiling lz4 (Android $TARGET_ABI) ..."
  cmake -S "$ADB_MOBILE_ROOT/external/lz4/contrib/cmake_unofficial" -B "$LZ4_BUILD/cmake" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$TARGET_ABI" -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF
  cmake --build "$LZ4_BUILD/cmake" --target lz4_static --parallel "$(nproc)"
  find "$LZ4_BUILD/cmake" -name 'liblz4.a' -exec cp -v {} "$LZ4_BUILD/" \;
fi
COMPRESS_LIBS+=("$(find "$LZ4_BUILD" -maxdepth 1 -name 'liblz4.a' | head -1)")

# zstd (build/cmake)
ZSTD_BUILD="$BUILD_ROOT/zstd-android"
if ! ls "$ZSTD_BUILD"/*.a >/dev/null 2>&1; then
  echo "==[adb-mobile-android] cross-compiling zstd (Android $TARGET_ABI) ..."
  cmake -S "$ADB_MOBILE_ROOT/external/zstd/build/cmake" -B "$ZSTD_BUILD/cmake" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$TARGET_ABI" -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release \
    -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF
  cmake --build "$ZSTD_BUILD/cmake" --target libzstd_static --parallel "$(nproc)"
  find "$ZSTD_BUILD/cmake" -name 'libzstd.a' -exec cp -v {} "$ZSTD_BUILD/" \;
fi
COMPRESS_LIBS+=("$(find "$ZSTD_BUILD" -maxdepth 1 -name 'libzstd.a' | head -1)")

# brotli (top-level CMakeLists). adb's transport links BrotliDecoder*/BrotliEncoder*.
# brotli's CMake emits both shared and static targets; depending on cache state the
# *.a may not materialise. To be robust we (1) try the static targets, then
# (2) fall back to archiving the compiled brotli .o objects directly (they are
# built -fPIC by the NDK toolchain), so the symbols always make it into the bundle.
BROTLI_BUILD="$BUILD_ROOT/brotli-android"
if ! ls "$BROTLI_BUILD"/*.a >/dev/null 2>&1; then
  echo "==[adb-mobile-android] cross-compiling brotli (Android $TARGET_ABI) ..."
  cmake -S "$ADB_MOBILE_ROOT/external/brotli" -B "$BROTLI_BUILD/cmake" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
    -DANDROID_ABI="$TARGET_ABI" -DANDROID_PLATFORM="android-$ANDROID_API" \
    -DCMAKE_BUILD_TYPE=Release -DBROTLI_BUNDLED_MODE=ON -DBUILD_SHARED_LIBS=OFF
  cmake --build "$BROTLI_BUILD/cmake" \
    --target brotlidec-static --target brotlienc-static --target brotlicommon-static \
    --parallel "$(nproc)" 2>/dev/null || \
  cmake --build "$BROTLI_BUILD/cmake" \
    --target brotlidec --target brotlienc --target brotlicommon --parallel "$(nproc)"
  find "$BROTLI_BUILD/cmake" -name 'libbrotli*.a' -exec cp -v {} "$BROTLI_BUILD/" \;
fi
# Fallback: if no brotli .a, archive its .o objects into one static lib.
if ! ls "$BROTLI_BUILD"/*.a >/dev/null 2>&1; then
  echo "==[adb-mobile-android] no brotli .a — archiving brotli objects directly ..."
  mapfile -t _BROBJ < <(find "$BROTLI_BUILD/cmake/CMakeFiles" -name '*.c.o' \
    \( -path '*brotlidec*' -o -path '*brotlienc*' -o -path '*brotlicommon*' \))
  if [[ ${#_BROBJ[@]} -gt 0 ]]; then
    "$ANDROID_AR" rcs "$BROTLI_BUILD/libbrotli-bundled.a" "${_BROBJ[@]}"
  fi
fi
while IFS= read -r a; do COMPRESS_LIBS+=("$a"); done < <(find "$BROTLI_BUILD" -maxdepth 1 -name 'libbrotli*.a')
echo "==[adb-mobile-android] compression libs: ${COMPRESS_LIBS[*]}"

# --- abseil + utf8_range: protobuf (and thus adb's *.pb.cc) depend on these.
# The android libprotobuf.a does NOT inline them, so collect the per-module
# libabsl_*.a / libutf8_*.a that protobuf's bundled abseil produced and fold them
# into the same archive — otherwise libadb-full.a leaves ~80 absl:: symbols
# undefined and any consumer .so fails to load.
ABSL_LIBS=()
while IFS= read -r a; do ABSL_LIBS+=("$a"); done < <(
  find "$BUILD_ROOT/protobuf-android" \( -name 'libabsl_*.a' -o -name 'libutf8_*.a' \) -type f)
echo "==[adb-mobile-android] abseil/utf8 libs: ${#ABSL_LIBS[@]} archives"

# ================================================================================
# 4. Configure + build the standalone adb static-lib project through the NDK.
# ================================================================================
ADB_BUILD="$BUILD_ROOT/cmake"
# The project file lives next to this script as adb-mobile-android-CMakeLists.txt;
# cmake wants a dir named CMakeLists.txt, so stage it into the build root.
rm -rf "$ADB_BUILD"; mkdir -p "$ADB_BUILD"
cp "$SCRIPT_DIR/adb-mobile-android-CMakeLists.txt" "$BUILD_ROOT/CMakeLists.txt"

cmake -S "$BUILD_ROOT" -B "$ADB_BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_CMAKE_TOOLCHAIN_FILE" \
  -DANDROID_ABI="$TARGET_ABI" \
  -DANDROID_PLATFORM="android-$ANDROID_API" \
  -DCMAKE_BUILD_TYPE=Release \
  -DADB_MOBILE_ROOT="$ADB_MOBILE_ROOT" \
  -DPROTOBUF_INCLUDE="$PROTOBUF_SRC/src" \
  -DADB_PROTO_GEN_DIR="$PROTO_GEN" \
  -DADB_PROTO_SRCS="$ADB_PROTO_SRCS"

cmake --build "$ADB_BUILD" --target adb --parallel "$(nproc)"

# ================================================================================
# 5. Bundle every produced .a (+ android libprotobuf) into libadb-full.a.
# ================================================================================
echo "==[adb-mobile-android] bundling libadb-full.a ..."
BUNDLE_DIR="$BUILD_ROOT/bundle"
rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"
ALL_A=()
while IFS= read -r a; do ALL_A+=("$a"); done < <(find "$ADB_BUILD" -name '*.a' -type f)
ALL_A+=("$PB_LIB")
for a in "${COMPRESS_LIBS[@]}"; do [[ -n "$a" && -f "$a" ]] && ALL_A+=("$a"); done
for a in "${ABSL_LIBS[@]}"; do [[ -n "$a" && -f "$a" ]] && ALL_A+=("$a"); done

# Merge with llvm-ar MRI script (thin-merge all members into one archive).
MRI="$BUNDLE_DIR/merge.mri"
{
  echo "create $OUTPUT/libadb-full.a"
  for a in "${ALL_A[@]}"; do echo "addlib $a"; done
  echo "save"
  echo "end"
} > "$MRI"
rm -f "$OUTPUT/libadb-full.a"
"$ANDROID_AR" -M < "$MRI"
"$ANDROID_RANLIB" "$OUTPUT/libadb-full.a"

# Strip debug info from the archive (built with -g; debug data would otherwise be
# ~10x the code size). Keeps all global/defined symbols needed for linking.
"$ANDROID_STRIP" --strip-debug "$OUTPUT/libadb-full.a" 2>/dev/null || true

cp -v "$PORTING_ADB/include/adb_public.h" "$OUTPUT/include/adb_public.h"

echo "==[adb-mobile-android] DONE -> $OUTPUT/libadb-full.a"
ls -la "$OUTPUT/libadb-full.a"
