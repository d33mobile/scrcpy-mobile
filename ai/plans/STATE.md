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
- [ ] Decide & document the Android build image (reuse the proven d-claude pattern:
      `eclipse-temurin:21-jdk` + cmdline-tools + sdkmanager: platform-tools,
      `platforms;android-36`, build-tools, `ndk;<pin>`, `cmake;3.22.1`,
      `emulator`, `system-images;android-30;google_apis;x86_64`). Write
      `e2e/Dockerfile` for it.
- [ ] Scaffold `android-app/` Gradle project (Kotlin, AGP, minSdk 26, target 36),
      a stub `MainActivity`, `:app` module, that produces `app-debug.apk`.
      Add `android-app/.gitignore` (build/, .gradle/, local.properties).
- [ ] Write `e2e/run.sh` — single entry script: build image, start two emulators
      (A + B) on one docker network, wait for boot, run a **placeholder**
      assertion (both `adb` online; B controllable by a baseline `adb shell input`
      tap that changes a dumpsys value). Exit non-zero on any failure. Make it
      idempotent and self-cleaning; artifacts to a mounted dir.
- [ ] Make `e2e/run.sh` parameterizable so it can run locally or via
      `ssh d-claude`. Provide a thin `e2e/run-on-d-claude.sh` that rsyncs the repo
      to `/srv/work/scrcpy-mobile-e2e` and invokes `run.sh` there.
- [ ] Run the placeholder e2e on d-claude; iterate until green. Capture logs to
      `ai/plans/runlogs/`.

### Progress log
- 2026-06-01: Repo forked → `d33mobile/scrcpy-mobile`; branch
  `android-controls-android` created; README overwritten (WIP + goal); master plan
  + research written. Starting M0.

---

## Backlog (next milestones — see master plan for full accept criteria)
- M1 — Native stack cross-compiled for Android x86_64 (then arm64-v8a).
- M2 — Android client app wraps `libscrcpy.so` (connects to B, shows screen,
  touches propagate).
- M3 — Full GUI-automation e2e: uiautomator taps A's remote view, assert B reacts.
- M4 — Reproducibility/flake-hunt/arm64/review until audit says fully realized.
