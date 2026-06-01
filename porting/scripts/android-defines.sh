# Android NDK build defines — sourced by android-* build scripts and Makefile.android.
#
# This file is the Android counterpart of scripts/defines.sh. It NEVER touches the
# iOS build: the iOS scripts are unchanged and this file is only used by the
# `android-*` Makefile targets / android-make-*.sh drivers.
#
# Inputs (env, all optional):
#   TARGET_ABI    Android ABI to build (default: x86_64). Supported: x86_64, arm64-v8a.
#   ANDROID_API   Android API level / minSdk for the native toolchain (default: 26).
#   ANDROID_NDK_ROOT / ANDROID_SDK_ROOT
#                 Used to locate the NDK. We pin NDK 27.2.12479018 (matches the
#                 scrcpy-e2e:dev image). Resolution order:
#                   1. $ANDROID_NDK_ROOT if it exists
#                   2. $ANDROID_SDK_ROOT/ndk/27.2.12479018
#                   3. $ANDROID_HOME/ndk/27.2.12479018
#
# Outputs (exported for callers):
#   ANDROID_NDK_ROOT_RESOLVED, ANDROID_NDK_VERSION, TARGET_ABI, ANDROID_API,
#   ANDROID_TRIPLE, ANDROID_LLVM_TRIPLE, ANDROID_TOOLCHAIN, ANDROID_SYSROOT,
#   ANDROID_CC, ANDROID_CXX, ANDROID_AR, ANDROID_RANLIB, ANDROID_STRIP,
#   ANDROID_OUTPUT (output/android/$TARGET_ABI), ANDROID_CMAKE_TOOLCHAIN_FILE.

# --- Pinned NDK version (must match scrcpy-e2e:dev) -------------------------------
ANDROID_NDK_VERSION="27.2.12479018"

# --- ABI / API selection ---------------------------------------------------------
TARGET_ABI="${TARGET_ABI:-x86_64}"
ANDROID_API="${ANDROID_API:-26}"

# --- Locate the NDK --------------------------------------------------------------
_andef_find_ndk() {
	if [[ -n "$ANDROID_NDK_ROOT" && -d "$ANDROID_NDK_ROOT" ]]; then
		echo "$ANDROID_NDK_ROOT"; return 0
	fi
	if [[ -n "$ANDROID_SDK_ROOT" && -d "$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION" ]]; then
		echo "$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"; return 0
	fi
	if [[ -n "$ANDROID_HOME" && -d "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION" ]]; then
		echo "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"; return 0
	fi
	return 1
}

ANDROID_NDK_ROOT_RESOLVED="$(_andef_find_ndk)" || {
	echo "** ERROR: Android NDK $ANDROID_NDK_VERSION not found." >&2
	echo "          Set ANDROID_NDK_ROOT, or ANDROID_SDK_ROOT/ANDROID_HOME with ndk/$ANDROID_NDK_VERSION." >&2
	exit 1
}

# --- Map ABI -> toolchain triples ------------------------------------------------
# ANDROID_TRIPLE      = binutils-style triple (ar/ranlib/strip live here as llvm-*).
# ANDROID_LLVM_TRIPLE = clang target prefix (includes the API level).
case "$TARGET_ABI" in
	x86_64)
		ANDROID_TRIPLE="x86_64-linux-android"
		ANDROID_LLVM_TRIPLE="x86_64-linux-android${ANDROID_API}"
		;;
	arm64-v8a)
		ANDROID_TRIPLE="aarch64-linux-android"
		ANDROID_LLVM_TRIPLE="aarch64-linux-android${ANDROID_API}"
		;;
	*)
		echo "** ERROR: unsupported TARGET_ABI='$TARGET_ABI' (expected x86_64 or arm64-v8a)." >&2
		exit 1
		;;
esac

# --- Toolchain paths (NDK r23+ unified llvm prebuilt toolchain) ------------------
# Host tag is linux-x86_64 inside scrcpy-e2e:dev.
ANDROID_HOST_TAG="${ANDROID_HOST_TAG:-linux-x86_64}"
ANDROID_TOOLCHAIN="$ANDROID_NDK_ROOT_RESOLVED/toolchains/llvm/prebuilt/$ANDROID_HOST_TAG"
ANDROID_SYSROOT="$ANDROID_TOOLCHAIN/sysroot"

ANDROID_CC="$ANDROID_TOOLCHAIN/bin/${ANDROID_LLVM_TRIPLE}-clang"
ANDROID_CXX="$ANDROID_TOOLCHAIN/bin/${ANDROID_LLVM_TRIPLE}-clang++"
ANDROID_AR="$ANDROID_TOOLCHAIN/bin/llvm-ar"
ANDROID_RANLIB="$ANDROID_TOOLCHAIN/bin/llvm-ranlib"
ANDROID_STRIP="$ANDROID_TOOLCHAIN/bin/llvm-strip"

# CMake toolchain shipped inside the NDK (used by future cmake-based targets).
ANDROID_CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT_RESOLVED/build/cmake/android.toolchain.cmake"

# --- Output dir ------------------------------------------------------------------
# Sourced from porting/, so SOURCE_ROOT is the parent of this scripts/ dir's parent.
_ANDEF_PORTING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="$(cd "$_ANDEF_PORTING_ROOT/.." && pwd)"
ANDROID_OUTPUT="${ANDROID_OUTPUT:-$SOURCE_ROOT/output/android/$TARGET_ABI}"
[[ -d "$ANDROID_OUTPUT" ]] || mkdir -p "$ANDROID_OUTPUT"

export ANDROID_NDK_ROOT_RESOLVED ANDROID_NDK_VERSION TARGET_ABI ANDROID_API \
	ANDROID_TRIPLE ANDROID_LLVM_TRIPLE ANDROID_TOOLCHAIN ANDROID_SYSROOT \
	ANDROID_CC ANDROID_CXX ANDROID_AR ANDROID_RANLIB ANDROID_STRIP \
	ANDROID_OUTPUT ANDROID_CMAKE_TOOLCHAIN_FILE

# --- Summary ---------------------------------------------------------------------
echo " - NDK:            $ANDROID_NDK_ROOT_RESOLVED (pinned $ANDROID_NDK_VERSION)";
echo " - Target ABI:     $TARGET_ABI";
echo " - Android API:    $ANDROID_API";
echo " - Clang triple:   $ANDROID_LLVM_TRIPLE";
echo " - Toolchain:      $ANDROID_TOOLCHAIN";
echo " - Sysroot:        $ANDROID_SYSROOT";
echo " - CC:             $ANDROID_CC";
echo " - Output:         $ANDROID_OUTPUT";
