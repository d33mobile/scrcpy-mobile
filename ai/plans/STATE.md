# LIVE STATE — read this every loop iteration

This file is the single source of truth for the 1-min foreground loop. It is
editable mid-loop without restarting. Master plan: `ai/plans/00-master-plan.md`.

## How each loop iteration works
1. Read this file + `ai/plans/00-master-plan.md`.
2. Pick the **first unchecked task** under "Current milestone".
3. Do it in a focused way; run/verify; commit (no `-a`, no `--no-verify`).
4. Update the checkbox + "Progress log" below. Keep changes small.
5. If the whole milestone's accept-criteria are met, run the milestone's audit:
   spawn a **foreground** audit subagent. If it passes, advance "Current
   milestone" to the next one and copy in its tasks. If it fails, paste its
   findings as new tasks here.

Repo facts: branch `android-controls-android`; push to `fork` remote. e2e target
host = `d-claude` (ssh). Build/run scratch on d-claude under `/srv/work`.

---

## Current milestone: **M1 — Native stack cross-compiled for Android x86_64**

(M0 — Scaffolding & red-but-running pipeline — **PASSED audit 2026-06-01**, all
5 tasks done; see progress log. Harness boots two emulators green on d-claude.)

Accept: `libscrcpy.so` + its native deps are produced for Android `x86_64`; a tiny
NDK smoke executable links `scrcpy_main` and prints usage/help without crashing,
run inside `scrcpy-e2e:dev`. The iOS build must remain intact (do not break it).
Start with `x86_64` (emulator arch); `arm64-v8a` comes later.

### Tasks
- [x] Add an Android NDK cross-compile path to `porting/` **without breaking the
      iOS build**: new scripts/targets (parallel to the iOS ones) that emit into
      `output/android/x86_64/`. Drive arch/SDK selection so iOS Makefile targets are
      untouched. Pin NDK 27.2.12479018 (matches `scrcpy-e2e:dev`).
- [x] Cross-compile **FFmpeg** for android x86_64 (NDK clang, `--target-os=android
      --arch=x86_64`, software H.264 decode; no VideoToolbox).
- [x] Cross-compile **SDL2** for android x86_64 using SDL2's native Android backend
      (not the iOS UIKit path).
- [x] Provide **OpenSSL** for android x86_64 (cross-build, or a vetted prebuilt /
      NDK approach). Document choice.
- [x] Build **adb-mobile** (`external/adb-mobile`) for android x86_64, or substitute
      an equivalent in-process ADB path. Document choice.
- [ ] Adapt `porting/src` behind the NDK path: drop the `OpenGLES/ES3` include (use
      SDL2 GLES), bypass VideoToolbox/Metal hijacks → software FFmpeg decode + SDL
      texture upload, Android clipboard stub. Keep iOS code paths via `#ifdef`.
- [ ] Build **`libscrcpy.so`** for x86_64; link a tiny NDK smoke executable that
      calls `scrcpy_main` and prints usage without crashing — run it inside
      `scrcpy-e2e:dev` on d-claude and capture output. Commit + push when green.

