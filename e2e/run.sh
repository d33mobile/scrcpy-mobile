#!/usr/bin/env bash
# scrcpy-mobile e2e harness — THE single authoritative entry script.
#
# This runs the GOAL e2e end-to-end: two x86_64 emulators (B=target, A=controller
# running our APK); A's app connects to B over ADB-over-TCP and renders B's screen;
# UI automation taps A's rendered remote-view surface and the test asserts B
# received each tap at the coordinate-faithful location. Exit 0 ONLY if the whole
# chain passes.
#
# Modes:
#   OUTER (default): runs on the host (d-claude or local). Builds the image if
#     missing, then `docker run`s itself in INNER mode with /dev/kvm, the repo
#     mounted at /workspace, a persistent gradle cache, the native-deps output dir,
#     and an artifacts dir.
#   INNER (--inner): runs inside scrcpy-e2e:dev (with /dev/kvm). apt-installs the
#     build tools missing from the image, builds the native stack if libscrcpy.so
#     is absent, builds BOTH APKs (android-app + target-app), boots BOTH emulators
#     (B=5554, A=5556), bridges B's adbd to 10.0.2.2:6555, installs + launches the
#     target on B, drives A's connect flow, waits for a stable stream, resets B's
#     tap counter, then injects calibration + validation taps on A and asserts each
#     maps onto B within tolerance and the total count matches. Writes artifacts
#     (logcat A+B, screenshots, the per-tap evidence table) to /artifacts and
#     cleans up (kill emulators, delete AVDs, stop socat) on EXIT.
#   --smoke (with --inner): the legacy M0 placeholder assertion (both emulators
#     boot + adb online + B controllable from the container adb). A fast harness
#     sanity-check that does NOT need the native lib / APKs.
#
# Topology: ONE container, BOTH emulators. set -euo pipefail throughout.
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared config / logging
# ---------------------------------------------------------------------------
IMAGE="${SCRCPY_E2E_IMAGE:-scrcpy-e2e:dev}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Per-emulator memory (MB). 1536: the host cannot fit 2x2048 alongside the other
# long-running containers; 2x1536 boots reliably.
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
# Max seconds to wait for a stable A->B stream after tapping Connect.
STREAM_SECS="${SCRCPY_STREAM_SECS:-90}"

log()  { printf '%s [run.sh] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

# ===========================================================================
# OUTER MODE
# ===========================================================================
outer() {
  local mode="${1:-}"   # passthrough sub-mode (e.g. --smoke)
  local artifacts="${SCRCPY_E2E_ARTIFACTS:-$REPO_ROOT/e2e/artifacts}"
  mkdir -p "$artifacts"
  rm -rf "${artifacts:?}/"* 2>/dev/null || true

  log "OUTER: image=$IMAGE repo=$REPO_ROOT artifacts=$artifacts mode=${mode:-full}"

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # Build context is the repo ROOT (not e2e/) because the Dockerfile's gradle-home
    # priming layer COPYs android-app/ + e2e/target-app/ + porting/vendor/sdl-android-java
    # — all outside e2e/. The repo-root .dockerignore keeps the context lean (submodules,
    # native build trees, .git, artifacts are excluded; they're mounted at runtime).
    log "Image $IMAGE missing — building from e2e/Dockerfile (context=repo root)"
    docker build -t "$IMAGE" -f "$REPO_ROOT/e2e/Dockerfile" "$REPO_ROOT"
  else
    log "Image $IMAGE present — skipping build"
  fi

  [ -e /dev/kvm ] || fail "/dev/kvm not present on host — x86_64 emulators need KVM"

  # The e2e is hermetic by DEFAULT: the inner container gets NO network. Every build
  # input is baked into the image (apt tools, Android SDK/NDK, native source, and the
  # offline GRADLE_USER_HOME=/opt/gradle-home seeded with the gradle-8.9 distribution +
  # all AGP/Maven deps). Set E2E_ALLOW_NET=1 ONLY to debug / re-prime against the network.
  local netarg="--network none"
  if [ "${E2E_ALLOW_NET:-0}" = "1" ]; then
    netarg=""
    log "E2E_ALLOW_NET=1 — inner container gets network (NON-hermetic; debug only)"
  else
    log "inner container runs with --network none (hermetic)"
  fi

  log "Launching INNER container (docker run --device /dev/kvm $netarg)"
  set +e
  docker run --rm \
    $netarg \
    --device /dev/kvm \
    -v "$REPO_ROOT:/workspace" \
    -v scrcpy-gradle-cache:/root/.gradle \
    -v "$artifacts:/artifacts" \
    -e SCRCPY_E2E_EMU_MEM="$EMU_MEM" \
    -e SCRCPY_E2E_BOOT_TIMEOUT="$BOOT_TIMEOUT" \
    -e SCRCPY_STREAM_SECS="$STREAM_SECS" \
    -e SKIP_BUILD="${SKIP_BUILD:-0}" \
    -e FORCE_NATIVE_REBUILD="${FORCE_NATIVE_REBUILD:-0}" \
    "$IMAGE" \
    bash /workspace/e2e/run.sh --inner $mode
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    log "==================== SUCCESS (e2e green) ===================="
  else
    log "==================== FAILURE (rc=$rc) ===================="
  fi
  return "$rc"
}

# ===========================================================================
# INNER MODE (in container)
# ===========================================================================

WORKSPACE="${WORKSPACE:-/workspace}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
export SCRCPY_E2E_ARTIFACTS="$ARTIFACTS"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/android-sdk/ndk/27.2.12479018}"
TARGET_ABI="${TARGET_ABI:-x86_64}"

