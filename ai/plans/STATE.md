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

## Current milestone: **M3 — Full GUI-automation two-emulator e2e (THE GOAL GATE)**

(M0 — Scaffolding & red-but-running pipeline — **PASSED audit 2026-06-01**.
M1 — Native stack cross-compiled for Android x86_64 — **PASSED audit 2026-06-01**;
`libscrcpy.so` + deps build green and the NDK smoke exe runs `scrcpy_main --help`
cleanly on the bionic linker.
M2 — Android client app wraps the native lib — **PASSED audit 2026-06-01**; clean
rebuild links + exports `T scrcpy_android_main` + `T scrcpy_main`, the APK bundles
all three .so + the SDL glue, and a fresh-emulator launch enters scrcpy_main and
runs the native client with zero crashes. See progress log.)

Accept: `bash e2e/run.sh` on d-claude (one script) boots TWO emulators (B=target,
A=controller running our APK), A's app connects to B over ADB-over-TCP and renders
B's screen, then UI automation on A taps the rendered remote view and the test
asserts B reacted to that exact input; reliably green across repeated runs incl. a
cold run.

### Tasks
- [x] Solve A→B reachability in the harness: boot both emulators; expose B's
      adb-over-tcp (`adb tcpip 5555` on B) at an address emulator A's in-process adb
      can reach (e.g. forward B:5555 to the container host, A connects via
      10.0.2.2:PORT). Verify from inside A that the target is reachable. Document the
      address scheme. **DONE 2026-06-01 — A reaches B's adbd at `10.0.2.2:6555` via a
      host-side socat `0.0.0.0:6555 -> 127.0.0.1:5555` bridge; verified by adbd CNXN
      banner received inside A. See progress log + `e2e/lib-net.sh`.**
- [x] Put a DETERMINISTIC input target on B (a known app/activity or widget whose
      state is checkable via dumpsys/uiautomator), so a tap at a known coordinate
      produces an unambiguous, assertable state change on B. **DONE 2026-06-01 —
      purpose-built `net.scrcpy.e2etarget/.TargetActivity` records every tap on 3
      channels (uiautomator text, logcat, run-as file); tap at (X,Y) -> recorded
      X,Y in device pixels with dx=dy=0. See progress log + `e2e/target-app/`,
      `e2e/lib-target.sh`.**
- [x] Drive A: launch MainActivity → enter B's reachable host:port → Connect →
      ScrcpyActivity; confirm via A's logcat the session reaches Connected
      (ScrcpyUpdateStatus Connected) and scrcpy-server is running on B (pidof /
      dumpsys on B). **DONE 2026-06-01 — A's in-app scrcpy connects to B at
      `10.0.2.2:6555`, PUSHES + LAUNCHES scrcpy-server on B, reaches Connected,
      and renders B's screen. 2/2 runs green. See progress log +
      `e2e/m3-connect.sh`, `e2e/m3-build-and-connect.sh`.**
- [x] Full GUI automation: with uiautomator/adb `input` ON EMULATOR A, tap a known
      coordinate over the rendered remote-view surface; map it to the expected
      coordinate on B; assert via B (uiautomator/dumpsys/screencap) that B received
      that exact input. Handle the coordinate scaling (A's surface → B's resolution).
      **DONE 2026-06-01 — 5 taps injected on A's remote-view surface; ALL received by
      B at the expected coordinate (4/5 with dx=dy=0, worst dx=1px); count 5/5. The
      A→B transform (X 1:1; Y scale 1.109 + offset −70.8px from A's status bar /
      letterboxing) was derived empirically from 2 calibration taps and the 3
      validation taps fit it. See progress log + `e2e/lib-automation.sh`,
      `e2e/m3-automation.sh`, `e2e/m3-build-and-automate.sh`.**
- [ ] Wire this as the REAL e2e in e2e/run.sh (replace the M0 placeholder
      assertion): two emulators, connect, automate, assert; idempotent,
      self-cleaning, artifacts (logcat A+B, screenshots) to mounted dir, correct exit
      codes.
- [ ] Make it reliably green: run `bash e2e/run.sh` via run-on-d-claude.sh ≥3 times
      incl. one cold run; 100% pass. Capture evidence.