### Progress log
- 2026-06-01: **M1 task 5 done — adb-mobile (`libadb-full.a`) cross-compiled for
  android x86_64.** This is the in-process ADB host (`adb_commandline_porting` API)
  that pushes the scrcpy server + opens TCP tunnels, same role as the iOS build.
  **APPROACH (b): a standalone NDK driver, NOT adb-mobile's own ios-cmake build.**
  `external/adb-mobile`'s build (`make-adb.sh`) wires Google's adb sources through
  `nmeum/android-tools`'s CMake, which `pkg_check_modules(REQUIRED)` for
  brotli/lz4/pcre2/zstd/protobuf/libusb and compiles a pile of unrelated host tools
  (fastboot/e2fsprogs/...); the iOS port tolerates that via brew. Rather than fight
  it under the NDK, I wrote a small **standalone CMakeLists**
  (`porting/scripts/adb-mobile-android-CMakeLists.txt`) that compiles **exactly the
  iOS static-lib target set** (libadb + libbase/libcutils/liblog/libcrypto_utils/
  libdiagnoseusb/libziparchive/adb_crypto_defaults/adb_tls_connection_defaults + fmt)
  against the vendored AOSP sources + the `porting/adb/` client overrides, pulling
  **boringssl** in as a subdirectory (cross-compiles cleanly with NDK + host Go). The
  iOS targets in `external/adb-mobile` are 100% untouched (additive, alongside).
  Driver = **`porting/scripts/make-adb-mobile-android.sh`** (wired into
  `Makefile.android` `android-adb-mobile`, TODO stub replaced; iOS Makefile untouched).
  It (1) builds a **host protoc 28.3** from the pinned `external/protobuf` (apt's is
  the wrong ver) + uses it to generate adb's `*.pb.cc`; (2) cross-compiles **Android
  libprotobuf** and **lz4/zstd/brotli** (transport/incremental compression) via the
  NDK cmake toolchain; (3) **overlays `porting/adb/client/*` onto vendor/adb/client/**
  (the iOS mechanism — required so path-qualified `#include "client/file_sync_client.h"`
  resolves to the porting override, in-process no-fork server + extended do_sync_pull);
  (4) configures+builds the standalone project through the NDK; (5) bundles every `.a`
  (+ android libprotobuf + lz4/zstd/brotli) into **`output/android/x86_64/libadb-full.a`**
  via an `llvm-ar -M` MRI script, then `--strip-debug`. **adb_public.h** copied to the
  android `include/`.
  **Submodules initialized (pinned, NOT bumped):** `external/adb-mobile` @78c32c2 +
  its `external/{lz4,zstd,brotli,protobuf}` and `android-tools` vendor subset
  `{adb,core,libbase,libziparchive,boringssl,fmtlib,logging}` (+ protobuf's nested
  abseil-cpp/utf8_range). The big unused android-tools vendors (selinux/extras/
  e2fsprogs/f2fs/libusb/...) are intentionally left un-inited.
  **Key porting fixes (all in the driver/standalone CMake, none touch committed
  vendor files — overlay+patch happen on the build host's rsync'd tree which has no
  `.git`, so patches use idempotent GNU `patch --forward`, not `git am`):**
   • API floor **29** for this lib only (`ANDROID_API_ADB`, overrides the repo
     default 26): AOSP `libbase/unique_fd.h` hard-`#if`-gates fdsan on
     `__ANDROID_API__>=29`; the symbols are weak so the lib still loads on <29, and
     the adb host runs on the API-30 emulator anyway. (ffmpeg/sdl/openssl stay at 26.)
   • `-D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__` — liblog/adb reference bionic
     symbols `__INTRODUCED_IN(30)`; makes those weak refs instead of hard errors.
   • applied upstream adb patches **0007** (guard the sysdeps `write` macro so it
     doesn't clobber `std::ostream::write` that abseil str_format pulls in) and
     **0013** (disable fastdeploy → no `ApkEntry.pb.h` requirement).
   • `ZLIB_CONST` for libziparchive (NDK zlib `next_in` const mismatch); in-tree
     incfs_support + gtest_prod includes added.
   • guarded the porting `main.cpp`'s `#include "fdevent_poll.cpp"` behind
     `#if !defined(__linux__)` — it amalgamates BOTH poll and epoll backends; on iOS
     epoll is `__linux__`-excluded so poll wins, but Android IS `__linux__` → both
     compiled → `fdevent_interrupt` redefinition. Android uses the epoll backend.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** end-to-end via
  `make android-adb-mobile` (clean cmake/bundle rebuild): `MAKE_RC=0`,
  `[adb-mobile-android] DONE`. **apt deps (transient in the run cmd, NOT baked into
  the image):** `golang-go build-essential make patch` (go is needed for boringssl's
  codegen; build-essential for the host protoc; patch for the idempotent vendor
  patching). cmake 3.22.1 + ninja come from `$ANDROID_SDK_ROOT/cmake/*/bin` (script
  auto-prepends, same trick as the SDL build). **libadb-full.a = 6.1M** (stripped;
  22.7M unstripped; 980 object members). **VERIFIED Android x86_64** (llvm-nm /
  llvm-ar / llvm-readelf in the image): defined `T adb_commandline_porting`,
  `T adb_trace_init_porting`, `T adb_trace_enable_porting`, `T capture_printf`, and
  the in-process `T launch_server`/`launch_server_thread` overrides; an extracted
  member (`commandline.cpp.o`) is `ELF64 / X86-64 / REL`; brotli/lz4/zstd/protobuf
  symbols bundled; `adb_public.h` present in the android include dir.
  gitignore swallows `output/`+`build/`+`*.a` (only the driver script, the standalone
  CMakeLists, the Makefile.android edit + STATE committed; submodule pointer NOT
  bumped — adb-mobile stays @78c32c2).
- 2026-06-01: **M1 task 4 done — OpenSSL cross-compiled for android x86_64.** New
  `porting/scripts/make-openssl-android.sh` (mirrors the FFmpeg/SDL android-driver
  style; iOS untouched). **OpenSSL 1.1.1w** (matches the iOS OpenSSL-for-iPhone 1.1.1
  series, for ABI/API parity). Configured `./Configure android-x86_64
  -D__ANDROID_API__=26 no-shared no-tests` via the NDK clang (`x86_64-linux-
  android26-clang`, on PATH from android-defines.sh). Produced **libcrypto.a (5.2 MB)
  + libssl.a (1.0 MB)** + headers into `output/android/x86_64/` (the canonical
  output dir, same place ffmpeg/sdl land). VERIFIED on d-claude in `scrcpy-e2e:dev`:
  build rc=0 / "[openssl-android] DONE"; `nm` shows defined `T OPENSSL_init_crypto`
  (libcrypto) and `T SSL_new` (libssl); archive has 637 object members all compiled
  by the android NDK clang. apt deps `make perl` installed per-run.
  PROCESS NOTE: the first attempt was launched by the iteration subagent as a
  background task and got TORN DOWN when that subagent paused (un-resumable) — the
  build was re-launched as a parent-session harness-tracked task and finished clean.
  Going forward, heavy builds should run BLOCKING in the subagent's own context (or
  be launched by the parent) so they aren't killed.
- 2026-06-01: **M1 task 3 done — SDL2 cross-compiled for android x86_64 (native
  Android backend).** New `porting/scripts/make-libsdl-android.sh` (mirrors the
  iOS `make-libsdl.sh` STYLE but retargets the NDK; iOS script untouched). **Same
  SDL2 version as iOS: 2.32.8** (downloaded from libsdl.org, tarball cached under
  `porting/build/libsdl-android/`, re-runs reuse it). **Build method:** SDL2's own
  CMake build driven through the NDK `build/cmake/android.toolchain.cmake`
  (resolved by android-defines.sh) with `-DANDROID_ABI=x86_64
  -DANDROID_PLATFORM=android-26 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF`
  → **SHARED `libSDL2.so`** (the Android norm, loaded at runtime by SDLActivity in
  M2). cmake auto-selected the **Android backend** (configure summary: `Platform:
  Android-1`; compiled `src/core/android/SDL_android.c`, `audio/openslES`,
  `audio/aaudio`, `video/android/SDL_android{video,touch,events,clipboard,...}.c`,
  `joystick/android`, `sensor/android` — NOT the iOS UIKit path). Wired
  `android-libsdl` target in `porting/Makefile.android` to call the script (TODO
  stub replaced; iOS untouched). Outputs `output/android/x86_64/libSDL2.so` +
  `include/SDL2/*.h` (79 headers incl. generated SDL_config.h — iOS-compatible
  layout so libscrcpy can `#include <SDL.h>`).
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (`EXIT_CODE=0`, 265/265 ninja
  steps + install). **apt deps:** transiently `apt-get install make ninja-build`
  in the run command (NOT baked into the image, same as the FFmpeg task). **cmake:**
  the image's Android-SDK cmake 3.22.1 is NOT on PATH; the script auto-prepends
  `$ANDROID_SDK_ROOT/cmake/<ver>/bin` (which also supplies the bundled ninja) when
  `cmake` is absent — so the build is self-contained. **libSDL2.so size: 6.2M.**
  **VERIFIED Android x86_64** (`llvm-readelf`/`llvm-nm` in the image): `ELF64 / DYN
  (shared object) / X86-64`; SONAME `libSDL2.so`; NEEDED includes the Android
  system libs `libOpenSLES.so libandroid.so liblog.so libGLESv1_CM.so libGLESv2.so`
  (proves Android backend, not iOS); `.note.android.ident` present; `llvm-nm -D`
  finds `T SDL_Init`, `T SDL_CreateWindow`, `T SDL_GetPlatform`; SDL.h present.
  **SDL Android Java glue for M2:** vendored 9 files (SDLActivity, SDLSurface,
  SDLAudioManager, SDLControllerManager, SDL, HIDDevice*) from the SDL2-2.32.8
  tarball's `android-project/app/src/main/java/org/libsdl/app/` into
  `porting/vendor/sdl-android-java/org/libsdl/app/` (TRACKED — `.gitignore`
  ignores `porting/libs` but NOT `porting/vendor`; verified `git check-ignore`
  exit 1) + a `SOURCE.txt` provenance note. M2 imports this `org.libsdl.app`
  package so SDLActivity.loadLibraries() loads libSDL2.so at runtime. gitignore
  confirmed swallowing `output/` + `build/` + `*.so` (only script + Makefile edit
  + vendored java + STATE committed; no SDL tarball or libSDL2.so).
- 2026-06-01: **M1 task 2 done — FFmpeg cross-compiled for android x86_64.**
  New `porting/scripts/make-ffmpeg-android.sh` (mirrors the iOS `make-ffmpeg.sh` but
  retargets the NDK): same **FFmpeg release/6.0**, sources the M1-task-1
  `scripts/android-defines.sh` toolchain (CC=`x86_64-linux-android26-clang`,
  `--cross-prefix=$TOOLCHAIN/bin/llvm-`, `--sysroot`, `--target-os=android
  --arch=x86_64 --enable-cross-compile`). Source is git-cloned once and cached under
  `porting/build/ffmpeg-android/ffmpeg-source` (re-runs reuse it). **Static `.a`**
  (mirrors iOS: `--enable-static --disable-shared`); **no VideoToolbox/MediaCodec/JNI**
  (`--disable-videotoolbox --disable-mediacodec --disable-jni`), software decode only.
  **Lean config:** `--disable-everything` then enable avcodec/avformat/avutil/swscale/
  swresample + decoders h264,hevc,av1,aac,opus,flac,pcm_s16le + matching parsers +
  demuxers (h264/hevc/av1/aac/ogg/flac/pcm + matroska/mov/mpegts) + protocols
  file,pipe. (avfilter/avdevice also fall out of the build — kept; mirrors the iOS
  link list which includes both.) **x86 asm: nasm** (auto-detected; script falls back
  to `--disable-x86asm` if absent). Wired `android-ffmpeg` target in
  `porting/Makefile.android` to call the script (TODO stub replaced; iOS untouched).
  Outputs to `output/android/x86_64/lib*.a` + `include/` in the iOS layout.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (apt-get installed make/nasm/
  pkg-config transiently in the run command — NOT baked into the Dockerfile, kept the
  image change-free): `EXIT_CODE=0`, "DONE. Libraries in: output/android/x86_64".
  Produced: libavcodec.a 5.0M, libavformat.a 844K, libavutil.a 1.2M, libswscale.a
  1.4M, libswresample.a 212K, libavfilter.a 197K, libavdevice.a 13K, + full include/
  tree (libav*/libsw*). **VERIFIED Android x86_64:** `llvm-readelf -h` on an extracted
  object shows `ELF64 / X86-64 / REL`; `llvm-nm libavcodec.a` finds `T
  avcodec_send_packet` and `D ff_h264_decoder` (H.264 software decoder compiled in).
  gitignore confirmed ignoring `output/` + `build/` + `*.a` (only script + Makefile +
  STATE committed; no FFmpeg sources or libs).
