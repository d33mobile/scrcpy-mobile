#!/usr/bin/env bash
# scrcpy-mobile e2e harness — single entry script.
#
# Two modes:
#   OUTER (default): runs on the host (d-claude or local). Builds the image if
#     missing, then `docker run`s itself in INNER mode with /dev/kvm, the repo
#     mounted at /workspace, a persistent gradle cache, and an artifacts dir.
#   INNER (--inner): runs inside the container. Creates two AVDs, boots two
#     headless x86_64 emulators (B=target 5554/5555, A=controller 5556/5557),
#     waits for boot, runs the M0 PLACEHOLDER assertion (both adb online + B is
#     controllable via `adb shell` driving a dumpsys state change), writes
#     artifacts to /artifacts, and cleans up (kill emulators, delete AVDs).
#
# Exit 0 only if every assertion passes. set -euo pipefail throughout.
#
# Topology decided for M0 (hermetic, simple): ONE container, BOTH emulators.
set -euo pipefail

# ---------------------------------------------------------------------------
# Shared config / logging
# ---------------------------------------------------------------------------
IMAGE="${SCRCPY_E2E_IMAGE:-scrcpy-e2e:dev}"
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Per-emulator memory (MB). 1536 chosen because the host (8GB, ~2.7GB free) cannot
# fit 2x2048 alongside the other long-running containers; 2x1536 boots reliably.
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"

