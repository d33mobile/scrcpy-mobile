# LIVE STATE (drawing e2e) — read this every loop iteration

Single source of truth for the drawing-e2e 1-min foreground loop. Editable mid-loop
without restarting. Plan: `ai/plans/drawing-e2e-plan.md`. (The main Android-controls-
Android goal is already DONE & audited — see `STATE.md`; do NOT break `e2e/run.sh`.)

## How each loop iteration works
1. Read this file + `ai/plans/drawing-e2e-plan.md`.
2. Pick the **first unchecked task** under "Current milestone".
3. Do it focused; run/verify on d-claude; commit (specific paths only — no `-a`, no
   `-A`, no `--no-verify`; trailer `Co-Authored-By: Claude Opus 4.8 (1M context)
   <noreply@anthropic.com>`); push to `fork` branch `android-controls-android`.
4. Update the checkbox + Progress log. Keep changes small.
5. If the whole milestone's accept-criteria are met, spawn a **foreground AUDIT**
   subagent. Pass → advance "Current milestone" + copy in next tasks. Fail → paste
   findings as new tasks.

## Hard rules (d-claude)
- Builds/e2e BLOCKING in your own context (long timeout); NEVER
  background-and-return (paused subagents get their builds killed).
- ONE e2e run at a time; emulators `mem=1536`; kill only stray `scrcpy-e2e`
  containers; NEVER touch `mf-e2e-*`/`redroid`/`ws-scrcpy`; self-clean on exit.
- Hermetic: bake any new build/runtime deps (draw-app gradle deps, python3+Pillow)
  into `e2e/Dockerfile`; the run stays `--network none`.
- Honesty: never fake green; record verbatim blockers; partial work stays unchecked.
- Reuse: `e2e/lib-net.sh` (bridge → `10.0.2.2:6555`), `e2e/lib-automation.sh`
  (A→B transform via 2 calibration taps), the connect flow in `e2e/run.sh`.

---

## Current milestone: **D1 — Drawing app on B + standalone stroke capture**

Accept: `e2e/draw-app/` builds; installed on ONE emulator, an `adb shell input
swipe` injected directly on it produces (a) a recorded multi-point stroke whose
start/end match the swipe and (b) visible red pixels along the path in that
emulator's screenshot. Draw-app gradle deps baked into the image. Verified on
d-claude.

