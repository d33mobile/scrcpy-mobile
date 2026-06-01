# Android NDK build (porting/)

Scaffolding for cross-compiling the native scrcpy stack (`libscrcpy.so` + its deps:
FFmpeg, SDL2, OpenSSL, adb-mobile) for **Android**, parallel to and independent of
the existing iOS build. The iOS targets in `porting/Makefile` are unchanged and
unaffected — nothing here is wired into the iOS `all`/`libs` path.

> Status: **scaffolding only.** The per-lib targets are stubs that print `TODO(M1)`
> and create their output dir. The toolchain plumbing itself is real and verified.

## Pins / defaults

| Setting        | Value                          | How to override            |
|----------------|--------------------------------|----------------------------|
| NDK version    | `27.2.12479018` (matches `scrcpy-e2e:dev`) | locate via env (see below) |
| Target ABI     | `x86_64` (emulator arch)       | `TARGET_ABI=arm64-v8a`     |
| Android API    | `26`                           | `ANDROID_API=24`           |
| Host tag       | `linux-x86_64`                 | `ANDROID_HOST_TAG=...`     |
| Output dir     | `output/android/$TARGET_ABI/`  | `ANDROID_OUTPUT=...`       |

Supported ABIs: `x86_64`, `arm64-v8a`.

API level **26** is chosen as the native `minSdk`: it matches the Android app's
`minSdk 26` (see `android-app/`), and 24/26 are the typical floors for modern NDK
builds. Override with `ANDROID_API` if a dependency needs a different floor.

## Locating the NDK

`scripts/android-defines.sh` resolves the NDK in this order (first hit wins):

1. `$ANDROID_NDK_ROOT` (if it is a directory)
2. `$ANDROID_SDK_ROOT/ndk/27.2.12479018`
3. `$ANDROID_HOME/ndk/27.2.12479018`

Inside `scrcpy-e2e:dev`, `$ANDROID_SDK_ROOT/ndk/27.2.12479018` resolves it.

## Toolchain

NDK r23+ unified LLVM toolchain at
`$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin`. The clang driver embeds the API
level in its name:

- CC  = `x86_64-linux-android26-clang`
- CXX = `x86_64-linux-android26-clang++`
- AR / RANLIB / STRIP = `llvm-ar` / `llvm-ranlib` / `llvm-strip`
- CMake toolchain file = `$NDK/build/cmake/android.toolchain.cmake`

(For `arm64-v8a`: `aarch64-linux-android26-clang`.)

## Invoking

```sh
# From repo root or porting/:
make -C porting android-toolchain-check     # resolve + compile a trivial ELF, prints TOOLCHAIN_OK
make -C porting android-libs                # run every stub target (creates output dir)
make -C porting android-ffmpeg              # one target
TARGET_ABI=arm64-v8a make -C porting android-libs

# Or source the defines directly:
. porting/scripts/android-defines.sh
"$ANDROID_CC" hello.c -o hello              # produces an Android x86_64 ELF
```

Available targets: `android-libs`, `android-ffmpeg`, `android-libsdl`,
`android-openssl`, `android-adb-mobile`, `android-scrcpy`,
`android-toolchain-check`.

## Verified

Inside `scrcpy-e2e:dev` on d-claude: sourcing `android-defines.sh` resolves
`x86_64-linux-android26-clang` and compiles+links a trivial C file into an
`ELF 64-bit LSB pie executable, x86-64 ... for GNU/Linux ... (Android)` binary
(`TOOLCHAIN_OK`). The iOS build path is byte-for-byte unchanged.