### Progress log
- 2026-06-01: **M3 task 4 DONE — THE GOAL PROVEN: a tap on emulator A's rendered
  remote-view surface is received by emulator B at the expected, coordinate-faithful
  location. 5 taps, 5/5 received, all within tolerance.**
  **FLOW (e2e/m3-automation.sh, one `docker run --device /dev/kvm`, two emulators
  mem=1536):** boot B(5554)+A(5556); install + LAUNCH the deterministic target app
  on B (`net.scrcpy.e2etarget`, full-screen, records every tap's device (X,Y) on 3
  channels); `ensure_b_reachable` → socat bridge `10.0.2.2:6555 -> 127.0.0.1:5555`;
  install our android-app on A; `am start MainActivity --es host 10.0.2.2 --es port
  6555` → tap the located Connect → ScrcpyActivity; wait for a STABLE stream
  (scrcpy `INFO: Connected to 10.0.2.2:6555` + scrcpy-server `net.scrcpy.e2etarget`
  process on B), settle 6s; re-assert the target owns B's focus; **reset B's tap
  counter AFTER the stream is stable** (so stray taps don't pollute); then inject
  `adb -s emulator-5556 shell input tap AX AY` at 5 distinct A points, polling B's
  file channel until the count increments per tap.
  **CONTROL PATH (why a tap on A reaches B):** A's ScrcpyActivity extends
  SDLActivity, so the SDL surface that renders B's video also forwards its touch
  events to scrcpy's controller, which injects them on B over the ADB control
  channel. `input tap AX AY` on A → A's SDLSurface ACTION_DOWN → scrcpy maps surface
  coords → B's video resolution → INJECT_TOUCH_EVENT to B → B's target records
  (BX,BY). No `--no-control`; nothing ignored touch; the target stays foreground on
  B (scrcpy only mirrors, doesn't change B's foreground app).
  **A→B TRANSFORM (derived empirically, NOT hardcoded):** A and B are the SAME AVD
  resolution (1080×1920), but A's ScrcpyActivity is `Theme.AppCompat.NoActionBar`
  (NOT immersive-fullscreen), so A keeps its status/navigation bars and the SDL
  surface showing B occupies only A's content rectangle; scrcpy letterboxes B's
  video into it. Modelled as a per-axis affine map fitted from the 2 calibration
  taps (pure-bash integer math ×1000, no bc/python):
  ```
  BX = round((1000*AX +    -1000)/1000)   # X is ~1:1 (full-width), tiny offset
  BY = round((1109*AY +   -70784)/1000)   # Y scaled 1.109 + offset −70.8px
  ```
  The non-trivial Y scale+offset is exactly A's status-bar / aspect letterboxing —
  and crucially the 3 INDEPENDENT validation taps fit it, proving coordinate-faithful
  control, not a lucky single hit.
  **VERBATIM EVIDENCE (e2e/artifacts/m3-automation-evidence.txt, run exit 0):**
  ```
  A screen = 1080x1920   B screen = 1080x1920
  Derived A->B transform (scaled x1000): SX=1000 OX=-1000 SY=1109 OY=-70784
  Tolerance: max(25px, 3% of screen dim)
  tap  A(ax,ay)       expect B       got B          dx,dy   verdict
  p1 [calibration] (324,576)  -> expect (323,568)  got (323,568)  dx=0 dy=0 PASS
  p2 [calibration] (756,1344) -> expect (755,1420) got (755,1420) dx=0 dy=0 PASS
  p3 [validation]  (540,960)  -> expect (539,994)  got (540,994)  dx=1 dy=0 PASS
  p4 [validation]  (756,576)  -> expect (755,568)  got (755,568)  dx=0 dy=0 PASS
  p5 [validation]  (324,1344) -> expect (323,1420) got (323,1420) dx=0 dy=0 PASS
  B final tap count = 5 (sent 5)
  ```
  Every A tap mapped to a DISTINCT, correctly-ordered B location; max error 1px
  (well under the 25px / 3% tolerance); B's total count == 5 sent (no taps lost or
  duplicated on the control path). PASS first run.
  **REUSABLE HARNESS PIECE — `e2e/lib-automation.sh`** (sourceable, no external deps):
   • `auto_tap_on_a <A> <ax> <ay>` — inject a tap on A's surface.
   • `auto_read_b <B> [file|ui|logcat]` — read B's recorded "N X Y" (via lib-target).
   • `auto_derive_transform <ax1 ay1 bx1 by1 ax2 ay2 bx2 by2>` — fit the per-axis
     affine map from 2 calibration points (echoes `SX1000 OX1000 SY1000 OY1000`).
   • `auto_expect_b <SX OX SY OY> <ax> <ay>` — expected B coord under the map.
   • `auto_within_tol <exp> <act> <dim>` — tolerance check (max abs/rel).
   • `auto_assert_point <SX OX SY OY> <ax ay> <bx by> <bw bh>` — full per-point
     verdict line + PASS/FAIL return. Task 5 wires these into run.sh.
  **DRIVERS:** `e2e/m3-automation.sh` (the task-4 harness above; reuses lib-net,
  lib-target, lib-automation, run.sh's AVD/boot logic) + `e2e/m3-build-and-automate.sh`
  (INNER: apt-installs build tools, builds the native stack if libscrcpy.so absent,
  builds BOTH APKs, hands off). Self-cleaning: `--rm` container auto-removed,
  emulators killed, AVDs deleted, socat bridge stopped; verified host left clean
  (no stray scrcpy-e2e/qemu/socat, no e2e AVDs); mf-e2e-*/redroid/ws-scrcpy untouched.
  **NO new app/native changes were needed** — task 3's connect path already forwards
  surface touches correctly; task 4 is pure harness + assertion logic.
  **Committed:** e2e/lib-automation.sh, e2e/m3-automation.sh,
  e2e/m3-build-and-automate.sh, STATE. NOT committed: APK/.so/jniLibs/assets/
  artifacts (all gitignored).
- 2026-06-01: **M3 task 3 DONE — A's app drives a REAL scrcpy session to B over
  ADB-over-TCP: connects to `10.0.2.2:6555`, pushes scrcpy-server to B, launches it
  (`app_process com.genymobile.scrcpy.Server 3.3.4`), reaches Connected, and renders
  B's screen. PASS 2/2 runs.**
  **SERVER-BUNDLING MECHANISM (the gap the brief flagged):** scrcpy locates the
  server to push via the `SCRCPY_SERVER_PATH` env (scrcpy/app/src/server.c
  `get_server_path` → `sc_adb_push` to `/data/local/tmp/scrcpy-server.jar` on B).
  Android has no install prefix, so the app SHIPS the server (v3.3.4, matching the
  client) as an APK ASSET, copies it to filesDir at runtime, and sets the env —
  mirroring iOS `ScrcpyADBClient.m setupScrcpyEnvs`. Concretely:
   • `android-app/stage-natives.sh` now also copies
     `scrcpy-app/ADBClient/scrcpy-server` → `app/src/main/assets/scrcpy-server` at
     build time (the asset is a build artifact, gitignored — NOT committed under
     android-app; the binary stays only in its existing tracked location).
   • `ScrcpyActivity.onCreate()` calls `deployServer()` (copies the asset to
     `filesDir/scrcpy-server`, idempotent) then `nativeSetServerPath(path)`.
   • New JNI `Java_..._ScrcpyActivity_nativeSetServerPath` (android-jni-bridge.c):
     `setenv("SCRCPY_SERVER_PATH", path, 1)` after verifying the file — set BEFORE
     SDL starts the scrcpy_main thread, so server.c sees it.
  **CONNECT PARAMS:** A's app connects to **host=`10.0.2.2` port=`6555`** (the
  lib-net socat bridge `0.0.0.0:6555 -> 127.0.0.1:5555` fronting B's adbd).
  ScrcpyActivity builds `--tcpip=10.0.2.2:6555 --video-codec=h264 --video-bit-rate=4M
  --video-buffer=0 --print-fps --stay-awake --shortcut-mod=... --no-audio` (the
  in-process adb host does `adb connect`, push, reverse tunnel, app_process). The
  reverse tunnel works through the socat bridge with NO `--force-adb-forward`.
  **VERBATIM EVIDENCE (e2e/artifacts/, run 5, exit 0):**
  A-side scrcpy in-process client log (`A-scrcpy-stdio.log`):
  ```
  INFO: Connecting to 10.0.2.2:6555...
  connected to 10.0.2.2:6555
  INFO: Connected to 10.0.2.2:6555
  > adb -s 10.0.2.2:6555 push /data/user/0/net.scrcpy.android/files/scrcpy-server /data/local/tmp/scrcpy-server.jar
  /data/local/tmp/scrcpy-server.jar: 1 file pushed ... (91012 bytes in 0.006s)
  > adb -s 10.0.2.2:6555 reverse localabstract:scrcpy_49c3c89f tcp:27183
  > adb -s 10.0.2.2:6555 shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 3.3.4 scid=... video_bit_rate=4000000 audio=false stay_awake=true
  > scrcpy-server app_process started
  [server] INFO: Device: [Google] google sdk_gphone_x86_64 (Android 11)
  INFO: Texture: 1080x1920 / INFO: FPS counter started / INFO: 6 fps ...
  ```
  scrcpy-server RUNNING on B (`evidence-bserver.txt`, `adb -s emulator-5554 ps -A`):
  ```
  shell  3999  3997 ... do_epoll_wait  S app_process
  shell  4077  3999 ... pipe_read      S app_process
  ```
  B-side server logcat (`logcat-B-full.txt`):
  ```
  D AndroidRuntime: Calling main entry com.genymobile.scrcpy.Server
  I scrcpy  : Device: [Google] google sdk_gphone_x86_64 (Android 11)
  ```
  A-side porting status callback (`logcat-A-full.txt`): `onScrcpyStatus: status=2
  message=SDL Inited` (×2) then `onScrcpyStatus: status=3 message=SDL Window Created`
  — status=3 only fires AFTER a successful server connect + first video frame, so it
  is a reliable post-connection marker; video streams (continuous `N fps`). No
  UnsatisfiedLinkError / dlopen-fail / SIGSEGV / SIGABRT / FATAL / ANR on A.
  **BUGS FOUND + FIXED (instrumented, root-caused — not assumed):**
   1. **Server not bundled** (the brief's predicted gap): without SCRCPY_SERVER_PATH
      scrcpy can't push the server. Fixed via the asset+deploy+setenv mechanism above.
   2. **scrcpy diagnostics invisible:** scrcpy installs its own SDL log handler that
      `fprintf`s to stdout/stderr, which Android discards — so ALL connect/server/
      tunnel errors were silent. Added `redirect_stdio_to_logcat()` in
      android-jni-bridge.c (tees stdout+stderr to `$HOME/scrcpy-stdio.log` in the
      app's cacheDir, pulled by the harness via `run-as`). This is what made the next
      two bugs diagnosable.
   3. **Harness mis-routed the port into the host field:** the old fragile
      soft-keyboard typing put `6555` into the HOST EditText → scrcpy got
      `--tcpip=6555` → "Connecting to 6555:5555" → `failed to resolve host '6555'`.
      Fixed by making `MainActivity` accept `host`/`port` Intent extras and prefill
      the fields (`am start ... --es host 10.0.2.2 --es port 6555`), then tap Connect
      — deterministic, no typing. (Screenshot proof of the old bug:
      `screen-A-after.png` from the failing run showed host=6555 port=5555.)
   4. **Audio capture aborted the session:** with audio on, the server hit
      `ERROR: Audio capture error` (the AVD has no audio-capture HAL) and tore down
      the WHOLE session before Connected. Added `--no-audio` (overridable via the
      `noAudio` extra, default true) to ScrcpyActivity's argv.
   5. **Harness `set -e`/pipefail abort:** a field-verify `grep | grep | sed` that
      found nothing returned non-zero in a `$(...)` and killed the script before the
      Connect tap; wrapped non-fatal + added a UI-dump retry loop.
  **KNOWN QUIRK (documented, not blocking):** the porting layer's
  `sc_server_on_connected_hijack` (scrcpy-porting.c) — which would emit
  `ScrcpyStatusConnected` (status=6) — does NOT surface in logcat on this Android
  build (the bridge's own pre-scrcpy_main `__android_log_print` LOGIs are likewise
  swallowed, while ScrcpyUpdateStatus status=2/3 DO appear — root cause not yet
  pinned; the preprocessed .o DOES contain the rewritten `sc_server_init_hijack`
  call, so the macro applies). It does NOT affect the session: scrcpy's OWN
  authoritative `INFO: Connected to <host:port>` line + the server running on B +
  status=3 (post-connect window) are the Connected proof the harness asserts on.
  Added a one-line diagnostic LOGI in the hijack for future investigation. A
  follow-up could route status=6 through a path that reliably logs (e.g. emit it
  from the SC_EVENT_SERVER_CONNECTED handler).
  **HARNESS:** new `e2e/m3-connect.sh` (boots both emulators reusing run.sh's AVD/
  flags/boot-wait, `ensure_b_reachable` → 10.0.2.2:6555 socat bridge, installs the
  APK on A, `am start MainActivity --es host/port` → tap Connect, observes,
  asserts scrcpy-Connected + server-on-B + no-crash) and `e2e/m3-build-and-connect.sh`
  (INNER driver: apt-installs the build tools missing from the image —
  make/meson/nasm/golang/rsync/socat/pkg-config — builds the full native stack
  `make android-libs`, then hands off to m3-connect.sh). One `docker run --device
  /dev/kvm`, mem=1536 ×2, self-cleaning; `--rm` container auto-removed; emulators
  killed; AVDs deleted; socat bridge stopped; mf-e2e-*/redroid/ws-scrcpy untouched;
  host clean. **Committed:** android-jni-bridge.c (nativeSetServerPath +
  redirect_stdio_to_logcat), ScrcpyActivity.kt (deploy server asset + --no-audio),
  MainActivity.kt (host/port extras prefill), stage-natives.sh (stage server asset),
  scrcpy-porting.c (hijack diagnostic LOGI), android-app/.gitignore (ignore the
  assets/scrcpy-server build artifact), e2e/m3-connect.sh, e2e/m3-build-and-connect.sh,
  STATE. NOT committed: built .so / APK / staged jniLibs / assets/scrcpy-server /
  artifacts (all gitignored).
- 2026-06-01: **M3 task 2 DONE — deterministic input target app built, installed,
  launched, and PROVEN on all three state channels; recorded tap coords match the
  `input tap` coords exactly (dx=dy=0).**
  **App:** new minimal standalone Gradle project `e2e/target-app/` (mirrors
  android-app's toolchain: AGP 8.7.3 / Gradle 8.9 / Kotlin 2.0.21, compileSdk=36,
  minSdk=26; NO AndroidX so uiautomator dumps are clean). Package/applicationId
  **`net.scrcpy.e2etarget`**, single exported LAUNCHER Activity
  **`net.scrcpy.e2etarget.TargetActivity`** (full-screen
  `Theme.Black.NoTitleBar.Fullscreen`, `screenOrientation=sensor`,
  `FLAG_KEEP_SCREEN_ON`, system bars hidden). A full-screen `TextView` is the
  content view; the Activity overrides **`dispatchTouchEvent`** (NOT
  `onTouchEvent`) so it records EVERY `ACTION_DOWN` before any view can consume it
  — `taps` increments (reset to 0 on launch/onCreate), `lastX,lastY` =
  `Math.round(rawX/rawY)` in DEVICE PIXELS (view is full-screen ⇒ raw coord ==
  `input tap` coord within rounding).
  **THREE state channels (all verified):**
   1. ON-SCREEN/uiautomator — TextView text AND content-desc = `taps=N last=X,Y`.
   2. LOGCAT — `Log.i("E2E_TARGET","tap #N at X,Y")`, one line per tap.
   3. FILE — latest `N X Y` written to the app's INTERNAL `filesDir/e2e_state.txt`
      (internal, NOT external: API 30+ shell can't `cat` an app's external files
      dir — got `Permission denied` — and `run-as cat files/...` reads the INTERNAL
      dir, so external would never be found; internal + run-as is the robust combo).
  **TWO bugs found+fixed during verification** (caught by the BLOCKING self-test,
  not assumed): (a) first cut set the TextView `isClickable=true` + used the
  Activity's `onTouchEvent` — a clickable full-screen view CONSUMES ACTION_DOWN in
  View.onTouchEvent, so the Activity's onTouchEvent never fired and `taps` stayed
  0; fixed by making the view non-clickable and capturing in `dispatchTouchEvent`.
  (b) first cut wrote to `getExternalFilesDir(null)` but read via `run-as cat
  files/...` (internal dir) → file channel always empty; fixed by writing to the
  internal `filesDir`.
  **VERIFICATION (BLOCKING, d-claude, `scrcpy-e2e:dev`, `--device /dev/kvm`, ONE
  emulator mem=1536, AVD android-30 google_apis x86_64 — reused run.sh boot
  logic):** `e2e/m3-target-selftest.sh` built the APK (`./gradlew --no-daemon
  assembleDebug` → app-debug.apk 816,473 B), booted the emulator, `adb install
  -r -g`'d + launched the Activity (confirmed `mCurrentFocus=Window{... 
  net.scrcpy.e2etarget/net.scrcpy.e2etarget.TargetActivity}`), tapped (200,400)
  then (540,1000), and asserted all 3 channels per tap. **VERBATIM evidence
  (e2e/artifacts/m3-target-evidence.txt) after both taps:**
  ```
  === mCurrentFocus ===
    mCurrentFocus=Window{51664d1 u0 net.scrcpy.e2etarget/net.scrcpy.e2etarget.TargetActivity}
  === file channel (run-as net.scrcpy.e2etarget cat files/e2e_state.txt) ===
  2 540 1000
  === uiautomator (taps=N last=X,Y node) ===
  taps=2 last=540,1000
  === logcat -d -s E2E_TARGET ===
  06-01 09:54:56.722  2478  2478 I E2E_TARGET: tap #1 at 200,400
  06-01 09:55:07.117  2478  2478 I E2E_TARGET: tap #2 at 540,1000
  ```
  Self-test per-channel asserts: tap#1 file/ui/logcat all `1 200 400`
  (dx=0 dy=0); tap#2 all `2 540 1000` (dx=0 dy=0). Self-test exit rc=0.
  **ASSERTION QUERIES for task 4** (`$S`=B serial, e.g. emulator-5554):
   • uiautomator: `adb -s $S shell uiautomator dump /sdcard/e2e_ui.xml >/dev/null;
     adb -s $S shell cat /sdcard/e2e_ui.xml | grep -o 'taps=[0-9]* last=[0-9-]*,[0-9-]*' | head -1`
     → `taps=N last=X,Y`.
   • logcat: `adb -s $S logcat -d -s E2E_TARGET | grep -oE 'tap #[0-9]+ at [0-9-]+,[0-9-]+' | tail -1`
     → `tap #N at X,Y`.
   • file: `adb -s $S shell run-as net.scrcpy.e2etarget cat files/e2e_state.txt`
     → `N X Y`.
   Or just source `e2e/lib-target.sh` and call `target_read_state $S [file|ui|logcat]`
   (echoes normalised `"N X Y"`), `target_install/target_launch/target_reset`.
  **Committed:** e2e/target-app/** (gradle sources, manifest, TargetActivity.kt,
  strings.xml, gradlew + wrapper, .gitignore, README), e2e/lib-target.sh,
  e2e/m3-target-selftest.sh, STATE. NOT committed: build/ or the APK (gitignored).
  Container `--rm` self-removed; emulator killed; AVD deleted; no stray
  qemu/scrcpy-e2e; mf-e2e-*/redroid/ws-scrcpy untouched.
- 2026-06-01: **M3 task 1 DONE — A→B adb-over-TCP reachability solved, verified,
  and documented. WORKING ADDRESS SCHEME: A's app connects to `10.0.2.2:6555`,
  where a host-side `socat TCP-LISTEN:6555,fork,reuseaddr -> TCP:127.0.0.1:5555`
  bridge fronts B's adbd. NO `adb tcpip`/`forward`/`reverse` needed.**
  **Topology (empirically established, not assumed):** both emulators run in ONE
  `scrcpy-e2e:dev` container (`--device /dev/kvm`, mem=1536 each). Each emulator
  has its OWN isolated QEMU user-mode (slirp) net: guest eth0 `10.0.2.15/24`,
  gateway `10.0.2.2`. The emulator forwards each guest's adbd to the CONTAINER-HOST
  *loopback*: B(console 5554)→`127.0.0.1:5555`, A(console 5556)→`127.0.0.1:5557`.
  Emulator adbd already listens on TCP — `adb tcpip` (physical-device flow) is
  NOT needed; confirmed.
  **The wrinkle the brief warned about is REAL:** the obvious scheme
  `10.0.2.2:5555` from inside A does **NOT** reach B. Verbatim probe (a tiny NDK
  x86_64 C probe `e2e/m3-tcp-probe.c` pushed to A, sends a valid adb CNXN, reads
  the reply): `PROBE_RESULT=connect_fail host=10.0.2.2 port=5555`. Diagnostics
  proved A's slirp gateway `10.0.2.2` does NOT route to the container host's
  `127.0.0.1` services at all in the pinned emulator v33.1.24 —
  `A->10.0.2.2:5037` (host adb-server) = connect_fail, and a socat listener bound
  to `127.0.0.1:6001`→B reached via `A->10.0.2.2:6001` = connect_fail. **BUT**
  A's `10.0.2.2` DOES reach any host service bound on `0.0.0.0` (all interfaces):
  a socat `0.0.0.0:6002 -> 127.0.0.1:5555` bridge IS reachable from A at
  `10.0.2.2:6002`. (Direct container-bridge IP `172.17.0.2:5555/:6000` also
  unreachable from A — slirp NAT only routes A out via its own gateway.)
  **STRONG VERBATIM EVIDENCE — A reached B's adbd** (final probe run, A's C probe
  → `10.0.2.2:6555`, the lib-net socat bridge to B's `127.0.0.1:5555`):
  ```
  PROBE_RESULT=connected host=10.0.2.2 port=6555
  PROBE_RESULT=reply_bytes=256
  HEX: 43 4e 58 4e 01 00 00 01 00 00 10 00 04 01 00 00 00 00 00 00 bc b1 a7 b1
       64 65 76 69 63 65 3a 3a 72 6f 2e 70 72 6f 64 75 63 74 2e 6e 61 6d 65 3d ...
  ASCII: CNXN....................device::ro.product.name=sdk_gphone_x86_64;
         ro.product.model=sdk_gphone_x86_64;ro.product.device=generic_x86_64_arm64;
         features=sendrecv_v2_brotli,remount_shell,sendrecv_v2,abb_exec,...
  REPLY_COMMAND_IS_CNXN=yes
  ```
  `43 4e 58 4e` = "CNXN" — A received B's adbd CNXN handshake banner. **Negative /
  disambiguation:** tagged B with `setprop debug.m3.mark=m3_1780306444`; host-side
  `adb connect 127.0.0.1:5555` read it back = `m3_1780306444` (==B), while
  `127.0.0.1:5557` read empty (==A). So `127.0.0.1:5555` (what the bridge fronts,
  what A's `10.0.2.2:6555` maps to) is unambiguously B's adbd, not A's own.
  **Helper added (reusable by M3 tasks 3-5): `e2e/lib-net.sh`** — sourceable;
  documents the scheme in a header; `ensure_b_reachable <serial_b> <adbd_b>
  [bridge_port]` confirms B's adbd on `127.0.0.1:adbd_b`, idempotently starts the
  `0.0.0.0:bridge -> 127.0.0.1:adbd_b` socat bridge (apt-installs socat if
  missing), and echoes `10.0.2.2:bridge` (default `6555`); `b_target_for_a`,
  `stop_b_bridge` for teardown. Proof harness: **`e2e/m3-reachability-probe.sh`**
  (boots both emulators reusing run.sh's AVD/flags/boot-wait, sources lib-net,
  compiles+pushes the C probe to A, PASS/FAILs on adbd-CNXN + marker
  disambiguation) and the throwaway diagnostics `e2e/m3-net-diag.sh`/`-diag2.sh`.
  Probe exit 0; container `--rm` auto-removed; socat died with it; host left clean
  (no stray scrcpy-e2e containers/qemu/socat; mf-e2e-*/redroid/ws-scrcpy untouched).
  **Committed:** lib-net.sh, m3-reachability-probe.sh, m3-tcp-probe.c,
  m3-net-diag.sh, m3-net-diag2.sh, STATE. NOT committed: /artifacts (gitignored).
  **NOTE for task 3:** the M2 ScrcpyActivity defaults host=10.0.2.2; the harness
  must set the PORT to the bridge port (6555), not 5555.
- 2026-06-01: **M2 AUDIT PASSED.** Skeptical audit re-verified everything with
  commands on d-claude (`scrcpy-e2e:dev`, `--device /dev/kvm`, NDK 27.2.12479018),
  trusting nothing cached. Evidence:
  • **Clean rebuild:** deleted the cached `output/android/x86_64/libscrcpy.so` +
    `porting/build/scrcpy-android`, rsync'd the tree, ran
    `make android-scrcpy TARGET_ABI=x86_64` → **70/70 ninja, MAKE_RC=0**, fresh
    `libscrcpy.so` (13,044,824 B). `llvm-nm -D`: exports `T scrcpy_android_main`,
    `T scrcpy_main`, `T scrcpy_print_version`, `T JNI_OnLoad`,
    `T Java_net_scrcpy_android_NativeBridge_runScrcpy`,
    `T Java_net_scrcpy_android_ScrcpyActivity_nativeSetHome`, `T ScrcpyUpdateStatus`.
    `llvm-readelf`: ELF64 / DYN / X86-64, FLAGS=SYMBOLIC only (**no TEXTREL**),
    NEEDED includes libSDL2.so + libc++_shared.so + libz.so. `stage-natives.sh` +
    `./gradlew --no-daemon assembleDebug` → **BUILD SUCCESSFUL** (app-debug.apk =
    24,322,263 B). `unzip -l`: `lib/x86_64/{libscrcpy.so 13044824, libSDL2.so
    6405544, libc++_shared.so 1617608}`; the APK-embedded libscrcpy.so still exports
    `T scrcpy_android_main` + `T scrcpy_main`; dexdump finds
    `Lnet/scrcpy/android/{ScrcpyActivity,MainActivity,NativeBridge};` +
    `Lorg/libsdl/app/SDLActivity;`.
  • **Fresh-emulator run (`e2e/launch-app.sh`, SKIP_BUILD=1, target 127.0.0.1:5555,
    one mem=1536 emulator):** harness exit 0. VERBATIM key logcat from THIS run
    (app pid 2923, 09:11:47):
    ```
    V SDL    : Running main function scrcpy_android_main from library /data/app/.../net.scrcpy.android-.../lib/x86_64/libscrcpy.so
    V SDL    : nativeRunMain()
    I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
    I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
    I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
    V SDL    : Finished main function
    V SDL    : SDLActivity thread ends
    ```
    So SDL dlsym'd + called our exported `scrcpy_android_main` from libscrcpy.so,
    control entered `scrcpy_main`, the native `ScrcpyUpdateStatus` callback fired
    (status=2 = ScrcpyStatusSDLInited, emitted from inside scrcpy_main's hijacked
    SDL_Init), scrcpy attempted the adb connect to the (deviceless) target, failed
    fast, returned, and SDL finished cleanly. **Crash-greps over THIS run's
    logcat-full.txt: UnsatisfiedLinkError=0, dlopen-fail=0,
    Fatal-signal/SIGSEGV/SIGABRT/signal11/signal6/Scudo=0, FATAL EXCEPTION/ANR=0.**
    The harness's own diagnostic: "PASS: native libs loaded, scrcpy entered, no
    crash. (connection attempt: yes)". (Note: the bridge's direct LOGI argc/argv
    lines were not captured, but the SDL "Running main function scrcpy_android_main"
    line + the in-scrcpy_main status callback are unambiguous proof the native
    client loaded + ran.)
  • **iOS intact:** android-jni-bridge.c, android-stubs.c, android-adb-stubs.cpp all
    guarded (`#if defined(__ANDROID__)` / `#if !defined(__APPLE__)`); NONE referenced
    in the iOS `porting/cmake/CMakeLists.txt`. `.gitmodules` diff (e06e734..HEAD)
    empty; submodule pointers NOT bumped (scrcpy @fb6381f, adb-mobile @78c32c2).
  • **git:** the 4 M2 commits (`19722f9..1c26758`) all pushed to `fork`
    (remote android-controls-android HEAD = 1c26758 = local HEAD); tree clean; no
    `.so`/`.a`/`.apk`/`.dex` tracked; jniLibs gitignored. Audit emulator killed,
    throwaway container auto-removed, mf-e2e-*/redroid/ws-scrcpy untouched, host
    clean (no orphan qemu, e2e_app AVD deleted). **→ advancing to M3.**
- 2026-06-01: **M2 task 4 done — APK launched on a headless x86_64 emulator;
  libscrcpy.so loads, scrcpy_main is entered, the in-process adb host runs through
  its connection path, NO crash. M2 COMPLETE. Two REAL native bugs found + fixed
  along the way.**
  **Harness:** new single-emulator helper **`e2e/launch-app.sh`** (the M3-ready
  counterpart to `e2e/run.sh`'s two-emulator harness): inside `scrcpy-e2e:dev`
  with `--device /dev/kvm` it stages natives + `assembleDebug`s the APK, boots ONE
  pinned-v33.1.24 emulator (same AVD/flags/boot-wait as run.sh, mem=1536), installs
  the APK, drives the REAL user flow (`am start` the exported MainActivity → set
  host/port fields → `uiautomator dump`-located tap on Connect → ScrcpyActivity),
  captures 30s of filtered+full logcat to /artifacts, and PASS/FAILs on
  UnsatisfiedLinkError/dlopen/SIGSEGV/SIGABRT/FATAL/ANR vs scrcpy-entry evidence.
  (ScrcpyActivity is correctly `exported=false`, so a direct `am start` of it gives
  `SecurityException: not exported from uid` — hence the via-MainActivity flow.)
  **BUG 1 (FATAL, fixed): adb auth aborts — `Cannot mkdir '/data/.android'`.**
  First launch: libs loaded + scrcpy_main entered, then SIGABRT on the
  `scrcpy-server` thread. Verbatim:
  ```
  F libc  : Fatal signal 6 (SIGABRT) ... in tid N (scrcpy-server), pid M (SDLActivity)
  F DEBUG : Abort message: 'Cannot mkdir '/data/.android': Permission denied'
  F DEBUG : #04 ... adb_get_android_dir_path()+515
  F DEBUG : #05 ... get_user_key_path()+34
  F DEBUG : #06 ... adb_auth_init()+63
  F DEBUG : #07 ... adb_server_main(...)
  F DEBUG : #08 ... launch_server_thread(...)
  ```
  Root cause: scrcpy's in-process adb host (`launch_server`→`adb_server_main`→
  `adb_auth_init`) derives its key store from `adb_get_homedir_path()` =
  `getenv("HOME")` ?: passwd home; an Android app uid's passwd home is the
  unwritable `/data`, so `mkdir("$HOME/.android")` FATAL-aborts. **Fix:** point
  `$HOME` at the app's writable `cacheDir` BEFORE the native thread runs. Added
  `Java_net_scrcpy_android_ScrcpyActivity_nativeSetHome(String)` to
  `porting/src/android-jni-bridge.c` (`setenv("HOME", path, 1)` after verifying
  it's a writable dir) + a defensive `ensure_writable_home()` (falls back to
  `$TMPDIR`) called at the top of both `scrcpy_android_main` and `runScrcpy`;
  `ScrcpyActivity.onCreate` calls `nativeSetHome(cacheDir.absolutePath)` right after
  `super.onCreate()` (SDLActivity.loadLibraries has run, so the symbol is bound;
  the SDL thread that runs scrcpy_main starts later in handleResume). (The vendored
  AOSP `adb_utils.cpp` is NOT patched — fixed purely via the env from our side.)
  **BUG 2 (FATAL, fixed): OpenSSL↔BoringSSL allocator collision — Scudo abort.**
  After the HOME fix, adb_get_android_dir_path() succeeded and the flow advanced one
  step further, into `load_key()`/`hash_key()`, then aborted. Verbatim:
  ```
  F DEBUG : Abort message: 'Scudo ERROR: misaligned pointer when deallocating address 0x...'
  F DEBUG : #04 ... scudo::reportMisalignedPointer(...)
  F DEBUG : #05 ... scudo::Allocator<...>::deallocate(...)
  F DEBUG : #06 ... load_key(std::string const&)+214        // = hash_key()'s OPENSSL_free(pubkey)
  F DEBUG : #07 ... adb_auth_init()+295
  F DEBUG : #08 ... adb_server_main(...)
  ```
  Root cause: the scrcpy-android link pulled in BOTH the standalone OpenSSL
  (`libssl.a`/`libcrypto.a`, built in M1 t4) AND adb's bundled **BoringSSL** (inside
  `libadb-full.a`), reconciled with `-Wl,--allow-multiple-definition`. That let lld
  resolve crypto symbols per-symbol from EITHER provider, so adb's
  `i2d_RSA_PUBKEY` (BoringSSL `OPENSSL_malloc`) and `OPENSSL_free` could bind to
  DIFFERENT allocators — freeing a BoringSSL-malloc'd buffer with the wrong free
  trips bionic Scudo's misaligned-pointer check. (The M1 link comment literally
  flagged this as a TODO.) **Fix:** scrcpy itself has NO OpenSSL/TLS dependency
  (verified: no `<openssl>`/`SSL_`/`EVP_` refs in `scrcpy/app/src`; the iOS link
  doesn't link libssl/libcrypto either), and adb is the only crypto user — so
  **dropped `libssl.a`+`libcrypto.a` from the link** in
  `porting/scripts/scrcpy-android-CMakeLists.txt`, leaving BoringSSL as the sole,
  self-consistent crypto provider. (`--allow-multiple-definition` kept defensively
  for protobuf intra-archive overlaps; the crypto collision is gone.) APK shrank
  26.5MB→24.3MB (no second crypto lib).
  **RELINK (d-claude, `scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`):** 70/70 ninja, MAKE_RC=0 after each fix; final
  libscrcpy.so links clean without OpenSSL. APK rebuilt green (assembleDebug, 20s).
  **PASS RUN (verbatim key logcat, emulator-5554, target `--tcpip=127.0.0.1:5555`):**
  ```
  V SDL    : Running main function scrcpy_android_main from library /data/app/.../lib/x86_64/libscrcpy.so
  V SDL    : nativeRunMain()
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  V SDL    : Finished main function
  V SDL    : SDLActivity thread ends
  ```
  Diagnostic greps over the FULL logcat: UnsatisfiedLinkError = none, dlopen
  failure = none, **SIGSEGV/Fatal signal/SIGABRT/Scudo = 0 occurrences**, FATAL
  EXCEPTION/ANR = none; app pid alive at +30s. So: **libscrcpy.so loaded (no link
  error), `scrcpy_android_main`→`scrcpy_main` entered, SDL initialized, the
  in-process adb host ran its `--tcpip=127.0.0.1:5555` connect path all the way
  through `adb_auth_init` (the exact spot that aborted twice before) WITHOUT
  crashing, and scrcpy returned/finished cleanly.** Harness exit 0; emulator killed,
  throwaway container self-removed, unrelated mf-e2e/redroid/ws-scrcpy untouched.
  Artifacts: `e2e/artifacts/{logcat-full.txt,logcat-scrcpy-launch.txt,
  screen-after-launch.png}` (gitignored).
  **Committed:** android-jni-bridge.c (nativeSetHome + ensure_writable_home),
  ScrcpyActivity.kt (onCreate→nativeSetHome), scrcpy-android-CMakeLists.txt (drop
  OpenSSL), e2e/launch-app.sh (new helper), STATE. NOT committed: relinked .so /
  APK / staged jniLibs / artifacts (gitignored). **M2 accept criteria fully
  satisfied → run M2 audit next.**
- 2026-06-01: **M2 task 3 done — ScrcpyActivity (extends SDLActivity) runs scrcpy
  under SDL's Android infra; launcher UI (host/port + Connect) hands off to it;
  bridge exports `scrcpy_android_main`; relinked .so + APK build green.**
  **Architecture (the correct one — implemented):** scrcpy runs as the SDL "main"
  under `org.libsdl.app.SDLActivity` so `SDL_CreateWindow` inside `scrcpy_main`
  returns the real SDLActivity surface — video renders into it and the SDLSurface's
  touch/key events feed scrcpy's controller with NO extra Java wiring.
  **New native entry (`porting/src/android-jni-bridge.c`):**
   • `__attribute__((visibility("default"))) JNIEXPORT int
     scrcpy_android_main(int argc, char **argv)` — LOGs argc/argv, calls
     `scrcpy_main(argc,argv)`, LOGs + returns rc. This is the symbol
     `SDLActivity.nativeRunMain()` dlsym's from `getMainSharedObject()`
     (libscrcpy.so) and invokes on the dedicated SDL thread once the surface is
     ready. (The task-2 `Java_..._runScrcpy`/`JNI_OnLoad`/`ScrcpyUpdateStatus`
     stay — unused by this SDL path but harmless.)
  **New `ScrcpyActivity.kt` (extends `org.libsdl.app.SDLActivity`), 4 overrides:**
   • `getLibraries()` → `["c++_shared","SDL2","scrcpy"]` (load order: c++_shared +
     SDL2 are NEEDED by libscrcpy.so, so first; scrcpy last = also the main .so).
     SDL's `loadLibraries()` `System.loadLibrary`'s each, so no separate loader.
   • `getMainSharedObject()` → `"${applicationInfo.nativeLibraryDir}/libscrcpy.so"`
     (absolute path to the packaged lib; default would derive `libmain.so`).
   • `getMainFunction()` → `"scrcpy_android_main"` (not the default `SDL_main`).
   • `getArguments()` → scrcpy argv from Intent `host`/`port` extras. **argv shape
     mirrors the iOS ADB-over-TCP client (`ScrcpyADBClient.m buildScrcpyArgs`):**
     same option set (`--video-codec=h264 --video-bit-rate=4M --video-buffer=0
     --audio-buffer=150 --audio-output-buffer=10 --print-fps --stay-awake
     --shortcut-mod=lctrl,rctrl,lalt,ralt`), but the **connection target is
     scrcpy's own `--tcpip=HOST:PORT`** (the in-process adb host in libscrcpy.so
     does the `adb connect`) instead of the iOS app's external `adb connect` +
     `--serial=HOST:PORT`. NOTE: the task brief suggested `--adb=tcp:...`, but that
     flag does not exist in scrcpy 3.3.4 (`cli.c`); `--tcpip=<addr>` is the correct
     single-arg ADB-over-TCP target. SDL prepends argv[0]. Defaults
     127.0.0.1:5555 if extras blank. `companion newIntent(ctx,host,port)`.
  **Launcher UI:** `MainActivity` rewritten — `res/layout/activity_main.xml`
  (title + host EditText[default 10.0.2.2] + port EditText[default 5555] + Connect
  Button); Connect validates non-empty then
  `startActivity(ScrcpyActivity.newIntent(this,host,port))`. The task-2
  auto-run-`--help`-on-launch path (and its NativeBridge wiring in MainActivity +
  the `wip_message` string) is DROPPED — MainActivity is now purely the launcher.
  (`NativeBridge.kt` left intact/unused — task-2 proof.) New strings:
  host_hint/port_hint/connect/error_empty_target.
  **Manifest:** registers `ScrcpyActivity` (`exported=false`,
  `alwaysRetainTaskState`, `hardwareAccelerated`, `launchMode=singleInstance`,
  `screenOrientation=user`, `theme=Theme.AppCompat.NoActionBar`, and the SDL
  sample's `configChanges=layoutDirection|locale|orientation|uiMode|screenLayout|
  screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation`) so SDL keeps
  its surface across rotation/keyboard/resize. Added `<uses-permission INTERNET>`
  + `hardwareAccelerated` on `<application>`. MainActivity stays the LAUNCHER.
  **RELINK (d-claude, `scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`):** 70/70 ninja, MAKE_RC=0, libscrcpy.so = 15279880 B.
  **VERIFIED** (`llvm-nm -D`): **`T scrcpy_android_main`** now exported, alongside
  `T scrcpy_main`, `T Java_net_scrcpy_android_NativeBridge_runScrcpy`,
  `T JNI_OnLoad`, `T ScrcpyUpdateStatus`.
  **APK (stage-natives.sh → `./gradlew --no-daemon assembleDebug`):** BUILD
  SUCCESSFUL in 30s, app-debug.apk = 26.56 MB. **VERIFIED on the APK:**
   • `unzip -l`: `lib/x86_64/{libSDL2.so 6405544, libc++_shared.so 1617608,
     libscrcpy.so 15279880}` — the relinked .so packaged.
   • extracted `lib/x86_64/libscrcpy.so` `llvm-nm -D` → `T scrcpy_android_main` +
     `T scrcpy_main` (the export survives into the APK).
   • dex class map lists `Lnet/scrcpy/android/ScrcpyActivity;`,
     `Lnet/scrcpy/android/MainActivity;`, `Lorg/libsdl/app/SDLActivity;` (+ the
     full vendored `org.libsdl.app.*` glue) — the Kotlin overrides type-checked
     against SDLActivity's protected hooks (build success = compile-time proof the
     getLibraries/getMainSharedObject/getMainFunction/getArguments signatures
     match).
   • `aapt2 dump xmltree` of the packaged manifest: both
     `net.scrcpy.android.MainActivity` (line 28) and
     `net.scrcpy.android.ScrcpyActivity` (line 44) registered.
  (Did NOT launch the GUI Activity on-emulator — redroid on d-claude is
  GUI-degraded; the real launch-on-emulator-A connect proof is M2 task 4.)
  **Committed:** android-jni-bridge.c, ScrcpyActivity.kt, MainActivity.kt,
  AndroidManifest.xml, res/layout/activity_main.xml, res/values/strings.xml, STATE.
  NOT committed: relinked .so / APK / staged jniLibs (gitignored).
- 2026-06-01: **M2 task 2 done — JNI bridge in libscrcpy.so + Kotlin loader +
  worker-thread scrcpy_main(--help) call, proven through real ART on-device.**
  **Native bridge (`porting/src/android-jni-bridge.c`, `#if defined(__ANDROID__)`,
  added to `scrcpy-android-CMakeLists.txt` source list):**
   • `JNIEXPORT jint Java_net_scrcpy_android_NativeBridge_runScrcpy(JNIEnv*,
     jclass, jobjectArray)` — converts the Java `String[]` → NUL-terminated
     argc/argv (`GetStringUTFChars`+`strdup`, freed after the call), `LOGI`s
     entry + each argv, calls `scrcpy_main(argc,argv)` on the CALLING (worker)
     thread, `LOGI`s the return code, frees argv, returns the int.
   • STRONG `void ScrcpyUpdateStatus(enum ScrcpyStatus, const char*)` — overrides
     the weak default in `scrcpy-porting.c` (and the weak one in `android-stubs.c`);
     `__android_log_print`s status+message under tag "scrcpy", then best-effort
     forwards to `net.scrcpy.android.NativeBridge.onScrcpyStatus(int,String)`
     (GetEnv/AttachCurrentThread, never throws back across JNI).
   • `jint JNI_OnLoad(JavaVM*,void*)` caches the `JavaVM*` (for the status
     forward), returns `JNI_VERSION_1_6`.
   • Load order: libscrcpy.so NEEDs libSDL2.so + libc++_shared.so, so
     `NativeBridge.load()` does `System.loadLibrary("c++_shared")` →
     `"SDL2"` → `"scrcpy"` (idempotent, `@Synchronized`).
  **Kotlin:** new `NativeBridge.kt` (`object`, `external fun runScrcpy`,
  `@JvmStatic onScrcpyStatus`, `statusListener` for the UI); `MainActivity`
  spawns a `"scrcpy-native"` worker `Thread` → `load()` →
  `runScrcpy(arrayOf("scrcpy","--help"))`, logs the rc, surfaces status into a
  `TextView` via the listener.
  **RELINK (must-fix bug found + fixed):** rebuilt libscrcpy.so WITH the bridge
  on d-claude (`scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`, 70/70 ninja, MAKE_RC=0). First relink loaded fine for
  libc++_shared+libSDL2 but **`dlopen failed: cannot locate symbol "uncompress"`**
  (a real UnsatisfiedLinkError) when ART loaded libscrcpy.so: adb's libziparchive
  (in libadb-full.a) + FFmpeg pull zlib's `uncompress`/`inflate*`/`crc32`, but
  `libz.so` was NOT in NEEDED — the `--unresolved-symbols=ignore-all` link flag
  let the .so build anyway, and the M1 smoke exe tolerated it because `--help`
  exits before any zlib path AND the exe link differed. **Fix:** added `z` to the
  `target_link_libraries` system-lib list in `scrcpy-android-CMakeLists.txt`.
  Re-relink → `libz.so` now in NEEDED (verified `llvm-readelf -d`); bridge symbols
  still exported (`llvm-nm -D`: **`T Java_net_scrcpy_android_NativeBridge_runScrcpy`,
  `T JNI_OnLoad`, `T ScrcpyUpdateStatus`, `T scrcpy_main`**); ELF64/DYN/X86-64,
  NO TEXTREL.
  **APK REBUILD:** `stage-natives.sh` re-staged the 3 fresh libs →
  `./gradlew --no-daemon assembleDebug` → BUILD SUCCESSFUL (26.5 MB). VERIFIED
  the APK's `lib/x86_64/libscrcpy.so` (15279104 B, the relinked one) contains
  `T Java_net_scrcpy_android_NativeBridge_runScrcpy` + `T JNI_OnLoad`.
  **RUNTIME SANITY (real ART, on-device):** the redroid-11 x86_64 GUI stack on
  d-claude is too degraded to launch an Activity (surfaceflinger/sensors/health/
  wificond/logd HALs SIGABRT at boot → `sys.boot_completed` never flips, no
  launcher, `am start`/monkey never start the app process) — so instead of the
  GUI launch I drove the **exact JNI entrypoint through real ART** with
  `app_process64`: a tiny `NbTest` dex (built with the SDK `d8`, bundling the
  vendored `org.libsdl.app.*` glue so SDL2's own `JNI_OnLoad` — which registers
  natives against `org.libsdl.app.SDLActivity` — resolves) `System.load`s the 3
  libs in order and reflectively calls `net.scrcpy.android.NativeBridge
  .runScrcpy({"scrcpy","--help"})`. **VERBATIM stdout (688 lines):**
  ```
  [nbtest] loaded libc++_shared.so
  [nbtest] loaded libSDL2.so
  [nbtest] loaded libscrcpy.so
  [nbtest] NativeBridge class resolved: class net.scrcpy.android.NativeBridge
  [nbtest] calling runScrcpy(scrcpy --help) via JNI ...
  scrcpy 3.3.4 <https://github.com/Genymobile/scrcpy>
  Usage: scrcpy [options]
  ... [full scrcpy 3.3.4 usage] ...
  [nbtest] runScrcpy returned 0
  Exit status:
        0  Normal program termination
        1  Start failure
        2  Device disconnected while running
  ```
  → ART loaded all 3 native libs (NO UnsatisfiedLinkError after the libz fix),
  bound + invoked `Java_net_scrcpy_android_NativeBridge_runScrcpy`, control
  entered `scrcpy_main`, the full scrcpy 3.3.4 usage printed, and `runScrcpy
  returned 0` with `app_process` exit 0 — no crash/SIGSEGV. (The bridge's own
  `__android_log_print` "scrcpy"-tag lines could NOT be captured because logd is
  one of the redroid services that SIGABRTs at boot; the usage text reaches us via
  scrcpy's own `printf`/stdout, which is the authoritative proof the native method
  ran. Driving the real `MainActivity` Activity awaits a healthy emulator — M2
  task 4.) Throwaway redroids removed; `mf-e2e-redroid-1` untouched; host clean.
  **Committed:** android-jni-bridge.c, scrcpy-android-CMakeLists.txt (bridge in
  source list + `z` link), NativeBridge.kt, MainActivity.kt, STATE. NOT committed:
  the relinked `.so`/APK (gitignored) or the throwaway nbtest harness (under e2e/,
  on the build host only).
