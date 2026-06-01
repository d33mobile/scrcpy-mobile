#!/bin/bash
#
# make-openssl-android.sh — cross-compile OpenSSL for Android using the NDK.
#
# Android counterpart of the iOS `openssl` Makefile target (which drives
# external/OpenSSL-for-iPhone/build-libssl.sh). The iOS path is NEVER touched:
# this driver builds OpenSSL from upstream source with OpenSSL's first-class
# Android support, retargeted to the NDK clang toolchain resolved by
# scripts/android-defines.sh.
#
# VERSION CHOICE — 1.1.1w (matches the iOS build):
#   The iOS build links OpenSSL 1.1.1w (see porting/libs/include/openssl/
#   opensslv.h: "OpenSSL 1.1.1w  11 Sep 2023"). adb-mobile and libvncserver are
#   written against that ABI/API. We deliberately match the SAME major series
#   (1.1.1w) on Android so the consumers compile identically across platforms —
#   no 1.1.1-vs-3.x API divergence to chase. OpenSSL 1.1.1 has first-class
#   Android targets (`Configure android-x86_64`) and builds cleanly with the NDK
#   unified clang toolchain.
#
# What it produces (per ABI, default x86_64), mirroring the iOS .a layout:
#   output/android/$TARGET_ABI/libssl.a      static lib
#   output/android/$TARGET_ABI/libcrypto.a   static lib
#   output/android/$TARGET_ABI/include/openssl/*.h   public headers
#
# Knobs (env):
#   TARGET_ABI       x86_64 (default) | arm64-v8a   — forwarded to android-defines.sh
#   ANDROID_API      default 26
#   OUTPUT           optional override; default = output/android/$TARGET_ABI
#   OPENSSL_VERSION  default 1.1.1w (matches the iOS build)
#   JOBS             parallel make jobs (default: nproc)
#
# OpenSSL's Configure needs `perl` and `make` on PATH; the NDK clang must be
# reachable. OpenSSL's android-* targets read $ANDROID_NDK_ROOT and put the
# right `<triple><api>-clang` on the compiler line, so we export ANDROID_NDK_ROOT
# and prepend the NDK toolchain bin/ to PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve the Android NDK toolchain (exports ANDROID_*, TARGET_ABI, ...) --------
# android-defines.sh probes optional env vars that may be unset; relax nounset
# only while sourcing it (same pattern as make-ffmpeg-android.sh).
# shellcheck source=/dev/null
set +u
. "$SCRIPT_DIR/android-defines.sh" >/dev/null
set -u

OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Output dir: honour caller's OUTPUT, else the android-defines default.
OUTPUT="${OUTPUT:-$ANDROID_OUTPUT}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# Build scratch (cached tarball + source so re-runs are fast).
BUILD_DIR="$SOURCE_ROOT/porting/build/openssl-android"
SRC_DIR="$BUILD_DIR/openssl-$OPENSSL_VERSION"
WORK_DIR="$BUILD_DIR/$TARGET_ABI"
mkdir -p "$BUILD_DIR"

# --- Map ABI -> OpenSSL Configure target -----------------------------------------
case "$TARGET_ABI" in
	x86_64)    OSSL_TARGET="android-x86_64" ;;
	arm64-v8a) OSSL_TARGET="android-arm64"  ;;
	*) echo "** unsupported TARGET_ABI=$TARGET_ABI" >&2; exit 1 ;;
esac

echo "=================================================================="
echo " OpenSSL (Android) cross-compile"
echo "   OpenSSL ver:  $OPENSSL_VERSION"
echo "   TARGET_ABI:   $TARGET_ABI"
echo "   OSSL target:  $OSSL_TARGET"
echo "   Android API:  $ANDROID_API"
echo "   NDK:          $ANDROID_NDK_ROOT_RESOLVED"
echo "   Toolchain:    $ANDROID_TOOLCHAIN"
echo "   Output:       $OUTPUT"
echo "   Jobs:         $JOBS"
echo "=================================================================="