APP_DIR="$WORKSPACE/android-app"
TARGET_DIR="$WORKSPACE/e2e/target-app"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
TARGET_APK="$TARGET_DIR/app/build/outputs/apk/debug/app-debug.apk"
NATIVE_OUT="$WORKSPACE/output/android/$TARGET_ABI"

PKG=net.scrcpy.android
MAIN_ACT="$PKG/.MainActivity"

# Emulator identity: B=target (5554/5555), A=controller (5556/5557).
AVD_B=e2e_target
AVD_A=e2e_controller
PORT_B=5554
PORT_A=5556
SERIAL_B=emulator-5554
SERIAL_A=emulator-5556
ADBD_B=5555
BRIDGE_PORT="${M3_BRIDGE_PORT:-6555}"

SKIP_BUILD="${SKIP_BUILD:-0}"

# PIDs for cleanup.
PID_B=""
PID_A=""
LOGCATA_PID=""
LOGCATB_PID=""

cleanup() {
  local rc=$?
  log "cleanup: collecting final artifacts + killing emulators"
  kill "$LOGCATA_PID" "$LOGCATB_PID" >/dev/null 2>&1 || true
  { adb devices -l || true; } >"$ARTIFACTS/adb-devices.txt" 2>&1 || true
  for s in "$SERIAL_B" "$SERIAL_A"; do
    { adb -s "$s" exec-out screencap -p || true; } >"$ARTIFACTS/screen-$s.png" 2>/dev/null || true
  done
  stop_b_bridge "$BRIDGE_PORT" 2>/dev/null || true
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1 || true
  adb -s "$SERIAL_A" emu kill >/dev/null 2>&1 || true
  [ -n "$PID_B" ] && kill "$PID_B" >/dev/null 2>&1 || true
  [ -n "$PID_A" ] && kill "$PID_A" >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_A" >/dev/null 2>&1 || true
  log "cleanup done (rc=$rc)"
}

create_avd() {
  local name="$1"
  avdmanager delete avd -n "$name" >/dev/null 2>&1 || true
  log "creating AVD $name"
  echo no | avdmanager create avd -n "$name" \
    -k "system-images;android-30;google_apis;x86_64" -d "pixel" --force >/dev/null
}

launch_emu() {
  # $1=avd $2=console-port -> echoes the launched PID.
  local name="$1" port="$2"
  log "launching emulator $name on port $port (mem=${EMU_MEM}MB)"
  # Headless KVM flags. swiftshader_indirect = SW GL without an X server.
  # -no-snapshot avoids snapshot corruption races between the two AVDs. No
  # -no-metrics flag — the pinned emulator v33.1.24 aborts if given it.
  emulator -avd "$name" -port "$port" \
    -no-window -gpu swiftshader_indirect \
    -no-snapshot -no-audio -no-boot-anim \
    -accel on -memory "$EMU_MEM" -partition-size 2048 \
    >"$ARTIFACTS/emulator-$port.log" 2>&1 &
  echo $!
}