- 2026-06-01: **M1 task 1 done — Android NDK build scaffold (scaffolding only).**
  Added `porting/scripts/android-defines.sh` (NDK locate honoring
  `$ANDROID_NDK_ROOT` / `$ANDROID_SDK_ROOT/ndk/27.2.12479018` / `$ANDROID_HOME`,
  **NDK pinned 27.2.12479018**, **TARGET_ABI=x86_64** default, **ANDROID_API=26**,
  unified-llvm toolchain paths, output `output/android/$TARGET_ABI/`),
  `porting/Makefile.android` (stub targets `android-ffmpeg/libsdl/openssl/adb-mobile/
  scrcpy` each echoing `TODO(M1)` + creating output dir, plus `android-libs` and a
  real `android-toolchain-check`; `SHELL := /bin/bash` for the bashy defines),
  `porting/scripts/README-android.md`. Wired into `porting/Makefile` purely
  additively (`SOURCE_ROOT := ...` + `include Makefile.android` appended after
  `server-diff`; nothing references the iOS `all` target). **iOS build UNCHANGED:**
  `make -n all` recipe output is byte-for-byte identical before/after (diff clean);
  no iOS script touched. **VERIFIED in `scrcpy-e2e:dev` on d-claude:** sourcing
  android-defines.sh resolves CC=`x86_64-linux-android26-clang`; it compiles+links a
  trivial C file into an Android x86_64 ELF — `llvm-readelf` shows `ELF64` /
  `X86-64` / PIE with a `.note.android.ident` (`r27c`, NDK build 12479018);
  `make android-toolchain-check` prints `[android] TOOLCHAIN_OK`; `make android-libs`
  runs all 5 stubs and creates `output/android/x86_64/`. ABI switch sanity-checked:
  `TARGET_ABI=arm64-v8a` resolves `aarch64-linux-android26-clang` (binary present).
  (Note: `scrcpy-e2e:dev` lacks `make`/`file`; installed transiently in the throwaway
  verify container — the toolchain-check recipe falls back to `llvm-readelf` when
  `file` is absent.)
