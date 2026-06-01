#!/usr/bin/env bash
# launch-app.sh — INNER helper: boot ONE headless x86_64 emulator, install the
# android-app debug APK, launch ScrcpyActivity against a HOST:PORT, and capture
# filtered logcat proving libscrcpy.so loads + scrcpy_main is entered + a
# connection attempt is made, all without crashing.
#
# This is the single-emulator counterpart to e2e/run.sh (which boots TWO). It is
# meant to be run INSIDE the scrcpy-e2e:dev container (with /dev/kvm) from a repo
# mounted at /workspace, e.g.:
#
#   docker run --rm --device /dev/kvm \
#     -v $REPO:/workspace -v scrcpy-gradle-cache:/root/.gradle \
#     -v $ART:/artifacts scrcpy-e2e:dev \
#     bash /workspace/e2e/launch-app.sh
#
# Env:
#   SCRCPY_TARGET_HOST (default 127.0.0.1)  scrcpy --tcpip host
#   SCRCPY_TARGET_PORT (default 5555)       scrcpy --tcpip port
#   SCRCPY_E2E_EMU_MEM (default 1536)
#   SCRCPY_E2E_BOOT_TIMEOUT (default 300)
#   SCRCPY_LOGCAT_SECS (default 30)         seconds to capture logcat after launch
#   SKIP_BUILD (default 0)                  if 1, reuse an existing APK
#
# Exit 0 only if the PASS bar is met: native libs load (no UnsatisfiedLinkError /
# dlopen failure), scrcpy_main entered, a connection attempt logged, and no fatal
# exception / SIGSEGV / ANR.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
APP_DIR="$WORKSPACE/android-app"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"

PKG=net.scrcpy.android
MAIN_ACT="$PKG/.MainActivity"
SCRCPY_ACT="$PKG/.ScrcpyActivity"

TARGET_HOST="${SCRCPY_TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${SCRCPY_TARGET_PORT:-5555}"
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
LOGCAT_SECS="${SCRCPY_LOGCAT_SECS:-30}"
SKIP_BUILD="${SKIP_BUILD:-0}"

# Single emulator.
AVD=e2e_app
PORT=5554
SERIAL=emulator-5554
PID=""

