#!/usr/bin/env bash
# M3 task 1 — network DIAGNOSTIC (throwaway). Boots both emulators and probes
# several candidate A->B reachability schemes to find one that works.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS=/artifacts
EMU_MEM="${SCRCPY_E2E_EMU_MEM:-1536}"
BOOT_TIMEOUT="${SCRCPY_E2E_BOOT_TIMEOUT:-300}"
AVD_B=e2e_target; AVD_A=e2e_controller
PORT_B=5554; ADBD_B=5555; PORT_A=5556; ADBD_A=5557
SERIAL_B=emulator-5554; SERIAL_A=emulator-5556
PID_B=""; PID_A=""
log(){ printf '%s [diag] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
fail(){ log "FAILURE: $*"; exit 1; }
cleanup(){ local rc=$?; log "cleanup (rc=$rc)";
  adb -s "$SERIAL_B" emu kill >/dev/null 2>&1||true; adb -s "$SERIAL_A" emu kill >/dev/null 2>&1||true
  [ -n "$PID_B" ]&&kill "$PID_B" 2>/dev/null||true; [ -n "$PID_A" ]&&kill "$PID_A" 2>/dev/null||true
  sleep 2; pkill -9 -f qemu-system 2>/dev/null||true; pkill -9 -f socat 2>/dev/null||true; adb kill-server 2>/dev/null||true
  avdmanager delete avd -n "$AVD_B" >/dev/null 2>&1||true; avdmanager delete avd -n "$AVD_A" >/dev/null 2>&1||true; }
create_avd(){ avdmanager delete avd -n "$1" >/dev/null 2>&1||true; log "creating AVD $1"
  echo no|avdmanager create avd -n "$1" -k "system-images;android-30;google_apis;x86_64" -d pixel --force >/dev/null; }
launch_emu(){ log "launching $1 on $2"; emulator -avd "$1" -port "$2" -no-window -gpu swiftshader_indirect \
  -no-snapshot -no-audio -no-boot-anim -accel on -memory "$EMU_MEM" -partition-size 2048 \
  >"$ARTIFACTS/emulator-$2.log" 2>&1 & echo $!; }
wait_boot(){ local s="$1" p="$2" dl=$(( $(date +%s)+BOOT_TIMEOUT )); log "waiting $s";
  while :; do kill -0 "$p" 2>/dev/null||{ log "$s DEAD";return 1;}
    local bc; bc="$(timeout 15 adb -s "$s" shell getprop sys.boot_completed 2>/dev/null|tr -d '\r\n '||true)"
    [ "$bc" = 1 ]&&{ log "$s booted";return 0;}; [ "$(date +%s)" -ge "$dl" ]&&{ log "$s NOT booted";return 1;}; sleep 5; done; }

probeA(){ # $1=host $2=port  -> run the C probe on A, print result
  adb -s "$SERIAL_A" shell "/data/local/tmp/m3-tcp-probe $1 $2" 2>&1 || true; }

main(){
  mkdir -p "$ARTIFACTS"; trap cleanup EXIT
  log "diag start"; [ -e /dev/kvm ]||fail "no kvm"
  command -v socat >/dev/null 2>&1 || fail "socat missing (baked into scrcpy-e2e:dev; rebuild from e2e/Dockerfile)"
  adb kill-server >/dev/null 2>&1||true; adb start-server >/dev/null 2>&1||true
  create_avd "$AVD_B"; create_avd "$AVD_A"
  PID_B="$(launch_emu "$AVD_B" "$PORT_B")"; PID_A="$(launch_emu "$AVD_A" "$PORT_A")"
  wait_boot "$SERIAL_B" "$PID_B"||fail "B boot"; wait_boot "$SERIAL_A" "$PID_A"||fail "A boot"
  adb devices -l >&2

  # Compile + push the C probe to A.
  local NDK; NDK="$(ls -d "${ANDROID_SDK_ROOT:-/opt/android-sdk}"/ndk/* 2>/dev/null|head -1)"
  local CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android24-clang"
  "$CC" -O2 "$HERE/m3-tcp-probe.c" -o /tmp/m3-tcp-probe
  adb -s "$SERIAL_A" push /tmp/m3-tcp-probe /data/local/tmp/m3-tcp-probe >/dev/null
  adb -s "$SERIAL_A" shell chmod 755 /data/local/tmp/m3-tcp-probe

  echo "=================== NETWORK FACTS ===================" | tee "$ARTIFACTS/m3-net-diag.txt"
  {
    echo "--- container host ip (hostname -i) ---"
    hostname -i 2>/dev/null || true
    echo "--- host listening sockets (/proc/net/tcp, hex ports 15B3=5555 15B5=5557) ---"
    awk 'NR>1{print $2}' /proc/net/tcp 2>/dev/null | sort -u || true
    echo "--- inside A: ip route ---"
    adb -s "$SERIAL_A" shell ip route 2>/dev/null || true
    echo "--- inside A: ip addr ---"
    adb -s "$SERIAL_A" shell ip -4 addr 2>/dev/null | grep -E 'inet ' || true
  } | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2

  local CONTAINER_IP; CONTAINER_IP="$(hostname -i 2>/dev/null | awk '{print $1}' | grep -v '^127' || true)"
  log "container eth0 IP guess = $CONTAINER_IP"

  echo "=================== CANDIDATE PROBES (from inside A) ===================" | tee -a "$ARTIFACTS/m3-net-diag.txt"

  # Candidate 1: 10.0.2.2:5555 (host loopback alias) — known to fail, recheck.
  log "C1: A -> 10.0.2.2:$ADBD_B"
  { echo "### C1 10.0.2.2:$ADBD_B"; probeA 10.0.2.2 "$ADBD_B"; } | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2

  # Candidate 2: adb -s B reverse won't help (that's B->host). Instead use a
  # host-side socat bridge: bind 0.0.0.0:6000 on the container -> 127.0.0.1:5555
  # (B's adbd). Then A reaches it via 10.0.2.2:6000 (host loopback won't include
  # 0.0.0.0? test) AND via the container IP. We test both.
  if command -v socat >/dev/null 2>&1; then
    log "starting socat bridge 0.0.0.0:6000 -> 127.0.0.1:$ADBD_B"
    socat TCP-LISTEN:6000,fork,reuseaddr TCP:127.0.0.1:"$ADBD_B" >"$ARTIFACTS/socat.log" 2>&1 &
    sleep 1
    log "C2: A -> 10.0.2.2:6000 (socat on host loopback+all-ifaces)"
    { echo "### C2 10.0.2.2:6000 (socat 0.0.0.0:6000->127.0.0.1:$ADBD_B)"; probeA 10.0.2.2 6000; } | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2
    if [ -n "$CONTAINER_IP" ]; then
      log "C3: A -> $CONTAINER_IP:6000 (socat via container eth0 IP)"
      { echo "### C3 $CONTAINER_IP:6000"; probeA "$CONTAINER_IP" 6000; } | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2
    fi
  else
    echo "socat NOT available" | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2
  fi

  # Candidate 4: emulator console redir add on A to forward A:guest port? No.
  # Candidate 4 (real): `adb -s B forward` exposes B's guest service on the HOST,
  # not useful for A. Skip.

  # Candidate 5: the emulator's special guest address 10.0.2.2 maps to host
  # loopback; but each emulator also exposes the *other* emulator only if we
  # redir. Try emulator console "redir" via telnet is complex; skip unless needed.

  # Candidate 6: container eth0 IP directly to B's adbd — only works if adbd
  # bound to 0.0.0.0. Test.
  if [ -n "$CONTAINER_IP" ]; then
    log "C6: A -> $CONTAINER_IP:$ADBD_B (direct, needs adbd on 0.0.0.0)"
    { echo "### C6 $CONTAINER_IP:$ADBD_B (direct)"; probeA "$CONTAINER_IP" "$ADBD_B"; } | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2
  fi

  echo "=================== END ===================" | tee -a "$ARTIFACTS/m3-net-diag.txt" >&2
  log "diag complete — inspect $ARTIFACTS/m3-net-diag.txt"
}
main "$@"
