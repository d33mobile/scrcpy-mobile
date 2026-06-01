# Research findings — Android-controls-Android for scrcpy-mobile

Date: 2026-06-01. Host for e2e: `d-claude` (Hetzner, ssh).

## Current state of the repo
- It is **iOS-only**. There is **no Android client app** anywhere (no Gradle, no
  AndroidManifest, no NDK files). The README's "Android controlling Android … in
  future" is literally unimplemented.
- `scrcpy-app/` = the active iOS app ("Scrcpy Remote.xcodeproj", Obj-C/Swift).
  `scrcpy-ios/` = older iOS app + iOS-only submodules.
- `porting/` = a C layer that compiles the **scrcpy desktop client** (from the
  `scrcpy/` submodule, pinned/targeting v3.3.4) into `libscrcpy.a` for iOS. Public
  API is essentially `int scrcpy_main(int argc, char**argv)` + a weak
  `ScrcpyUpdateStatus()` callback. It uses SDL2 (window/input), FFmpeg (decode),
  VideoToolbox (HW decode), OpenGLES, and `adb-mobile` (ADB as an in-process lib).
- The **scrcpy server** (`scrcpy-server`, a `.jar`/dex that runs on the *target*
  device) is downloaded+built (v3.3.4) and stored at
  `scrcpy-app/ADBClient/scrcpy-server`. This is reusable as-is for Android targets.

## What "Android controls Android" requires
A new Android **client** app (the controller). Two viable strategies:
- **(A) Reuse `porting/` via NDK**: cross-compile FFmpeg/SDL2/OpenSSL/adb-mobile +
  `libscrcpy` for `arm64-v8a`/`x86_64`, replace VideoToolbox with MediaCodec or SW
  decode, SDL2 Android backend, thin Kotlin shell calling `scrcpy_main()`. Faithful
  to repo design + shares iOS code, but ~weeks of native cross-compilation, high
  risk to get fully green.
- **(B) Fresh Kotlin client**: implement the scrcpy client protocol natively —
  embed a pure-JVM ADB client (e.g. `dadb`) to push the server jar + open the
  video/control sockets, decode H.264 with `MediaCodec`, render to `SurfaceView`,
  send scrcpy control messages. Idiomatic Android, fastest to a working+testable
  WIP, decodes fine on x86_64 emulators. Does not reuse the C port.

## e2e harness — environment facts (d-claude)
- x86_64, 4 cores, 8 GB RAM. **`/dev/kvm` present, nested virt yes.**
- **Emulator-in-Docker is already proven on this host**: sibling projects left
  `mf-e2e-emulator:dev` (10.3 GB) and `inkstone-apk-e2e` images. Pattern =
  `eclipse-temurin` + cmdline-tools + `sdkmanager` system-image + headless emulator
  (`-no-window -gpu swiftshader_indirect`).
- **redroid is risky here**: kernel exposes a single `/dev/binder`, **no
  CONFIG_ANDROID_BINDERFS, no `/dev/ashmem`**. redroid wants binder+hwbinder+
  vndbinder. → avoid redroid; use AVD emulators.
- **Disk**: `/` has only 6.5 GB free, but `/srv/work` and `/tank` have ~369 GB
  free and Docker storage already lives there. Point all build/run workdirs there.

## Decided without asking (precedent + spec-constrained)
- e2e device tech = **two x86_64 Android emulators in Docker + KVM** (B = target
  running scrcpy-server, A = controller running our client). One script builds the
  image and boots both on a docker network; A reaches B by container IP.
- Fork target = `d33mobile/scrcpy-mobile` (the gh-authed account).
- ADB embedding for strategy B = `dadb` (pure-JVM) to avoid needing adb-mobile NDK.

## Open questions → see ai/questions/