- 2026-06-01: **M0 AUDIT PASSED.** Fresh authoritative run on d-claude (after
  killing two overlapping/racing harness containers that were starving RAM —
  single clean run only): `AUDIT_RC=0`, SUCCESS banner, both `emulator-5554` and
  `emulator-5556` reached `device`, all placeholder asserts passed (both online +
  settings round-trip on B + `am start` moved `mCurrentFocus` to Settings + input
  keyevent/tap dispatched), `cleanup done (rc=0)`, host left clean (0 scrcpy
  containers). Cold runtime ~3.5 min. Advancing to M1. NOTE for future runs: only
  ONE e2e run at a time on d-claude — host shares ~8 GB RAM with unrelated long-
  running mf-e2e/redroid/ws-scrcpy containers, so concurrent runs OOM/phantom.
- 2026-06-01: Repo forked → `d33mobile/scrcpy-mobile`; branch
  `android-controls-android` created; README overwritten (WIP + goal); master plan
  + research written. Starting M0.
- 2026-06-01: M0 task 1 done. `e2e/Dockerfile` + `e2e/README.md` written and built
  green on d-claude as `scrcpy-e2e:dev` (7.96 GB). Verified inside the image:
  emulator, avdmanager, sdkmanager, adb, NDK 27.2.12479018, cmake 3.22.1,
  build-tools 37.0.0, platforms;android-36, system-images;android-30;google_apis;
  x86_64 all present. Image requires `--device /dev/kvm` to run the emulators.
