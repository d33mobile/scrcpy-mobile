#!/usr/bin/env bash
# M3 task 2 — deterministic input-target self-test (INNER, in scrcpy-e2e:dev).
#
# Builds the target APK, boots ONE emulator (reusing run.sh's AVD/flags/boot
# logic), installs + launches the target Activity, taps TWO known coordinates,
# and PROVES the state changed via ALL THREE channels (uiautomator text, logcat,
# file) and that the recorded (X,Y) matches the input (X,Y) within rounding.
#
# Not a permanent harness — a focused proof for M3 task 2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
ARTIFACTS=/artifacts
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"

AVD_B=e2e_target
PORT_B=5554
SERIAL_B=emulator-5554
PID_B=""

log()  { printf '%s [target-selftest] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

# shellcheck source=lib-target.sh
. "$HERE/lib-target.sh"

cleanup() {
  local rc=$?
  log "cleanup (rc=$rc)"
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1 || true
  [ -n "$PID_B" ] && kill "$PID_B" >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1 || true
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
      log "$serial process DEAD"; return 1; fi
    local bc
    bc="$(timeout 15 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
    [ "$bc" = "1" ] && { log "$serial booted"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { log "$serial NOT booted (last='$bc')"; return 1; }
    sleep 5
  done
}

# Build the target APK inside the container's gradle environment.
build_apk() {
  log "building target APK (./gradlew --no-daemon assembleDebug)"
  ( cd "$REPO_ROOT/e2e/target-app" && ./gradlew --no-daemon assembleDebug ) \
    >"$ARTIFACTS/target-gradle-build.log" 2>&1 \
    || { tail -60 "$ARTIFACTS/target-gradle-build.log" >&2; fail "target APK build failed"; }
  APK="$REPO_ROOT/e2e/target-app/app/build/outputs/apk/debug/app-debug.apk"
  [ -f "$APK" ] || fail "APK not found at $APK"
  log "APK built: $APK ($(stat -c%s "$APK") bytes)"
}

# Assert recorded coords match expected within tolerance (rounding/insets).
assert_coords() {
  local label="$1" gotx="$2" goty="$3" wantx="$4" wanty="$5" tol="${6:-2}"
  local dx=$(( gotx - wantx )); [ "$dx" -lt 0 ] && dx=$(( -dx ))
  local dy=$(( goty - wanty )); [ "$dy" -lt 0 ] && dy=$(( -dy ))
  if [ "$dx" -le "$tol" ] && [ "$dy" -le "$tol" ]; then
    log "  OK ($label): got=$gotx,$goty want=$wantx,$wanty (dx=$dx dy=$dy <= $tol)"
    return 0
  fi
  fail "$label coords mismatch: got=$gotx,$goty want=$wantx,$wanty (dx=$dx dy=$dy)"
}

# Read all three channels and assert they agree with expected (N,X,Y).
prove_tap() {
  local n="$1" wx="$2" wy="$3"
  log "--- proving tap #$n at ($wx,$wy) across all channels ---"

  local fstate ustate lstate
  set +e
  fstate="$(target_read_state "$SERIAL_B" file)"
  ustate="$(target_read_state "$SERIAL_B" ui)"
  lstate="$(target_read_state "$SERIAL_B" logcat)"
  set -e
  log "  file   channel: '$fstate'"
  log "  ui     channel: '$ustate'"
  log "  logcat channel: '$lstate'"

  [ -n "$fstate" ] || fail "file channel empty (expected '$n $wx $wy')"
  [ -n "$ustate" ] || fail "ui channel empty (expected '$n $wx $wy')"
  [ -n "$lstate" ] || fail "logcat channel empty (expected '$n $wx $wy')"

  # File channel
  read -r fn fx fy <<<"$fstate"
  [ "$fn" = "$n" ] || fail "file taps=$fn expected $n"
  assert_coords "file" "$fx" "$fy" "$wx" "$wy"

  # UI channel
  read -r un ux uy <<<"$ustate"
  [ "$un" = "$n" ] || fail "ui taps=$un expected $n"
  assert_coords "ui" "$ux" "$uy" "$wx" "$wy"

  # Logcat channel
  read -r ln lx ly <<<"$lstate"
  [ "$ln" = "$n" ] || fail "logcat tap #$ln expected $n"
  assert_coords "logcat" "$lx" "$ly" "$wx" "$wy"

  log "--- tap #$n proven on all 3 channels ---"
}

main() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "INNER self-test start; EMU_MEM=$EMU_MEM"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible"

  build_apk

  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true

  create_avd "$AVD_B"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; log "B pid=$PID_B"
  wait_boot "$SERIAL_B" "$PID_B" || { tail -40 "$ARTIFACTS/emulator-$PORT_B.log" >&2; fail "B boot"; }

  adb -s "$SERIAL_B" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$SERIAL_B" shell wm dismiss-keyguard >/dev/null 2>&1 || true

  log "installing target APK"
  target_install "$SERIAL_B" "$APK" >&2

  log "launching TargetActivity"
  target_launch "$SERIAL_B" || fail "target_launch failed"
  log "mCurrentFocus: $(target_focused "$SERIAL_B")"

  # Clear logcat so per-tap line counting is unambiguous.
  adb -s "$SERIAL_B" logcat -c >/dev/null 2>&1 || true

  # ---- Tap #1 at a known coordinate ----
  local X1=200 Y1=400
  log "input tap $X1 $Y1"
  target_tap "$SERIAL_B" "$X1" "$Y1"
  sleep 2
  prove_tap 1 "$X1" "$Y1"

  # ---- Tap #2 at a different known coordinate ----
  local X2=540 Y2=1000
  log "input tap $X2 $Y2"
  target_tap "$SERIAL_B" "$X2" "$Y2"
  sleep 2
  prove_tap 2 "$X2" "$Y2"

  # Capture verbatim evidence for STATE.md.
  {
    echo "=== mCurrentFocus ==="
    target_focused "$SERIAL_B"
    echo "=== file channel (run-as $TARGET_PKG cat $TARGET_STATE_RELPATH) ==="
    adb -s "$SERIAL_B" shell run-as "$TARGET_PKG" cat "$TARGET_STATE_RELPATH"
    echo "=== uiautomator (taps=N last=X,Y node) ==="
    adb -s "$SERIAL_B" shell uiautomator dump /sdcard/e2e_ui.xml >/dev/null 2>&1 || true
    adb -s "$SERIAL_B" shell cat /sdcard/e2e_ui.xml | grep -o 'taps=[0-9]* last=[0-9-]*,[0-9-]*' | head -1
    echo "=== logcat -d -s E2E_TARGET ==="
    adb -s "$SERIAL_B" logcat -d -s "$TARGET_TAG"
  } >"$ARTIFACTS/m3-target-evidence.txt" 2>&1
  log "evidence -> $ARTIFACTS/m3-target-evidence.txt"

  log "PASS: target app records taps deterministically; all 3 channels agree;"
  log "      recorded coords match input coords within tolerance."
  exit 0
}

main "$@"
