# scrcpy-mobile — Android client (WIP fork)

> ⚠️ **Work in progress.** This is a fork of
> [wsvn53/scrcpy-mobile](https://github.com/wsvn53/scrcpy-mobile) whose goal is to
> let **Android users control other Android phones** — i.e. run the scrcpy client
> *on an Android device* and use it to remotely view and control a second Android
> device over ADB-over-TCP.
>
> The upstream project ports [scrcpy](https://github.com/Genymobile/scrcpy) to iOS
> (controlling Android from an iPhone). Upstream noted that "Android controlling
> Android will be supported in the future" — **this fork is that work.** The core
> phone-to-phone path is now demonstrably working in an automated two-emulator
> harness (see below), but it remains WIP: emulator-proven only, not yet validated
> on real hardware, and not on any app store.

## Goal

Enable a phone-to-phone workflow: **install this app on Android device A, point it
at Android device B, and control B from A** — screen mirroring plus touch input —
reusing the same native scrcpy port that the upstream iOS app uses.

## Approach

This fork reuses the existing native C scrcpy port in [`porting/`](porting/) (the
same code the iOS app links as `libscrcpy.a`) and retargets it to the **Android
NDK**, then wraps it in a minimal Android app:

- Cross-compile the native stack (scrcpy client + FFmpeg + SDL2 + OpenSSL +
  `adb-mobile`) for Android, producing `libscrcpy.so` + its dependencies.
- Build a thin Kotlin app that hosts the SDL surface, calls `scrcpy_main()`, and
  exposes a touchable remote-view that maps gestures to scrcpy control messages.
- Connect to the target device over ADB-over-TCP; the existing `scrcpy-server`
  (runs on the *target*) is reused unchanged and shipped as an app asset.

See [`ai/plans/`](ai/plans/) for the full, phased implementation plan and
[`ai/research/`](ai/research/) for the architecture analysis.

## Status

| Piece | State |
|-------|-------|
| iOS app (upstream) | ✅ works (unchanged in this fork) |
| Native port → Android NDK (x86_64) | ✅ done — FFmpeg / SDL2 / OpenSSL / adb-mobile + `libscrcpy.so` cross-compiled and smoke-tested on the bionic linker |
| Android client app | ✅ done (core path) — loads `libscrcpy.so` via SDL, connects to a target over ADB-over-TCP, renders the remote screen, forwards touches |
| Dockerized two-emulator e2e | ✅ done & reliably green — one script proves emulator A controls emulator B with coordinate-faithful taps |
| arm64-v8a / real-device | ⬜ not yet (x86_64 emulator only so far) |

## What works today

Phone-to-phone control is **proven in the automated end-to-end test** (`bash
e2e/run.sh`). In that harness, on a single host running two x86_64 Android
emulators:

- Emulator **A** runs our APK (the controller).
- A connects to emulator **B** over ADB-over-TCP, using the in-process `adb-mobile`
  embedded in the native lib (the harness fronts B's adbd via a host socat bridge,
  so A reaches it at `10.0.2.2:6555`).
- A pushes the matching `scrcpy-server` (v3.3.4, shipped as an app asset) to B and
  launches it; scrcpy's own client log reports `INFO: Connected to 10.0.2.2:6555`
  and the server process runs on B.
- B's screen is streamed as H.264 and **decoded in software** (FFmpeg) and rendered
  into A's SDL surface.
- **Taps on A's remote view land on B at the right coordinates.** The test injects
  taps on A (2 calibration + 3 independent validation points), derives the A→B
  affine transform from the calibration taps, and asserts that every tap — including
  the independent validation taps — maps onto B within tolerance, with no taps lost
  or duplicated. The independent validation points fitting the transform is what
  proves the control is coordinate-faithful, not a lucky single hit.

**How this is proven, precisely:** the e2e injects input on A and reads the
resulting tap coordinates back from a deterministic target app on B (the controller
and the assertion are on different emulators). A broken connection, a lost tap, or a
wrong mapping each fails the script with a non-zero exit. The run has been green
repeatedly (multiple warm runs plus a cold from-scratch native rebuild) with a
stable per-tap result (max ~1px error against the derived transform).

## Known limitations / WIP

This is honest WIP. What is **not** yet covered:

- **x86_64 emulators only.** `arm64-v8a` (the real-device ABI) and actual phones
  are not yet built/tested. The native stack has been cross-compiled and smoke-run
  on the bionic linker for x86_64 only.
- **Software H.264 decode** via FFmpeg — no MediaCodec hardware decode yet, so
  framerate is low.
- **Minimal launcher UI** — one screen for host/port + a Connect button, then the
  remote view. No keyboard/clipboard/navigation-button UI affordances beyond what
  scrcpy's surface event loop handles.
- **Audio is disabled** in the e2e (`--no-audio`); the emulator has no audio-capture
  HAL, and enabling it tore down the session.
- **System bars kept** — A's activity is not immersive-fullscreen, so it keeps its
  status/navigation bars and B's video is letterboxed into A's content rectangle
  (this is exactly what the A→B transform accounts for).
- **Connection-state reporting quirk:** the porting layer's `status=6` "Connected"
  callback (`sc_server_on_connected_hijack`) does not surface in logcat on this
  Android build. The session is instead confirmed via scrcpy's own authoritative
  `INFO: Connected to <host:port>` line plus the server process running on B; this
  is a logging/observability gap, not a functional one.

## Building & running the end-to-end test

The whole thing is one command. The hermeticity model has two phases:

- **Image build (`docker build`, networked, one-time).** Everything the run needs
  is baked into `scrcpy-e2e:dev` by `e2e/Dockerfile`: the apt build tools, the
  Android SDK / NDK / CMake / emulator, the pinned native sources (FFmpeg
  `release/6.0`, SDL2 2.32.8, OpenSSL 1.1.1w into `/opt/native-src`), and an offline
  Gradle home (`GRADLE_USER_HOME=/opt/gradle-home`) seeded with the `gradle-8.9`
  distribution plus every AGP / Kotlin / AndroidX Maven dependency. This step is the
  only one that touches the network, and it only runs once (the layers are cached).
- **The e2e run itself is fully offline.** `e2e/run.sh` runs the inner container with
  `--network none` by default — no flag needed. The native stack cross-compiles from
  the baked sources, and both APKs build `--offline` from the baked Gradle home, so
  any un-baked input fails loudly instead of silently fetching. This was proven by a
  from-absolute-scratch run (gradle volume removed + native caches/outputs cleared,
  image only) under `--network none` reaching the SUCCESS banner with 5/5
  coordinate-faithful taps and zero network fetches. (Set `E2E_ALLOW_NET=1` only to
  re-prime / debug against the network.)

- **From a clone, targeting the `d-claude` build host over SSH:**

  ```sh
  bash e2e/run-on-d-claude.sh
  ```

  This rsyncs the tree to the host, runs `e2e/run.sh` there, and pulls the
  artifacts back into `e2e/artifacts/`.

- **Directly on any host with Docker + `/dev/kvm`:**

  ```sh
  bash e2e/run.sh
  ```

What it does: builds the `scrcpy-e2e:dev` image if missing, then in one container
(with `--device /dev/kvm`) cross-compiles the native stack (if `libscrcpy.so` is
absent), builds both APKs (the controller `android-app` and the deterministic
target app), boots emulators B (5554) and A (5556), bridges B's adbd, drives A's
connect flow, waits for a stable stream, then injects taps on A and asserts B
received each at the expected coordinate. Exit 0 only if the whole chain passes.

**Requirements at run time: Docker + `/dev/kvm` only — no network needed.** The
x86_64 emulators need KVM hardware acceleration. Artifacts (logcat A+B, screenshots
of both emulators, the native build log, and the per-tap evidence table) land in
`e2e/artifacts/`. See
[`e2e/README.md`](e2e/README.md) for the pinned SDK/NDK/emulator versions and image
details.

## License

Same as upstream — see [LICENSE](LICENSE). scrcpy is © Genymobile and contributors.

---

### Upstream documentation

For the iOS app, App Store install, ADB/VNC connection modes and pairing-code
instructions, see the original upstream README:
<https://github.com/wsvn53/scrcpy-mobile>.
