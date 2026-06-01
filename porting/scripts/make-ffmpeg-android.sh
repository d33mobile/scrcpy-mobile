#!/bin/bash
#
# make-ffmpeg-android.sh — cross-compile a LEAN FFmpeg for Android using the NDK.
#
# Android counterpart of scripts/make-ffmpeg.sh. The iOS script is NEVER touched:
# this driver retargets the SAME FFmpeg version (release/6.0) to the Android NDK
# clang toolchain resolved by scripts/android-defines.sh.
#
# What it produces (per ABI, default x86_64):
#   output/android/$TARGET_ABI/lib*.a   static libs (mirrors the iOS .a layout)
#   output/android/$TARGET_ABI/include  FFmpeg public headers
#
# Build goals: software H.264 decode + demux for scrcpy. No VideoToolbox, no
# MediaCodec (software decode per M1 task). We enable the video codecs scrcpy can
# negotiate (h264/hevc/av1) plus the audio codecs (aac/opus/flac/raw) it supports,
# their parsers + raw demuxers, swscale + swresample (the iOS build links both),
# and the file/pipe protocols.
#
# Knobs (env):
#   TARGET_ABI   x86_64 (default) | arm64-v8a   — forwarded to android-defines.sh
#   ANDROID_API  default 26
#   OUTPUT       optional override; default = output/android/$TARGET_ABI
#   FFMPEG_REF   FFmpeg git ref (default release/6.0, matches make-ffmpeg.sh)
#   JOBS         parallel make jobs (default: nproc)
#
# x86 asm: requires nasm. If nasm is missing we fall back to --disable-x86asm
# (slower decode but still correct), printing a warning. Install nasm for speed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve the Android NDK toolchain (exports ANDROID_CC, ANDROID_AR, ...) -------
# android-defines.sh probes optional env vars ($ANDROID_NDK_ROOT etc.) that may be
# unset, so relax `nounset` only while sourcing it.
# shellcheck source=/dev/null
set +u
. "$SCRIPT_DIR/android-defines.sh" >/dev/null
set -u

FFMPEG_REF="${FFMPEG_REF:-release/6.0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Output dir: honour caller's OUTPUT, else the android-defines default.
OUTPUT="${OUTPUT:-$ANDROID_OUTPUT}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# Build scratch (cached source so re-runs are fast).
BUILD_DIR="$SOURCE_ROOT/porting/build/ffmpeg-android"
SRC_DIR="$BUILD_DIR/ffmpeg-source"
WORK_DIR="$BUILD_DIR/$TARGET_ABI"
mkdir -p "$BUILD_DIR"

echo "=================================================================="
echo " FFmpeg (Android) cross-compile"
echo "   FFmpeg ref:   $FFMPEG_REF"
echo "   TARGET_ABI:   $TARGET_ABI"
echo "   Android API:  $ANDROID_API"
echo "   CC:           $ANDROID_CC"
echo "   Sysroot:      $ANDROID_SYSROOT"
echo "   Output:       $OUTPUT"
echo "   Jobs:         $JOBS"
echo "=================================================================="

# --- Fetch source (cached) --------------------------------------------------------
if [[ ! -d "$SRC_DIR/.git" ]]; then
	echo "[ffmpeg-android] cloning FFmpeg $FFMPEG_REF ..."
	rm -rf "$SRC_DIR"
	git clone --depth 1 --branch "$FFMPEG_REF" https://github.com/FFmpeg/FFmpeg.git "$SRC_DIR"
else
	echo "[ffmpeg-android] reusing cached source at $SRC_DIR"
fi

# --- FFmpeg arch name (configure wants the bare arch, not the ABI string) ----------
case "$TARGET_ABI" in
	x86_64)    FF_ARCH="x86_64";  FF_CPU="" ;;
	arm64-v8a) FF_ARCH="aarch64"; FF_CPU="" ;;
	*) echo "** unsupported TARGET_ABI=$TARGET_ABI" >&2; exit 1 ;;
esac

