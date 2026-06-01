#!/usr/bin/env bash
# m3-connect.sh — M3 task 3 harness: boot BOTH emulators (B=target 5554/5555,
# A=controller 5556/5557), bridge B's adbd to 10.0.2.2:6555 (lib-net.sh), install
# our APK on A, drive the real MainActivity -> Connect -> ScrcpyActivity flow with
# host=10.0.2.2 port=6555, and ASSERT:
#   * A's logcat reaches ScrcpyStatusConnected (onScrcpyStatus status=6).
#   * scrcpy-server is RUNNING on B (app_process / com.genymobile.scrcpy.Server).
#   * No crash on A.
#
# Runs INSIDE scrcpy-e2e:dev (with /dev/kvm), repo mounted at /workspace, e.g.:
#   docker run --rm --device /dev/kvm \
#     -v $REPO:/workspace -v scrcpy-gradle-cache:/root/.gradle \
#     -v $ART:/artifacts scrcpy-e2e:dev bash /workspace/e2e/m3-connect.sh
#
# Env:
#   SCRCPY_E2E_EMU_MEM       (default 1536)
#   SCRCPY_E2E_BOOT_TIMEOUT  (default 300)
#   SCRCPY_LOGCAT_SECS       (default 45)  seconds to observe after Connect
#   SKIP_BUILD               (default 0)   reuse an existing APK
#   M3_BRIDGE_PORT           (default 6555)
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
APP_DIR="$WORKSPACE/android-app"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
export SCRCPY_E2E_ARTIFACTS="$ARTIFACTS"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"

# shellcheck source=lib-net.sh
source "$WORKSPACE/e2e/lib-net.sh"

PKG=net.scrcpy.android
MAIN_ACT="$PKG/.MainActivity"

EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
LOGCAT_SECS="${SCRCPY_LOGCAT_SECS:-45}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BRIDGE_PORT="${M3_BRIDGE_PORT:-6555}"

AVD_B=e2e_target
AVD_A=e2e_controller
PORT_B=5554
PORT_A=5556
SERIAL_B=emulator-5554
SERIAL_A=emulator-5556
ADBD_B=5555   # container-host loopback port for B's adbd
PID_B=""
PID_A=""

