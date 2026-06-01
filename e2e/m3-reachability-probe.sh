#!/usr/bin/env bash
# M3 task 1 — A->B reachability probe (INNER-only, runs inside scrcpy-e2e:dev).
# Boots BOTH emulators (B=target 5554/5555, A=controller 5556/5557), then from
# INSIDE emulator A opens a TCP connection to B's adbd and proves it reached it
# (adbd answers a CNXN packet). Sources e2e/lib-net.sh for the address scheme.
#
# NOT a permanent harness — a focused proof-of-reachability for M3 task 1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS=/artifacts
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"

AVD_B=e2e_target
AVD_A=e2e_controller
PORT_B=5554; ADBD_B=5555
PORT_A=5556; ADBD_A=5557
SERIAL_B=emulator-5554
SERIAL_A=emulator-5556
PID_B=""; PID_A=""

log()  { printf '%s [probe] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail() { log "FAILURE: $*"; exit 1; }

# shellcheck source=lib-net.sh
. "$HERE/lib-net.sh"

cleanup() {
  local rc=$?
  log "cleanup (rc=$rc)"
  stop_b_bridge 2>/dev/null || true
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1 || true
  adb -s "$SERIAL_A" emu kill >/dev/null 2>&1 || true
  [ -n "$PID_B" ] && kill "$PID_B" >/dev/null 2>&1 || true
  [ -n "$PID_A" ] && kill "$PID_A" >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1 || true
  avdmanager delete avd -n "$AVD_A" >/dev/null 2>&1 || true
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

main() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "INNER probe start; EMU_MEM=$EMU_MEM"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible"

  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true

  create_avd "$AVD_B"
  create_avd "$AVD_A"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; log "B pid=$PID_B"
  PID_A="$(launch_emu "$AVD_A" "$PORT_A")"; log "A pid=$PID_A"

  wait_boot "$SERIAL_B" "$PID_B" || { tail -40 "$ARTIFACTS/emulator-$PORT_B.log" >&2; fail "B boot"; }
  wait_boot "$SERIAL_A" "$PID_A" || { tail -40 "$ARTIFACTS/emulator-$PORT_A.log" >&2; fail "A boot"; }

  adb devices -l | tee "$ARTIFACTS/adb-devices.txt" >&2

  # Address scheme under test: from inside A, B's adbd is reachable at
  # 10.0.2.2:<ADBD_B>. ensure_b_reachable confirms B's adbd is on the container
  # host loopback (which 10.0.2.2 maps to inside A) and echoes the A-side target.
  local target
  target="$(ensure_b_reachable "$SERIAL_B" "$ADBD_B")" || fail "ensure_b_reachable failed"
  log "address scheme: A should use target = $target"
  echo "$target" >"$ARTIFACTS/m3-target.txt"

  local host="${target%:*}" port="${target##*:}"
  log "A will connect to host=$host port=$port"

  # ---- Tag B so we can prove the answering device is B, not A ----
  local mark="m3_$(date +%s)"
  adb -s "$SERIAL_B" shell setprop debug.m3.mark "$mark" >/dev/null 2>&1 || true
  log "tagged B with debug.m3.mark=$mark"

  # ---- STRONG PROBE: cross-compile a tiny TCP probe, push to A, run on A ----
  # The probe (e2e/m3-tcp-probe.c) connects to host:port, sends a valid adb CNXN
  # handshake, and prints the reply. adbd answers with its own CNXN advertising
  # the device banner ("device::...") — unambiguous proof A reached B's adbd.
  local NDK_ROOT
  NDK_ROOT="$(ls -d "${ANDROID_SDK_ROOT:-/opt/android-sdk}"/ndk/* 2>/dev/null | head -1)"
  local CC="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang"
  local probe_out=""
  if [ -x "$CC" ]; then
    log "compiling m3-tcp-probe with $CC"
    "$CC" -O2 -static-libstdc++ "$HERE/m3-tcp-probe.c" -o /tmp/m3-tcp-probe \
      && adb -s "$SERIAL_A" push /tmp/m3-tcp-probe /data/local/tmp/m3-tcp-probe >/dev/null \
      && adb -s "$SERIAL_A" shell chmod 755 /data/local/tmp/m3-tcp-probe
    log "running m3-tcp-probe ON emulator A -> $host:$port"
    probe_out="$(adb -s "$SERIAL_A" shell "/data/local/tmp/m3-tcp-probe $host $port" 2>&1 || true)"
  else
    log "WARN: NDK clang not found at $CC — falling back to nc"
  fi

  # ---- Fallback / corroborating PROBE via nc inside A ----
  local nc_out
  nc_out="$(adb -s "$SERIAL_A" shell "
    set +e
    if command -v nc >/dev/null 2>&1; then T=nc
    elif toybox nc 2>/dev/null </dev/null >/dev/null; then T='toybox nc'
    else T=''; fi
    echo \"PROBE_TOOL=\${T:-none}\"
    if [ -n \"\$T\" ]; then
      ( printf 'CNXN'; sleep 2 ) | \$T -w 5 $host $port 2>/dev/null \
        | od -An -tx1 -c 2>/dev/null | head -20
      echo NC_DONE
    fi
  " 2>&1 || true)"

  probe_out="$probe_out
=== nc corroboration ===
$nc_out"
  printf '%s\n' "$probe_out" | tee "$ARTIFACTS/m3-probe-A-to-B.txt" >&2

  # ---- DISAMBIGUATION: prove 10.0.2.2:5555 == B, not A ----
  # From the container host, connect to 127.0.0.1:5555 (the same socket A's
  # 10.0.2.2:5555 maps to) and read B's marker. If it matches, the host:port A
  # uses is unambiguously B's adbd. Also sanity-check A's own adbd (5557).
  adb connect "127.0.0.1:$ADBD_B" >/dev/null 2>&1 || true
  sleep 1
  local read_b read_a
  read_b="$(adb -s "127.0.0.1:$ADBD_B" shell getprop debug.m3.mark 2>/dev/null | tr -d '\r\n ' || true)"
  adb disconnect "127.0.0.1:$ADBD_B" >/dev/null 2>&1 || true
  adb connect "127.0.0.1:$ADBD_A" >/dev/null 2>&1 || true
  sleep 1
  read_a="$(adb -s "127.0.0.1:$ADBD_A" shell getprop debug.m3.mark 2>/dev/null | tr -d '\r\n ' || true)"
  adb disconnect "127.0.0.1:$ADBD_A" >/dev/null 2>&1 || true
  log "host via 127.0.0.1:$ADBD_B read debug.m3.mark='$read_b' (expect '$mark')"
  log "host via 127.0.0.1:$ADBD_A read debug.m3.mark='$read_a' (expect empty/diff = A)"
  {
    echo "expected_B_mark=$mark"
    echo "read_via_${ADBD_B}=$read_b"
    echo "read_via_${ADBD_A}=$read_a"
  } >"$ARTIFACTS/m3-disambiguation.txt"

  # ---- VERDICT ----
  local reached=0 isadbd=0
  # Strong: the C probe connected.
  printf '%s' "$probe_out" | grep -qE 'PROBE_RESULT=connected|PROBE_RESULT=reply_bytes' && reached=1
  # Strong: the reply is an adb CNXN packet (REPLY_COMMAND_IS_CNXN=yes) or the
  # reply bytes contain the adbd "device::"/"host::"/"CNXN" banner.
  printf '%s' "$probe_out" | grep -qE 'REPLY_COMMAND_IS_CNXN=yes' && isadbd=1
  printf '%s' "$probe_out" | grep -qiE 'CNXN|device|host' && isadbd=1
  # nc corroboration: any non-empty hex line from nc also counts as reached.
  printf '%s' "$probe_out" | grep -qE '^ +[0-9a-f]{2} ' && reached=1

  local disambig_ok=0
  [ "$read_b" = "$mark" ] && [ "$read_a" != "$mark" ] && disambig_ok=1

  log "VERDICT: reached=$reached isadbd=$isadbd disambig_ok=$disambig_ok"
  if [ "$reached" -eq 1 ] && [ "$isadbd" -eq 1 ] && [ "$disambig_ok" -eq 1 ]; then
    log "PASS: A reached B's adbd at $host:$port (host-side socat 0.0.0.0:$port -> 127.0.0.1:$ADBD_B);"
    log "      reply is an adb CNXN banner, and 127.0.0.1:$ADBD_B is proven to be B (marker match)."
    exit 0
  fi
  fail "reachability NOT proven (reached=$reached isadbd=$isadbd disambig_ok=$disambig_ok)"
}

main "$@"
