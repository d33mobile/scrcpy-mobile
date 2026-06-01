#!/usr/bin/env bash
# M3 task 1 — network DIAGNOSTIC #2 (throwaway). Determines whether emulator A's
# slirp gateway 10.0.2.2 can reach the container-host loopback at all, and finds
# the working A->B adbd scheme. Boots both emulators.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS=/artifacts
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
AVD_B=e2e_target; AVD_A=e2e_controller
PORT_B=5554; ADBD_B=5555; PORT_A=5556; ADBD_A=5557
SERIAL_B=emulator-5554; SERIAL_A=emulator-5556
PID_B=""; PID_A=""
log(){ printf '%s [diag2] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail(){ log "FAILURE: $*"; exit 1; }
cleanup(){ local rc=$?; log "cleanup (rc=$rc)";
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1||true; adb -s "$SERIAL_A" emu kill >/dev/null 2>&1||true
  [ -n "$PID_B" ]&&kill "$PID_B" 2>/dev/null||true; [ -n "$PID_A" ]&&kill "$PID_A" 2>/dev/null||true
  sleep 2; pkill -9 -f qemu-system 2>/dev/null||true; pkill -9 -f socat 2>/dev/null||true; adb kill-server 2>/dev/null||true
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1||true; avdmanager delete avd -n "$AVD_A" >/dev/null 2>&1||true; }
create_avd(){ avdmanager delete avd -n "$1" >/dev/null 2>&1||true; log "AVD $1"
  echo no|avdmanager create avd -n "$1" -k "system-images;android-30;google_apis;x86_64" -d pixel --force >/dev/null; }
launch_emu(){ log "launch $1:$2"; emulator -avd "$1" -port "$2" -no-window -gpu swiftshader_indirect \
  -no-snapshot -no-audio -no-boot-anim -accel on -memory "$EMU_MEM" -partition-size 2048 \
  >"$ARTIFACTS/emulator-$2.log" 2>&1 & echo $!; }
wait_boot(){ local s="$1" p="$2" dl=$(( $(date +%s)+BOOT_TIMEOUT )); log "wait $s";
  while :; do kill -0 "$p" 2>/dev/null||{ log "$s DEAD";return 1;}
    local bc; bc="$(timeout 15 adb -s "$s" shell getprop sys.boot_completed 2>/dev/null|tr -d '\r\n '||true)"
    [ "$bc" = 1 ]&&{ log "$s booted";return 0;}; [ "$(date +%s)" -ge "$dl" ]&&{ log "$s NOT booted";return 1;}; sleep 5; done; }
probeA(){ adb -s "$SERIAL_A" shell "/data/local/tmp/m3-tcp-probe $1 $2" 2>&1 || true; }

main(){
  mkdir -p "$ARTIFACTS"; trap cleanup EXIT
  command -v socat >/dev/null 2>&1 || { log "apt socat"; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq socat >/dev/null 2>&1||true; }
  adb kill-server >/dev/null 2>&1||true; adb start-server >/dev/null 2>&1||true
  create_avd "$AVD_B"; create_avd "$AVD_A"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; PID_A="$(launch_emu "$AVD_A" "$PORT_A")"
  wait_boot "$SERIAL_B" "$PID_B"||fail "B boot"; wait_boot "$SERIAL_A" "$PID_A"||fail "A boot"
  local NDK; NDK="$(ls -d "${ANDROID_SDK_ROOT:-/opt/android-sdk}"/ndk/*|head -1)"
  "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang" -O2 "$HERE/m3-tcp-probe.c" -o /tmp/m3-tcp-probe
  adb -s "$SERIAL_A" push /tmp/m3-tcp-probe /data/local/tmp/m3-tcp-probe >/dev/null
  adb -s "$SERIAL_A" shell chmod 755 /data/local/tmp/m3-tcp-probe

  : >"$ARTIFACTS/m3-net-diag2.txt"
  rec(){ printf '%s\n' "$*" | tee -a "$ARTIFACTS/m3-net-diag2.txt" >&2; }

  rec "=== Q1: can A's 10.0.2.2 reach ANY host-loopback service? ==="
  # Host adb server listens on 127.0.0.1:5037. Probe it from A (it won't speak
  # the adb wire CNXN, but a successful CONNECT proves slirp host-loopback works).
  rec "[A->10.0.2.2:5037 host adb-server] $(probeA 10.0.2.2 5037 | tr '\n' ' ')"

  rec "=== Q2: socat bound EXPLICITLY on host 127.0.0.1 then via 10.0.2.2 ==="
  if command -v socat >/dev/null 2>&1; then
    socat TCP-LISTEN:6001,fork,reuseaddr,bind=127.0.0.1 TCP:127.0.0.1:"$ADBD_B" >"$ARTIFACTS/socat6001.log" 2>&1 & sleep 1
    rec "[A->10.0.2.2:6001 socat@127.0.0.1->B:$ADBD_B] $(probeA 10.0.2.2 6001 | tr '\n' ' ')"
    # Also bind on all interfaces and try the slirp gateway.
    socat TCP-LISTEN:6002,fork,reuseaddr TCP:127.0.0.1:"$ADBD_B" >"$ARTIFACTS/socat6002.log" 2>&1 & sleep 1
    rec "[A->10.0.2.2:6002 socat@0.0.0.0->B:$ADBD_B] $(probeA 10.0.2.2 6002 | tr '\n' ' ')"
  else
    rec "socat unavailable"
  fi

  rec "=== Q3: emulator console redir — forward A guest:7000 -> host:$ADBD_B ==="
  # 'redir add tcp:HOSTPORT:GUESTPORT' makes the HOST forward to the GUEST (wrong
  # way). The useful console verb is the AVD's user-net host-forward, set at
  # launch with -tcpdump/redir. We instead test the documented guest path:
  # the guest can reach the host's loopback only if slirp restrict=off. Print the
  # emulator's network config via the console.
  {
    echo "auth $(cat "$HOME/.emulator_console_auth_token" 2>/dev/null)"
    echo "network status"
    echo "redir list"
    echo "quit"
  } | timeout 10 nc -w 3 localhost "$PORT_A" 2>/dev/null | tee -a "$ARTIFACTS/m3-net-diag2.txt" >&2 || rec "(console nc failed)"

  rec "=== Q4: relaunch A with an explicit host-forward to B's adbd ==="
  # The robust scheme: relaunch A adding a qemu hostfwd so that, inside A,
  # 10.0.2.2:5555 (or a chosen guest-visible address) NATs to host 127.0.0.1:B.
  # emulator flag: -qemu -netdev ... is awkward; emulator supports
  # `-http-proxy` not relevant. The supported per-AVD forward is via the console
  # `redir` (host->guest) — not what we need. So instead we rely on socat above.
  rec "(see Q2 results — socat on host loopback is the bridge)"

  log "diag2 complete"
}
main "$@"
