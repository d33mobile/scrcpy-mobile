# scrcpy-mobile e2e image

`e2e/Dockerfile` defines a single, version-pinned image (`scrcpy-e2e:dev`) used by
the Android-controls-Android e2e harness. It does two jobs:

1. Builds the `android-app` debug APK (the controller client) with the Android SDK
   + NDK + CMake toolchain.
2. Runs **two** headless x86_64 Android emulators in one container — B (target,
   runs the scrcpy-server) and A (controller, runs our APK).

## Pins

| Component       | Version                          | Why |
|-----------------|----------------------------------|-----|
| Base            | `eclipse-temurin:21-jdk`         | JDK 21, matches the proven d-claude sibling images. |
| cmdline-tools   | `11076708`                       | Reproducible sdkmanager/avdmanager. |
| Platform        | `platforms;android-36`           | compileSdk / targetSdk 36. |
| build-tools     | `37.0.0`                         | Matches the sibling build image. |
| NDK             | `27.2.12479018` (r27c)           | Recent stable LTS NDK for the `porting/` cross-compile (M1). |
| CMake           | `3.22.1`                         | NDK-bundled CMake. |
| Emulator image  | `system-images;android-30;google_apis;x86_64` | API 30, Google APIs, x86_64 — known-good reliable headless boot under KVM. |

## Requirements

- Docker.
- **`/dev/kvm`** — the container must be started with `--device /dev/kvm`. The
  x86_64 emulators need hardware acceleration; without KVM they will not boot in a
  usable time.

## Build

```sh
docker build -t scrcpy-e2e:dev -f e2e/Dockerfile e2e
```