# --- x86 asm: prefer nasm, otherwise disable (documented fallback) -----------------
X86ASM_FLAG=""
if [[ "$FF_ARCH" == "x86_64" ]]; then
	if command -v nasm >/dev/null 2>&1; then
		X86ASM_FLAG="--x86asmexe=$(command -v nasm)"
		echo "[ffmpeg-android] using nasm for x86 asm: $(command -v nasm)"
	elif command -v yasm >/dev/null 2>&1; then
		X86ASM_FLAG="--x86asmexe=$(command -v yasm)"
		echo "[ffmpeg-android] using yasm for x86 asm: $(command -v yasm)"
	else
		echo "[ffmpeg-android] WARNING: no nasm/yasm found -> --disable-x86asm (slower)."
		X86ASM_FLAG="--disable-x86asm"
	fi
fi

# --- Fresh per-ABI build tree from the cached source -------------------------------
echo "[ffmpeg-android] preparing build tree $WORK_DIR ..."
rm -rf "$WORK_DIR"
cp -a "$SRC_DIR" "$WORK_DIR"
cd "$WORK_DIR"

PREFIX="$WORK_DIR/_install"

# Toolchain binaries from android-defines.sh.
CROSS_PREFIX="$ANDROID_TOOLCHAIN/bin/llvm-"

# --- Configure: lean build for scrcpy's software decode + demux --------------------
# Start from a clean slate (--disable-everything) and add back exactly what scrcpy
# needs. Video: h264 (primary, software decode per task) + hevc + av1 (scrcpy can
# negotiate these). Audio: aac/opus/flac/raw (scrcpy audio forwarding). Plus the
# matching parsers + raw demuxers, swscale + swresample, file/pipe protocols.
./configure \
	--prefix="$PREFIX" \
	--target-os=android \
	--arch="$FF_ARCH" \
	--enable-cross-compile \
	--cross-prefix="$CROSS_PREFIX" \
	--cc="$ANDROID_CC" \
	--cxx="$ANDROID_CXX" \
	--ar="$ANDROID_AR" \
	--ranlib="$ANDROID_RANLIB" \
	--strip="$ANDROID_STRIP" \
	--nm="$ANDROID_TOOLCHAIN/bin/llvm-nm" \
	--sysroot="$ANDROID_SYSROOT" \
	--extra-cflags="-fPIC -O2 -DANDROID -D__ANDROID_API__=$ANDROID_API" \
	--extra-ldflags="" \
	--pkg-config=pkg-config \
	$X86ASM_FLAG \
	--enable-pic \
	--enable-static \
	--disable-shared \
	--disable-programs \
	--disable-doc \
	--disable-debug \
	--disable-symver \
	--disable-audiotoolbox \
	--disable-videotoolbox \
	--disable-mediacodec \
	--disable-jni \
	--disable-vulkan \
	--disable-sdl2 \
	--disable-network \
	--disable-everything \
	--enable-avcodec \
	--enable-avformat \
	--enable-avutil \
	--enable-swscale \
	--enable-swresample \
	--enable-decoder=h264 \
	--enable-decoder=hevc \
	--enable-decoder=av1 \
	--enable-decoder=aac \
	--enable-decoder=opus \
	--enable-decoder=flac \
	--enable-decoder=pcm_s16le \
	--enable-parser=h264 \
	--enable-parser=hevc \
	--enable-parser=av1 \
	--enable-parser=aac \
	--enable-parser=opus \
	--enable-parser=flac \
	--enable-demuxer=h264 \
	--enable-demuxer=hevc \
	--enable-demuxer=av1 \
	--enable-demuxer=aac \
	--enable-demuxer=ogg \
	--enable-demuxer=flac \
	--enable-demuxer=pcm_s16le \
	--enable-demuxer=matroska \
	--enable-demuxer=mov \
	--enable-demuxer=mpegts \
	--enable-protocol=file \
	--enable-protocol=pipe

echo "[ffmpeg-android] configure OK; building (-j$JOBS) ..."
make -j"$JOBS"
make install

# --- Stage outputs in the iOS-compatible layout -----------------------------------
# iOS build copies lib*.a flat into OUTPUT and an include/ dir alongside. Mirror it.
echo "[ffmpeg-android] staging libs + headers into $OUTPUT ..."
find "$PREFIX/lib" -maxdepth 1 -name '*.a' -exec cp -v {} "$OUTPUT/" \;
rm -rf "$OUTPUT/include"
cp -a "$PREFIX/include" "$OUTPUT/include"

echo "=================================================================="
echo "[ffmpeg-android] DONE. Libraries in: $OUTPUT"
ls -lh "$OUTPUT"/*.a
echo "=================================================================="