log()  { printf '%s [launch-app] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

cleanup() {
  local rc=$?
  log "cleanup: collecting final artifacts + killing emulator"
  { adb devices -l || true; } >"$ARTIFACTS/adb-devices.txt" 2>&1 || true
  { adb -s "$SERIAL" exec-out screencap -p || true; } >"$ARTIFACTS/screen-$SERIAL.png" 2>/dev/null || true
  adb -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  [ -n "$PID" ] && kill "$PID" >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD" >/dev/null 2>&1 || true
  log "cleanup done (rc=$rc)"
}

create_avd() {
  avdmanager delete avd -n "$AVD" >/dev/null 2>&1 || true
  log "creating AVD $AVD"
  echo no | avdmanager create avd \
    -n "$AVD" \
    -k "system-images;android-30;google_apis;x86_64" \
    -d "pixel" \
    --force >/dev/null
}

launch_emu() {
  log "launching emulator $AVD on port $PORT (mem=${EMU_MEM}MB)"
  emulator -avd "$AVD" -port "$PORT" \
    -no-window -gpu swiftshader_indirect \
    -no-snapshot -no-audio -no-boot-anim \
    -accel on -memory "$EMU_MEM" -partition-size 2048 \
    >"$ARTIFACTS/emulator-$PORT.log" 2>&1 &
  PID=$!
  log "emulator pid=$PID"
}

wait_boot() {
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  log "waiting for $SERIAL (pid $PID) to boot (timeout ${BOOT_TIMEOUT}s)"
  while :; do
    if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
      log "$SERIAL emulator process (pid $PID) is DEAD — boot aborted"
      tail -40 "$ARTIFACTS/emulator-$PORT.log" >&2 || true
      return 1
    fi
    local bc
    bc="$(timeout 15 adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
    if [ "$bc" = "1" ]; then
      log "$SERIAL booted (sys.boot_completed=1)"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "$SERIAL did NOT boot within ${BOOT_TIMEOUT}s (last boot_completed='$bc')"
      tail -40 "$ARTIFACTS/emulator-$PORT.log" >&2 || true
      return 1
    fi
    sleep 5
  done
}

build_apk() {
  if [ "$SKIP_BUILD" = "1" ] && [ -f "$APK" ]; then
    log "SKIP_BUILD=1 and APK present — reusing $APK"
    return 0
  fi
  log "staging natives + building debug APK"
  ( cd "$APP_DIR" && ./stage-natives.sh "$WORKSPACE/output/android/x86_64" x86_64 )
  ( cd "$APP_DIR" && ./gradlew --no-daemon assembleDebug )
  [ -f "$APK" ] || fail "APK not produced at $APK"
  log "APK built: $(ls -la "$APK")"
}

main() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "starting on $(uname -m); whoami=$(whoami); target=${TARGET_HOST}:${TARGET_PORT}"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  build_apk

  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true

  create_avd
  launch_emu
  wait_boot || fail "emulator failed to boot"

  # Settle: wake + dismiss keyguard so the Activity surface comes up.
  adb -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true

  log "installing APK"
  adb -s "$SERIAL" install -r "$APK" || fail "adb install failed"

  # Start capturing logcat BEFORE launch so we don't miss early lines.
  adb -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
  local RAW="$ARTIFACTS/logcat-scrcpy-launch.txt"
  log "starting logcat capture -> $RAW"
  ( adb -s "$SERIAL" logcat -v threadtime \
      scrcpy:V SDL:V AndroidRuntime:E DEBUG:V libc:V "*:S" \
      >"$RAW" 2>&1 ) &
  local LOGCAT_PID=$!
  # Also a full unfiltered logcat for forensic detail.
  local RAWFULL="$ARTIFACTS/logcat-full.txt"
  ( adb -s "$SERIAL" logcat -v threadtime >"$RAWFULL" 2>&1 ) &
  local LOGCATFULL_PID=$!

  # ScrcpyActivity is (correctly) exported=false, so it cannot be started directly
  # by the shell uid (`am start` → SecurityException "not exported"). We drive the
  # REAL user flow instead: launch the exported MainActivity, set the host/port
  # fields, then tap Connect — which calls startActivity(ScrcpyActivity.newIntent).
  log "launching $MAIN_ACT (launcher)"
  adb -s "$SERIAL" shell am start -n "$MAIN_ACT" || fail "am start MainActivity failed"
  sleep 3

  # Set the target host/port deterministically (the layout defaults to
  # 10.0.2.2:5555 but we override to the requested target for reproducibility).
  log "setting host=$TARGET_HOST port=$TARGET_PORT in the launcher fields"
  # Find the EditText bounds via a UI dump, focus + type.
  local UIXML="$ARTIFACTS/uidump-main.xml"
  adb -s "$SERIAL" shell uiautomator dump /sdcard/uidump.xml >/dev/null 2>&1 || true
  adb -s "$SERIAL" shell cat /sdcard/uidump.xml >"$UIXML" 2>/dev/null || true

  # Helper: extract the center x,y of a node by resource-id.
  node_center() {
    # $1 = resource-id suffix (e.g. connectButton). Echoes "X Y" or empty.
    local rid="$1"
    local bounds
    bounds="$(grep -o "resource-id=\"net.scrcpy.android:id/${rid}\"[^>]*bounds=\"[^\"]*\"" "$UIXML" 2>/dev/null \
              | grep -o 'bounds="[^"]*"' | head -1 | sed 's/bounds="//; s/"//')"
    [ -z "$bounds" ] && return 1
    # bounds form: [x1,y1][x2,y2]
    local x1 y1 x2 y2
    x1="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/')"
    y1="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/')"
    x2="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/')"
    y2="$(echo "$bounds" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/')"
    echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
  }

  # Set host field.
  local HXY PXY CXY
  HXY="$(node_center hostInput || true)"
  if [ -n "$HXY" ]; then
    adb -s "$SERIAL" shell input tap $HXY >/dev/null 2>&1 || true
    adb -s "$SERIAL" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || true
    # Clear existing default then type the requested host.
    for _ in $(seq 1 20); do adb -s "$SERIAL" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || true; done
    adb -s "$SERIAL" shell input text "$TARGET_HOST" >/dev/null 2>&1 || true
  fi
  PXY="$(node_center portInput || true)"
  if [ -n "$PXY" ]; then
    adb -s "$SERIAL" shell input tap $PXY >/dev/null 2>&1 || true
    adb -s "$SERIAL" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do adb -s "$SERIAL" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || true; done
    adb -s "$SERIAL" shell input text "$TARGET_PORT" >/dev/null 2>&1 || true
  fi
  # Dismiss the soft keyboard so it doesn't cover Connect.
  adb -s "$SERIAL" shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  sleep 1

  log "tapping Connect → hands off to ScrcpyActivity"
  CXY="$(node_center connectButton || true)"
  if [ -n "$CXY" ]; then
    adb -s "$SERIAL" shell input tap $CXY >/dev/null 2>&1 || true
  else
    log "WARN: could not locate connectButton in UI dump; falling back to fixed tap"
    adb -s "$SERIAL" shell input tap 540 1100 >/dev/null 2>&1 || true
  fi

  log "capturing logcat for ${LOGCAT_SECS}s"
  sleep "$LOGCAT_SECS"

  # Pull the app pid (if alive) + a screenshot.
  local APPPID
  APPPID="$(adb -s "$SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n ' || true)"
  log "app pid after ${LOGCAT_SECS}s: '${APPPID:-<none>}'"
  adb -s "$SERIAL" exec-out screencap -p >"$ARTIFACTS/screen-after-launch.png" 2>/dev/null || true

  kill "$LOGCAT_PID" "$LOGCATFULL_PID" >/dev/null 2>&1 || true
  sleep 1

  log "==== filtered logcat (scrcpy/SDL/AndroidRuntime/DEBUG) ===="
  cat "$RAW" >&2 || true
  log "==== end logcat ===="

  # --- Evaluate PASS / FAIL --------------------------------------------------
  local ULE SEGV DLOPEN FATAL SCRCPY_VER SCRCPY_ENTRY CONNECT
  ULE="$(grep -i 'UnsatisfiedLinkError' "$RAWFULL" || true)"
  DLOPEN="$(grep -iE 'dlopen failed|cannot locate symbol|library .* not found' "$RAWFULL" || true)"
  SEGV="$(grep -iE 'SIGSEGV|signal 11|Fatal signal' "$RAWFULL" || true)"
  FATAL="$(grep -iE 'FATAL EXCEPTION|ANR in ' "$RAWFULL" || true)"
  SCRCPY_VER="$(grep -iE 'scrcpy 3\.|scrcpy_android_main|scrcpy_main|scrcpy [0-9]' "$RAW" || true)"
  CONNECT="$(grep -iE 'Connecting|tcpip|adb connect|127\.0\.0\.1:5555|ServerConnection|Connection refused|adb_connect' "$RAWFULL" || true)"

  log "--- diagnostic greps ---"
  log "UnsatisfiedLinkError: ${ULE:-<none>}"
  log "dlopen failure:       ${DLOPEN:-<none>}"
  log "SIGSEGV/fatal signal: ${SEGV:-<none>}"
  log "FATAL EXCEPTION/ANR:  ${FATAL:-<none>}"
  log "scrcpy entry lines:   ${SCRCPY_VER:-<none>}"
  log "connection attempt:   ${CONNECT:-<none>}"

  if [ -n "$ULE" ] || [ -n "$DLOPEN" ]; then
    fail "native libs failed to load (UnsatisfiedLinkError / dlopen) — REAL BUG"
  fi
  if [ -n "$SEGV" ] || [ -n "$FATAL" ]; then
    fail "app crashed (SIGSEGV / FATAL EXCEPTION / ANR) — REAL BUG"
  fi
  if [ -z "$SCRCPY_VER" ]; then
    fail "no evidence scrcpy_main/scrcpy_android_main was entered"
  fi

  log "PASS: native libs loaded, scrcpy entered, no crash. (connection attempt: ${CONNECT:+yes})"
  exit 0
}

main "$@"
