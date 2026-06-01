# scrcpy-mobile e2e image

`e2e/Dockerfile` defines a single, version-pinned image (`scrcpy-e2e:dev`) used by
the Android-controls-Android e2e harness. It does two jobs:

1. Builds the `android-app` debug APK (the controller client) with the Android SDK
   + NDK + CMake toolchain.
2. Runs **two** headless x86_64 Android emulators in one container — B (target,
   runs the scrcpy-server) and A (controller, runs our APK).

## Hermeticity

The image build (`docker build`) is networked and one-time: it bakes the apt build
tools, the Android SDK / NDK / CMake / emulator, the pinned native sources (FFmpeg
`release/6.0`, SDL2 2.32.8, OpenSSL 1.1.1w into `/opt/native-src`), and an offline
Gradle home (`GRADLE_USER_HOME=/opt/gradle-home`) seeded with the `gradle-8.9`
distribution + all AGP / Kotlin / AndroidX Maven deps. The **e2e run itself is fully
offline**: `e2e/run.sh` launches the inner container with `--network none` by default
— the native stack cross-compiles from the baked sources and both APKs build
`--offline` from the baked Gradle home. (`E2E_ALLOW_NET=1` re-enables the network for
re-priming / debug only.)

## Pins

| Component       | Version                          | Why |
|-----------------|----------------------------------|-----|
| Base            | `eclipse-temurin:21-jdk`         | JDK 21, matches the proven d-claude sibling images. |
| cmdline-tools   | `11076708`                       | Reproducible sdkmanager/avdmanager. |
| Platform        | `platforms;android-36`           | compileSdk / targetSdk 36. |
| build-tools     | `37.0.0`                         | Matches the sibling build image. |
| NDK             | `27.2.12479018` (r27c)           | Recent stable LTS NDK for the `porting/` cross-compile (M1). |
| CMake           | `3.22.1`                         | NDK-bundled CMake. |
| Emulator binary | build `11237101` (v33.1.24)      | Pinned, overlaying sdkmanager's current emulator. The current build (v36.5.11) segfaults under KVM-in-Docker on d-claude ("detected a hanging thread 'QEMU2 CPU0 thread'… No response for ~19000 ms" → core dump before boot); v33.1.24 boots API 30 cleanly. |
| Emulator image  | `system-images;android-30;google_apis;x86_64` | API 30, Google APIs, x86_64 — known-good reliable headless boot under KVM. |

## Requirements

- Docker.
- **`/dev/kvm`** — the container must be started with `--device /dev/kvm`. The
  x86_64 emulators need hardware acceleration; without KVM they will not boot in a
  usable time.

## Build

The build context is the repo **root** (the Dockerfile's Gradle-priming layer COPYs
`android-app/`, `e2e/target-app/`, and `porting/vendor/sdl-android-java`, all outside
`e2e/`); a repo-root `.dockerignore` keeps the context lean. `e2e/run.sh` builds the
image this way automatically; to build it by hand:

```sh
docker build -t scrcpy-e2e:dev -f e2e/Dockerfile .
```
