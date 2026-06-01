#!/usr/bin/env bash
# e2e/lib-net.sh — A->B reachability helper for the two-emulator M3 harness.
#
# ============================ ADDRESS SCHEME =================================
# Both emulators run in ONE scrcpy-e2e:dev container, each on its OWN isolated
# QEMU user-mode (slirp) network:
#     guest eth0 = 10.0.2.15/24, gateway/host-alias = 10.0.2.2
# The emulator forwards each guest's adbd to the CONTAINER-HOST *loopback* only:
#     B (console 5554) -> adbd at 127.0.0.1:5555 on the container host
#     A (console 5556) -> adbd at 127.0.0.1:5557 on the container host
#
# EMPIRICAL FINDING (M3 task 1, 2026-06-01, verified on d-claude):
#   * From INSIDE emulator A, 10.0.2.2:5555 does NOT reach B's adbd, and 10.0.2.2
#     does NOT reach the container host's 127.0.0.1 services at all (slirp's
#     host-loopback redirect is effectively off for arbitrary ports in the pinned
#     emulator v33.1.24). Probing A->10.0.2.2:5037 (host adb-server) and
#     A->10.0.2.2:<socat bound to 127.0.0.1> both got connect_fail.
#   * HOWEVER, A's 10.0.2.2 DOES reach any service the container host binds on
#     0.0.0.0 (all interfaces). A socat listener bound to 0.0.0.0 that forwards to
#     127.0.0.1:5555 (B's adbd) IS reachable from A at 10.0.2.2:<listen-port>, and
#     A received B's adbd CNXN banner ("device::ro.product.name=sdk_gphone_x86_64
#     ;...features=...") through it.
#
# THEREFORE the working scheme A's app must use:
#       host = 10.0.2.2
#       port = <bridge port>  (a host-side socat 0.0.0.0:<port> -> 127.0.0.1:5555)
#   `adb tcpip`/`adb forward`/`adb reverse` are NOT needed — emulator adbd already
#   listens on TCP; we only bridge the host loopback onto an all-interfaces port
#   that the slirp gateway exposes to A.
# ============================================================================
#
# Functions are idempotent and safe to source repeatedly. They require `socat`
# on the container host — it is BAKED into scrcpy-e2e:dev (see e2e/Dockerfile),
# so there is no runtime apt; this just asserts it is present.

# Default bridge port that A connects to (10.0.2.2:<this>).
: "${M3_BRIDGE_PORT:=6555}"

# _lib_net_have_socat — assert socat is present (baked into the image; no apt).
_lib_net_have_socat() {
  command -v socat >/dev/null 2>&1
}

# b_target_for_a [bridge_port]
#   Echoes the HOST:PORT that emulator A's app should connect to in order to
#   reach emulator B's adbd. (host is always the slirp gateway 10.0.2.2.)
b_target_for_a() {
  printf '10.0.2.2:%s\n' "${1:-$M3_BRIDGE_PORT}"
}

# ensure_b_reachable <serial_b> <adbd_port_b> [bridge_port]
#   1. Confirms B's adbd is listening on the container host 127.0.0.1:<adbd_b>.
#   2. Starts (idempotently) a host-side socat bridge bound to 0.0.0.0:<bridge>
#      forwarding to 127.0.0.1:<adbd_b>, so emulator A can reach it via the slirp
#      gateway at 10.0.2.2:<bridge>.
#   3. Echoes the A-side target "10.0.2.2:<bridge>".
#   Returns non-zero if B's adbd cannot be confirmed or socat is unavailable.
ensure_b_reachable() {
  local serial_b="${1:?serial_b required}" adbd_b="${2:-5555}" bridge="${3:-$M3_BRIDGE_PORT}"

  # (1) Confirm B's adbd on the host loopback via a host-side adb round-trip.
  adb connect "127.0.0.1:$adbd_b" >/dev/null 2>&1 || true
  local ok=""
  ok="$(adb -s "127.0.0.1:$adbd_b" shell echo ok 2>/dev/null | tr -d '\r\n ' || true)"
  adb disconnect "127.0.0.1:$adbd_b" >/dev/null 2>&1 || true
  if [ "$ok" != "ok" ]; then
    printf '[lib-net] B adbd NOT confirmed on 127.0.0.1:%s\n' "$adbd_b" >&2
    return 1
  fi

  # (2) Bring up the socat bridge (idempotent — skip if the port is already ours).
  _lib_net_have_socat || { printf '[lib-net] socat unavailable\n' >&2; return 1; }
  if ! pgrep -f "TCP-LISTEN:$bridge,.*127.0.0.1:$adbd_b" >/dev/null 2>&1; then
    # Kill any stale bridge on that port first.
    pkill -f "TCP-LISTEN:$bridge," >/dev/null 2>&1 || true
    socat "TCP-LISTEN:$bridge,fork,reuseaddr" "TCP:127.0.0.1:$adbd_b" \
      >"${SCRCPY_E2E_ARTIFACTS:-/artifacts}/socat-bridge-$bridge.log" 2>&1 &
    sleep 1
    printf '[lib-net] started socat bridge 0.0.0.0:%s -> 127.0.0.1:%s (pid %s)\n' \
      "$bridge" "$adbd_b" "$!" >&2
  else
    printf '[lib-net] socat bridge 0.0.0.0:%s -> 127.0.0.1:%s already up\n' \
      "$bridge" "$adbd_b" >&2
  fi

  b_target_for_a "$bridge"
}

# stop_b_bridge [bridge_port] — tear down the socat bridge (for cleanup).
stop_b_bridge() {
  pkill -f "TCP-LISTEN:${1:-$M3_BRIDGE_PORT}," >/dev/null 2>&1 || true
}