wait_boot() {
  # $1=serial $2=emulator-pid — poll sys.boot_completed==1 within BOOT_TIMEOUT.
  # Every adb call is wrapped in `timeout` so a dead/hung emulator can never hang
  # the harness; bail immediately if the emulator process has died.
  local serial="$1" pid="$2" deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  log "waiting for $serial (pid $pid) to boot (timeout ${BOOT_TIMEOUT}s)"
  while :; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "$serial emulator process (pid $pid) is DEAD — boot aborted"; return 1
    fi
    local bc
    bc="$(timeout 15 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
    [ "$bc" = "1" ] && { log "$serial booted (sys.boot_completed=1)"; return 0; }
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "$serial did NOT boot within ${BOOT_TIMEOUT}s (last boot_completed='$bc')"; return 1
    fi
    sleep 5
  done
}

# Boot both emulators + settle (shared by full + smoke). Sets PID_B/PID_A.
boot_both() {
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  create_avd "$AVD_B"
  create_avd "$AVD_A"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; log "B pid=$PID_B"
  PID_A="$(launch_emu "$AVD_A" "$PORT_A")"; log "A pid=$PID_A"
  wait_boot "$SERIAL_B" "$PID_B" || { tail -40 "$ARTIFACTS/emulator-$PORT_B.log" >&2 || true; fail "B failed to boot"; }
  wait_boot "$SERIAL_A" "$PID_A" || { tail -40 "$ARTIFACTS/emulator-$PORT_A.log" >&2 || true; fail "A failed to boot"; }
  for s in "$SERIAL_B" "$SERIAL_A"; do
    adb -s "$s" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb -s "$s" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
  done
}

# --- Build helpers ---------------------------------------------------------
ensure_build_tools() {
  # Build tools are BAKED into scrcpy-e2e:dev (see e2e/Dockerfile). No runtime apt:
  # the run is hermetic. Assert the toolchain is present instead of installing it.
  log "asserting baked build tools are present (no runtime apt)"
  local missing="" t
  for t in make nasm perl go pkg-config patch socat rsync gcc; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || fail "missing baked build tool(s):$missing — rebuild scrcpy-e2e:dev from e2e/Dockerfile"
  # The Android-SDK cmake (with bundled ninja) is not on PATH by default; add it
  # so the native scripts find cmake/ninja.
  local sdk_cmake_dir
  sdk_cmake_dir="$(ls -d /opt/android-sdk/cmake/*/bin 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$sdk_cmake_dir" ] && export PATH="$sdk_cmake_dir:$PATH"
  log "cmake=$(command -v cmake || echo none) ninja=$(command -v ninja || echo none)"
}