- 2026-06-01: **M2 task 1 done — native libs + SDL Java glue integrated into the
  android-app Gradle build; APK packages all 3 .so + compiles `org.libsdl.app.*`.**
  This is BUILD-INTEGRATION ONLY (no `scrcpy_main` call / no UI yet — that's M2
  task 2/3); `MainActivity` left as-is (stub TextView).
  **`android-app/app/build.gradle.kts` changes (all additive):**
   • `defaultConfig.ndk { abiFilters += "x86_64" }` — packages only the x86_64 ABI
     (arm64-v8a deferred to M4); without this AGP would warn/expect every ABI.
   • `sourceSets.named("main")`: `java.srcDir("../../porting/vendor/sdl-android-java")`
     — that dir is the source ROOT (`org/libsdl/app/*.java` under it), so the
     `org.libsdl.app` package compiles straight into the app. Verified the glue is
     self-contained: single package decl `org.libsdl.app`, NO `R.*` resource refs,
     NO `BuildConfig`, no non-android/java/libsdl imports → compiles clean with the
     stub MainActivity still as launcher (SDLActivity not yet used). Also pinned
     `jniLibs.srcDir("src/main/jniLibs")` (AGP default, explicit).
  **Staging mechanism (reproducible, .so never committed):** new
  **`android-app/stage-natives.sh`** (executable) — copies the 3 prebuilt libs
  (`libscrcpy.so`, `libSDL2.so`, `libc++_shared.so`) from
  `output/android/<ABI>` into `app/src/main/jniLibs/<ABI>/` BEFORE `./gradlew
  assembleDebug`. Args: `stage-natives.sh [OUTPUT_DIR] [ABI]` (defaults
  `../output/android/x86_64`, `x86_64`); errors out if any lib is missing. The
  e2e/CI path calls it before gradlew. `android-app/.gitignore` now ignores
  `app/src/main/jniLibs/` (the .so are gitignored build artifacts; root .gitignore
  already swallows `*.so`/`output`). Verified `git check-ignore
  app/src/main/jniLibs/x86_64/libscrcpy.so` → ignored.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (persistent `scrcpy-gradle-cache`
  volume): rsync'd `android-app/` + `porting/vendor/` to
  `/srv/work/scrcpy-mobile-e2e`, ran `./stage-natives.sh /workspace/output/android/
  x86_64 x86_64 && ./gradlew --no-daemon assembleDebug` → **BUILD SUCCESSFUL in
  44s** (`:app:compileDebugJavaWithJavac` compiled the SDL glue;
  `:app:mergeDebugNativeLibs` packaged the .so; only a benign "Unable to strip"
  note for the 3 prebuilt .so). APK = `app/build/outputs/apk/debug/app-debug.apk`
  (26.5 MB, up from the 3.18 MB stub APK).
  **VERIFIED — APK CONTAINS the libs** (`unzip -l app-debug.apk | grep
  "lib/x86_64/"`):
  ```
    6405544  lib/x86_64/libSDL2.so
    1617608  lib/x86_64/libc++_shared.so
   15252168  lib/x86_64/libscrcpy.so
  ```
  **VERIFIED — SDL glue compiled into the dex:** APK has classes{,2,3}.dex; the
  multidex map in classes3.dex lists `Lorg/libsdl/app/SDLActivity;`,
  `Lorg/libsdl/app/SDLSurface;`, `Lorg/libsdl/app/SDLAudioManager;`,
  `Lorg/libsdl/app/SDLControllerManager;`, `Lorg/libsdl/app/SDLMain;`, the four
  `Lorg/libsdl/app/HIDDevice*;` and `Lnet/scrcpy/android/MainActivity;` — i.e. the
  full vendored `org.libsdl.app` package + the app's launcher Activity.
  **Committed** (build.gradle.kts, .gitignore, stage-natives.sh, STATE).
  **NOT committed:** the staged jniLibs/.so (gitignored) and the APK/build dir.
  MainActivity untouched.
