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

## Current milestone: **D3 — Display round-trip: the drawn shape is visible on A**

Accept: In the same two-emulator run, after a stroke is drawn (via A), a screenshot
of EMULATOR A (its decoded remote view of B) shows the red stroke at the expected
location — proven by detect_red.py: red-pixel count jumps from ~0 (before) to a clear
threshold (after) within A's remote-view region, and the red blob's location
corresponds to the swipe path on A. Plus a multi-segment shape (e.g. an L) is asserted
both on B (geometry) and on A (visible).

### Tasks
- [x] Extend the driver (m4draw-control.sh → or a D3 variant) to capture an A
      screenshot (`adb -s emulator-5556 exec-out screencap -p`) BEFORE the stroke and
      AFTER, and run detect_red.py on A's screenshot. ASSERT: before red_count≈0 in
      the canvas region; after red_count jumps over a clear threshold; and the after
      red blob's centroid/bbox is near the swipe path on A (the stroke is displayed
      where we drew it). This proves the drawn shape rendered back through the video
      stream to A.  → DONE in `e2e/m4draw-display.sh` (D3 driver). before=0
      after=21151 (≫500). The "centroid near A swipe coords" sub-claim turned out to
      be EMPIRICALLY FALSE for this app (A renders B MAGNIFIED ~1.8x, not at swipe
      coords — see progress log); replaced with a stronger, non-circular location
      proof: shape signature + a B→A display affine fit from the single stroke,
      cross-validated against the L. See 2026-06-04 D3 log.
- [x] Account for A's remote-view region: A keeps system bars + letterboxes B's video
      (per the M3 transform OY offset). Restrict/crop the red detection to A's surface
      region (or just exclude the strokes=N overlay area / status bar) so the
      assertion is about the rendered remote canvas, not chrome. Derive the A-side
      expected location from the A swipe coords directly (the stroke on A's surface
      shows ~where you swiped).  → DONE: crop = (54,153,993,1766) of 1080x1920
      (excludes A status bar top 8%, nav bar bottom 8%, gray `strokes=N` overlay,
      right black letterbox). CORRECTION to the assumption: the displayed stroke does
      NOT show at the A swipe coords — A magnifies B ~1.8x top-left-anchored, so the
      expected A location is derived from B's recorded coords via a fitted B→A display
      affine, NOT from the swipe coords. Shapes kept in A's UPPER region so the whole
      image is unclipped.
