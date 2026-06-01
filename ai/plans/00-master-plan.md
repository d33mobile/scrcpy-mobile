# Master plan — Android-controls-Android + Dockerized e2e

Goal (locked with operator 2026-06-01):
- **Build an Android client** that lets Android device A control Android device B,
  **reusing the native C scrcpy port in `porting/` retargeted to the Android NDK**
  (decision Q1=A).
- **Prove it with a one-script, Dockerized e2e** on `d-claude`: two x86_64 Android
  emulators (B=target, A=controller running our APK); the test drives our app's
  rendered remote view on A via **UI automation** and asserts **B reacts**
  (decision Q2=full GUI automation of A).
- **Done = that e2e is reliably green**, built+run reproducibly by one script.
  SW-decode / low-fps / minimal UI are acceptable; it stays WIP (decision Q3).

Environment facts (see `ai/research/00-findings.md`): d-claude = x86_64, KVM +
nested-virt present, emulator-in-Docker already proven on this host, redroid ruled
out (no binderfs/ashmem), big scratch on `/srv/work` & `/tank`.

---

## Design overview

Three components, one connecting protocol:

1. **scrcpy-server** (runs on target B) — reused unchanged from upstream v3.3.4,
   already downloaded to `scrcpy-app/ADBClient/scrcpy-server`. Pushed to B via ADB.
2. **Native client lib `libscrcpy.so`** (runs on controller A) — the existing
   `porting/` C code (scrcpy client + SDL2 + FFmpeg + OpenSSL + adb-mobile),
   cross-compiled for Android. Entry point `scrcpy_main(argc, argv)`; weak
   `ScrcpyUpdateStatus()` callback; SW H.264 decode via FFmpeg (no VideoToolbox).
3. **Android app `android-app/`** (runs on controller A) — minimal Kotlin app built
   on SDL2's Android backend (`SDLActivity`) that owns the GL surface, starts a
   scrcpy session against B, and renders B's screen. Touches on the surface map to
   scrcpy control messages (handled inside the native lib's SDL event loop).

Connectivity in the e2e: both emulators sit on one Docker network. B runs
`adb tcpip 5555`; A's app (with embedded adb-mobile) connects to `B_IP:5555`,
pushes the server, opens the video+control streams.

---

## Milestones (each is an independently verifiable loop target)

### M0 — Scaffolding & red-but-running pipeline
- `android-app/` Gradle project (Kotlin, AGP, minSdk 26, target 36) that builds a
  debug APK (initially a stub Activity). Uses the same SDK image pattern as the
  proven d-claude harness (`eclipse-temurin:21-jdk` + cmdline-tools + sdkmanager +
  NDK + CMake).
- `e2e/` skeleton: `e2e/run.sh` (single entry script) + `e2e/Dockerfile` that boots
  **two** emulators and runs a placeholder assertion. Must run end-to-end on
  d-claude even before the real client exists (placeholder = "both emulators boot,
  adb sees both, B is controllable by a baseline tool"). This de-risks the harness
  before the native long-pole.
- **Accept:** `bash e2e/run.sh` on d-claude exits 0 with two booted emulators and a
  green placeholder; `android-app` debug APK builds in the build image.

### M1 — Native stack cross-compiled for Android x86_64 (emulator arch first)
- Add Android NDK targets to `porting/` build (new scripts, do **not** break iOS):
  FFmpeg, SDL2 (Android backend), OpenSSL, adb-mobile, then `libscrcpy` →
  `output/android/<abi>/`. Start with `x86_64` (matches emulator), add `arm64-v8a`.
- Replace iOS-only bits behind the NDK path: drop `OpenGLES/ES3` include
  (use SDL2 GLES), bypass VideoToolbox (`decoder-porting`/`display-porting` →
  software FFmpeg decode + SDL texture upload), Android clipboard via SDL or stub.
- **Accept:** `libscrcpy.so` + deps produced for `x86_64`; a tiny NDK smoke
  executable links `scrcpy_main` and prints usage without crashing.

### M2 — Android client app wraps the native lib
- App embeds SDL2 (`SDLActivity`/`SDLSurface`) + `libscrcpy.so`; a JNI/launch path
  calls `scrcpy_main` with `--adb=tcp:<B>:5555 ...` on a worker; implements
  `ScrcpyUpdateStatus` to surface connection state; surface receives touches that
  the native SDL loop turns into scrcpy control.
- Minimal UI: one screen to enter B's host:port and Connect; then the remote view.
- **Accept:** installed on an x86_64 emulator A, the app connects to emulator B and
  shows B's screen; a manual tap on A's surface moves B.

### M3 — Full GUI-automation e2e (the real gate)
- `e2e/run.sh` end-to-end: build image → boot B and A → `adb tcpip` on B → install
  our APK on A → launch it pointed at B → **uiautomator on A** taps a known
  location on the rendered remote view → assert (via dumpsys/uiautomator/screenshot
  **on B**) that B reacted to that exact input. Deterministic target on B (a tiny
  instrumented test app or a known launcher widget) so the assertion is stable.
- Idempotent, hermetic (pins SDK/image/NDK versions), cleans up, writes artifacts
  (logcat, screenshots) to a mounted dir. Few external assumptions: only Docker +
  `/dev/kvm`.
- **Accept:** `bash e2e/run.sh` green on d-claude across repeated runs (≥3 clean,
  incl. one cold run), proving A's app controls B.

### M4 — Reproducibility, hardening, review
- One-command build+run documented; arm64-v8a ABI added; flake hunt (10+ runs,
  100% green incl. cold); README/status updated; CI-ish wrapper.
- **Accept:** audit subagent confirms the locked goal is fully realized.

---

## Working agreement (per operator global rules)
- Work in 1-min **foreground** subagent loop; each iteration reads
  `ai/plans/STATE.md` (editable without restarting the loop) and advances the
  current milestone, running tests after small changes.
- Reproduce/iterate **locally / on d-claude** rather than idling.
- When a milestone looks done, a **foreground audit subagent** judges it; if
  incomplete it writes the next iteration's instructions into `STATE.md` and the
  loop continues. Repeat until the M4 audit says OK.
- English-only in repo; commit + run the harness before claiming success; never
  bypass hooks; push to `fork` remote on a branch; no force-push.

## Key risks / mitigations
- **Native cross-compile is the long pole** → do x86_64 first (emulator), keep iOS
  build intact, land the harness skeleton (M0) before M1 so failures isolate.
- **VideoToolbox/Metal assumptions** → NDK path uses SW decode; video fidelity is
  out of the done-bar (Q3), so don't block on HW decode.
- **GUI automation brittleness (Q2)** → use a deterministic input target on B and
  assert on B's state, not pixels of A; retry with backoff; capture artifacts.
- **SDL2 Android app structure** → follow SDL's `android-project` template so the
  Activity owns the surface and feeds events into the native loop.