build_native() {
  if [ -f "$NATIVE_OUT/libscrcpy.so" ] && [ "${FORCE_NATIVE_REBUILD:-0}" != "1" ]; then
    log "libscrcpy.so present at $NATIVE_OUT — skipping native build (FORCE_NATIVE_REBUILD=1 to force)"
  else
    log "building native stack: make -C porting android-libs (ABI=$TARGET_ABI) — LONG"
    ( cd "$WORKSPACE/porting" && \
      ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT" TARGET_ABI="$TARGET_ABI" \
      make android-libs ) 2>&1 | tee "$ARTIFACTS/native-build.log"
    [ -f "$NATIVE_OUT/libscrcpy.so" ] || fail "libscrcpy.so not produced at $NATIVE_OUT"
  fi
  log "native lib: $(ls -la "$NATIVE_OUT/libscrcpy.so")"
}

build_apks() {
  if [ "$SKIP_BUILD" = "1" ] && [ -f "$APK" ] && [ -f "$TARGET_APK" ]; then
    log "SKIP_BUILD=1 and both APKs present — reusing"; return 0
  fi
  # Use the OFFLINE gradle home baked into the image (GRADLE_USER_HOME=/opt/gradle-home,
  # seeded at image-build time with the gradle-8.9 distribution + all AGP/Maven deps)
  # and pass --offline so the build NEVER reaches the network. This makes the run
  # hermetic with NO persistent gradle volume required (the scrcpy-gradle-cache mount
  # is now an optional speed cache, not a correctness dependency). GRADLE_USER_HOME is
  # set in the image; we assert + re-export defensively. --offline + --network none means
  # any un-baked artifact fails loudly instead of silently fetching.
  local gradle_home="${GRADLE_USER_HOME:-/opt/gradle-home}"
  [ -d "$gradle_home/wrapper/dists" ] \
    || fail "offline GRADLE_USER_HOME not primed at $gradle_home — rebuild scrcpy-e2e:dev from e2e/Dockerfile"
  export GRADLE_USER_HOME="$gradle_home"
  log "using offline GRADLE_USER_HOME=$GRADLE_USER_HOME (--offline; baked gradle dist + deps)"

  log "staging natives + scrcpy-server asset + building android-app APK"
  ( cd "$APP_DIR" && ./stage-natives.sh "$NATIVE_OUT" "$TARGET_ABI" )
  ( cd "$APP_DIR" && ./gradlew --no-daemon --offline assembleDebug )
  [ -f "$APK" ] || fail "android-app APK not produced at $APK"
  log "building target-app APK"
  ( cd "$TARGET_DIR" && ./gradlew --no-daemon --offline assembleDebug )
  [ -f "$TARGET_APK" ] || fail "target-app APK not produced at $TARGET_APK"
  log "APKs built:"; ls -la "$APK" "$TARGET_APK" >&2
}

# --- Small helpers ---------------------------------------------------------
# node_center <resource-id-suffix> <uixml> -> echoes "cx cy" of the node's bounds.
node_center() {
  local rid="$1" uixml="$2" bounds
  bounds="$(grep -o "resource-id=\"net.scrcpy.android:id/${rid}\"[^>]*bounds=\"[^\"]*\"" "$uixml" 2>/dev/null \
            | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//; s/"//')"
  [ -z "$bounds" ] && return 1
  local x1 y1 x2 y2
  x1="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/')"
  y1="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/')"
  x2="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/')"
  y2="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/')"
  echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
}

# b_server_proc -> echoes the scrcpy-server app_process line(s) running on B.
b_server_proc() {
  adb -s "$SERIAL_B" shell ps -A 2>/dev/null \
    | grep -iE 'app_process|scrcpy' | grep -vi grep || true
}

# wm_size <serial> -> echoes "W H" (override size if present, else physical).
wm_size() {
  local serial="$1" line
  line="$(adb -s "$serial" shell wm size 2>/dev/null | tr -d '\r')"
  echo "$line" | grep -i 'Override size' | grep -oE '[0-9]+x[0-9]+' | head -1 | tr 'x' ' ' || true
  if ! echo "$line" | grep -qi 'Override size'; then
    echo "$line" | grep -i 'Physical size' | grep -oE '[0-9]+x[0-9]+' | head -1 | tr 'x' ' '
  fi
}

# ===========================================================================
# INNER — FULL GOAL e2e
# ===========================================================================
inner_full() {
  source "$WORKSPACE/e2e/lib-net.sh"
  source "$WORKSPACE/e2e/lib-target.sh"
  source "$WORKSPACE/e2e/lib-automation.sh"

  log "INNER(full): starting on $(uname -m); target for A = 10.0.2.2:${BRIDGE_PORT}"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  ensure_build_tools
  build_native
  build_apks

  boot_both

  # Screen sizes.
  local ASIZE BSIZE AW AH BW BH
  ASIZE="$(wm_size "$SERIAL_A")"; AW="${ASIZE%% *}"; AH="${ASIZE##* }"
  BSIZE="$(wm_size "$SERIAL_B")"; BW="${BSIZE%% *}"; BH="${BSIZE##* }"
  log "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
  [ -n "$AW" ] && [ -n "$BW" ] || fail "could not read screen sizes (A='$ASIZE' B='$BSIZE')"

  # --- Install + LAUNCH the deterministic target app on B --------------------
  log "installing target app on B ($SERIAL_B)"
  target_install "$SERIAL_B" "$TARGET_APK" >/dev/null || fail "target install on B failed"
  log "launching target app on B"
  target_launch "$SERIAL_B" || fail "target app did not gain focus on B"
  log "B focus: $(target_focused "$SERIAL_B")"

  # Pre-clear B's pushed server + start B logcat (server-side evidence).
  adb -s "$SERIAL_B" shell rm -f /data/local/tmp/scrcpy-server.jar >/dev/null 2>&1 || true
  adb -s "$SERIAL_B" logcat -c >/dev/null 2>&1 || true
  ( adb -s "$SERIAL_B" logcat -v threadtime >"$ARTIFACTS/logcat-B-full.txt" 2>&1 ) &
  LOGCATB_PID=$!

  # --- Bridge B's adbd onto 10.0.2.2:6555 for A ------------------------------
  local ATARGET
  ATARGET="$(ensure_b_reachable "$SERIAL_B" "$ADBD_B" "$BRIDGE_PORT")" \
    || fail "ensure_b_reachable failed"
  local THOST="${ATARGET%%:*}" TPORT="${ATARGET##*:}"
  log "A connect target = $ATARGET"

  # --- Install + drive A's connect flow --------------------------------------
  log "installing android-app APK on A ($SERIAL_A)"
  adb -s "$SERIAL_A" install -r "$APK" >/dev/null || fail "adb install on A failed"

  adb -s "$SERIAL_A" logcat -c >/dev/null 2>&1 || true
  ( adb -s "$SERIAL_A" logcat -v threadtime >"$ARTIFACTS/logcat-A-full.txt" 2>&1 ) &
  LOGCATA_PID=$!

  log "launching $MAIN_ACT on A with host=$THOST port=$TPORT"
  adb -s "$SERIAL_A" shell am start -n "$MAIN_ACT" \
    --es host "$THOST" --es port "$TPORT" >/dev/null || fail "am start MainActivity failed"
  sleep 5

  # Locate + tap Connect.
  local UIXML="$ARTIFACTS/uidump-A-main.xml" dtry=0
  while [ "$dtry" -lt 6 ]; do
    adb -s "$SERIAL_A" shell uiautomator dump /sdcard/uidump.xml >/dev/null 2>&1 || true
    adb -s "$SERIAL_A" shell cat /sdcard/uidump.xml >"$UIXML" 2>/dev/null || true
    grep -q 'id/connectButton' "$UIXML" 2>/dev/null && break
    sleep 2; dtry=$((dtry+1))
  done
  local CXY
  CXY="$(node_center connectButton "$UIXML" || true)"
  [ -n "$CXY" ] || fail "could not locate connectButton in UI dump"
  log "tapping Connect ($CXY) -> ScrcpyActivity"
  adb -s "$SERIAL_A" shell input tap $CXY >/dev/null 2>&1 || true

  # --- Wait for a STABLE stream (server on B + scrcpy 'Connected' on A) -------
  log "waiting up to ${STREAM_SECS}s for a stable stream (server on B + Connected)"
  local ASTDIO="$ARTIFACTS/A-scrcpy-stdio.log" t=0 CONNECTED="" BPROC=""
  while [ "$t" -lt "$STREAM_SECS" ]; do
    adb -s "$SERIAL_A" shell run-as "$PKG" cat cache/scrcpy-stdio.log >"$ASTDIO" 2>/dev/null || true
    CONNECTED="$(grep -E 'INFO: Connected to ' "$ASTDIO" 2>/dev/null | head -1 || true)"
    BPROC="$(b_server_proc | head -1 || true)"
    [ -n "$CONNECTED" ] && [ -n "$BPROC" ] && break
    sleep 3; t=$((t+3))
  done
  [ -n "$CONNECTED" ] || fail "A did NOT reach scrcpy Connected (no 'INFO: Connected to')"
  [ -n "$BPROC" ]     || fail "scrcpy-server NOT running on B"
  log "stream up: '$CONNECTED' ; B server: '$BPROC'"
  # Let the first video frames + surface settle before tapping.
  sleep 6

  # The target on B must still own focus after the stream came up (scrcpy mirrors,
  # it does not change B's foreground app). Re-assert + relaunch if needed.
  if ! target_focused "$SERIAL_B" | grep -q "$TARGET_PKG"; then
    log "target lost focus on B — relaunching"
    target_launch "$SERIAL_B" || fail "could not refocus target on B"
  fi

  # --- Reset B's counter, then tap A's remote surface ------------------------
  log "resetting B tap counter (post-stream, so stray taps don't pollute)"
  target_reset "$SERIAL_B" || fail "target_reset on B failed"
  local START; START="$(auto_read_b "$SERIAL_B" file)"
  log "B state after reset: '$START' (expect taps=0)"

  # A tap points well inside the remote surface (avoid A's status/nav bars and the
  # left/right edges); chosen to span the surface so the derived transform is
  # well-conditioned: p1/p2 = calibration, p3..p5 = independent validation.
  local cx=$(( AW / 2 )) cy=$(( AH / 2 ))
  local x_lo=$(( AW * 30 / 100 ))  x_hi=$(( AW * 70 / 100 ))
  local y_lo=$(( AH * 30 / 100 ))  y_hi=$(( AH * 70 / 100 ))
  local PTS=(
    "$x_lo $y_lo"   # p1 calibration
    "$x_hi $y_hi"   # p2 calibration
    "$cx $cy"       # p3 validation (center)
    "$x_hi $y_lo"   # p4 validation
    "$x_lo $y_hi"   # p5 validation
  )

  local -a AX AY BX BY
  local i=0 prev_n=0
  for p in "${PTS[@]}"; do
    local ax="${p%% *}" ay="${p##* }"
    log "tap #$((i+1)) on A at ($ax,$ay)"
    auto_tap_on_a "$SERIAL_A" "$ax" "$ay"
    local wait=0 st n bx by
    while [ "$wait" -lt 12 ]; do
      st="$(auto_read_b "$SERIAL_B" file)"
      n="${st%% *}"; [ -z "$n" ] && n=0
      [ "$n" -gt "$prev_n" ] && break
      sleep 1; wait=$((wait+1))
    done
    st="$(auto_read_b "$SERIAL_B" file)"
    n="${st%% *}"; bx="$(echo "$st" | awk '{print $2}')"; by="$(echo "$st" | awk '{print $3}')"
    log "  -> B state '$st' (count=$n, recorded ($bx,$by))"
    AX[$i]="$ax"; AY[$i]="$ay"; BX[$i]="${bx:-NA}"; BY[$i]="${by:-NA}"
    prev_n="$n"
    i=$((i+1))
  done

  local FINAL FINAL_N
  FINAL="$(auto_read_b "$SERIAL_B" file)"; FINAL_N="${FINAL%% *}"
  log "B final state: '$FINAL' (expected count=${#PTS[@]})"

  for j in "${!AX[@]}"; do
    [ "${BX[$j]}" = "NA" ] && fail "tap $((j+1)) at (${AX[$j]},${AY[$j]}) was NOT received by B (count never incremented) — control path broken"
  done

  # --- Derive the A->B transform from the two calibration taps ---------------
  local XFORM
  XFORM="$(auto_derive_transform \
            "${AX[0]}" "${AY[0]}" "${BX[0]}" "${BY[0]}" \
            "${AX[1]}" "${AY[1]}" "${BX[1]}" "${BY[1]}")" \
    || fail "could not derive A->B transform from calibration taps"
  local SX1000 OX1000 SY1000 OY1000
  read -r SX1000 OX1000 SY1000 OY1000 <<<"$XFORM"
  log "derived A->B transform (x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"

  # --- Assert every point fits the transform ---------------------------------
  local EVID="$ARTIFACTS/m3-automation-evidence.txt"
  {
    echo "=== e2e GOAL: tap-A -> assert-B evidence ($(date '+%F %T')) ==="
    echo "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
    echo "Derived A->B transform (scaled x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"
    echo "  BX = round((SX*AX + OX)/1000) ; BY = round((SY*AY + OY)/1000)"
    echo "Tolerance: max(${AB_ABS_TOL}px, ${AB_REL_TOL_PCT}% of screen dim)"
    echo "Calibration taps: p1, p2 (transform fitted from these; they pass by construction)"
    echo
    printf '%-4s %-14s %-14s %-14s %-12s %s\n' "tap" "A(ax,ay)" "expect B" "got B" "dx,dy" "verdict"
  } >"$EVID"

  local all_pass=1 line role rc
  for j in "${!AX[@]}"; do
    line="$(auto_assert_point "$SX1000" "$OX1000" "$SY1000" "$OY1000" \
              "${AX[$j]}" "${AY[$j]}" "${BX[$j]}" "${BY[$j]}" "$BW" "$BH")"
    rc=$?
    role="validation"; { [ "$j" -eq 0 ] || [ "$j" -eq 1 ]; } && role="calibration"
    log "point $((j+1)) ($role): $line"
    printf '%s\n' "p$((j+1)) [$role] $line" >>"$EVID"
    [ "$rc" -eq 0 ] || all_pass=0
  done
  echo >>"$EVID"
  echo "B final tap count = $FINAL_N (sent ${#PTS[@]})" >>"$EVID"

  log "==== evidence ($EVID) ===="; cat "$EVID" >&2; log "==== end evidence ===="

  # --- Final verdicts --------------------------------------------------------
  [ "$FINAL_N" = "${#PTS[@]}" ] \
    || fail "B tap count $FINAL_N != ${#PTS[@]} sent — taps lost/duplicated on the control path"
  [ "$all_pass" -eq 1 ] \
    || fail "at least one tap did NOT map to the expected B coordinate within tolerance"

  kill "$LOGCATA_PID" "$LOGCATB_PID" >/dev/null 2>&1 || true
  log "PASS: every tap on A's remote view was received by B at the expected coordinate."
  exit 0
}

# ===========================================================================
# INNER — M0 SMOKE placeholder (harness sanity only; no native lib / APKs)
# ===========================================================================
assert_online() {
  local out
  out="$(adb devices)"
  log "adb devices:"; printf '%s\n' "$out" >&2
  echo "$out" | grep -qE "^${SERIAL_B}[[:space:]]+device$" \
    || fail "B ($SERIAL_B) is not online in adb devices"
  echo "$out" | grep -qE "^${SERIAL_A}[[:space:]]+device$" \
    || fail "A ($SERIAL_A) is not online in adb devices"
  log "ASSERT ok: both emulators show as 'device'"
}

assert_controllable() {
  local serial="$SERIAL_B"
  local marker="e2e_$(date +%s)"
  adb -s "$serial" shell settings put system e2e_probe "$marker" >/dev/null
  local got
  got="$(adb -s "$serial" shell settings get system e2e_probe 2>/dev/null | tr -d '\r\n ')"
  [ "$got" = "$marker" ] || fail "settings round-trip failed (put=$marker get=$got)"
  log "ASSERT ok: settings round-trip on B ($got)"

  local focus_before focus_after
  focus_before="$(adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
  adb -s "$serial" shell am start -W -n com.android.settings/.Settings >/dev/null 2>&1 || true
  local tries=0
  while [ "$tries" -lt 20 ]; do
    focus_after="$(adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
    [ "$focus_after" != "$focus_before" ] && echo "$focus_after" | grep -qi settings && break
    sleep 1; tries=$((tries+1))
  done
  echo "$focus_after" | grep -qi "settings" \
    || fail "am start did not move focus to Settings (after='$focus_after')"
  log "ASSERT ok: am start changed mCurrentFocus to Settings on B"

  adb -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  adb -s "$serial" shell input tap 200 600 >/dev/null 2>&1 || true
  log "ASSERT ok: input keyevent/tap dispatched to B without error"
}

inner_smoke() {
  # The M0 placeholder needs lib-net's stop_b_bridge for cleanup symmetry only.
  source "$WORKSPACE/e2e/lib-net.sh" 2>/dev/null || true
  log "INNER(smoke): M0 placeholder — boot both + adb online + B controllable"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"
  boot_both
  assert_online
  assert_controllable
  log "all SMOKE assertions passed"
  exit 0
}

inner() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "INNER: $(uname -m); whoami=$(whoami); EMU_MEM=${EMU_MEM} BOOT_TIMEOUT=${BOOT_TIMEOUT} STREAM_SECS=${STREAM_SECS}"
  log "KVM: $(ls -l /dev/kvm 2>&1 || echo 'NO /dev/kvm')"
  case "${1:-}" in
    --smoke) inner_smoke ;;
    *)       inner_full ;;
  esac
}

# ===========================================================================
# Dispatch
# ===========================================================================
case "${1:-}" in
  --inner) shift; inner "$@" ;;
  --smoke) outer --smoke ;;
  *)       outer ;;
esac