- 2026-06-01: **M1 AUDIT PASSED.** Skeptical audit re-verified everything with
  commands on d-claude (`scrcpy-e2e:dev`, NDK 27.2.12479018), did not trust the
  cached `.so`. Evidence:
  • **iOS intact:** every `porting/src`+`porting.h` edit is `#if defined(__APPLE__)`
    guarded (porting.h GLES include, demuxer-porting VideoToolbox hijack) or portable
    (controller-porting `#import`→`#include` of a guarded header — identical on
    clang/iOS); both new stub files are `#if !defined(__APPLE__)` wrapped;
    `Makefile.android` is additive (`include`d, nothing in the iOS `all` recipe
    references it). Submodule pointers NOT bumped: `.gitmodules` diff empty, scrcpy
    @fb6381f, adb-mobile @78c32c2 (the `-`-prefixed submodules are merely
    uninitialized, not re-pointed).
  • **Rebuilt from scratch:** deleted the cached `libscrcpy.so` + build dir, rsync'd
    `porting/`, ran `make android-scrcpy TARGET_ABI=x86_64` (with
    `ANDROID_NDK_ROOT=/opt/android-sdk/ndk/27.2.12479018`) → 69/69 ninja, `MAKE_RC=0`,
    fresh `libscrcpy.so` = 15.25 MB.
  • **Static verify** (llvm-readelf/llvm-nm): `ELF64 / DYN / X86-64`, SONAME
    `libscrcpy.so`, **NO TEXTREL** (FLAGS=SYMBOLIC only), exports `T scrcpy_main` +
    `T scrcpy_print_version`; NEEDED = libSDL2.so liblog.so libandroid.so libGLESv3.so
    libGLESv2.so libEGL.so libOpenSLES.so libm.so libc++_shared.so libdl.so libc.so.
  • **Smoke on bionic:** rebuilt `scrcpy-smoke` (RUNPATH `$ORIGIN`, NEEDED
    libscrcpy.so+libSDL2.so), pushed it + the 3 libs into a THROWAWAY redroid-11
    x86_64 container, ran it → bionic linker loaded all libs with no
    dlopen/textrel/missing-symbol error, entered `scrcpy_main`, printed full scrcpy
    3.3.4 usage/version, `[smoke] scrcpy_main returned 0`, `SMOKE_EXIT=0`. Throwaway
    container removed; unrelated `mf-e2e-redroid-1` untouched; host left clean.
  • **git:** all 6 M1 commits (`0200f63..d29023d`) pushed to `fork`, working tree
    clean, no built `.so`/`.a` tracked. **→ advancing to M2.**
