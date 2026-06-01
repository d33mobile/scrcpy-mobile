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

## Current milestone: **M0 — Scaffolding & red-but-running pipeline**

Accept: `bash e2e/run.sh` on d-claude exits 0 with two booted emulators + green
placeholder; `android-app` debug APK builds in the build image.

### Tasks
- [x] Decide & document the Android build image (reuse the proven d-claude pattern:
      `eclipse-temurin:21-jdk` + cmdline-tools + sdkmanager: platform-tools,
      `platforms;android-36`, build-tools, `ndk;<pin>`, `cmake;3.22.1`,
      `emulator`, `system-images;android-30;google_apis;x86_64`). Write
      `e2e/Dockerfile` for it.
- [x] Scaffold `android-app/` Gradle project (Kotlin, AGP, minSdk 26, target 36),
      a stub `MainActivity`, `:app` module, that produces `app-debug.apk`.
      Add `android-app/.gitignore` (build/, .gradle/, local.properties).
- [x] Write `e2e/run.sh` — single entry script: build image, start two emulators
      (A + B) on one docker network, wait for boot, run a **placeholder**
      assertion (both `adb` online; B controllable by a baseline `adb shell input`
      tap that changes a dumpsys value). Exit non-zero on any failure. Make it
      idempotent and self-cleaning; artifacts to a mounted dir.
- [x] Make `e2e/run.sh` parameterizable so it can run locally or via
      `ssh d-claude`. Provide a thin `e2e/run-on-d-claude.sh` that rsyncs the repo
      to `/srv/work/scrcpy-mobile-e2e` and invokes `run.sh` there.
- [x] Run the placeholder e2e on d-claude; iterate until green. (Ran green; see
      2026-06-01 log entry below. Artifacts collected under `e2e/artifacts/`.)

### Progress log
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