# --- Fetch source (cached) --------------------------------------------------------
# HERMETICITY: prefer a pre-staged tarball baked into the build image (the e2e
# Docker image drops $NATIVE_SRC_DIR/openssl-$OPENSSL_VERSION.tar.gz at IMAGE-build
# time, when the network is available). Extracting from there lets a cold native
# rebuild run fully offline (`--network none`). The curl download is kept only as a
# fallback for dev outside the image, so behaviour is unchanged when no pre-staged
# tarball exists.
NATIVE_SRC_DIR="${NATIVE_SRC_DIR:-/opt/native-src}"
PRESTAGED_OPENSSL_TARBALL="$NATIVE_SRC_DIR/openssl-$OPENSSL_VERSION.tar.gz"
if [[ ! -f "$SRC_DIR/Configure" ]]; then
	echo "[openssl-android] downloading openssl-$OPENSSL_VERSION ..."
	rm -rf "$SRC_DIR"
	TARBALL="$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz"
	if [[ ! -f "$TARBALL" ]]; then
		if [[ -f "$PRESTAGED_OPENSSL_TARBALL" ]]; then
			echo "[openssl-android] using pre-staged tarball $PRESTAGED_OPENSSL_TARBALL (offline)"
			cp "$PRESTAGED_OPENSSL_TARBALL" "$TARBALL"
		else
			# Primary: openssl.org "old" archive; fallback: GitHub release mirror.
			curl -fL -o "$TARBALL" \
				"https://www.openssl.org/source/old/1.1.1/openssl-$OPENSSL_VERSION.tar.gz" \
			|| curl -fL -o "$TARBALL" \
				"https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-$OPENSSL_VERSION.tar.gz"
		fi
	fi
	tar xzf "$TARBALL" -C "$BUILD_DIR"
else
	echo "[openssl-android] reusing cached source at $SRC_DIR"
fi

# --- Fresh per-ABI build tree from the cached source ------------------------------
echo "[openssl-android] preparing build tree $WORK_DIR ..."
rm -rf "$WORK_DIR"
cp -a "$SRC_DIR" "$WORK_DIR"
cd "$WORK_DIR"

PREFIX="$WORK_DIR/_install"

# --- Toolchain on PATH for OpenSSL's android-* Configure target -------------------
# OpenSSL's Configurations/15-android.conf builds the compiler name from the
# target triple + $ANDROID_API and expects the NDK clang on PATH. It reads
# ANDROID_NDK_ROOT (preferred) / ANDROID_NDK_HOME / NDK to locate the sysroot.
export ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT_RESOLVED"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT_RESOLVED"
export PATH="$ANDROID_TOOLCHAIN/bin:$PATH"

# --- Configure: STATIC libssl.a + libcrypto.a (mirror the iOS link list) ----------
# no-shared  -> static archives only (we link .a like the iOS build).
# no-tests   -> skip the test harness (faster; not cross-runnable anyway).
# no-asm could be added if assembling fails, but the NDK clang handles OpenSSL's
# x86_64 perlasm fine, so keep asm for speed.
echo "[openssl-android] configuring ($OSSL_TARGET, API $ANDROID_API) ..."
./Configure "$OSSL_TARGET" \
	-D__ANDROID_API__="$ANDROID_API" \
	--prefix="$PREFIX" \
	--openssldir="$PREFIX/ssl" \
	no-shared \
	no-tests \
	no-engine

echo "[openssl-android] building (-j$JOBS) ..."
# build_libs covers libcrypto.a + libssl.a without the apps/tests.
make -j"$JOBS" build_libs

# Install just the static libs + headers (skip docs/apps).
echo "[openssl-android] installing headers + libs into $PREFIX ..."
make install_dev

# --- Stage outputs in the iOS-compatible layout -----------------------------------
# iOS build drops libssl.a/libcrypto.a flat and the openssl/ headers under
# include/. Mirror it: flat .a in OUTPUT, headers in OUTPUT/include/openssl.
echo "[openssl-android] staging libs + headers into $OUTPUT ..."
for lib in libssl.a libcrypto.a; do
	src="$(find "$PREFIX" -name "$lib" -type f 2>/dev/null | head -n1)"
	if [[ -z "$src" ]]; then
		echo "** ERROR: $lib not found after build." >&2
		exit 1
	fi
	cp -v "$src" "$OUTPUT/$lib"
done

mkdir -p "$OUTPUT/include/openssl"
if [[ -d "$PREFIX/include/openssl" ]]; then
	cp -v "$PREFIX"/include/openssl/*.h "$OUTPUT/include/openssl/"
else
	echo "** ERROR: openssl headers not found under $PREFIX/include." >&2
	exit 1
fi

echo "=================================================================="
echo "[openssl-android] DONE. Libraries in: $OUTPUT"
ls -lh "$OUTPUT"/libssl.a "$OUTPUT"/libcrypto.a
echo "[openssl-android] headers: $OUTPUT/include/openssl ($(ls "$OUTPUT/include/openssl" | wc -l) files)"
echo "=================================================================="
