#!/usr/bin/env bash
# e2e/lib-target.sh — drive + assert the deterministic input target app on B.
#
# The target app (e2e/target-app/, package net.scrcpy.e2etarget) is a single
# full-screen Activity that records EVERY tap and exposes the resulting state
# through THREE channels. This library wraps install/launch/read/reset and
# documents the exact assertion queries M3 task 4 will use.
#
# ============================ STATE CHANNELS ================================
# After a tap, the app records:
#   * taps   = total ACTION_DOWN count since launch (launch resets to 0)
#   * lastX  = raw X of the most recent tap, in DEVICE PIXELS (rounded)
#   * lastY  = raw Y of the most recent tap, in DEVICE PIXELS (rounded)
# (lastX/lastY equal the `adb shell input tap X Y` coordinates within rounding,
#  because the target view is full-screen, so the raw touch coord == screen coord.)
#
# Channel 1 — ON-SCREEN TEXT (uiautomator):
#   The full-screen TextView's text AND content-desc = "taps=N last=X,Y".
#   QUERY:
#     adb -s "$S" shell uiautomator dump /sdcard/ui.xml >/dev/null
#     adb -s "$S" shell cat /sdcard/ui.xml \
#       | grep -o 'taps=[0-9]* last=[0-9-]*,[0-9-]*' | head -1
#   PARSE: e.g. "taps=2 last=540,1200"  ->  N=2  X=540  Y=1200.
#
# Channel 2 — LOGCAT:
#   One line per tap, tag E2E_TARGET: "tap #N at X,Y".
#   QUERY:
#     adb -s "$S" logcat -d -s E2E_TARGET | grep -oE 'tap #[0-9]+ at [0-9-]+,[0-9-]+'
#   The LAST such line is the latest tap; "tap #N at X,Y" -> N, X, Y.
#
# Channel 3 — FILE (most robust for scripted parsing):
#   getExternalFilesDir(null)/e2e_state.txt holds a single line "N X Y".
#   Path on device:
#     /sdcard/Android/data/net.scrcpy.e2etarget/files/e2e_state.txt
#   On API 30+ the adb shell user cannot `cat` an app's external files dir
#   directly (Permission denied), so we read it via `run-as` (works because the
#   target is a debuggable build):
#     adb -s "$S" shell run-as net.scrcpy.e2etarget cat files/e2e_state.txt
#       ->  "N X Y"
# ===========================================================================

TARGET_PKG="net.scrcpy.e2etarget"
TARGET_ACTIVITY="$TARGET_PKG/.TargetActivity"
# Path inside the app sandbox, as seen by `run-as` (relative to the app home).
TARGET_STATE_RELPATH="files/e2e_state.txt"
# Absolute external path (for reference / documentation).
TARGET_STATE_FILE="/sdcard/Android/data/$TARGET_PKG/files/e2e_state.txt"
TARGET_TAG="E2E_TARGET"

# target_install <serial> <apk_path>
#   Reinstalls the target APK on the given device.
target_install() {
  local serial="${1:?serial required}" apk="${2:?apk path required}"
  adb -s "$serial" install -r -g "$apk"
}

# target_launch <serial>
#   Starts TargetActivity and waits until it owns mCurrentFocus. Launch resets
#   the tap counter to 0. Returns non-zero if focus is not acquired.
target_launch() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell am start -W -n "$TARGET_ACTIVITY" >/dev/null 2>&1 || true
  local tries=0 focus=""
  while [ "$tries" -lt 30 ]; do
    focus="$(adb -s "$serial" shell dumpsys window 2>/dev/null \
              | grep -m1 mCurrentFocus || true)"
    echo "$focus" | grep -q "$TARGET_PKG" && return 0
    sleep 1; tries=$((tries+1))
  done
  printf '[lib-target] TargetActivity did not gain focus (mCurrentFocus=%s)\n' \
    "$focus" >&2
  return 1
}

# target_focused <serial>
#   Echoes the mCurrentFocus line (for assertions/diagnostics).
target_focused() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true
}

# target_reset <serial>
#   Relaunch == reset (onCreate sets taps=0 and rewrites the state file). Kept as
#   a named helper so task 4 reads clearly.
target_reset() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell am force-stop "$TARGET_PKG" >/dev/null 2>&1 || true
  target_launch "$serial"
}

# target_read_state <serial> [channel]
#   Echoes "N X Y" (space-separated) for the latest recorded tap.
#   channel: file (default) | ui | logcat — reads the requested channel and
#   normalises it to "N X Y" so callers parse one format regardless of channel.
target_read_state() {
  local serial="${1:?serial required}" channel="${2:-file}"
  case "$channel" in
    file)
      adb -s "$serial" shell run-as "$TARGET_PKG" cat "$TARGET_STATE_RELPATH" 2>/dev/null \
        | tr -d '\r' | awk 'NF{print $1, $2, $3}' | tail -1 || true
      ;;
    ui)
      adb -s "$serial" shell uiautomator dump /sdcard/e2e_ui.xml >/dev/null 2>&1 || true
      adb -s "$serial" shell cat /sdcard/e2e_ui.xml 2>/dev/null \
        | grep -o 'taps=[0-9]* last=[0-9-]*,[0-9-]*' | head -1 \
        | sed -E 's/taps=([0-9]*) last=([0-9-]*),([0-9-]*)/\1 \2 \3/' || true
      ;;
    logcat)
      adb -s "$serial" logcat -d -s "$TARGET_TAG" 2>/dev/null \
        | grep -oE 'tap #[0-9]+ at [0-9-]+,[0-9-]+' | tail -1 \
        | sed -E 's/tap #([0-9]+) at ([0-9-]+),([0-9-]+)/\1 \2 \3/' || true
      ;;
    *)
      printf '[lib-target] unknown channel: %s\n' "$channel" >&2; return 0 ;;
  esac
  return 0
}

# target_tap <serial> <x> <y>
#   Dispatches a tap at device-pixel (x,y) on the device's own input (used by the
#   task-2 self-test; task 4 taps A's rendered surface instead).
target_tap() {
  local serial="${1:?serial required}" x="${2:?x required}" y="${3:?y required}"
  adb -s "$serial" shell input tap "$x" "$y"
}