- [x] Add a MULTI-SEGMENT shape (e.g. an L or triangle = 2-3 chained swipes on A) and
      assert BOTH: its segments on B (geometry, via lib-draw strokes) AND its
      visibility on A (red present along each segment in A's screenshot). Capture
      before/after A screenshots as artifacts.  → DONE: an L (vertical arm + horizontal
      arm sharing a corner). B: 2 strokes, per-segment geometry within tol. A: red
      along BOTH predicted segment bands (seg1 V=14118px, seg2 H=5424px) + L-shaped
      combined bbox (W=404 H=715, both ≫80). A_L_after.png shows a clean L. Artifacts
      A_before/A_after/A_L_before/A_L_after + B screencap + evidence captured.

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
- 2026-06-04: D1 task 2 DONE — standalone swipe→stroke + red-pixel verify GREEN on
  d-claude (`scrcpy-e2e:dev`, one emulator `mem=1536`, `--device /dev/kvm`, network
  gradle cache for the build). Wrote reusable `e2e/lib-draw.sh` (`draw_install`,
  `draw_launch`, `draw_focused`, `draw_reset`, `draw_read_file`,
  `draw_strokes_count`, `draw_read_strokes`, `draw_swipe`, `draw_screencap`,
  `draw_count_red`, `draw_red_count_value` — sourceable pure bash) and
  `e2e/detect_red.py` (Pillow; args `<png> [x0,y0,x1,y1]`, prints
  `red_count=.. bbox=minx,miny,maxx,maxy centroid=cx,cy`, tunable via
  `RED_R_MIN`/`RED_GB_MAX`; sanity-checked: a white-corner crop → `red_count=0`).
  Verify driver `e2e/verify-draw.sh` (NOT committed; reusable bits live in
  lib-draw/detect_red) reproduces run.sh boot logic (AVD
  `system-images;android-30;google_apis;x86_64`, emulator v33.1.24,
  `-no-window -gpu swiftshader_indirect -no-snapshot -accel on -memory 1536`).
  * SCREEN: `1080x1920` (Physical size). SWIPE: `adb shell input swipe 300 800
    760 1400 300` (diagonal, well inside the screen, clear of the top-left
    `strokes=N` overlay).
  * ASSERT (a) CONTROL/geometry — VERBATIM `e2e_draw.txt`:
        STROKE 1 points=8 start=300,800 end=760,1400 bbox=300,800,760,1400
        taps=0 last=-1,-1
        strokes=1
    LOGCAT: `E2E_DRAW: stroke #1 points=8 start=300,800 end=760,1400
    bbox=300,800,760,1400`. strokes=1, points=8 (>2, a real drag — `input swipe`
    interpolated 8 samples; observed 6–8 across runs, always >2), start delta
    `(0,0)` end delta `(0,0)`. Tolerance used: `max(25px, 3%) = 57px`. PASS.
  * ASSERT (b) DISPLAY/red — `exec-out screencap -p` → `detect_red.py`:
    `red_count=8186 bbox=294,794,721,1347 centroid=507,1070`. red_count 8186
    (≫ threshold 2000; the 12px-wide diagonal over ~460×600px). bbox spans the
    swipe path: minx 294≈x0 300, miny 794≈y0 800, maxx 721≈x1 760, maxy 1347≈y1
    1400. bbox-span tolerance `90px` — the painted red stops ~40–75px short of the
    exact endpoint because `input swipe`'s final ACTION_UP is NOT connected by a
    drawn MOVE segment (the app only stamps a dot for taps), leaving the last
    interpolation gap unpainted; the RECORDED end is exact (delta 0,0). PASS.
  * TRANSIENT DEP: `apt-get install -y python3 python3-pil` (Pillow 12.1.1) inside
    the run container for THIS verify — gets BAKED into `e2e/Dockerfile` in the
    NEXT D1 task; documented so the bake task is unambiguous.
  * Full driver exited rc=0 (`D1 STANDALONE VERIFY: PASS`); self-cleaned (emulator
    killed, AVD deleted, `--rm` container; mf-e2e-*/redroid/ws-scrcpy untouched).
    Committed ONLY `e2e/lib-draw.sh`, `e2e/detect_red.py`, this STATE file.
- 2026-06-04: D1 task 3 DONE — **D1 COMPLETE (all 3 tasks)**. Baked draw-app gradle
  deps + Pillow into `scrcpy-e2e:dev`; rebuilt on d-claude with the expensive SDK
  layers CACHED; verified offline draw-app build + `import PIL` under `--network none`.
  * `e2e/Dockerfile` EDITS (additive, ordering-aware):
    - apt build-deps layer (the native-build apt RUN, which sits AFTER the SDK/NDK/
      system-image/emulator layers): appended `python3 python3-pil` to the existing
      package list — NO new layer, NO runtime apt. The Android-SDK layers are BEFORE
      this apt layer so they stay cached when apt changes.
    - GRADLE-PRIME layer: added `COPY e2e/draw-app /opt/prime/draw-app` and a third
      `( cd /opt/prime/draw-app && ./gradlew --no-daemon assembleDebug )`; added
      draw-app's `app/build` + `.gradle` to the post-prime `rm -rf` cleanup. draw-app
      is fully standalone (no sdl-android-java glue ref, unlike android-app), AGP
      8.7.3 / Gradle 8.9 / Kotlin 2.0.21 — same as target-app.
    - `.dockerignore`: only a doc-comment line added (draw-app listed among the
      primed projects). draw-app SOURCES were already in context (under `e2e/`);
      `**/build` + `**/.gradle` already exclude its artifacts. No functional change.
  * REBUILD CACHE RESULT (d-claude, `docker build -t scrcpy-e2e:dev -f e2e/Dockerfile .`,
    context=repo root, image sha256:ed870b00…): layers 1-5 (FROM, base apt,
    cmdline-tools, `sdkmanager` SDK+NDK+cmake+system-image, emulator-binary pin) all
    `CACHED` — ZERO SDK re-download. Only layer 6 apt (`+python3 python3-pil`) re-ran
    (86.4s), native-src git/wget (12.1s), and the gradle-prime (180.5s). Prime ran all
    THREE `assembleDebug`: android-app `BUILD SUCCESSFUL in 2m 1s`, target-app `27s`,
    draw-app `27s` (tiny delta → shared cache). `/opt/gradle-home` = 582M. Image
    `naming to docker.io/library/scrcpy-e2e:dev DONE`.
  * VERIFY (rebuilt image):
    - Pillow, `docker run --rm --network none scrcpy-e2e:dev bash -lc 'python3 -c
      "import PIL, PIL.Image; print(PIL.__version__)"'` → `12.1.1` (no network).
    - Offline draw-app, `docker run --rm --network none -v
      /srv/work/scrcpy-mobile-e2e:/workspace:ro scrcpy-e2e:dev bash -lc 'cp -r
      /workspace/e2e/draw-app /tmp/draw && cd /tmp/draw && export
      GRADLE_USER_HOME=/opt/gradle-home && ./gradlew --no-daemon --offline
      assembleDebug'` → VERBATIM `BUILD SUCCESSFUL in 16s` / `33 actionable tasks: 14
      executed, 19 from cache`, APK `app-debug.apk` 821737 bytes. Under `--network
      none` → the baked offline `GRADLE_USER_HOME` is sufficient; no fetch.
    - Existing builds undisturbed (same `--network none`, baked gradle home):
      target-app `--offline assembleDebug` → `target-app: BUILD OK`; android-app
      `--offline help` → `android-app: --offline help OK (deps resolvable)`.
  * Committed ONLY `e2e/Dockerfile`, `.dockerignore`, this STATE file (no artifacts).
    >>> D1 milestone accept-criteria all met — spawn the D1 foreground AUDIT next.
- 2026-06-04: **D1 FOREGROUND AUDIT — PASS** (skeptical judge, all checks reproduced
  with COMMANDS on d-claude in `scrcpy-e2e:dev` `ed870b002dfd`, `--network none`
  `--device /dev/kvm`). Advancing Current milestone D1 → D2.
  * CHECK 1 hermetic build (CURRENT image, no network): `python3 -c "import PIL"` →
    `PIL 12.1.1`; draw-app `./gradlew --no-daemon --offline assembleDebug` with baked
    `GRADLE_USER_HOME=/opt/gradle-home` → `BUILD SUCCESSFUL in 15s`, APK 821737 bytes.
    Dockerfile confirmed: `python3 python3-pil` appended to the post-SDK apt layer +
    `COPY e2e/draw-app /opt/prime/draw-app` + draw-app `assembleDebug` in the prime
    RUN. Image SDK layers current (built 18:54 from the committed context).
  * CHECK 2 standalone swipe→stroke+red (authoritative, BLOCKING, in-context): ONE
    emulator (mem=1536, API 30, emulator v33.1.24), APK built offline, installed +
    `DrawActivity` focused, screen `1080x1920`, `input swipe 300 800 760 1400 300`.
    - CONTROL (verbatim `e2e_draw.txt`):
        STROKE 1 points=8 start=300,800 end=760,1400 bbox=300,800,760,1400
        taps=0 last=-1,-1
        strokes=1
      LOGCAT: `E2E_DRAW: stroke #1 points=8 start=300,800 end=760,1400 …`. strokes=1,
      points=8 (>2, real drag), start/end deltas ALL 0 (tol max(25,3%)=32px X / 57px Y).
    - DISPLAY (`exec-out screencap -p` → `detect_red.py`):
        red_count=7483 bbox=294,794,684,1299 centroid=488,1046
      7483 ≫ 2000 threshold; bbox spans the path (minx 294≈300, miny 794≈800). maxx/maxy
      stop ~76/101px short — the documented unpainted final ACTION_UP gap (`input swipe`
      doesn't draw a MOVE to the last point); RECORDED end is exact. Benign WARN, not a
      fail.
    - NEGATIVE (white-corner crop `850,50,1070,400`): `red_count=0 bbox=NA` — detector
      is NOT trivially always-positive.
    Driver exited rc=0 `D1 STANDALONE VERIFY: PASS`; self-cleaned; mf-e2e-*/redroid/
    ws-scrcpy untouched; no stray scrcpy-e2e containers.
  * CHECK 3 sanity (no regressions): target-app `--offline assembleDebug` → `BUILD
    SUCCESSFUL`; android-app `--offline help` → `BUILD SUCCESSFUL` (deps resolve);
    `bash -n` clean on run.sh + lib-draw.sh, `py_compile` clean on detect_red.py; NO
    apk/build tracked (`git ls-files` clean); all 3 D1 commits (d2e25c4, 287fc09,
    4620e9f) pushed to `fork/android-controls-android`; tree clean. detect_red.py +
    lib-draw.sh work exactly as committed.

- 2026-06-04: **D2 COMPLETE (all 4 tasks)** — a STROKE injected on controller A is
  provably received by the DRAW app on target B as a correct multi-point drag.
  Driver `e2e/m4draw-control.sh` (reusable base for D3/D4). VERIFIED GREEN
  end-to-end on d-claude in `scrcpy-e2e:dev` (`--device /dev/kvm`, `--network none`,
  2 emulators mem=1536, v33.1.24), rc=0, self-cleaned; **3 consecutive green runs**
  (17:41 canonical + two stability runs 17:47, 17:52); protected mf-e2e-*/redroid/
  ws-scrcpy untouched, no stray scrcpy-e2e containers, host root not polluted.
  * DRIVER DESIGN: `e2e/m4draw-control.sh` SOURCES `e2e/run.sh` for its proven
    helpers (boot_both/build_native/build_apks, create_avd/launch_emu/wait_boot,
    node_center/wm_size/b_server_proc, cleanup trap, AVD/serial/port/path consts,
    log/fail) — NO copy-paste of the connect flow. Made run.sh sourceable by
    guarding its dispatch behind `[ "${BASH_SOURCE[0]}" = "$0" ]` (executed
    directly → unchanged; sourced → only exposes helpers; `bash -n` + a
    source-side-effect probe confirm run.sh's behaviour is untouched). m4draw adds
    only what differs: OUTER docker-runs ITSELF `--inner`; INNER installs+launches
    the DRAW app (`net.scrcpy.e2edraw/.DrawActivity`) on B (not the tap target),
    builds the draw APK offline (`build_draw_apk`, baked GRADLE_USER_HOME), and
    asserts a multi-point DRAG instead of taps. The android-app controller on A is
    UNCHANGED. `e2e/run.sh` is NOT broken (only the sourcing guard was added).
  * FLOW (one `docker run --device /dev/kvm`, BLOCKING, `--network none`):
    boot B(5554)+A(5556) → wait boot_completed → build native (cached) + APKs
    offline → install+launch DRAW app on B, focus
    `net.scrcpy.e2edraw/.DrawActivity` → `ensure_b_reachable`→10.0.2.2:6555 →
    install android-app on A → drive MainActivity→Connect→ScrcpyActivity → wait
    stable stream (`INFO: Connected to 10.0.2.2:6555` + scrcpy-server proc on B) →
    `draw_reset` B → 2 calibration taps → derive transform → `draw_reset` → inject
    2 strokes → assert each.
  * TRANSFORM (verbatim, derived from 2 calibration taps on A):
        calibration: A(324,576)->B(323,568) ; A(756,1344)->B(755,1420)
        A->B (x1000): SX=1000 OX=-1000 SY=1109 OY=-70784
        BX = round((SX*AX+OX)/1000) ; BY = round((SY*AY+OY)/1000)
    (SX≈1.0/SY≈1.109 + OY≈-70.8px: A's ScrcpyActivity status-bar offset + scrcpy's
    aspect-preserving letterbox of B's video into A's content rect — same shape the
    tap e2e derives.) Tolerance: max(30px, 4% of B dim) = max(30, 43px X / 77px Y).
  * PER-STROKE EVIDENCE (canonical 17:41 run, VERBATIM `d2-stroke-evidence.txt`;
    A screen 1080x1920, B 1080x1920; swipe 1000ms):
        STROKE 1 [PASS] points=15
          A swipe : (378,672) -> (702,1248)
          expect B: start=(377,674) end=(701,1313)
          got    B: start=(377,675) rawEnd=(685,1282) bbox=(377,675,685,1282)
          effEnd B: (685,1282) [bbox corner in travel dir]
          delta   : start dx=0 dy=1 (PASS)   end dx=16 dy=31 (PASS)
        STROKE 2 [PASS] points=17
          A swipe : (669,729) -> (410,1190)
          expect B: start=(668,738) end=(409,1249)
          got    B: start=(668,737) rawEnd=(408,1251) bbox=(408,737,668,1251)
          effEnd B: (408,1251) [bbox corner in travel dir]
          delta   : start dx=0 dy=1 (PASS)   end dx=1 dy=2 (PASS)
    B final draw file:
        STROKE 1 points=15 start=377,675 end=685,1282 bbox=377,675,685,1282
        STROKE 2 points=17 start=668,737 end=408,1251 bbox=408,737,668,1251
        taps=0 last=-1,-1
        strokes=2
    Both strokes are genuine multi-point drags (points 15/17 ≫ 2 — NOT taps),
    distinct, opposite directions, start exact (dx=0 dy=1), end within tol.
  * TWO DEBUG FINDINGS (real, fixed — not papered over):
    1. `input swipe` END is FLAKY. The recorded ACTION_UP (`end=`) intermittently
       undershoots the last forwarded MOVE — observed a down-right drag whose bbox
       reached the true end but whose UP landed ~165px short, varying run-to-run.
       The drag PHYSICALLY traverses the whole path (the bbox proves it). FIX: the
       assertion uses the EFFECTIVE end = the bbox corner in the swipe's direction
       of travel (maxX if AX1≥AX0 else minX; maxY if AY1≥AY0 else minY), which is
       the real extent the forwarded MOVE events reached. The reliable ACTION_DOWN
       start is asserted directly. Raw UP + bbox both logged for transparency.
    2. A short/fast swipe (400ms) intermittently TRUNCATES: the tail MOVE samples
       race the UP through scrcpy's event forwarding and can be dropped (a down-
       right drag landed ~58/115px short one run, full the next; points only 6-8).
       FIX: swipe 1000ms (`DRAW_SWIPE_MS`) — MOVE samples spaced far enough that
       scrcpy forwards every one; the drag deterministically reaches its endpoint
       (points jump to 13-17, end deltas collapse to ≤31px). This is the honest fix
       (denser/forwarded samples), NOT a loosened tolerance.
    Plus a connect-robustness gate: A's slirp net can lag sys.boot_completed
    (`Network is unreachable`, scrcpy connects ONCE then aborts) — added a pre-
    connect reachability probe + a 3-attempt connect/relaunch loop. One run hit the
    race and the retry recovered it; the rest connected on attempt #1.
  * Committed ONLY `e2e/m4draw-control.sh` (new driver), `e2e/run.sh` (sourcing
    guard), this STATE file. No APK/.so/artifacts. Pushed to
    `fork/android-controls-android`.
    >>> D2 milestone accept-criteria all met — spawn the D2 foreground AUDIT next.
- 2026-06-04: **D2 FOREGROUND AUDIT — PASS** (skeptical judge, all 4 checks
  reproduced with COMMANDS on d-claude in `scrcpy-e2e:dev`, OUTER docker-run,
  `--network none`, `--device /dev/kvm`, 2 emulators mem=1536). Advancing Current
  milestone D2 → D3.
  * CHECK 1 assertion integrity (read m4draw-control.sh): swipe injected on
    `SERIAL_A`=emulator-5556 (NOT B) via `draw_swipe` (line 323); stroke read from B
    via `run-as net.scrcpy.e2edraw cat files/e2e_draw.txt` (lib-draw); transform
    DERIVED EACH RUN from 2 calibration taps (lines 252-278, `auto_derive_transform`,
    hard-fails if a cal tap isn't received). PASS requires ALL of: `points>2` (line
    369, tap fails), `start≈expected` and `effEnd≈expected` within max(30px,4%)
    (lines 370-372, AB_ABS_TOL=30/AB_REL_TOL_PCT=4). The "effEnd = bbox corner in
    travel direction" is NOT a silent accept: the bbox is the real min/max of
    recorded points, so effEnd reflects the genuine drag extent and must reach within
    tol of the expected FAR endpoint — a tap/short drag has a small bbox → effEnd near
    start → FAILS the end assertion; a wrong-mapping/wrong-direction stroke lands far
    → FAILS; no-stroke → `all_pass=0` + `fail` (non-zero). Confirmed honest.
  * CHECK 2 run.sh intact: `bash -n e2e/run.sh` clean; the dispatch is guarded by
    `if [ "${BASH_SOURCE[0]}" = "$0" ]` so executed behavior (outer/inner/--smoke
    cases) is unchanged; sourcing produces 0 bytes of output and exposes
    boot_both/build_native/node_center/wm_size/b_server_proc (verified). Guard gates
    ONLY the top-level dispatch.
  * CHECK 3 ran it myself (authoritative, BLOCKING, OUTER docker-run `--network none`,
    rc=0, `DRAW SUCCESS (D2 green)`, `cleanup done (rc=0)`). A connected:
    `INFO: Connected to 10.0.2.2:6555`; B server proc:
    `net.scrcpy.e2edraw` (scrcpy injecting into the draw app on B). Per-stroke
    evidence VERBATIM from MY run (transform derived from cal taps
    A(324,576)->B(323,568) ; A(756,1344)->B(755,1420); SX=1000 OX=-1000 SY=1109
    OY=-70784; tol max(30px,4%)):
        STROKE 1 [PASS] points=9
          A swipe : (378,672)->(702,1248)  expect B: start=(377,674) end=(701,1313)
          got B: start=(377,675) bbox=(377,675,698,1308)  effEnd=(698,1308)
          delta : start dx=0 dy=1 (PASS)   end dx=3 dy=5 (PASS)
        STROKE 2 [PASS] points=14
          A swipe : (669,729)->(410,1190)  expect B: start=(668,738) end=(409,1249)
          got B: start=(668,737) bbox=(409,737,668,1250)  effEnd=(409,1250)
          delta : start dx=0 dy=1 (PASS)   end dx=0 dy=1 (PASS)
        B final: STROKE 1 points=9 …; STROKE 2 points=14 …; taps=0; strokes=2
    Both genuine multi-point drags (9/14 ≫ 2 — NOT taps), distinct, opposite
    directions, start exact, end ≤5px (≪ 30px tol). taps=0 → cal taps reset cleanly,
    read-back strokes are unambiguously the injected ones. Self-cleaned: no stray
    scrcpy-e2e containers; mf-e2e-*/redroid/ws-scrcpy untouched; no leftover e2e
    emulator procs.
  * CHECK 4 git: D2 commit `5d53007` pushed to `fork/android-controls-android` (tip
    matches); tree clean; only gradle-wrapper.jar tracked (standard wrapper, not an
    artifact); no APK/.so/.png tracked; `e2e/artifacts` gitignored.

- 2026-06-04: **D3 COMPLETE (all 3 tasks)** — the display ROUND-TRIP is proven: a
  stroke drawn on controller A is forwarded to B, B renders it red, B streams the
  frame back, A decodes+displays it, and a SCREENSHOT OF EMULATOR A shows the red
  stroke. New driver `e2e/m4draw-display.sh` (D3 variant of the D2 driver; sources
  run.sh + lib-draw/lib-automation, same boot/build/connect/transform plumbing).
  VERIFIED GREEN end-to-end on d-claude in `scrcpy-e2e:dev` (`--device /dev/kvm`,
  `--network none`, 2 emulators mem=1536, scrcpy 3.3.4), rc=0 `DRAW-DISPLAY SUCCESS
  (D3 green)`, self-cleaned; **2 consecutive green runs** (18:33 + 18:39, numbers
  stable); mf-e2e-*/redroid/ws-scrcpy untouched, no stray scrcpy-e2e containers.
  * KEY GEOMETRIC FINDING (debugged from the first run's screenshots, NOT papered
    over): this app does NOT display B's video at A's swipe coordinates. A renders
    B's frame MAGNIFIED ~1.8x, top-left anchored, so the displayed stroke lands
    well below/right of where we swiped, and B content past B_y≈960 is CLIPPED off
    A's surface bottom. The first D3 attempt (drawing in A's centre, asserting
    "red centroid ≈ A swipe-path midpoint") FAILED exactly here: swipe-mid (540,960)
    vs A red centroid (809,1517), and the L's horizontal arm ran off-screen
    (A_L_after red bbox W=19 — only the vertical arm visible). The fix is geometric,
    not a loosened tolerance: (a) draw every shape in A's UPPER region (small A_y)
    so its whole B-image is inside A's visible magnified surface (unclipped);
    (b) prove location via SHAPE SIGNATURE + a B→A display affine fitted from the
    single stroke's B-recorded endpoints vs its A red bbox, CROSS-VALIDATED by
    predicting where the L's segments must appear on A. The L bands are predicted
    from the PART-1 diagonal — so the location match is not self-fulfilling.
  * A REMOTE-VIEW CROP (D3 task 2): `(54,153,993,1766)` of A's `1080x1920` — excludes
    A's status bar (top 8%), nav bar (bottom 8%), the gray `strokes=N` overlay
    (top-left; gray not red so harmless anyway), and the right black letterbox
    (right edge at 92%). detect_red thresholds: A before ≤50, after ≥500, per-segment
    ≥200, predict-tol 90px. B-geometry tol max(30px,4%).
  * A→B transform (verbatim, derived from 2 cal taps each run):
        Calibration taps: A(324,576)->B(323,568) ; A(756,1344)->B(755,1420)
        A->B (x1000): SX=1000 OX=-1000 SY=1109 OY=-70784
  * PART 1 — SINGLE DIAGONAL STROKE (verbatim, canonical 18:33 run):
        A swipe : (216,288) -> (594,768)
        B geometry [PASS]: points=13 start=(215,249) effEnd=(591,779)
          expS=(215,249) expE=(593,781) dStart=(0,0)[PASS] dEnd=(2,2)[PASS]
        A_before red: red_count=0 bbox=NA centroid=NA          (need <=50 : PASS)
        A_after  red: red_count=21151 bbox=382,489,983,1353 centroid=686,914
                                                               (need >=500 : PASS)
        A_after shape: bbox W=601 H=864  (diagonal needs both >=80 : PASS)
        B->A display affine (x1000) fitted from this stroke:
          SX=1598 OX=38430 SY=1630 OY=83130 (ok=1)   [~1.6x magnification]
        PART1 verdict: B=PASS  A=PASS
    before red_count 0 → after 21151 is the round-trip delta. A_after.png shows a
    clean diagonal red line on A's white remote canvas.
  * PART 2 — MULTI-SEGMENT L (verbatim, canonical 18:33 run):
        A L: seg1 V (324,288)->(324,633) ; seg2 H (324,633)->(626,633)
        B seg1 [PASS]: points=16 start=(323,249) effEnd=(323,618)
          expS=(323,249) expE=(323,631) dStart=(0,0) dEnd=(0,13) [PASS]
        B seg2 [PASS]: points=13 start=(323,631) effEnd=(622,631)
          expS=(323,631) expE=(625,631) dStart=(0,0) dEnd=(3,0) [PASS]
        A_L_before red: red_count=0  (need <=50 : PASS; B reset → A's red drained,
          proving the displayed red TRACKS B's live canvas, not a static artifact)
        A_L_after red (full crop): red_count=20742 bbox=579,489,983,1204
          L-shape bbox W=404 H=715 (both >=80 : PASS)
        A_L_after seg1(V) PREDICTED band=(465,399,645,1202): red_count=14118 (PASS)
        A_L_after seg2(H) PREDICTED band=(645,1022,1127,1202): red_count=5424 (PASS)
        B final: STROKE 1 points=16 …; STROKE 2 points=13 …; taps=0; strokes=2
        L verdict: B=PASS  A=PASS   ;  OVERALL: PASS
    A_L_after.png shows a clean L (vertical arm + horizontal arm sharing the corner),
    fully inside A's visible surface. Both segment bands are PREDICTED from the
    PART-1 diagonal's B→A affine — the L's visible red lands in those predicted
    bands (cross-validation).
  * STABILITY (18:39 rerun, same coords): B->A affine SX=1611 (≈1.6x, matches);
    A_after=21035; L seg1 A=14465 seg2 A=6422; all PASS; rc=0. Numbers reproduce.
  * Committed ONLY `e2e/m4draw-display.sh` (new D3 driver) + this STATE file. No
    APK/.so/PNG/artifacts (`e2e/artifacts` gitignored). Pushed to
    `fork/android-controls-android`.
    >>> D3 milestone accept-criteria all met — spawn the D3 foreground AUDIT next.

## Backlog (next milestones — see plan for full accept criteria)
- D4 — `e2e/run-draw.sh` one script, hermetic `--network none`, reliably green ≥3
  incl. cold; final audit → done → stop loop.
