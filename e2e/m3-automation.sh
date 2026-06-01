#!/usr/bin/env bash
# m3-automation.sh — M3 task 4 harness: FULL GUI automation proving A controls B.
#
# Boots BOTH emulators (B=target 5554/5555, A=controller 5556/5557), bridges B's
# adbd to 10.0.2.2:6555 (lib-net.sh), installs + LAUNCHES the deterministic target
# app on B (lib-target.sh), installs our APK on A and drives MainActivity ->
# Connect -> ScrcpyActivity so A renders B's screen, then:
#
#   * resets B's tap counter AFTER the stream is stable,
#   * injects taps on A's rendered remote-view surface (`adb -s A input tap AX AY`),
#   * derives the A->B coordinate transform from the first 2 calibration taps,
#   * asserts every further tap maps to the correct B location within tolerance,
#   * asserts the total tap count on B equals the number of taps we sent.
#
# This is THE GOAL proof: a tap on A's remote view is provably received by B at
# the expected location. Reusable harness logic lives in e2e/lib-automation.sh.
#
# Runs INSIDE scrcpy-e2e:dev (with /dev/kvm), repo mounted at /workspace.
#
# Env:
#   SCRCPY_E2E_EMU_MEM       (default 1536)
#   SCRCPY_E2E_BOOT_TIMEOUT  (default 300)
#   SCRCPY_STREAM_SECS       (default 60)  max seconds to wait for a stable stream
#   SKIP_BUILD               (default 0)   reuse existing APKs
#   M3_BRIDGE_PORT           (default 6555)
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
APP_DIR="$WORKSPACE/android-app"
TARGET_DIR="$WORKSPACE/e2e/target-app"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
export SCRCPY_E2E_ARTIFACTS="$ARTIFACTS"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
TARGET_APK="$TARGET_DIR/app/build/outputs/apk/debug/app-debug.apk"

# shellcheck source=lib-net.sh
source "$WORKSPACE/e2e/lib-net.sh"
# shellcheck source=lib-target.sh
source "$WORKSPACE/e2e/lib-target.sh"
# shellcheck source=lib-automation.sh
source "$WORKSPACE/e2e/lib-automation.sh"

PKG=net.scrcpy.android
MAIN_ACT="$PKG/.MainActivity"

EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
STREAM_SECS="${SCRCPY_STREAM_SECS:-60}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BRIDGE_PORT="${M3_BRIDGE_PORT:-6555}"

AVD_B=e2e_target
AVD_A=e2e_controller
PORT_B=5554
PORT_A=5556
SERIAL_B=emulator-5554
SERIAL_A=emulator-5556
ADBD_B=5555
PID_B=""
PID_A=""

