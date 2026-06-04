#!/usr/bin/env bash
# e2e/lib-draw.sh — drive + assert the deterministic DRAWING target app on a device.
#
# The draw app (e2e/draw-app/, package net.scrcpy.e2edraw, DrawActivity) turns a
# touch STROKE (DOWN -> MOVE* -> UP) into queryable geometry AND an accumulating
# bright-red (#FF0000) drawing on a white canvas. This library wraps install /
# launch / reset / read / swipe and the red-pixel screenshot analysis so both the
# standalone (D1) and the A->B (D2/D3) flows parse one stable format.
#
# Sourceable, pure bash. Depends on `adb` on PATH and (for draw_count_red)
# `python3` + Pillow via the sibling e2e/detect_red.py.
#
# ============================ STATE CHANNELS ================================
# The app records, per stroke, in DEVICE PIXELS (the view is full-screen so the
# touch coord == the `adb shell input swipe/tap` coord within rounding):
#   points  = touch sample count of the stroke (DOWN + each MOVE + UP)
#   start   = (x0,y0) of ACTION_DOWN
#   end     = (xN,yN) of ACTION_UP
#   bbox    = (minx,miny,maxx,maxy)
# plus a running taps=N last=X,Y line (DOWN+UP gestures classified as taps, for
# lib-automation calibration) and a strokes=N summary.
#
# Channel 1 — FILE (most robust): filesDir/e2e_draw.txt, rewritten every stroke:
#     STROKE 1 points=42 start=120,300 end=620,800 bbox=120,300,620,800
#     taps=0 last=-1,-1
#     strokes=1
#   adb -s "$S" shell run-as net.scrcpy.e2edraw cat files/e2e_draw.txt
# Channel 2 — LOGCAT (tag E2E_DRAW): "stroke #n points=K start=.. end=.. bbox=.."
#   and "tap #N at X,Y".
# Channel 3 — ON-SCREEN (uiautomator): a top-left TextView text/content-desc
#   "strokes=N".
# ===========================================================================

DRAW_PKG="net.scrcpy.e2edraw"
DRAW_ACTIVITY="$DRAW_PKG/.DrawActivity"
# Path inside the app sandbox, as seen by `run-as` (relative to the app home).
DRAW_STATE_RELPATH="files/e2e_draw.txt"
DRAW_TAG="E2E_DRAW"

# Directory of this library (so draw_count_red finds the sibling detect_red.py).
DRAW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DRAW_DETECT_RED="${DRAW_DETECT_RED:-$DRAW_LIB_DIR/detect_red.py}"

# draw_install <serial> <apk_path>
#   Reinstalls the draw APK on the given device (granting runtime perms; the app
#   declares none, but -g is harmless and matches the target-app helper).
draw_install() {
  local serial="${1:?serial required}" apk="${2:?apk path required}"
  adb -s "$serial" install -r -g "$apk"
}

# draw_launch <serial>
#   Starts DrawActivity and waits until it owns mCurrentFocus. onCreate rewrites
#   the state file clean (strokes=0). Returns non-zero if focus is not acquired.
draw_launch() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell am start -W -n "$DRAW_ACTIVITY" >/dev/null 2>&1 || true
  local tries=0 focus=""
  while [ "$tries" -lt 30 ]; do
    focus="$(adb -s "$serial" shell dumpsys window 2>/dev/null \
              | grep -m1 mCurrentFocus || true)"
    echo "$focus" | grep -q "$DRAW_PKG" && return 0
    sleep 1; tries=$((tries+1))
  done
  printf '[lib-draw] DrawActivity did not gain focus (mCurrentFocus=%s)\n' \
    "$focus" >&2
  return 1
}

# draw_focused <serial>
#   Echoes the mCurrentFocus line (for assertions/diagnostics).
draw_focused() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus || true
}

# draw_reset <serial>
#   Clear all strokes: force-stop + relaunch (onCreate re-inits the stroke list
#   and rewrites the file to strokes=0). Also clears the E2E_DRAW logcat buffer so
#   the logcat channel starts clean too.
draw_reset() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell am force-stop "$DRAW_PKG" >/dev/null 2>&1 || true
  adb -s "$serial" logcat -c >/dev/null 2>&1 || true
  draw_launch "$serial"
}

# draw_read_file <serial>
#   Echoes the raw e2e_draw.txt contents (all STROKE lines + taps line + summary).
draw_read_file() {
  local serial="${1:?serial required}"
  adb -s "$serial" shell run-as "$DRAW_PKG" cat "$DRAW_STATE_RELPATH" 2>/dev/null \
    | tr -d '\r' || true
}

# draw_strokes_count <serial>
#   Echoes N from the strokes=N summary line (0 if none / app not launched).
draw_strokes_count() {
  local serial="${1:?serial required}" n
  n="$(draw_read_file "$serial" | sed -n 's/^strokes=\([0-9]*\).*/\1/p' | tail -1)"
  [ -n "$n" ] && echo "$n" || echo 0
}

# draw_read_strokes <serial>
#   Echoes the LAST stroke as a normalised single line:
#     "points start_x start_y end_x end_y minx miny maxx maxy"
#   (space-separated ints) so callers parse one format. Empty if no stroke yet.
draw_read_strokes() {
  local serial="${1:?serial required}" line
  line="$(draw_read_file "$serial" | grep '^STROKE ' | tail -1)"
  [ -z "$line" ] && return 0
  echo "$line" | sed -E \
    's/^STROKE [0-9]+ points=([0-9]+) start=([0-9-]+),([0-9-]+) end=([0-9-]+),([0-9-]+) bbox=([0-9-]+),([0-9-]+),([0-9-]+),([0-9-]+).*/\1 \2 \3 \4 \5 \6 \7 \8 \9/'
}

# draw_swipe <serial> <x0> <y0> <x1> <y1> [ms]
#   Injects a straight drag stroke directly on the device (DOWN at x0,y0 ->
#   MOVE* -> UP at x1,y1). Default duration 300ms; `input swipe` interpolates a
#   handful of MOVE samples so the recorded stroke has several points.
draw_swipe() {
  local serial="${1:?serial required}" x0="${2:?x0}" y0="${3:?y0}" \
        x1="${4:?x1}" y1="${5:?y1}" ms="${6:-300}"
  adb -s "$serial" shell input swipe "$x0" "$y0" "$x1" "$y1" "$ms"
}

# draw_screencap <serial> <out.png>
#   Captures the device screen to a PNG on the host.
draw_screencap() {
  local serial="${1:?serial required}" out="${2:?out png required}"
  adb -s "$serial" exec-out screencap -p >"$out"
}

# draw_count_red <png> [crop]
#   Shells to detect_red.py; echoes its single line:
#     red_count=<n> bbox=<minx,miny,maxx,maxy|NA> centroid=<cx,cy|NA>
#   crop (optional) = "x0,y0,x1,y1" to restrict to a region (e.g. A's surface).
draw_count_red() {
  local png="${1:?png required}" crop="${2:-}"
  python3 "$DRAW_DETECT_RED" "$png" "$crop"
}

# draw_red_count_value <png> [crop]
#   Convenience: echoes just the integer red_count from draw_count_red.
draw_red_count_value() {
  draw_count_red "$1" "${2:-}" | sed -n 's/.*red_count=\([0-9]*\).*/\1/p'
}