### Tasks
- [x] Build `e2e/draw-app/` — a minimal standalone Gradle/Android project (mirror
      `e2e/target-app/`'s AGP 8.7.3 / Gradle 8.9 / Kotlin 2.0.21 setup), package
      `net.scrcpy.e2edraw`, fullscreen white `DrawActivity` with a custom drawing
      View: ACTION_DOWN/MOVE/UP capture strokes, draw thick bright-red (`#FF0000`,
      width ~12) polylines on a persistent Bitmap, record per-stroke geometry
      (points, start, end, bbox in device px) to channels: file
      `filesDir/e2e_draw.txt`, logcat tag `E2E_DRAW`, and a `strokes=N` summary.
      ALSO record single touches as `taps=N last=X,Y` (so `lib-automation.sh`
      calibration still works). Add `.gitignore` (build/, .gradle/).
- [ ] Verify standalone on d-claude in `scrcpy-e2e:dev` (BLOCKING): build the APK,
      boot ONE emulator, install + launch the draw app, `adb shell input swipe
      X0 Y0 X1 Y1 300`, then assert: (a) `e2e_draw.txt`/logcat show a stroke with
      points>2 and start≈(X0,Y0) end≈(X1,Y1) within tolerance; (b) `exec-out
      screencap -p` shows red pixels (count over threshold) with bbox spanning the
      path. Capture verbatim evidence. Write the assertion helpers into a new
      `e2e/lib-draw.sh` (e.g. `draw_install`, `draw_launch`, `draw_reset`,
      `draw_read_strokes`, `draw_swipe`, `draw_count_red` — the red-pixel analysis
      can shell out to a tiny tool; if it needs python3+Pillow, do the next task
      first or install transiently for this verify and bake it next).
- [ ] Bake draw-app gradle deps into the offline `GRADLE_USER_HOME` in
      `e2e/Dockerfile` (same priming pattern as android-app/target-app) AND add
      `python3` + `python3-pil` (Pillow) for screenshot color analysis. Rebuild
      `scrcpy-e2e:dev` (SDK/NDK/native-src/gradle layers must stay cached); verify
      the tools + draw-app deps are present in the image.

### Progress log
- 2026-06-04: Plan + STATE-drawing created. Goal: prove strokes work (A→B geometry)
  AND that drawn shapes are displayed back on A (red-pixel detection in A's
  screenshot). Starting D1.
- 2026-06-04: D1 task 1 DONE — built `e2e/draw-app/` (package `net.scrcpy.e2edraw`,
  activity `net.scrcpy.e2edraw.DrawActivity`, exported LAUNCHER, fullscreen WHITE
  `Theme.Light.NoTitleBar.Fullscreen` + explicit white view bg, `FLAG_KEEP_SCREEN_ON`,
  system bars hidden, `screenOrientation=sensor`). Mirrors target-app gradle setup
  exactly: AGP 8.7.3 / Gradle 8.9 / Kotlin 2.0.21, `compileSdk=36`, `minSdk=26`,
  `buildToolsVersion=37.0.0`, copied gradlew/wrapper jar+props/gradle.properties/
  .gitignore verbatim.
  * Touch handling: a deliberately NON-clickable custom `DrawView.onTouchEvent`
    (returns true for handled gestures so we receive the full DOWN→MOVE*→UP — the
    clickable-consumes-DOWN bug the target-app hit). ACTION_DOWN starts a stroke,
    ACTION_MOVE appends a point + draws a thick bright-red `#FF0000` segment
    (strokeWidth 12, ANTI_ALIAS, ROUND cap/join) from the prev point onto a
    PERSISTENT ARGB_8888 Bitmap (accumulates; re-created preserving content on
    onSizeChanged), ACTION_UP finalizes (pure DOWN+UP stamps a red dot).
    Coords via `event.getX()/getY()` rounded to int device px.
  * Recording channels (mirror target-app): FILE `filesDir/e2e_draw.txt` rewritten
    every stroke — one line per stroke `STROKE n points=K start=x0,y0 end=xN,yN
    bbox=minx,miny,maxx,maxy`, then a `taps=N last=X,Y` line, then `strokes=N`
    summary; LOGCAT tag `E2E_DRAW` (`stroke #n points=K start=.. end=.. bbox=..`
    per stroke and `tap #N at X,Y` per tap); on-screen small top-left
    semi-transparent TextView text+content-desc `strokes=N` for uiautomator
    (placed/sized so it doesn't obscure the canvas the red detector samples).
  * Tap vs stroke THRESHOLD: `TAP_SLOP_PX=16`. A gesture is a TAP when it has ≤1
    move-distinct point AND its bbox spans ≤16 px in BOTH axes (DOWN+UP, negligible
    movement); taps are ALSO recorded as `taps=N last=X,Y` so `lib-automation.sh`'s
    2-tap A→B calibration works unchanged. Any real `input swipe` (tens-hundreds px)
    is a stroke. 16 px is a few px above typical ViewConfiguration touch slop.
  * BUILD VERIFIED on d-claude in `scrcpy-e2e:dev`: rsynced draw-app to
    `/srv/work/scrcpy-mobile-e2e/e2e/draw-app/`, `docker run` (repo at /workspace,
    `-v scrcpy-gradle-cache:/root/.gradle`) `./gradlew --no-daemon assembleDebug` →
    `BUILD SUCCESSFUL in 1m 38s`, produced `app/build/outputs/apk/debug/app-debug.apk`
    (821737 bytes). `aapt2 dump badging` → `package: name='net.scrcpy.e2edraw'`,
    `launchable-activity: name='net.scrcpy.e2edraw.DrawActivity'`. Dex byte-search
    confirms `Lnet/scrcpy/e2edraw/DrawActivity;`, `…/DrawView;`, `…/Stroke;` present
    (in classes3.dex; classes.dex is Kotlin stdlib).
  * NOTE: this FIRST build used the NETWORK gradle cache (`scrcpy-gradle-cache`
    volume, NO `--offline`/`--network none`), because baking the draw-app deps into
    the offline `GRADLE_USER_HOME=/opt/gradle-home` is the LATER D1 bake task. The
    on-emulator swipe→stroke + red-pixel assertion is the NEXT D1 task.

## Backlog (next milestones — see plan for full accept criteria)
- D2 — Stroke from A → control assertion on B (two emulators, connect, swipe on A,
  assert B recorded the scaled stroke).
- D3 — Display round-trip: red shape visible in A's screenshot at expected location;
  add a multi-segment shape.
- D4 — `e2e/run-draw.sh` one script, hermetic `--network none`, reliably green ≥3
  incl. cold; final audit → done → stop loop.
