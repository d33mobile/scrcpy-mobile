#!/usr/bin/env bash
# e2e/lib-automation.sh — M3 task 4: prove A controls B by injecting taps on
# emulator A's rendered remote-view surface and asserting they land at the
# expected coordinate on emulator B (the deterministic target app).
#
# ========================== HOW THE CONTROL PATH WORKS ======================
# A's app (ScrcpyActivity extends SDLActivity) renders B's screen into the SDL
# surface and forwards the surface's touch events to scrcpy's controller, which
# injects them on B over the ADB-over-TCP control channel. So:
#
#     adb -s <A> shell input tap AX AY
#        -> A's SDLSurface receives an SDL ACTION_DOWN at (AX,AY)
#        -> scrcpy maps surface coords -> B's video resolution
#        -> scrcpy controller sends INJECT_TOUCH_EVENT to B
#        -> B's target app records (BX,BY)  [via lib-target.sh channels]
#
# ============================ A->B COORDINATE TRANSFORM =====================
# A and B are the SAME AVD resolution, but A's ScrcpyActivity is NOT fullscreen
# (Theme.AppCompat.NoActionBar still leaves A's status/navigation bars), so the
# SDL surface that shows B's screen occupies only A's content rectangle, and
# scrcpy letterboxes B's video into it preserving aspect ratio. The surface is
# therefore offset (mostly vertically, by A's status bar) and uniformly scaled.
#
# We model the map as an independent affine transform per axis:
#     BX = round( SX * AX + OX )
#     BY = round( SY * AY + OY )
# and DERIVE (SX,OX,SY,OY) empirically from two calibration taps at distinct A
# points (so we never hardcode a guess about A's chrome). All other taps are then
# asserted to fit the derived transform within tolerance. This proves
# coordinate-faithful control rather than a lucky single hit.
#
# All arithmetic is integer (scaled by 1000 to keep a fractional slope) so it runs
# in pure bash with no bc/python dependency.
# ===========================================================================

# Tolerance for "recorded B == expected B": max(ABS_TOL px, REL_TOL% of B dim).
: "${AB_ABS_TOL:=25}"      # absolute pixel tolerance
: "${AB_REL_TOL_PCT:=3}"   # percent-of-screen-dimension tolerance

# auto_tap_on_a <serial_a> <ax> <ay>
#   Inject a tap at A device-pixel (ax,ay). This lands on whatever A view is
#   there; for the remote-view this is the SDLSurface showing B.
auto_tap_on_a() {
  local serial="${1:?serial_a}" ax="${2:?ax}" ay="${3:?ay}"
  adb -s "$serial" shell input tap "$ax" "$ay" >/dev/null 2>&1 || true
}

# auto_read_b <serial_b> [channel]
#   Echo "N X Y" recorded by B's target app (delegates to lib-target.sh). The
#   file channel is the most robust for scripted parsing.
auto_read_b() {
  local serial="${1:?serial_b}" channel="${2:-file}"
  target_read_state "$serial" "$channel"
}

# _abs <int> — absolute value.
_abs() { local v="$1"; [ "$v" -lt 0 ] && v=$(( -v )); printf '%s' "$v"; }

# auto_derive_transform <ax1> <ay1> <bx1> <by1> <ax2> <ay2> <bx2> <by2>
#   Derive the per-axis affine map from two calibration points and echo four
#   integers, each scaled by 1000:  "SX1000 OX1000 SY1000 OY1000"
#   where  BX = round((SX1000*AX + OX1000)/1000), similarly BY.
#     SX1000 = 1000*(bx2-bx1)/(ax2-ax1)
#     OX1000 = 1000*bx1 - SX1000*ax1
#   Requires ax1!=ax2 and ay1!=ay2 (the two calibration taps differ on both axes).
auto_derive_transform() {
  local ax1="$1" ay1="$2" bx1="$3" by1="$4" ax2="$5" ay2="$6" bx2="$7" by2="$8"
  local dax=$(( ax2 - ax1 )) day=$(( ay2 - ay1 ))
  [ "$dax" -ne 0 ] || { echo "[lib-automation] calibration taps share AX" >&2; return 1; }
  [ "$day" -ne 0 ] || { echo "[lib-automation] calibration taps share AY" >&2; return 1; }
  local sx1000 ox1000 sy1000 oy1000
  sx1000=$(( 1000 * (bx2 - bx1) / dax ))
  sy1000=$(( 1000 * (by2 - by1) / day ))
  ox1000=$(( 1000 * bx1 - sx1000 * ax1 ))
  oy1000=$(( 1000 * by1 - sy1000 * ay1 ))
  printf '%s %s %s %s\n' "$sx1000" "$ox1000" "$sy1000" "$oy1000"
}

# auto_expect_b <SX1000> <OX1000> <SY1000> <OY1000> <ax> <ay>
#   Echo the expected B coordinate "EBX EBY" for A point (ax,ay) under the map.
auto_expect_b() {
  local sx1000="$1" ox1000="$2" sy1000="$3" oy1000="$4" ax="$5" ay="$6"
  # round((s*a+o)/1000) with proper rounding for positive denominator.
  local nx=$(( sx1000 * ax + ox1000 )) ny=$(( sy1000 * ay + oy1000 ))
  local ebx eby
  if [ "$nx" -ge 0 ]; then ebx=$(( (nx + 500) / 1000 )); else ebx=$(( (nx - 500) / 1000 )); fi
  if [ "$ny" -ge 0 ]; then eby=$(( (ny + 500) / 1000 )); else eby=$(( (ny - 500) / 1000 )); fi
  printf '%s %s\n' "$ebx" "$eby"
}

# auto_within_tol <expected> <actual> <screen_dim>
#   Returns 0 if |expected-actual| <= max(AB_ABS_TOL, AB_REL_TOL_PCT% of dim).
auto_within_tol() {
  local exp="$1" act="$2" dim="$3"
  local d; d="$(_abs $(( exp - act )))"
  local reltol=$(( dim * AB_REL_TOL_PCT / 100 ))
  local tol="$AB_ABS_TOL"; [ "$reltol" -gt "$tol" ] && tol="$reltol"
  [ "$d" -le "$tol" ]
}

# auto_assert_point <SX1000> <OX1000> <SY1000> <OY1000> <ax> <ay> <bx> <by> \
#                   <bw> <bh>
#   Given the derived transform, A point (ax,ay) and the recorded B point
#   (bx,by) plus B's screen (bw,bh), echo a verdict line and return 0/1:
#     "(ax,ay) -> expect (ebx,eby) got (bx,by) dx=.. dy=.. PASS|FAIL"
auto_assert_point() {
  local sx="$1" ox="$2" sy="$3" oy="$4" ax="$5" ay="$6" bx="$7" by="$8" bw="$9" bh="${10}"
  local eb ebx eby
  eb="$(auto_expect_b "$sx" "$ox" "$sy" "$oy" "$ax" "$ay")"
  ebx="${eb%% *}"; eby="${eb##* }"
  local dx dy
  dx="$(_abs $(( bx - ebx )))"; dy="$(_abs $(( by - eby )))"
  local verdict="PASS"
  if auto_within_tol "$ebx" "$bx" "$bw" && auto_within_tol "$eby" "$by" "$bh"; then
    verdict="PASS"
  else
    verdict="FAIL"
  fi
  printf '(%s,%s) -> expect (%s,%s) got (%s,%s) dx=%s dy=%s %s\n' \
    "$ax" "$ay" "$ebx" "$eby" "$bx" "$by" "$dx" "$dy" "$verdict"
  [ "$verdict" = "PASS" ]
}