log()  { printf '%s [m3-auto] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

cleanup() {
  local rc=$?
  log "cleanup: collecting artifacts + killing emulators"
  { adb devices -l || true; } >"$ARTIFACTS/adb-devices.txt" 2>&1 || true
  for s in "$SERIAL_B" "$SERIAL_A"; do
    { adb -s "$s" exec-out screencap -p || true; } >"$ARTIFACTS/screen-$s.png" 2>/dev/null || true
  done
  stop_b_bridge "$BRIDGE_PORT" || true
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
  local name="$1" port="$2"
  log "launching emulator $name on port $port (mem=${EMU_MEM}MB)"
  emulator -avd "$name" -port "$port" \
    -no-window -gpu swiftshader_indirect \
    -no-snapshot -no-audio -no-boot-anim \
    -accel on -memory "$EMU_MEM" -partition-size 2048 \
    >"$ARTIFACTS/emulator-$port.log" 2>&1 &
  echo $!
}

wait_boot() {
  local serial="$1" pid="$2" deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  log "waiting for $serial (pid $pid) to boot (timeout ${BOOT_TIMEOUT}s)"
  while :; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "$serial process (pid $pid) DEAD — boot aborted"; return 1
    fi
    local bc
    bc="$(timeout 15 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
    [ "$bc" = "1" ] && { log "$serial booted"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { log "$serial boot TIMEOUT (last='$bc')"; return 1; }
    sleep 5
  done
}

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

b_server_proc() {
  adb -s "$SERIAL_B" shell ps -A 2>/dev/null \
    | grep -iE 'app_process|scrcpy' | grep -vi grep || true
}

# wm_size <serial> -> echoes "W H" (override size if present, else physical).
wm_size() {
  local serial="$1" line
  line="$(adb -s "$serial" shell wm size 2>/dev/null | tr -d '\r')"
  # Prefer "Override size:" if present, else "Physical size:".
  echo "$line" | grep -i 'Override size' | grep -oE '[0-9]+x[0-9]+' | head -1 | tr 'x' ' ' \
    || true
  if ! echo "$line" | grep -qi 'Override size'; then
    echo "$line" | grep -i 'Physical size' | grep -oE '[0-9]+x[0-9]+' | head -1 | tr 'x' ' '
  fi
}

build_apks() {
  if [ "$SKIP_BUILD" = "1" ] && [ -f "$APK" ] && [ -f "$TARGET_APK" ]; then
    log "SKIP_BUILD=1 and both APKs present — reusing"; return 0
  fi
  log "staging natives + scrcpy-server asset + building android-app APK"
  ( cd "$APP_DIR" && ./stage-natives.sh "$WORKSPACE/output/android/x86_64" x86_64 )
  ( cd "$APP_DIR" && ./gradlew --no-daemon assembleDebug )
  [ -f "$APK" ] || fail "android-app APK not produced at $APK"
  log "building target-app APK"
  ( cd "$TARGET_DIR" && ./gradlew --no-daemon assembleDebug )
  [ -f "$TARGET_APK" ] || fail "target-app APK not produced at $TARGET_APK"
  log "APKs built: $(ls -la "$APK" "$TARGET_APK")"
}

main() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "starting on $(uname -m); target for A = 10.0.2.2:${BRIDGE_PORT}"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  build_apks

  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true

  create_avd "$AVD_B"
  create_avd "$AVD_A"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; log "B pid=$PID_B"
  PID_A="$(launch_emu "$AVD_A" "$PORT_A")"; log "A pid=$PID_A"

  wait_boot "$SERIAL_B" "$PID_B" || { tail -40 "$ARTIFACTS/emulator-$PORT_B.log" >&2; fail "B failed to boot"; }
  wait_boot "$SERIAL_A" "$PID_A" || { tail -40 "$ARTIFACTS/emulator-$PORT_A.log" >&2; fail "A failed to boot"; }

  for s in "$SERIAL_B" "$SERIAL_A"; do
    adb -s "$s" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb -s "$s" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
    adb -s "$s" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
  done

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
  local LOGCATB_PID=$!

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
  local LOGCATA_PID=$!

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
    if [ -n "$CONNECTED" ] && [ -n "$BPROC" ]; then break; fi
    sleep 3; t=$((t+3))
  done
  [ -n "$CONNECTED" ] || fail "A did NOT reach scrcpy Connected (no 'INFO: Connected to')"
  [ -n "$BPROC" ]     || fail "scrcpy-server NOT running on B"
  log "stream up: '$CONNECTED' ; B server: '$BPROC'"
  # Give the first video frames + surface a moment to settle before tapping.
  sleep 6

  # The target on B must still own focus after the stream came up (scrcpy doesn't
  # change B's foreground app; it only mirrors). Re-assert + relaunch if needed.
  if ! target_focused "$SERIAL_B" | grep -q "$TARGET_PKG"; then
    log "target lost focus on B — relaunching"
    target_launch "$SERIAL_B" || fail "could not refocus target on B"
  fi

  # --- THE KEY STEP: reset B's counter, then tap A's remote surface ----------
  log "resetting B tap counter (post-stream, so stray taps don't pollute)"
  target_reset "$SERIAL_B" || fail "target_reset on B failed"
  local START; START="$(auto_read_b "$SERIAL_B" file)"
  log "B state after reset: '$START' (expect taps=0)"

  # Choose A tap points well inside the remote surface. A's status bar (~top) and
  # nav bar (~bottom) are NOT part of the surface, so keep AY within the middle
  # band; keep AX away from the left/right edges. Points chosen to span the
  # surface so the derived transform is well-conditioned:
  #   p1 = upper-left-ish, p2 = lower-right-ish (the two CALIBRATION taps),
  #   p3 = center, p4 = upper-right-ish, p5 = lower-left-ish (VALIDATION taps).
  local cx=$(( AW / 2 )) cy=$(( AH / 2 ))
  local x_lo=$(( AW * 30 / 100 ))  x_hi=$(( AW * 70 / 100 ))
  local y_lo=$(( AH * 30 / 100 ))  y_hi=$(( AH * 70 / 100 ))
  # A points (AX AY) ordered: calibration first, then validation.
  local PTS=(
    "$x_lo $y_lo"   # p1 calibration
    "$x_hi $y_hi"   # p2 calibration
    "$cx $cy"       # p3 validation (center)
    "$x_hi $y_lo"   # p4 validation
    "$x_lo $y_hi"   # p5 validation
  )

  # Inject each tap and record the resulting B coordinate. We read the count too,
  # to assert exactly-one-tap-per-injection.
  local -a AX AY BX BY
  local i=0 prev_n=0
  for p in "${PTS[@]}"; do
    local ax="${p%% *}" ay="${p##* }"
    log "tap #$((i+1)) on A at ($ax,$ay)"
    auto_tap_on_a "$SERIAL_A" "$ax" "$ay"
    # Poll B until the tap count increments (the control channel + injection has
    # a little latency); fall back after a bounded wait.
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

  # Final count must equal the number of taps we sent.
  local FINAL FINAL_N
  FINAL="$(auto_read_b "$SERIAL_B" file)"; FINAL_N="${FINAL%% *}"
  log "B final state: '$FINAL' (expected count=${#PTS[@]})"

  # All taps must have registered (no NA / zero-count points).
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
  log "  => BX = round((${SX1000}*AX + ${OX1000})/1000), BY = round((${SY1000}*AY + ${OY1000})/1000)"

  # --- Assert every point fits the transform ---------------------------------
  local EVID="$ARTIFACTS/m3-automation-evidence.txt"
  {
    echo "=== M3 task 4: tap-A -> assert-B evidence ($(date '+%F %T')) ==="
    echo "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
    echo "Derived A->B transform (scaled x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"
    echo "  BX = round((SX*AX + OX)/1000) ; BY = round((SY*AY + OY)/1000)"
    echo "Tolerance: max(${AB_ABS_TOL}px, ${AB_REL_TOL_PCT}% of screen dim)"
    echo "Calibration taps: p1, p2 (transform fitted from these; they pass by construction)"
    echo
    printf '%-4s %-14s %-14s %-14s %-12s %s\n' "tap" "A(ax,ay)" "expect B" "got B" "dx,dy" "verdict"
  } >"$EVID"

  local all_pass=1 line role
  for j in "${!AX[@]}"; do
    line="$(auto_assert_point "$SX1000" "$OX1000" "$SY1000" "$OY1000" \
              "${AX[$j]}" "${AY[$j]}" "${BX[$j]}" "${BY[$j]}" "$BW" "$BH")"
    local rc=$?
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

main "$@"