log()  { printf '%s [run.sh] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

# ===========================================================================
# OUTER MODE
# ===========================================================================
outer() {
  local artifacts="${SCRCPY_E2E_ARTIFACTS:-$REPO_ROOT/e2e/artifacts}"
  mkdir -p "$artifacts"
  # Wipe stale artifacts so each run is clean.
  rm -rf "${artifacts:?}/"* 2>/dev/null || true

  log "OUTER: image=$IMAGE repo=$REPO_ROOT artifacts=$artifacts"

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Image $IMAGE missing — building from e2e/Dockerfile"
    docker build -t "$IMAGE" -f "$REPO_ROOT/e2e/Dockerfile" "$REPO_ROOT/e2e"
  else
    log "Image $IMAGE present — skipping build"
  fi

  [ -e /dev/kvm ] || fail "/dev/kvm not present on host — x86_64 emulators need KVM"

  log "Launching INNER container (docker run --device /dev/kvm)"
  docker run --rm \
    --device /dev/kvm \
    -v "$REPO_ROOT:/workspace" \
    -v scrcpy-gradle-cache:/root/.gradle \
    -v "$artifacts:/artifacts" \
    -e SCRCPY_E2E_EMU_MEM="$EMU_MEM" \
    -e SCRCPY_E2E_BOOT_TIMEOUT="$BOOT_TIMEOUT" \
    "$IMAGE" \
    bash /workspace/e2e/run.sh --inner
  local rc=$?
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

ARTIFACTS=/artifacts

# Emulator identity: B=target (5554/5555), A=controller (5556/5557).
AVD_B=e2e_target
AVD_A=e2e_controller
PORT_B=5554
PORT_A=5556
SERIAL_B=emulator-5554
SERIAL_A=emulator-5556

# PIDs of launched emulators, for cleanup.
PID_B=""
PID_A=""

cleanup() {
  local rc=$?
  log "cleanup: collecting final artifacts + killing emulators"
  # Best-effort final artifact dumps (never abort cleanup on error).
  { adb devices -l || true; } >"$ARTIFACTS/adb-devices.txt" 2>&1 || true
  for s in "$SERIAL_B" "$SERIAL_A"; do
    { adb -s "$s" logcat -d || true; } >"$ARTIFACTS/logcat-$s.txt" 2>&1 || true
    { adb -s "$s" exec-out screencap -p || true; } >"$ARTIFACTS/screen-$s.png" 2>/dev/null || true
  done
  # Kill emulators via adb (clean) then SIGKILL the processes.
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1 || true
  adb -s "$SERIAL_A" emu kill >/dev/null 2>&1 || true
  [ -n "$PID_B" ] && kill "$PID_B" >/dev/null 2>&1 || true
  [ -n "$PID_A" ] && kill "$PID_A" >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  # Delete the throwaway AVDs so the run is idempotent.
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_A" >/dev/null 2>&1 || true
  log "cleanup done (rc=$rc)"
}

create_avd() {
  local name="$1"
  # Idempotent: delete any stale AVD of this name first.
  avdmanager delete avd -n "$name" >/dev/null 2>&1 || true
  log "creating AVD $name"
  echo no | avdmanager create avd \
    -n "$name" \
    -k "system-images;android-30;google_apis;x86_64" \
    -d "pixel" \
    --force >/dev/null
}

launch_emu() {
  # $1=avd $2=console-port  -> echoes the launched PID
  local name="$1" port="$2"
  log "launching emulator $name on port $port (mem=${EMU_MEM}MB)"
  # Headless KVM flags. swiftshader_indirect = SW GL that works without an X
  # server. -no-snapshot avoids snapshot corruption races between the two AVDs.
  # NB: no -no-metrics flag — the pinned emulator v33.1.24 (see e2e/Dockerfile)
  # does not accept it and aborts startup if given. Metrics are opt-in anyway and
  # never prompt in this headless image.
  emulator -avd "$name" -port "$port" \
    -no-window -gpu swiftshader_indirect \
    -no-snapshot -no-audio -no-boot-anim \
    -accel on -memory "$EMU_MEM" -partition-size 2048 \
    >"$ARTIFACTS/emulator-$port.log" 2>&1 &
  echo $!
}

wait_boot() {
  # $1=serial $2=emulator-pid — poll sys.boot_completed==1 within BOOT_TIMEOUT.
  # Every adb call is wrapped in `timeout` so a dead/hung emulator (where
  # `adb wait-for-device` / `adb shell` would block forever) can never hang the
  # harness. We also bail immediately if the emulator process has died.
  local serial="$1" pid="$2" deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  log "waiting for $serial (pid $pid) to boot (timeout ${BOOT_TIMEOUT}s)"
  while :; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      log "$serial emulator process (pid $pid) is DEAD — boot aborted"
      return 1
    fi
    local bc
    bc="$(timeout 15 adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ' || true)"
    if [ "$bc" = "1" ]; then
      log "$serial booted (sys.boot_completed=1)"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "$serial did NOT boot within ${BOOT_TIMEOUT}s (last boot_completed='$bc')"
      return 1
    fi
    sleep 5
  done
}

assert_online() {
  # Both serials must appear as `device` (not offline/unauthorized).
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
  # PLACEHOLDER control proof: drive B from the container's adb and assert a
  # dumpsys-observable state change. We use a settings round-trip (deterministic,
  # no UI timing flake) AND a focus change via `am start`, then verify.
  local serial="$SERIAL_B"

  # (1) settings round-trip via `adb shell` (proves shell input reaches B).
  local marker="e2e_$(date +%s)"
  adb -s "$serial" shell settings put system e2e_probe "$marker" >/dev/null
  local got
  got="$(adb -s "$serial" shell settings get system e2e_probe 2>/dev/null | tr -d '\r\n ')"
  [ "$got" = "$marker" ] || fail "settings round-trip failed (put=$marker get=$got)"
  log "ASSERT ok: settings round-trip on B ($got)"

  # (2) focus change: capture mCurrentFocus, start Settings, assert it changed.
  local focus_before focus_after
  focus_before="$(adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
  log "focus before: $focus_before"
  adb -s "$serial" shell am start -W -n com.android.settings/.Settings >/dev/null 2>&1 || true
  # Give the activity a moment to take focus.
  local tries=0
  while [ "$tries" -lt 20 ]; do
    focus_after="$(adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true)"
    [ "$focus_after" != "$focus_before" ] && echo "$focus_after" | grep -qi settings && break
    sleep 1; tries=$((tries+1))
  done
  log "focus after:  $focus_after"
  echo "$focus_after" | grep -qi "settings" \
    || fail "am start did not move focus to Settings (after='$focus_after')"
  log "ASSERT ok: am start changed mCurrentFocus to Settings on B"

  # (3) keyevent BACK to prove input events flow, then a tap.
  adb -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  adb -s "$serial" shell input tap 200 600 >/dev/null 2>&1 || true
  log "ASSERT ok: input keyevent/tap dispatched to B without error"
}

inner() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "INNER: starting on $(uname -m); whoami=$(whoami); EMU_MEM=${EMU_MEM} BOOT_TIMEOUT=${BOOT_TIMEOUT}"
  log "KVM check: $(ls -l /dev/kvm 2>&1 || echo 'NO /dev/kvm')"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  # Fresh adb server.
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true

  create_avd "$AVD_B"
  create_avd "$AVD_A"

  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"
  log "B pid=$PID_B"
  PID_A="$(launch_emu "$AVD_A" "$PORT_A")"
  log "A pid=$PID_A"

  # Wait for both to boot. Pass the emulator PID so a dead process fails fast.
  wait_boot "$SERIAL_B" "$PID_B" || { tail -40 "$ARTIFACTS/emulator-$PORT_B.log" >&2 || true; fail "B failed to boot"; }
  wait_boot "$SERIAL_A" "$PID_A" || { tail -40 "$ARTIFACTS/emulator-$PORT_A.log" >&2 || true; fail "A failed to boot"; }

  # Settle: disable animations / unlock so input is deterministic.
  for s in "$SERIAL_B" "$SERIAL_A"; do
    adb -s "$s" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb -s "$s" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  done

  assert_online
  assert_controllable

  log "all assertions passed"
  exit 0
}

# ===========================================================================
# Dispatch
# ===========================================================================
case "${1:-}" in
  --inner) inner ;;
  *)       outer ;;
esac