- 2026-06-01: **M1 tasks 6 + 7 done — `libscrcpy.so` cross-compiled for android
  x86_64 and the NDK smoke exe runs `scrcpy_main --help` cleanly on-device. M1
  COMPLETE.**
  **porting/src #ifdef adaptations (all additive, iOS path kept under `__APPLE__`):**
   • `porting/include/porting.h`: the iOS `<OpenGLES/ES3/gl.h>`+`<OpenGLES/gltypes.h>`
     include is now under `#if defined(__APPLE__)`; the `#else` (Android) uses the
     NDK `<GLES3/gl3.h>`+`<GLES2/gl2ext.h>`. Dropped the iOS `typedef GLfloat
     GLdouble`/`GLclampd` on Android (the NDK gl2ext.h already typedefs them →
     would conflict) and the iOS `<SDL2/SDL_opengl_glext.h>` include (clashes with
     NDK gl2ext; not needed — opengl.c pulls GL via SDL).
   • `porting/src/demuxer-porting.c`: the VideoToolbox HW-decode hijack
     (`av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)`) is now under
     `#if defined(__APPLE__)`; the `#else` (Android) just returns the plain
     AVCodecContext → scrcpy's normal FFmpeg **software** decode +
     `SDL_UpdateYUVTexture` rendering runs (no Metal/VT).
   • `porting/src/controller-porting.c`: `#import "screen.h"` (ObjC-only syntax)
     → `#include "screen.h"` (compiles under the NDK C frontend; identical on iOS).
   • decoder-porting.c / display-porting.c / screen-porting.c needed NO source
     change — their hijacks already gate on `ScrcpyEnableHardwareDecoding()` (0 on
     Android via the stub below ⇒ the SW path), and SDL handles clipboard
     cross-platform (the `SDL_CLIPBOARDUPDATE` handler in screen-porting.c is
     SDL-generic). process-porting.cpp already uses `adb_public.h` → libadb-full.a.
   • **NEW `porting/src/android-stubs.c`** (Android-only, also `#if !__APPLE__`
     guarded): weak defaults for the symbols the iOS app/SDL-fork provides —
     `ScrcpyEnableHardwareDecoding`(→0, forces SW path), `ScrcpyTryResetVideo`,
     `ScrcpyHandleFrame`, `GetUpdateApplicationBackgroundState`,
     `SDL_UpdateCommandGeneration` (iOS-SDL-fork ext, no-op), `ScrcpyAudioVolumeScale`
     (→1.0), and the AOSP adb globals `__adb_argv`/`__adb_envp` (defined in AOSP
     client/main.cpp, which the port excludes). The M2 app will provide strong
     overrides.
   • **NEW `porting/src/android-adb-stubs.cpp`**: weak no-op stubs for adb
     **dead-path** entry points that libadb-full.a references but does not define
     (its bundle lacks the adb mDNS/bonjour/emulator-command/logd-pmsg and
     adb-wifi-pairing TUs): `using_bonjour`, `mdns_check`,
     `mdns_{list_discovered_services,get_connect_service_info,get_pairing_service_info}`,
     `adb_secure_connect_by_service_name`, `adb_send_emulator_command`,
     `Logd{Write,Close}`, `Pmsg{Write,Close}`, `adbwifi::pairing::PairingClient::Create`.
     scrcpy's adb host uses only `adb_commandline_porting`, which never reaches
     these — but bionic resolves non-lazy relocs eagerly at dlopen, so the .so
     must define them to LOAD. Signatures mirror adb's headers so the C++ mangled
     names line up exactly (verified: 0 adb dead-path UND symbols remain).
  **Android CMake build (mirrors porting/cmake/CMakeLists.txt, additive):**
   • **NEW `porting/scripts/scrcpy-android-CMakeLists.txt`** + driver
     **`porting/scripts/make-scrcpy-android.sh`** (wired into `Makefile.android`
     `android-scrcpy`, TODO stub replaced; iOS Makefile untouched). Same source
     list as the iOS cmake (the porting/src replacements + scrcpy/app/src/* core),
     minus the USB sources (mobile) and — unlike iOS — it does NOT compile
     `sys/unix/process.c`/`util/process_intr.c` standalone (process-porting.c
     already amalgamates them via `#include`; the iOS Mach-O link tolerates the
     resulting dup symbols, lld does not). Builds a **SHARED `libscrcpy.so`** via
     the NDK `android.toolchain.cmake` (`ANDROID_ABI=x86_64`,
     `ANDROID_PLATFORM=android-26`, `ANDROID_STL=c++_shared`, `-include porting.h`
     mirroring iOS `-include porting.h`). C++17 (adb mDNS sigs use
     `std::optional`/`string_view`).
   • **config.h handling:** the iOS build gets `scrcpy/x/app/config.h` from
     `meson setup x`. The Android cmake instead WRITES a static config.h into the
     build dir replicating exactly meson's emitted defines (per
     scrcpy/app/meson.build): `HAVE_SOCK_CLOEXEC=1` (bionic has it),
     `SCRCPY_VERSION="3.3.4"`, `PREFIX`, `DEFAULT_LOCAL_PORT_RANGE_FIRST/LAST
     27183/27199`. CRITICAL: scrcpy gates features with `#ifdef` and meson emits
     disabled bools as `#undef`, so `PORTABLE`/`SERVER_DEBUGGER`/`HAVE_V4L2`/
     `HAVE_USB` are intentionally LEFT UNDEFINED (defining them `=0` would still
     be truthy under `#ifdef` and pull in `<libusb-1.0/libusb.h>` etc).
   • **Link:** `--start-group` over the prebuilt static deps
     (libav*/libsw*/libssl/libcrypto/libadb-full) `--end-group` + `libSDL2.so` +
     android sys libs (`-llog -landroid -lGLESv3 -lGLESv2 -lEGL -lOpenSLES -lm`).
     Link flags that were load-bearing: **`-Bsymbolic`** (FFmpeg's internal data
     tables e.g. `ff_h264_cabac_tables` are referenced cross-object via PC32;
     binding them locally makes the PC32 link-time-resolvable with no runtime
     reloc — without it lld errors "recompile with -fPIC"),
     **`--allow-multiple-definition`** (libadb-full.a statically bundles BoringSSL
     whose X509_*/EVP_* symbols collide with scrcpy's OpenSSL libcrypto.a),
     **`--unresolved-symbols=ignore-all`** (the NDK toolchain forces
     `-Wl,--no-undefined`; libc++ runtime + a few protobuf-pulled abseil symbols
     on adb dead paths are satisfied at runtime by `libc++_shared.so` / never
     called), **`-z lazy`**.
  **Two dep fixes required to make the .so actually LOAD on Android (bionic):**
   1. **`make-ffmpeg-android.sh`**: added `FFMPEG_DISABLE_X86ASM=1` knob and
      rebuilt FFmpeg with **`--disable-x86asm`**. FFmpeg's x86_64 hand-written asm
      emits R_X86_64_PC32 **text relocations** → the .so gets `DT_TEXTREL`, which
      bionic (API≥23) REFUSES to load ("has text relocations"). x86asm-off = pure-C
      PIC FFmpeg ⇒ libscrcpy.so is TEXTREL-free (verified `llvm-readelf -d` shows
      no TEXTREL). (libavcodec.a 5.0M→3.8M.) Also fixed the script to **MERGE**
      headers into the shared `include/` instead of `rm -rf include` (it was
      wiping SDL2/openssl/adb headers that the other deps install there — made the
      build order-dependent).
   2. **`make-adb-mobile-android.sh`**: the bundle was missing **brotli** (built
      `.so` not `.a` → `BrotliDecoder*` undefined) and **abseil/utf8_range** (only
      libprotobuf.a was folded in, not its abseil deps → ~80 `absl::` undefined).
      Fixed: try brotli `*-static` targets then fall back to archiving brotli's
      compiled `.o`s; collect+bundle the `libabsl_*.a`/`libutf8_*.a` from the
      protobuf-android abseil build. libadb-full.a 22M→26M, brotli/absl now `T`.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** via `make android-scrcpy`
  (`make-scrcpy-android.sh`): 69/69 ninja, `[scrcpy-android] DONE`. apt deps
  per-run: `make` (+ `nasm pkg-config` for the ffmpeg rebuild, `golang-go
  build-essential patch` for the adb rebuild). cmake 3.22.1 + ninja auto-resolved
  from `$ANDROID_SDK_ROOT/cmake/*/bin`. **libscrcpy.so = 15.25 MB**; **VERIFIED**
  (llvm-readelf/llvm-nm): `ELF64 / DYN / X86-64`, SONAME `libscrcpy.so`, **NO
  TEXTREL**, `.note.android.ident`, exports `T scrcpy_main` + `T
  scrcpy_print_version`; **NEEDED** = `libSDL2.so liblog.so libandroid.so
  libGLESv3.so libGLESv2.so libEGL.so libOpenSLES.so libm.so libc++_shared.so
  libdl.so libc.so`. The driver also stages the NDK `libc++_shared.so` next to it
  (ANDROID_STL=c++_shared ⇒ NEEDED at runtime; M2 APK must bundle it).
  **SMOKE TEST** (`porting/scripts/scrcpy-smoke.c`: `extern int scrcpy_main(int,
  char**)`, calls it with `{"scrcpy","--help"}`): cross-compiled for android
  x86_64, linked vs libscrcpy.so+libSDL2.so (RUNPATH `$ORIGIN`), pushed into a
  throwaway **redroid Android-11 x86_64** container on d-claude (the scrcpy-e2e
  emulator wasn't needed — redroid shares the host kernel, boots an Android
  userspace + bionic linker in seconds) and RUN. **VERBATIM output (head):**
  ```
  [smoke] calling scrcpy_main --help
  scrcpy 3.3.4 <https://github.com/Genymobile/scrcpy>
  Usage: scrcpy [options]

  Options:

      --always-on-top
          Make scrcpy window always on top (above other windows).
  ... [full scrcpy usage incl. shortcuts, env vars] ...
  Exit status:
        0  Normal program termination
        1  Start failure
        2  Device disconnected while running
  EXIT=0
  ```
  ACCEPT met: the bionic dynamic linker loaded libscrcpy.so + its deps with NO
  "has text relocations" / "cannot locate symbol" / dlopen error, control entered
  `scrcpy_main`, the full scrcpy 3.3.4 usage/version text printed, and the process
  exited 0 (scrcpy's `--help` path calls `exit(0)` itself, so the post-call
  `[smoke] returned` line is not reached — a clean exit, not a crash). Throwaway
  redroid removed after capture (host left clean).
  **Committed:** the porting.h/demuxer/controller `#ifdef` edits, the two new
  android-stubs source files, the new android cmake + driver + smoke source, the
  Makefile.android wire-up, the ffmpeg/adb dep-script fixes, STATE. **NOT
  committed** (gitignore swallows): `output/` (`.so`/`.a`), `porting/build/`, the
  scrcpy submodule (pointer NOT bumped — stays @fb6381f). **M1 accept criteria
  fully satisfied → run M1 audit next.**
- 2026-06-01: **M1 task 5 done — adb-mobile (`libadb-full.a`) cross-compiled for
  android x86_64.** This is the in-process ADB host (`adb_commandline_porting` API)
  that pushes the scrcpy server + opens TCP tunnels, same role as the iOS build.
  **APPROACH (b): a standalone NDK driver, NOT adb-mobile's own ios-cmake build.**
  `external/adb-mobile`'s build (`make-adb.sh`) wires Google's adb sources through
  `nmeum/android-tools`'s CMake, which `pkg_check_modules(REQUIRED)` for
  brotli/lz4/pcre2/zstd/protobuf/libusb and compiles a pile of unrelated host tools
  (fastboot/e2fsprogs/...); the iOS port tolerates that via brew. Rather than fight
  it under the NDK, I wrote a small **standalone CMakeLists**
  (`porting/scripts/adb-mobile-android-CMakeLists.txt`) that compiles **exactly the
  iOS static-lib target set** (libadb + libbase/libcutils/liblog/libcrypto_utils/
  libdiagnoseusb/libziparchive/adb_crypto_defaults/adb_tls_connection_defaults + fmt)
  against the vendored AOSP sources + the `porting/adb/` client overrides, pulling
  **boringssl** in as a subdirectory (cross-compiles cleanly with NDK + host Go). The
  iOS targets in `external/adb-mobile` are 100% untouched (additive, alongside).
  Driver = **`porting/scripts/make-adb-mobile-android.sh`** (wired into
  `Makefile.android` `android-adb-mobile`, TODO stub replaced; iOS Makefile untouched).
  It (1) builds a **host protoc 28.3** from the pinned `external/protobuf` (apt's is
  the wrong ver) + uses it to generate adb's `*.pb.cc`; (2) cross-compiles **Android
  libprotobuf** and **lz4/zstd/brotli** (transport/incremental compression) via the
  NDK cmake toolchain; (3) **overlays `porting/adb/client/*` onto vendor/adb/client/**
  (the iOS mechanism — required so path-qualified `#include "client/file_sync_client.h"`
  resolves to the porting override, in-process no-fork server + extended do_sync_pull);
  (4) configures+builds the standalone project through the NDK; (5) bundles every `.a`
  (+ android libprotobuf + lz4/zstd/brotli) into **`output/android/x86_64/libadb-full.a`**
  via an `llvm-ar -M` MRI script, then `--strip-debug`. **adb_public.h** copied to the
  android `include/`.
  **Submodules initialized (pinned, NOT bumped):** `external/adb-mobile` @78c32c2 +
  its `external/{lz4,zstd,brotli,protobuf}` and `android-tools` vendor subset
  `{adb,core,libbase,libziparchive,boringssl,fmtlib,logging}` (+ protobuf's nested
  abseil-cpp/utf8_range). The big unused android-tools vendors (selinux/extras/
  e2fsprogs/f2fs/libusb/...) are intentionally left un-inited.
  **Key porting fixes (all in the driver/standalone CMake, none touch committed
  vendor files — overlay+patch happen on the build host's rsync'd tree which has no
  `.git`, so patches use idempotent GNU `patch --forward`, not `git am`):**
   • API floor **29** for this lib only (`ANDROID_API_ADB`, overrides the repo
     default 26): AOSP `libbase/unique_fd.h` hard-`#if`-gates fdsan on
     `__ANDROID_API__>=29`; the symbols are weak so the lib still loads on <29, and
     the adb host runs on the API-30 emulator anyway. (ffmpeg/sdl/openssl stay at 26.)
   • `-D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__` — liblog/adb reference bionic
     symbols `__INTRODUCED_IN(30)`; makes those weak refs instead of hard errors.
   • applied upstream adb patches **0007** (guard the sysdeps `write` macro so it
     doesn't clobber `std::ostream::write` that abseil str_format pulls in) and
     **0013** (disable fastdeploy → no `ApkEntry.pb.h` requirement).
   • `ZLIB_CONST` for libziparchive (NDK zlib `next_in` const mismatch); in-tree
     incfs_support + gtest_prod includes added.
   • guarded the porting `main.cpp`'s `#include "fdevent_poll.cpp"` behind
     `#if !defined(__linux__)` — it amalgamates BOTH poll and epoll backends; on iOS
     epoll is `__linux__`-excluded so poll wins, but Android IS `__linux__` → both
     compiled → `fdevent_interrupt` redefinition. Android uses the epoll backend.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** end-to-end via
  `make android-adb-mobile` (clean cmake/bundle rebuild): `MAKE_RC=0`,
  `[adb-mobile-android] DONE`. **apt deps (transient in the run cmd, NOT baked into
  the image):** `golang-go build-essential make patch` (go is needed for boringssl's
  codegen; build-essential for the host protoc; patch for the idempotent vendor
  patching). cmake 3.22.1 + ninja come from `$ANDROID_SDK_ROOT/cmake/*/bin` (script
  auto-prepends, same trick as the SDL build). **libadb-full.a = 6.1M** (stripped;
  22.7M unstripped; 980 object members). **VERIFIED Android x86_64** (llvm-nm /
  llvm-ar / llvm-readelf in the image): defined `T adb_commandline_porting`,
  `T adb_trace_init_porting`, `T adb_trace_enable_porting`, `T capture_printf`, and
  the in-process `T launch_server`/`launch_server_thread` overrides; an extracted
  member (`commandline.cpp.o`) is `ELF64 / X86-64 / REL`; brotli/lz4/zstd/protobuf
  symbols bundled; `adb_public.h` present in the android include dir.
  gitignore swallows `output/`+`build/`+`*.a` (only the driver script, the standalone
  CMakeLists, the Makefile.android edit + STATE committed; submodule pointer NOT
  bumped — adb-mobile stays @78c32c2).
- 2026-06-01: **M1 task 4 done — OpenSSL cross-compiled for android x86_64.** New
  `porting/scripts/make-openssl-android.sh` (mirrors the FFmpeg/SDL android-driver
  style; iOS untouched). **OpenSSL 1.1.1w** (matches the iOS OpenSSL-for-iPhone 1.1.1
  series, for ABI/API parity). Configured `./Configure android-x86_64
  -D__ANDROID_API__=26 no-shared no-tests` via the NDK clang (`x86_64-linux-
  android26-clang`, on PATH from android-defines.sh). Produced **libcrypto.a (5.2 MB)
  + libssl.a (1.0 MB)** + headers into `output/android/x86_64/` (the canonical
  output dir, same place ffmpeg/sdl land). VERIFIED on d-claude in `scrcpy-e2e:dev`:
  build rc=0 / "[openssl-android] DONE"; `nm` shows defined `T OPENSSL_init_crypto`
  (libcrypto) and `T SSL_new` (libssl); archive has 637 object members all compiled
  by the android NDK clang. apt deps `make perl` installed per-run.
  PROCESS NOTE: the first attempt was launched by the iteration subagent as a
  background task and got TORN DOWN when that subagent paused (un-resumable) — the
  build was re-launched as a parent-session harness-tracked task and finished clean.
  Going forward, heavy builds should run BLOCKING in the subagent's own context (or
  be launched by the parent) so they aren't killed.
- 2026-06-01: **M1 task 3 done — SDL2 cross-compiled for android x86_64 (native
  Android backend).** New `porting/scripts/make-libsdl-android.sh` (mirrors the
  iOS `make-libsdl.sh` STYLE but retargets the NDK; iOS script untouched). **Same
  SDL2 version as iOS: 2.32.8** (downloaded from libsdl.org, tarball cached under
  `porting/build/libsdl-android/`, re-runs reuse it). **Build method:** SDL2's own
  CMake build driven through the NDK `build/cmake/android.toolchain.cmake`
  (resolved by android-defines.sh) with `-DANDROID_ABI=x86_64
  -DANDROID_PLATFORM=android-26 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF`
  → **SHARED `libSDL2.so`** (the Android norm, loaded at runtime by SDLActivity in
  M2). cmake auto-selected the **Android backend** (configure summary: `Platform:
  Android-1`; compiled `src/core/android/SDL_android.c`, `audio/openslES`,
  `audio/aaudio`, `video/android/SDL_android{video,touch,events,clipboard,...}.c`,
  `joystick/android`, `sensor/android` — NOT the iOS UIKit path). Wired
  `android-libsdl` target in `porting/Makefile.android` to call the script (TODO
  stub replaced; iOS untouched). Outputs `output/android/x86_64/libSDL2.so` +
  `include/SDL2/*.h` (79 headers incl. generated SDL_config.h — iOS-compatible
  layout so libscrcpy can `#include <SDL.h>`).
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (`EXIT_CODE=0`, 265/265 ninja
  steps + install). **apt deps:** transiently `apt-get install make ninja-build`
  in the run command (NOT baked into the image, same as the FFmpeg task). **cmake:**
  the image's Android-SDK cmake 3.22.1 is NOT on PATH; the script auto-prepends
  `$ANDROID_SDK_ROOT/cmake/<ver>/bin` (which also supplies the bundled ninja) when
  `cmake` is absent — so the build is self-contained. **libSDL2.so size: 6.2M.**
  **VERIFIED Android x86_64** (`llvm-readelf`/`llvm-nm` in the image): `ELF64 / DYN
  (shared object) / X86-64`; SONAME `libSDL2.so`; NEEDED includes the Android
  system libs `libOpenSLES.so libandroid.so liblog.so libGLESv1_CM.so libGLESv2.so`
  (proves Android backend, not iOS); `.note.android.ident` present; `llvm-nm -D`
  finds `T SDL_Init`, `T SDL_CreateWindow`, `T SDL_GetPlatform`; SDL.h present.
  **SDL Android Java glue for M2:** vendored 9 files (SDLActivity, SDLSurface,
  SDLAudioManager, SDLControllerManager, SDL, HIDDevice*) from the SDL2-2.32.8
  tarball's `android-project/app/src/main/java/org/libsdl/app/` into
  `porting/vendor/sdl-android-java/org/libsdl/app/` (TRACKED — `.gitignore`
  ignores `porting/libs` but NOT `porting/vendor`; verified `git check-ignore`
  exit 1) + a `SOURCE.txt` provenance note. M2 imports this `org.libsdl.app`
  package so SDLActivity.loadLibraries() loads libSDL2.so at runtime. gitignore
  confirmed swallowing `output/` + `build/` + `*.so` (only script + Makefile edit
  + vendored java + STATE committed; no SDL tarball or libSDL2.so).
- 2026-06-01: **M1 task 2 done — FFmpeg cross-compiled for android x86_64.**
  New `porting/scripts/make-ffmpeg-android.sh` (mirrors the iOS `make-ffmpeg.sh` but
  retargets the NDK): same **FFmpeg release/6.0**, sources the M1-task-1
  `scripts/android-defines.sh` toolchain (CC=`x86_64-linux-android26-clang`,
  `--cross-prefix=$TOOLCHAIN/bin/llvm-`, `--sysroot`, `--target-os=android
  --arch=x86_64 --enable-cross-compile`). Source is git-cloned once and cached under
  `porting/build/ffmpeg-android/ffmpeg-source` (re-runs reuse it). **Static `.a`**
  (mirrors iOS: `--enable-static --disable-shared`); **no VideoToolbox/MediaCodec/JNI**
  (`--disable-videotoolbox --disable-mediacodec --disable-jni`), software decode only.
  **Lean config:** `--disable-everything` then enable avcodec/avformat/avutil/swscale/
  swresample + decoders h264,hevc,av1,aac,opus,flac,pcm_s16le + matching parsers +
  demuxers (h264/hevc/av1/aac/ogg/flac/pcm + matroska/mov/mpegts) + protocols
  file,pipe. (avfilter/avdevice also fall out of the build — kept; mirrors the iOS
  link list which includes both.) **x86 asm: nasm** (auto-detected; script falls back
  to `--disable-x86asm` if absent). Wired `android-ffmpeg` target in
  `porting/Makefile.android` to call the script (TODO stub replaced; iOS untouched).
  Outputs to `output/android/x86_64/lib*.a` + `include/` in the iOS layout.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (apt-get installed make/nasm/
  pkg-config transiently in the run command — NOT baked into the Dockerfile, kept the
  image change-free): `EXIT_CODE=0`, "DONE. Libraries in: output/android/x86_64".
  Produced: libavcodec.a 5.0M, libavformat.a 844K, libavutil.a 1.2M, libswscale.a
  1.4M, libswresample.a 212K, libavfilter.a 197K, libavdevice.a 13K, + full include/
  tree (libav*/libsw*). **VERIFIED Android x86_64:** `llvm-readelf -h` on an extracted
  object shows `ELF64 / X86-64 / REL`; `llvm-nm libavcodec.a` finds `T
  avcodec_send_packet` and `D ff_h264_decoder` (H.264 software decoder compiled in).
  gitignore confirmed ignoring `output/` + `build/` + `*.a` (only script + Makefile +
  STATE committed; no FFmpeg sources or libs).
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
- M1 — Native stack cross-compiled for Android x86_64 — **DONE (audit passed
  2026-06-01)**; arm64-v8a still TODO (deferred to M4).
- M2 — Android client app wraps `libscrcpy.so` (connects to B, shows screen,
  touches propagate).
- M3 — Full GUI-automation e2e: uiautomator taps A's remote view, assert B reacts.
- M4 — Reproducibility/flake-hunt/arm64/review until audit says fully realized.