- 2026-06-01: M0 task 2 done. Scaffolded `android-app/` Kotlin-DSL Gradle project:
  AGP 8.7.3, Gradle 8.9, Kotlin 2.0.21, compileSdk/targetSdk 36, minSdk 26,
  applicationId `net.scrcpy.android`, stub `MainActivity` (AppCompat, TextView WIP
  message), deps androidx.core-ktx 1.13.1 + appcompat 1.7.0. `.gitignore` added
  (build/, .gradle/, local.properties, *.iml, .idea/, .kotlin/, .cxx/). Built green
  on d-claude in `scrcpy-e2e:dev` via the persistent `scrcpy-gradle-cache` volume:
  `./gradlew --no-daemon assembleDebug` → BUILD SUCCESSFUL (exit 0), APK at
  `/srv/work/scrcpy-e2e/android-app/app/build/outputs/apk/debug/app-debug.apk`
  (3.18 MB). Note: AGP 8.7.3 emits a non-fatal warning for compileSdk 36 (tested up
  to 35) and auto-pulled build-tools 34.0.0 as its default — build still green.
- 2026-06-01: M0 tasks 3 + 4 done. `e2e/run.sh` (OUTER `docker run --device /dev/kvm`
  → INNER) + `e2e/run-on-d-claude.sh` (rsync + remote invoke + pull artifacts)
  written and **ran green on d-claude (exit 0)**.
  - TOPOLOGY: one container, BOTH emulators. B=target console 5554 / adb 5555,
    A=controller 5556 / adb 5557. Created from `system-images;android-30;
    google_apis;x86_64`. Flags: `-no-window -gpu swiftshader_indirect -no-snapshot
    -no-audio -no-boot-anim -accel on -memory 1536 -partition-size 2048`.
  - MEMORY settled on **1536MB/emulator** (host is 8GB, ~2GB free alongside the
    pre-existing mf-e2e containers; 2x2048 wouldn't fit, 2x1536 boots reliably).
  - PLACEHOLDER assertion (all passed): both serials show `device` in `adb
    devices`; `settings put/get system e2e_probe` round-trips on B; `am start -n
    com.android.settings/.Settings` moves B's `dumpsys window mCurrentFocus` from
    NexusLauncher → com.android.settings.Settings; `input keyevent`/`input tap`
    dispatch to B (final screenshot shows the home-screen long-press popup, i.e.
    the tap landed). Proves the harness can drive an emulator end-to-end.
  - RUNTIME ~3.5 min cold (B booted +91s, A +98s from launch; asserts ~20s;
    self-cleaning trap kills emulators + deletes AVDs → host returns to 0 qemu).
  - Artifacts to mounted `/artifacts` → pulled to `e2e/artifacts/` (gitignored):
    adb-devices.txt, logcat-*.txt, emulator-*.log, screen-*.png (1080x1920).
  - KEY FIX / GOTCHA: the emulator sdkmanager currently installs (**v36.5.11**)
    SEGFAULTS under KVM-in-Docker on d-claude — every launch (any -gpu/-cpu/
    -feature combo, even a single emulator, RAM ample, KVM RW-accessible to root)
    stalls all vCPU threads ("detected a hanging thread 'QEMU2 CPU0 thread'. No
    response for ~19000 ms") right after "Starting QEMU main loop" then core-dumps
    at ~40s, so it never boots. Pinned the emulator binary to build **11237101
    (v33.1.24)** in `e2e/Dockerfile` (overlay sdkmanager's emulator, keep its
    package.xml) — boots API 30 cleanly. Also dropped `-no-metrics` (v33.x rejects
    it). run.sh's `wait_boot` was hardened: every adb poll wrapped in `timeout 15`
    and it bails if the emulator PID dies, so a crashed emulator can never hang the
    harness on `adb wait-for-device` (the original first-run failure mode).

---

## Backlog (next milestones — see master plan for full accept criteria)
- M1 — Native stack cross-compiled for Android x86_64 (then arm64-v8a).
- M2 — Android client app wraps `libscrcpy.so` (connects to B, shows screen,
  touches propagate).
- M3 — Full GUI-automation e2e: uiautomator taps A's remote view, assert B reacts.
- M4 — Reproducibility/flake-hunt/arm64/review until audit says fully realized.