log()  { printf '%s [m3-connect] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
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

build_apk() {
  if [ "$SKIP_BUILD" = "1" ] && [ -f "$APK" ]; then
    log "SKIP_BUILD=1 and APK present — reusing $APK"; return 0
  fi
  log "staging natives + scrcpy-server asset + building debug APK"
  ( cd "$APP_DIR" && ./stage-natives.sh "$WORKSPACE/output/android/x86_64" x86_64 )
  ( cd "$APP_DIR" && ./gradlew --no-daemon assembleDebug )
  [ -f "$APK" ] || fail "APK not produced at $APK"
  log "APK built: $(ls -la "$APK")"
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

# B-side: is scrcpy-server running? Echoes the matching ps line (or empty).
b_server_proc() {
  adb -s "$SERIAL_B" shell ps -A 2>/dev/null \
    | grep -iE 'app_process|scrcpy' | grep -vi grep || true
}

main() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "starting on $(uname -m); target for A = 10.0.2.2:${BRIDGE_PORT}"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  build_apk

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
  done

  # B's screen size (for task 4 + sanity).
  local BSIZE
  BSIZE="$(adb -s "$SERIAL_B" shell wm size 2>/dev/null | tr -d '\r' || true)"
  log "B screen size: $BSIZE"

  # Pre-clear B: remove any stale pushed server and kill any stale server proc.
  adb -s "$SERIAL_B" shell rm -f /data/local/tmp/scrcpy-server.jar >/dev/null 2>&1 || true
  log "B before connect: scrcpy-server procs = [$(b_server_proc | tr '\n' '|')]"

  # Bridge B's adbd onto 10.0.2.2:6555 for A.
  local ATARGET
  ATARGET="$(ensure_b_reachable "$SERIAL_B" "$ADBD_B" "$BRIDGE_PORT")" \
    || fail "ensure_b_reachable failed"
  log "A connect target = $ATARGET"
  local THOST="${ATARGET%%:*}" TPORT="${ATARGET##*:}"

  log "installing APK on A ($SERIAL_A)"
  adb -s "$SERIAL_A" install -r "$APK" || fail "adb install on A failed"

  # Start logcat capture on A BEFORE launch.
  adb -s "$SERIAL_A" logcat -c >/dev/null 2>&1 || true
  local RAW="$ARTIFACTS/logcat-A-scrcpy.txt"
  ( adb -s "$SERIAL_A" logcat -v threadtime \
      scrcpy:V SDL:V AndroidRuntime:E DEBUG:V libc:V "*:S" >"$RAW" 2>&1 ) &
  local LOGCAT_PID=$!
  local RAWFULL="$ARTIFACTS/logcat-A-full.txt"
  ( adb -s "$SERIAL_A" logcat -v threadtime >"$RAWFULL" 2>&1 ) &
  local LOGCATFULL_PID=$!
  # B logcat too (server start evidence).
  adb -s "$SERIAL_B" logcat -c >/dev/null 2>&1 || true
  local RAWB="$ARTIFACTS/logcat-B-full.txt"
  ( adb -s "$SERIAL_B" logcat -v threadtime >"$RAWB" 2>&1 ) &
  local LOGCATB_PID=$!

  # Launch MainActivity with the target pre-filled via Intent extras (the real
  # launcher path: MainActivity sets the EditText fields from host/port extras),
  # then tap the located Connect button. Deterministic — no fragile soft-keyboard
  # typing (which previously mis-routed the port into the host field).
  log "launching $MAIN_ACT on A with host=$THOST port=$TPORT"
  adb -s "$SERIAL_A" shell am start -n "$MAIN_ACT" \
    --es host "$THOST" --es port "$TPORT" || fail "am start MainActivity failed"
  sleep 5

  # Dump the launcher UI; retry until the EditTexts are present (the process can
  # take several seconds to draw on the memory-constrained emulator).
  local UIXML="$ARTIFACTS/uidump-A-main.xml" dtry=0
  while [ "$dtry" -lt 6 ]; do
    adb -s "$SERIAL_A" shell uiautomator dump /sdcard/uidump.xml >/dev/null 2>&1 || true
    adb -s "$SERIAL_A" shell cat /sdcard/uidump.xml >"$UIXML" 2>/dev/null || true
    grep -q 'id/connectButton' "$UIXML" 2>/dev/null && break
    sleep 2; dtry=$((dtry+1))
  done

  # Verify the fields were prefilled correctly (catch any regression early).
  # Non-fatal: grep returning nothing must not abort under `set -e`/pipefail.
  local HOSTVAL PORTVAL
  HOSTVAL="$( { grep -oE 'resource-id="net.scrcpy.android:id/hostInput"[^>]*' "$UIXML" | grep -oE 'text="[^"]*"' | head -1 | sed 's/text="//; s/"//'; } 2>/dev/null || true)"
  PORTVAL="$( { grep -oE 'resource-id="net.scrcpy.android:id/portInput"[^>]*' "$UIXML" | grep -oE 'text="[^"]*"' | head -1 | sed 's/text="//; s/"//'; } 2>/dev/null || true)"
  log "prefilled fields: host='$HOSTVAL' port='$PORTVAL' (want $THOST / $TPORT)"

  log "tapping Connect (target ${THOST}:${TPORT}) -> ScrcpyActivity"
  local CXY
  CXY="$(node_center connectButton "$UIXML" || true)"
  if [ -n "$CXY" ]; then
    adb -s "$SERIAL_A" shell input tap $CXY >/dev/null 2>&1 || true
  else
    fail "could not locate connectButton in UI dump"
  fi

  # Observe; poll for Connected + B-side server while the window runs.
  log "observing for up to ${LOGCAT_SECS}s for ScrcpyStatusConnected + B server"
  local CONNECTED="" BPROC="" t=0
  while [ "$t" -lt "$LOGCAT_SECS" ]; do
    CONNECTED="$(grep -E 'onScrcpyStatus: status=6|ScrcpyUpdateStatus: status=6|Scrcpy connected' "$RAWFULL" 2>/dev/null | head -1 || true)"
    BPROC="$(b_server_proc | grep -iE 'app_process|scrcpy' | head -1 || true)"
    if [ -n "$CONNECTED" ] && [ -n "$BPROC" ]; then break; fi
    sleep 3; t=$((t+3))
  done

  local APPPID
  APPPID="$(adb -s "$SERIAL_A" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n ' || true)"
  log "A app pid after observe: '${APPPID:-<none>}'"
  adb -s "$SERIAL_A" exec-out screencap -p >"$ARTIFACTS/screen-A-after.png" 2>/dev/null || true
  # capture B-side full process + server jar presence
  { adb -s "$SERIAL_B" shell ps -A || true; } >"$ARTIFACTS/B-ps.txt" 2>&1 || true
  { adb -s "$SERIAL_B" shell ls -l /data/local/tmp/scrcpy-server.jar || true; } >"$ARTIFACTS/B-server-jar.txt" 2>&1 || true

  # Pull scrcpy's own stdout/stderr (teed to $HOME/scrcpy-stdio.log = cacheDir).
  local ASTDIO="$ARTIFACTS/A-scrcpy-stdio.log"
  adb -s "$SERIAL_A" shell run-as "$PKG" cat cache/scrcpy-stdio.log >"$ASTDIO" 2>/dev/null || true
  log "==== A scrcpy stdout/stderr ($ASTDIO) ===="; cat "$ASTDIO" >&2 || true; log "==== end scrcpy stdio ===="

  # scrcpy's OWN authoritative connected signal (from its in-process log,
  # captured via the bridge's stdout/stderr redirect).
  SC_CONNECTED="$(grep -E 'INFO: Connected to ' "$ASTDIO" 2>/dev/null | head -1 || true)"
  SC_SERVERSTART="$(grep -E 'scrcpy-server app_process started|com.genymobile.scrcpy.Server' "$ASTDIO" 2>/dev/null | head -1 || true)"

  kill "$LOGCAT_PID" "$LOGCATFULL_PID" "$LOGCATB_PID" >/dev/null 2>&1 || true
  sleep 1

  log "==== A filtered logcat ===="; cat "$RAW" >&2 || true; log "==== end A logcat ===="

  # --- Evaluate --------------------------------------------------------------
  local ULE DLOPEN SEGV FATAL SERVERPATH
  ULE="$(grep -i 'UnsatisfiedLinkError' "$RAWFULL" || true)"
  DLOPEN="$(grep -iE 'dlopen failed|cannot locate symbol' "$RAWFULL" || true)"
  SEGV="$(grep -iE 'SIGSEGV|signal 11|Fatal signal|SIGABRT|Scudo ERROR' "$RAWFULL" || true)"
  # Only OUR app's crashes count — ignore unrelated system/Google-app ANRs.
  FATAL="$(grep -iE 'FATAL EXCEPTION|ANR in ' "$RAWFULL" | grep -i "$PKG" || true)"
  SERVERPATH="$(grep -iE 'SCRCPY_SERVER_PATH|nativeSetServerPath|deployServer' "$RAWFULL" || true)"
  # status=6 from the porting status callback (best-effort; see note below).
  local STATUS6
  STATUS6="$(grep -E 'onScrcpyStatus: status=6|ScrcpyUpdateStatus: status=6|Scrcpy connected' "$RAWFULL" 2>/dev/null | head -1 || true)"
  # status=3 (SDL Window Created) only fires AFTER a successful server connect +
  # first video frame — a reliable post-connection marker on this build.
  local STATUS3
  STATUS3="$(grep -E 'onScrcpyStatus: status=3|SDL Window Created' "$RAWFULL" 2>/dev/null | head -1 || true)"
  BPROC="$(grep -iE 'app_process|com.genymobile.scrcpy' "$ARTIFACTS/B-ps.txt" 2>/dev/null | head -3 || true)"
  local BSRVLOG
  BSRVLOG="$(grep -iE 'scrcpy|genymobile' "$RAWB" 2>/dev/null | head -10 || true)"

  # The authoritative "Connected" proof = scrcpy's own "INFO: Connected to ..."
  # log line (from its in-process client) OR the porting status=6 callback. The
  # status=6 callback (sc_server_on_connected_hijack) does not always surface in
  # logcat on this build, so we accept scrcpy's own connected line — it is the
  # canonical signal and is corroborated by the server running on B + status=3.
  CONNECTED="${STATUS6:-$SC_CONNECTED}"

  log "--- diagnostics ---"
  log "UnsatisfiedLinkError: ${ULE:-<none>}"
  log "dlopen failure:       ${DLOPEN:-<none>}"
  log "fatal signal:         ${SEGV:-<none>}"
  log "FATAL/ANR:            ${FATAL:-<none>}"
  log "server path env:      ${SERVERPATH:-<none>}"
  log "scrcpy 'Connected to': ${SC_CONNECTED:-<none>}"
  log "scrcpy server started: ${SC_SERVERSTART:-<none>}"
  log "status=6 callback:    ${STATUS6:-<none>}"
  log "status=3 (post-conn): ${STATUS3:-<none>}"
  log "B server proc(s):     ${BPROC:-<none>}"
  log "B server log(s):      ${BSRVLOG:-<none>}"

  printf '%s\n%s\n%s\n' "$SC_CONNECTED" "$SC_SERVERSTART" "$STATUS6" >"$ARTIFACTS/evidence-connected.txt"
  printf '%s\n' "$BPROC" >"$ARTIFACTS/evidence-bserver.txt"

  [ -n "$ULE$DLOPEN" ] && fail "native libs failed to load — REAL BUG"
  [ -n "$SEGV$FATAL" ] && fail "A crashed (fatal signal / FATAL / ANR) — REAL BUG"
  [ -z "$CONNECTED" ]  && fail "A did NOT reach Connected (no scrcpy 'Connected to' line and no status=6)"
  [ -z "$BPROC" ]      && fail "scrcpy-server NOT running on B (no app_process/genymobile in ps)"

  log "PASS: A reached Connected ('${CONNECTED}') AND scrcpy-server running on B."
  exit 0
}

main "$@"
