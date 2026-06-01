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
- [ ] Cross-compile **FFmpeg** for android x86_64 (NDK clang, `--target-os=android
      --arch=x86_64`, software H.264 decode; no VideoToolbox).
- [ ] Cross-compile **SDL2** for android x86_64 using SDL2's native Android backend
      (not the iOS UIKit path).
- [ ] Provide **OpenSSL** for android x86_64 (cross-build, or a vetted prebuilt /
      NDK approach). Document choice.
- [ ] Build **adb-mobile** (`external/adb-mobile`) for android x86_64, or substitute
      an equivalent in-process ADB path. Document choice.
- [ ] Adapt `porting/src` behind the NDK path: drop the `OpenGLES/ES3` include (use
      SDL2 GLES), bypass VideoToolbox/Metal hijacks → software FFmpeg decode + SDL
      texture upload, Android clipboard stub. Keep iOS code paths via `#ifdef`.
- [ ] Build **`libscrcpy.so`** for x86_64; link a tiny NDK smoke executable that
      calls `scrcpy_main` and prints usage without crashing — run it inside
      `scrcpy-e2e:dev` on d-claude and capture output. Commit + push when green.

### Progress log
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
