#!/usr/bin/env bash
# e2e/m4draw-display.sh — drawing-e2e milestone D3 driver: prove the DISPLAY
# round-trip. A stroke drawn on controller A is forwarded to target B, B renders
# it red on its white canvas, B streams the frame back, A decodes+displays it —
# and a SCREENSHOT OF EMULATOR A shows that red stroke at the expected location.
# This closes the VIDEO loop (D2 only proved the control loop: B *recorded* it).
#
# It reuses D2's entire boot/build/connect/transform plumbing (this file is a
# near-superset of e2e/m4draw-control.sh; it likewise SOURCES e2e/run.sh for the
# proven inner helpers — run.sh's dispatch is BASH_SOURCE-guarded so sourcing only
# exposes helpers). On top of D2 it adds three new proofs (the three D3 tasks):
#
#   (T1) BEFORE/AFTER red on A: screenshot A before the stroke -> detect_red on A's
#        remote-view crop -> assert red_count ~ 0 (A shows B's streamed WHITE
#        canvas). Inject a 1000ms stroke on A, poll until the decoded frame carries
#        the red back to A (video latency), screenshot A AFTER -> assert red_count
#        jumps OVER a clear threshold. ALSO assert on B (lib-draw geometry) the same
#        stroke was received — so each stroke is proven BOTH received-by-B AND
#        visible-on-A.
#   (T2) A's remote-view CROP: A keeps its status bar (top) + nav bar (bottom) and
#        letterboxes B's video. We crop detect_red to a safe central box that
#        excludes A's chrome and the draw-app's top-left `strokes=N` overlay, and
#        derive the A-side expected stroke location directly from the A swipe coords
#        (the displayed stroke on A appears ~where we swiped). The crop is documented
#        in the evidence file.
#   (T3) MULTI-SEGMENT shape (an L): two chained swipes on A (a vertical segment then
#        a horizontal segment sharing a corner). Assert on B: 2 strokes with the
#        expected per-segment geometry. Assert on A: red present along BOTH segments
#        (a crop around each segment shows red, and the combined red bbox spans the
#        L's extent).
#
# Exit 0 only if: connection reached AND (single stroke: B-geometry PASS +
# A-red-before~0 + A-red-after >> threshold + A-centroid-near-swipe-path) AND
# (L: both segments on B + red along both segments on A). Self-cleaning trap.
#
# Topology: ONE container, BOTH emulators, --network none, --device /dev/kvm.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SCRCPY_E2E_IMAGE:-scrcpy-e2e:dev}"

# shellcheck source=/dev/null
source "$REPO_ROOT/e2e/run.sh"

# ---------------------------------------------------------------------------
# OUTER MODE — docker-run THIS script in --inner (mirrors run.sh's outer()).
# ---------------------------------------------------------------------------
draw_outer() {
  local artifacts="$REPO_ROOT/e2e/artifacts"
  mkdir -p "$artifacts"
  rm -rf "${artifacts:?}/"* 2>/dev/null || true

  log "DRAW-DISPLAY OUTER: image=$IMAGE repo=$REPO_ROOT artifacts=$artifacts"

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "Image $IMAGE missing — building from e2e/Dockerfile (context=repo root)"
    docker build -t "$IMAGE" -f "$REPO_ROOT/e2e/Dockerfile" "$REPO_ROOT"
  else
    log "Image $IMAGE present — skipping build"
  fi

  [ -e /dev/kvm ] || fail "/dev/kvm not present on host — x86_64 emulators need KVM"

  local netarg="--network none"
  if [ "${E2E_ALLOW_NET:-0}" = "1" ]; then
    netarg=""
    log "E2E_ALLOW_NET=1 — inner container gets network (NON-hermetic; debug only)"
  else
    log "inner container runs with --network none (hermetic)"
  fi

  log "Launching DRAW-DISPLAY INNER container (docker run --device /dev/kvm $netarg)"
  set +e
  docker run --rm \
    $netarg \
    --device /dev/kvm \
    -v "$REPO_ROOT:/workspace" \
    -v scrcpy-gradle-cache:/root/.gradle \
    -v "$artifacts:/artifacts" \
    -e SCRCPY_E2E_EMU_MEM="${EMU_MEM}" \
    -e SCRCPY_E2E_BOOT_TIMEOUT="${BOOT_TIMEOUT}" \
    -e SCRCPY_STREAM_SECS="${STREAM_SECS}" \
    -e SKIP_BUILD="${SKIP_BUILD:-0}" \
    -e FORCE_NATIVE_REBUILD="${FORCE_NATIVE_REBUILD:-0}" \
    "$IMAGE" \
    bash /workspace/e2e/m4draw-display.sh --inner
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    log "==================== DRAW-DISPLAY SUCCESS (D3 green) ===================="
  else
    log "==================== DRAW-DISPLAY FAILURE (rc=$rc) ===================="
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# INNER MODE — boot both, connect A->B(draw), assert stroke A->B AND visible-on-A.
# ---------------------------------------------------------------------------

# Stroke-assert tolerance on B: max(30px, 4%) per the D2/D3 accept criteria.
export AB_ABS_TOL="${AB_ABS_TOL:-30}"
export AB_REL_TOL_PCT="${AB_REL_TOL_PCT:-4}"

# --- A-side display thresholds (justified in the evidence) -----------------
# A 12px-wide red line spanning hundreds of px = thousands of red px on B; on A
# the round-tripped frame renders the same line (this app shows B MAGNIFIED ~1.8x
# in A's surface — see the LOCATION note below), JPEG/H264 decode slightly
# desaturates the fringe. We require AFTER >= A_RED_AFTER_MIN (default 500) — a
# deliberately conservative floor: even heavy desaturation of a multi-hundred-px
# 12px line leaves well over 500 saturated-red px. BEFORE must be <=
# A_RED_BEFORE_MAX (default 50) — A is showing B's pristine WHITE canvas, so
# essentially 0; a tiny nonzero allowance covers stray decode noise.
export A_RED_BEFORE_MAX="${A_RED_BEFORE_MAX:-50}"
export A_RED_AFTER_MIN="${A_RED_AFTER_MIN:-500}"
# How long to poll A for the decoded red frame to arrive (video latency).
export A_RED_POLL_SECS="${A_RED_POLL_SECS:-20}"
#
# LOCATION proof — the honest geometry.
# Empirically (first D3 run, screenshots inspected) this app does NOT show B's
# video at A's swipe coordinates: A renders B MAGNIFIED (~1.8x) and top-left
# anchored, so the displayed stroke lands well below/right of where we swiped and
# B content past B_y~960 is clipped off A's surface bottom. So "red centroid ~ A
# swipe coords" is FALSE for this app. The robust, non-circular location proof we
# use instead:
#   1) keep every drawn shape in the UPPER region of A (small A_y) so its whole
#      B-image is inside A's visible (magnified) surface — nothing is clipped;
#   2) SHAPE SIGNATURE: a diagonal stroke renders as a diagonal on A (red bbox is
#      both wide AND tall); the L renders as an L (after seg1 the red is tall &
#      narrow; seg2 then ADDS width — a horizontal arm appears);
#   3) CROSS-VALIDATED LOCATION: derive the B->A display affine from the SINGLE
#      stroke's two endpoints (B recorded -> A red bbox corners), then PREDICT
#      where the L's vertical segment must appear on A and assert red is present
#      in that predicted band. The transform comes from shape #1 and is checked
#      against shape #2 — so the location match is not self-fulfilling.
# Per-segment red presence floor (a tight band around a ~hundreds-px 12px line).
export A_SEG_MIN="${A_SEG_MIN:-200}"
# Tolerance (px, in A coords) for the cross-validated predicted L-vertical band.
export A_PREDICT_TOL="${A_PREDICT_TOL:-90}"

# draw_state_b — echo "taps last_x last_y" for B's draw app (taps channel).
draw_state_b() {
  draw_read_file "$SERIAL_B" \
    | sed -n 's/^taps=\([0-9]*\) last=\([0-9-]*\),\([0-9-]*\).*/\1 \2 \3/p' \
    | tail -1
}

# _mid <a> <b> — integer midpoint.
_mid() { echo $(( ( $1 + $2 ) / 2 )); }

# a_red — run detect_red.py on an A screenshot crop; echo the whole result line.
#   a_red <png> <x0> <y0> <x1> <y1>
a_red() {
  python3 "$WORKSPACE/e2e/detect_red.py" "$1" "$2,$3,$4,$5"
}
# a_red_count <png> <x0> <y0> <x1> <y1> — just the integer red_count.
a_red_count() { a_red "$@" | sed -n 's/.*red_count=\([0-9]*\).*/\1/p'; }
# parse_centroid <detect_red line> -> "cx cy" (or empty if NA).
parse_centroid() {
  echo "$1" | sed -n 's/.*centroid=\([0-9]*\),\([0-9]*\).*/\1 \2/p'
}
# parse_bbox <detect_red line> -> "minx miny maxx maxy" (or empty if NA).
parse_bbox() {
  echo "$1" | sed -n 's/.*bbox=\([0-9]*\),\([0-9]*\),\([0-9]*\),\([0-9]*\).*/\1 \2 \3 \4/p'
}
# parse_count <detect_red line> -> integer red_count.
parse_count() {
  echo "$1" | sed -n 's/.*red_count=\([0-9]*\).*/\1/p'
}

# assert_b_stroke <expected sx sy ex ey on B> <AX0 AY0 AX1 AY1> <prev_strokes>
#   Waits for B's strokes=N to increment, reads it, asserts multi-point drag +
#   start/effEnd within tol of the expected B endpoints. Echoes (on fd 3, the
#   evidence file is the caller's job) a verdict; returns 0 PASS / 1 FAIL and sets
#   globals B_VERDICT, B_NCUR, B_RECORDED, B_DETAIL for the caller.
#   args: serial AX0 AY0 AX1 AY1 ebx0 eby0 ebx1 eby1 BW BH prev_strokes
assert_b_stroke() {
  local serial="$1" AX0="$2" AY0="$3" AX1="$4" AY1="$5"
  local ebx0="$6" eby0="$7" ebx1="$8" eby1="$9" BW="${10}" BH="${11}" prev="${12}"
  local wait=0 ncur
  while [ "$wait" -lt 15 ]; do
    ncur="$(draw_strokes_count "$serial")"
    [ "${ncur:-0}" -gt "$prev" ] && break
    sleep 1; wait=$((wait+1))
  done
  ncur="$(draw_strokes_count "$serial")"
  B_NCUR="$ncur"
  B_RECORDED="$(draw_read_strokes "$serial")"
  if [ "${ncur:-0}" -le "$prev" ]; then
    B_VERDICT="FAIL"; B_DETAIL="no new stroke on B (strokes still $ncur)"; return 1
  fi
  local rpoints rsx rsy rex rey rminx rminy rmaxx rmaxy
  read -r rpoints rsx rsy rex rey rminx rminy rmaxx rmaxy <<<"$B_RECORDED"
  local eex eey
  if [ "$AX1" -ge "$AX0" ]; then eex="$rmaxx"; else eex="$rminx"; fi
  if [ "$AY1" -ge "$AY0" ]; then eey="$rmaxy"; else eey="$rminy"; fi
  local v_pts="PASS" v_s="PASS" v_e="PASS"
  [ "${rpoints:-0}" -gt 2 ] || v_pts="FAIL"
  auto_within_tol "$ebx0" "$rsx" "$BW" && auto_within_tol "$eby0" "$rsy" "$BH" || v_s="FAIL"
  auto_within_tol "$ebx1" "$eex" "$BW" && auto_within_tol "$eby1" "$eey" "$BH" || v_e="FAIL"
  local dsx dsy dex dey
  dsx="$(_abs $(( rsx - ebx0 )))"; dsy="$(_abs $(( rsy - eby0 )))"
  dex="$(_abs $(( eex - ebx1 )))"; dey="$(_abs $(( eey - eby1 )))"
  B_DETAIL="points=$rpoints(need>2:$v_pts) start=($rsx,$rsy) effEnd=($eex,$eey) expS=($ebx0,$eby0) expE=($ebx1,$eby1) dStart=($dsx,$dsy)[$v_s] dEnd=($dex,$dey)[$v_e]"
  if [ "$v_pts" = PASS ] && [ "$v_s" = PASS ] && [ "$v_e" = PASS ]; then
    B_VERDICT="PASS"; return 0
  fi
  B_VERDICT="FAIL"; return 1
}

inner_draw() {
  source "$WORKSPACE/e2e/lib-net.sh"
  source "$WORKSPACE/e2e/lib-target.sh"
  source "$WORKSPACE/e2e/lib-automation.sh"
  source "$WORKSPACE/e2e/lib-draw.sh"

  local DRAW_APK="$WORKSPACE/e2e/draw-app/app/build/outputs/apk/debug/app-debug.apk"

  log "INNER(display): D3 on $(uname -m); A target = 10.0.2.2:${BRIDGE_PORT}; B-tol=max(${AB_ABS_TOL}px,${AB_REL_TOL_PCT}%)"
  log "  A-red thresholds: before<=${A_RED_BEFORE_MAX} after>=${A_RED_AFTER_MIN} seg>=${A_SEG_MIN} predictTol=${A_PREDICT_TOL}px poll=${A_RED_POLL_SECS}s"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  ensure_build_tools
  build_native
  build_apks
  build_draw_apk

  boot_both

  local ASIZE BSIZE AW AH BW BH
  ASIZE="$(wm_size "$SERIAL_A")"; AW="${ASIZE%% *}"; AH="${ASIZE##* }"
  BSIZE="$(wm_size "$SERIAL_B")"; BW="${BSIZE%% *}"; BH="${BSIZE##* }"
  log "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
  [ -n "$AW" ] && [ -n "$BW" ] || fail "could not read screen sizes (A='$ASIZE' B='$BSIZE')"

  # --- Install + LAUNCH the DRAW app on B ------------------------------------
  log "installing draw app on B ($SERIAL_B): $DRAW_APK"
  draw_install "$SERIAL_B" "$DRAW_APK" >/dev/null || fail "draw install on B failed"
  log "launching draw app on B"
  draw_launch "$SERIAL_B" || fail "draw app did not gain focus on B"
  log "B focus: $(draw_focused "$SERIAL_B")"

  adb -s "$SERIAL_B" shell rm -f /data/local/tmp/scrcpy-server.jar >/dev/null 2>&1 || true
  adb -s "$SERIAL_B" logcat -c >/dev/null 2>&1 || true
  ( adb -s "$SERIAL_B" logcat -v threadtime >"$ARTIFACTS/logcat-B-full.txt" 2>&1 ) &
  LOGCATB_PID=$!

  # --- Bridge B's adbd onto 10.0.2.2:6555 for A ------------------------------
  local ATARGET
  ATARGET="$(ensure_b_reachable "$SERIAL_B" "$ADBD_B" "$BRIDGE_PORT")" \
    || fail "ensure_b_reachable failed"
  local THOST="${ATARGET%%:*}" TPORT="${ATARGET##*:}"
  log "A connect target = $ATARGET"

  # --- Install + drive A's connect flow (android-app controller) -------------
  log "installing android-app APK on A ($SERIAL_A)"
  adb -s "$SERIAL_A" install -r "$APK" >/dev/null || fail "adb install on A failed"

  adb -s "$SERIAL_A" logcat -c >/dev/null 2>&1 || true
  ( adb -s "$SERIAL_A" logcat -v threadtime >"$ARTIFACTS/logcat-A-full.txt" 2>&1 ) &
  LOGCATA_PID=$!

  log "gating on A->$THOST:$TPORT reachability before connect"
  local rtry=0 reachable=0
  while [ "$rtry" -lt 30 ]; do
    if adb -s "$SERIAL_A" shell "echo > /dev/tcp/$THOST/$TPORT" >/dev/null 2>&1; then
      reachable=1; log "  A can reach $THOST:$TPORT (probe ok after ${rtry}x)"; break
    fi
    sleep 2; rtry=$((rtry+1))
  done
  [ "$reachable" = 1 ] || log "  WARN: A->$THOST:$TPORT probe never succeeded; trying connect anyway"

  local ASTDIO="$ARTIFACTS/A-scrcpy-stdio.log" CONNECTED="" BPROC="" attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt+1))
    log "connect attempt #$attempt: launching $MAIN_ACT on A (host=$THOST port=$TPORT)"
    adb -s "$SERIAL_A" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb -s "$SERIAL_A" shell am start -n "$MAIN_ACT" \
      --es host "$THOST" --es port "$TPORT" >/dev/null || fail "am start MainActivity failed"
    sleep 5
    local UIXML="$ARTIFACTS/uidump-A-main.xml" dtry=0
    while [ "$dtry" -lt 6 ]; do
      adb -s "$SERIAL_A" shell uiautomator dump /sdcard/uidump.xml >/dev/null 2>&1 || true
      adb -s "$SERIAL_A" shell cat /sdcard/uidump.xml >"$UIXML" 2>/dev/null || true
      grep -q 'id/connectButton' "$UIXML" 2>/dev/null && break
      sleep 2; dtry=$((dtry+1))
    done
    local CXY
    CXY="$(node_center connectButton "$UIXML" || true)"
    [ -n "$CXY" ] || fail "could not locate connectButton in UI dump"
    log "tapping Connect ($CXY) -> ScrcpyActivity"
    adb -s "$SERIAL_A" shell input tap $CXY >/dev/null 2>&1 || true
    log "waiting up to ${STREAM_SECS}s for a stable stream (server on B + Connected)"
    local t=0 FAILED=""
    while [ "$t" -lt "$STREAM_SECS" ]; do
      adb -s "$SERIAL_A" shell run-as "$PKG" cat cache/scrcpy-stdio.log >"$ASTDIO" 2>/dev/null || true
      CONNECTED="$(grep -E 'INFO: Connected to ' "$ASTDIO" 2>/dev/null | head -1 || true)"
      BPROC="$(b_server_proc | head -1 || true)"
      [ -n "$CONNECTED" ] && [ -n "$BPROC" ] && break
      FAILED="$(grep -E 'Network is unreachable|Could not connect to|Server connection failed' "$ASTDIO" 2>/dev/null | head -1 || true)"
      [ -n "$FAILED" ] && { log "  scrcpy aborted this attempt: '$FAILED'"; break; }
      sleep 3; t=$((t+3))
    done
    { [ -n "$CONNECTED" ] && [ -n "$BPROC" ]; } && break
    log "connect attempt #$attempt did not reach a stable stream; retrying after a settle"
    sleep 5
  done
  [ -n "$CONNECTED" ] || fail "A did NOT reach scrcpy Connected after $attempt attempts (no 'INFO: Connected to')"
  [ -n "$BPROC" ]     || fail "scrcpy-server NOT running on B"
  log "stream up: '$CONNECTED' ; B server: '$BPROC'"

  # Confirm A is actually RENDERING (not black) — the video-decode path must be
  # alive for the round-trip to be meaningful. scrcpy's SDL/GL logs a Texture/
  # decoder line once frames flow; record it for the evidence/debug.
  local ATEX
  ATEX="$(grep -E 'Texture|first frame|video|decoder|OpenGL|Renderer' "$ASTDIO" 2>/dev/null | head -3 || true)"
  log "A render evidence (scrcpy stdio): ${ATEX:-<none matched>}"

  sleep 6   # let the first video frames + surface settle

  if ! draw_focused "$SERIAL_B" | grep -q "$DRAW_PKG"; then
    log "draw app lost focus on B — relaunching"
    draw_launch "$SERIAL_B" || fail "could not refocus draw app on B"
  fi

  log "resetting B draw state (post-stream, so stray strokes/taps don't pollute)"
  draw_reset "$SERIAL_B" || fail "draw_reset on B failed"

  # ==========================================================================
  # Derive the A->B transform from two CALIBRATION TAPS on A.
  # ==========================================================================
  local x_lo=$(( AW * 30 / 100 ))  x_hi=$(( AW * 70 / 100 ))
  local y_lo=$(( AH * 30 / 100 ))  y_hi=$(( AH * 70 / 100 ))
  local CAL=( "$x_lo $y_lo" "$x_hi $y_hi" )

  local -a CAX CAY CBX CBY
  local i=0 prev_n=0
  for p in "${CAL[@]}"; do
    local ax="${p%% *}" ay="${p##* }"
    log "calibration tap #$((i+1)) on A at ($ax,$ay)"
    auto_tap_on_a "$SERIAL_A" "$ax" "$ay"
    local wait=0 st n bx by
    while [ "$wait" -lt 12 ]; do
      st="$(draw_state_b)"
      n="${st%% *}"; [ -z "$n" ] && n=0
      [ "$n" -gt "$prev_n" ] && break
      sleep 1; wait=$((wait+1))
    done
    st="$(draw_state_b)"
    n="${st%% *}"; bx="$(echo "$st" | awk '{print $2}')"; by="$(echo "$st" | awk '{print $3}')"
    log "  -> B taps state '$st' (count=$n, recorded ($bx,$by))"
    [ "$n" -gt "$prev_n" ] || fail "calibration tap $((i+1)) at ($ax,$ay) NOT received by B — control path broken"
    CAX[$i]="$ax"; CAY[$i]="$ay"; CBX[$i]="$bx"; CBY[$i]="$by"
    prev_n="$n"; i=$((i+1))
  done

  local XFORM
  XFORM="$(auto_derive_transform \
            "${CAX[0]}" "${CAY[0]}" "${CBX[0]}" "${CBY[0]}" \
            "${CAX[1]}" "${CAY[1]}" "${CBX[1]}" "${CBY[1]}")" \
    || fail "could not derive A->B transform from calibration taps"
  local SX1000 OX1000 SY1000 OY1000
  read -r SX1000 OX1000 SY1000 OY1000 <<<"$XFORM"
  log "derived A->B transform (x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"

  draw_reset "$SERIAL_B" || fail "draw_reset (post-calibration) on B failed"

  # ==========================================================================
  # A's REMOTE-VIEW CROP (D3 task 2). A keeps its status bar (top) + nav bar
  # (bottom) and renders B's video (magnified) into A's content rect. We restrict
  # detect_red on A to a box that excludes:
  #   - A's status bar (top): exclude top 8% of A's height
  #   - A's nav bar (bottom): exclude bottom 8% of A's height
  #   - the draw-app's `strokes=N` overlay (top-left small GRAY box; gray, not red,
  #     so harmless to the red detector) and the right-side black letterbox: keep
  #     left 5%..right 92%.
  # All drawn shapes are in A's UPPER region (small A_y) so their whole B-image is
  # inside A's visible magnified surface (nothing clipped) — see the LOCATION note.
  # ==========================================================================
  local ACX0=$(( AW *  5 / 100 ))
  local ACY0=$(( AH *  8 / 100 ))
  local ACX1=$(( AW * 92 / 100 ))
  local ACY1=$(( AH * 92 / 100 ))
  log "A remote-view crop for detect_red = ($ACX0,$ACY0,$ACX1,$ACY1) of ${AW}x${AH}"

  local EVID="$ARTIFACTS/d3-display-evidence.txt"
  {
    echo "=== D3 GOAL: stroke-on-A -> displayed-back-on-A (video round-trip) evidence ($(date '+%F %T')) ==="
    echo "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
    echo "Derived A->B transform (x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"
    echo "  BX = round((SX*AX + OX)/1000) ; BY = round((SY*AY + OY)/1000)"
    echo "B tolerance: max(${AB_ABS_TOL}px, ${AB_REL_TOL_PCT}% of B dim)"
    echo "A detect_red CROP = (${ACX0},${ACY0},${ACX1},${ACY1}) [excludes A status/nav bars + right letterbox]"
    echo "A-red thresholds: before<=${A_RED_BEFORE_MAX}  after>=${A_RED_AFTER_MIN}  per-segment>=${A_SEG_MIN}  predict-tol=${A_PREDICT_TOL}px"
    echo "NOTE: this app shows B MAGNIFIED (~1.8x) top-left anchored; displayed red is NOT at the A swipe coords."
    echo "      Location is proven by (a) shape signature and (b) a B->A display affine fit from the single"
    echo "      stroke, cross-validated by predicting the L's vertical position on A."
    echo "Calibration taps: A(${CAX[0]},${CAY[0]})->B(${CBX[0]},${CBY[0]}) ; A(${CAX[1]},${CAY[1]})->B(${CBX[1]},${CBY[1]})"
    echo
  } >"$EVID"

  local SWIPE_MS="${DRAW_SWIPE_MS:-1000}"
  local all_pass=1
  local prev_strokes=0

  # ==========================================================================
  # PART 1 — SINGLE DIAGONAL STROKE: B-geometry + A round-trip (before~0,
  # after>>thr) + shape signature (the red on A is a diagonal: wide AND tall).
  # The single stroke's B-recorded endpoints vs its A red bbox ALSO calibrate the
  # B->A display affine used to cross-validate the L in PART 2.
  # Keep it in A's UPPER region so the whole image is visible on A (unclipped).
  # ==========================================================================
  local SAX0=$(( AW * 20 / 100 )) SAY0=$(( AH * 15 / 100 ))
  local SAX1=$(( AW * 55 / 100 )) SAY1=$(( AH * 40 / 100 ))
  log "PART1 single stroke on A: ($SAX0,$SAY0)->($SAX1,$SAY1) ${SWIPE_MS}ms"

  # BEFORE screenshot of A — must show B's white canvas (red ~ 0).
  draw_screencap "$SERIAL_A" "$ARTIFACTS/A_before.png" || fail "A_before screencap failed"
  local A_BEFORE_LINE A_BEFORE_CNT
  A_BEFORE_LINE="$(a_red "$ARTIFACTS/A_before.png" "$ACX0" "$ACY0" "$ACX1" "$ACY1")"
  A_BEFORE_CNT="$(parse_count "$A_BEFORE_LINE")"
  log "  A_before: $A_BEFORE_LINE"

  # Inject the stroke on A.
  draw_swipe "$SERIAL_A" "$SAX0" "$SAY0" "$SAX1" "$SAY1" "$SWIPE_MS"

  # Assert B received it (geometry).
  local EB0 EB1 ebx0 eby0 ebx1 eby1
  EB0="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$SAX0" "$SAY0")"
  EB1="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$SAX1" "$SAY1")"
  ebx0="${EB0%% *}"; eby0="${EB0##* }"; ebx1="${EB1%% *}"; eby1="${EB1##* }"
  assert_b_stroke "$SERIAL_B" "$SAX0" "$SAY0" "$SAX1" "$SAY1" \
    "$ebx0" "$eby0" "$ebx1" "$eby1" "$BW" "$BH" "$prev_strokes" || true
  local P1_B_VERDICT="$B_VERDICT" P1_B_DETAIL="$B_DETAIL" P1_B_RECORDED="$B_RECORDED"
  prev_strokes="$B_NCUR"
  log "  PART1 B stroke: [$P1_B_VERDICT] $P1_B_DETAIL"
  # B-recorded geometry of the single stroke (for the B->A affine fit).
  local pb_pts pb_sx pb_sy pb_ex pb_ey pb_minx pb_miny pb_maxx pb_maxy
  read -r pb_pts pb_sx pb_sy pb_ex pb_ey pb_minx pb_miny pb_maxx pb_maxy <<<"$P1_B_RECORDED"

  # Poll A for the decoded red frame (video latency) until after-red crosses the
  # threshold or we time out.
  local poll=0 A_AFTER_LINE="" A_AFTER_CNT=0
  while [ "$poll" -lt "$A_RED_POLL_SECS" ]; do
    draw_screencap "$SERIAL_A" "$ARTIFACTS/A_after.png" || fail "A_after screencap failed"
    A_AFTER_LINE="$(a_red "$ARTIFACTS/A_after.png" "$ACX0" "$ACY0" "$ACX1" "$ACY1")"
    A_AFTER_CNT="$(parse_count "$A_AFTER_LINE")"
    [ "${A_AFTER_CNT:-0}" -ge "$A_RED_AFTER_MIN" ] && break
    sleep 2; poll=$((poll+2))
  done
  log "  A_after (after ${poll}s poll): $A_AFTER_LINE"

  # Shape signature: a diagonal stroke -> the red bbox on A is BOTH wide and tall.
  local A_AFTER_BBOX a_minx a_miny a_maxx a_maxy a_w a_h
  A_AFTER_BBOX="$(parse_bbox "$A_AFTER_LINE")"
  local P1_A_VERDICT="PASS" v_before="PASS" v_after="PASS" v_shape="PASS"
  [ "${A_BEFORE_CNT:-0}" -le "$A_RED_BEFORE_MAX" ] || v_before="FAIL"
  [ "${A_AFTER_CNT:-0}" -ge "$A_RED_AFTER_MIN" ] || v_after="FAIL"
  if [ -n "$A_AFTER_BBOX" ]; then
    read -r a_minx a_miny a_maxx a_maxy <<<"$A_AFTER_BBOX"
    a_w=$(( a_maxx - a_minx )); a_h=$(( a_maxy - a_miny ))
    # A diagonal: both extents substantial (>=80px each in A coords).
    { [ "$a_w" -ge 80 ] && [ "$a_h" -ge 80 ]; } || v_shape="FAIL"
  else
    a_minx=NA; a_miny=NA; a_maxx=NA; a_maxy=NA; a_w=NA; a_h=NA; v_shape="FAIL"
  fi
  { [ "$v_before" = PASS ] && [ "$v_after" = PASS ] && [ "$v_shape" = PASS ]; } || P1_A_VERDICT="FAIL"

  # ---- Calibrate the B->A display affine from THIS stroke (per axis). --------
  # The red diagonal on A runs from one bbox corner to the opposite, in the same
  # direction as the B stroke. Map B start/end -> A bbox corners (in travel dir),
  # scaled x1000 for integer math (mirrors lib-automation's transform).
  # We only fit this when PART1 passed (so the fiducials are trustworthy).
  local BA_SX1000=0 BA_OX1000=0 BA_SY1000=0 BA_OY1000=0 BA_OK=0
  if [ "$P1_A_VERDICT" = PASS ]; then
    # B endpoints (recorded): start (pb_sx,pb_sy), end (pb_ex,pb_ey). On A the red
    # bbox corner in the stroke's B-travel direction corresponds to the B end.
    local Aex Aey Asx Asy
    if [ "$pb_ex" -ge "$pb_sx" ]; then Aex="$a_maxx"; Asx="$a_minx"; else Aex="$a_minx"; Asx="$a_maxx"; fi
    if [ "$pb_ey" -ge "$pb_sy" ]; then Aey="$a_maxy"; Asy="$a_miny"; else Aey="$a_miny"; Asy="$a_maxy"; fi
    local dbx=$(( pb_ex - pb_sx )) dby=$(( pb_ey - pb_sy ))
    if [ "$dbx" -ne 0 ] && [ "$dby" -ne 0 ]; then
      BA_SX1000=$(( 1000 * (Aex - Asx) / dbx )); BA_OX1000=$(( 1000 * Asx - BA_SX1000 * pb_sx ))
      BA_SY1000=$(( 1000 * (Aey - Asy) / dby )); BA_OY1000=$(( 1000 * Asy - BA_SY1000 * pb_sy ))
      BA_OK=1
    fi
  fi
  log "  B->A display affine (x1000, from single stroke): SX=$BA_SX1000 OX=$BA_OX1000 SY=$BA_SY1000 OY=$BA_OY1000 (ok=$BA_OK)"

  {
    echo "--- PART 1: SINGLE DIAGONAL STROKE (display round-trip) ---"
    echo "A swipe : ($SAX0,$SAY0) -> ($SAX1,$SAY1)"
    echo "B geometry [$P1_B_VERDICT]: $P1_B_DETAIL"
    echo "A_before red: $A_BEFORE_LINE   (need <= $A_RED_BEFORE_MAX : $v_before)"
    echo "A_after  red: $A_AFTER_LINE   (need >= $A_RED_AFTER_MIN : $v_after; polled ${poll}s)"
    echo "A_after shape: bbox W=$a_w H=$a_h  (diagonal needs both >=80 : $v_shape)"
    echo "B->A display affine (x1000) fitted from this stroke: SX=$BA_SX1000 OX=$BA_OX1000 SY=$BA_SY1000 OY=$BA_OY1000 (ok=$BA_OK)"
    echo "PART1 verdict: B=$P1_B_VERDICT  A=$P1_A_VERDICT"
    echo
  } >>"$EVID"
  log "  PART1 A display: before=$A_BEFORE_CNT after=$A_AFTER_CNT shape W=$a_w H=$a_h -> A=$P1_A_VERDICT"
  [ "$P1_B_VERDICT" = PASS ] || all_pass=0
  [ "$P1_A_VERDICT" = PASS ] || all_pass=0

  # ==========================================================================
  # PART 2 — MULTI-SEGMENT L (D3 task 3). Two chained swipes forming an L in A's
  # UPPER region (so the whole L is visible on A, unclipped):
  #   segment 1 (vertical):   (LX, LY_TOP) -> (LX, LY_BOT)
  #   segment 2 (horizontal): (LX, LY_BOT) -> (LX_RIGHT, LY_BOT)
  # sharing the bottom-left corner. Assert on B: 2 strokes, each within tol.
  # Assert on A: (a) red along the VERTICAL arm (tall&narrow band) and along the
  # HORIZONTAL arm (wide&short band), each in the band PREDICTED by the B->A affine
  # fitted in PART 1 (cross-validation — the prediction comes from the diagonal,
  # not the L), and (b) the combined red bbox is L-shaped (tall AND wide).
  # ==========================================================================
  draw_reset "$SERIAL_B" || fail "draw_reset (pre-L) on B failed"
  prev_strokes=0

  local LX=$(( AW * 30 / 100 ))
  local LY_TOP=$(( AH * 15 / 100 ))
  local LY_BOT=$(( AH * 33 / 100 ))
  local LX_RIGHT=$(( AW * 58 / 100 ))
  log "PART2 L on A: seg1 V ($LX,$LY_TOP)->($LX,$LY_BOT) ; seg2 H ($LX,$LY_BOT)->($LX_RIGHT,$LY_BOT)"

  # A BEFORE-L screenshot (fresh canvas — B was reset, A should show white again).
  # Poll until A's red has cleared back under the before-max (the previous stroke's
  # red must drain from the stream after B's reset). This PROVES the displayed red
  # tracks B's live canvas, not a static screenshot artifact.
  local clr=0 AL_BEFORE_LINE="" AL_BEFORE_CNT=99999
  while [ "$clr" -lt "$A_RED_POLL_SECS" ]; do
    draw_screencap "$SERIAL_A" "$ARTIFACTS/A_L_before.png" || fail "A_L_before screencap failed"
    AL_BEFORE_LINE="$(a_red "$ARTIFACTS/A_L_before.png" "$ACX0" "$ACY0" "$ACX1" "$ACY1")"
    AL_BEFORE_CNT="$(parse_count "$AL_BEFORE_LINE")"
    [ "${AL_BEFORE_CNT:-0}" -le "$A_RED_BEFORE_MAX" ] && break
    sleep 2; clr=$((clr+2))
  done
  log "  A_L_before (after ${clr}s clear-poll): $AL_BEFORE_LINE"
  local v_lbefore="PASS"; [ "${AL_BEFORE_CNT:-0}" -le "$A_RED_BEFORE_MAX" ] || v_lbefore="FAIL"

  # Segment 1 (vertical).
  draw_swipe "$SERIAL_A" "$LX" "$LY_TOP" "$LX" "$LY_BOT" "$SWIPE_MS"
  local S1EB0 S1EB1 s1bx0 s1by0 s1bx1 s1by1
  S1EB0="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$LX" "$LY_TOP")"
  S1EB1="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$LX" "$LY_BOT")"
  s1bx0="${S1EB0%% *}"; s1by0="${S1EB0##* }"; s1bx1="${S1EB1%% *}"; s1by1="${S1EB1##* }"
  assert_b_stroke "$SERIAL_B" "$LX" "$LY_TOP" "$LX" "$LY_BOT" \
    "$s1bx0" "$s1by0" "$s1bx1" "$s1by1" "$BW" "$BH" "$prev_strokes" || true
  local L1_B_VERDICT="$B_VERDICT" L1_B_DETAIL="$B_DETAIL"
  prev_strokes="$B_NCUR"
  log "  L seg1 B: [$L1_B_VERDICT] $L1_B_DETAIL"

  # Segment 2 (horizontal), sharing the corner.
  draw_swipe "$SERIAL_A" "$LX" "$LY_BOT" "$LX_RIGHT" "$LY_BOT" "$SWIPE_MS"
  local S2EB0 S2EB1 s2bx0 s2by0 s2bx1 s2by1
  S2EB0="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$LX" "$LY_BOT")"
  S2EB1="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$LX_RIGHT" "$LY_BOT")"
  s2bx0="${S2EB0%% *}"; s2by0="${S2EB0##* }"; s2bx1="${S2EB1%% *}"; s2by1="${S2EB1##* }"
  assert_b_stroke "$SERIAL_B" "$LX" "$LY_BOT" "$LX_RIGHT" "$LY_BOT" \
    "$s2bx0" "$s2by0" "$s2bx1" "$s2by1" "$BW" "$BH" "$prev_strokes" || true
  local L2_B_VERDICT="$B_VERDICT" L2_B_DETAIL="$B_DETAIL"
  prev_strokes="$B_NCUR"
  log "  L seg2 B: [$L2_B_VERDICT] $L2_B_DETAIL"

  # ---- Predict the L's per-segment bands on A from the B->A affine (PART 1). --
  # Map each B endpoint of the L through the fitted B->A display affine to get its
  # expected A position, then build a padded band around each predicted segment.
  # ba_map <bx> <by> -> echoes "ax ay" under the fitted affine.
  ba_map() {
    local bx="$1" by="$2" nx ny ax ay
    nx=$(( BA_SX1000 * bx + BA_OX1000 )); ny=$(( BA_SY1000 * by + BA_OY1000 ))
    if [ "$nx" -ge 0 ]; then ax=$(( (nx + 500) / 1000 )); else ax=$(( (nx - 500) / 1000 )); fi
    if [ "$ny" -ge 0 ]; then ay=$(( (ny + 500) / 1000 )); else ay=$(( (ny - 500) / 1000 )); fi
    printf '%s %s\n' "$ax" "$ay"
  }
  local PAD="$A_PREDICT_TOL"
  local pV0 pV1 pH0 pH1
  local V_X0 V_Y0 V_X1 V_Y1 H_X0 H_Y0 H_X1 H_Y1
  if [ "$BA_OK" = 1 ]; then
    # vertical arm: B (s1bx0,s1by0)->(s1bx1,s1by1) ; horizontal: (s2bx0,..)->(s2bx1,..)
    pV0="$(ba_map "$s1bx0" "$s1by0")"; pV1="$(ba_map "$s1bx1" "$s1by1")"
    pH0="$(ba_map "$s2bx0" "$s2by0")"; pH1="$(ba_map "$s2bx1" "$s2by1")"
    local pv0x="${pV0%% *}" pv0y="${pV0##* }" pv1x="${pV1%% *}" pv1y="${pV1##* }"
    local ph0x="${pH0%% *}" ph0y="${pH0##* }" ph1x="${pH1%% *}" ph1y="${pH1##* }"
    # vertical band: around the predicted V line, padded.
    V_X0=$(( ( pv0x<pv1x ? pv0x : pv1x ) - PAD )); V_X1=$(( ( pv0x>pv1x ? pv0x : pv1x ) + PAD ))
    V_Y0=$(( ( pv0y<pv1y ? pv0y : pv1y ) - PAD )); V_Y1=$(( ( pv0y>pv1y ? pv0y : pv1y ) + PAD ))
    # horizontal band: around the predicted H line, padded; trim left so it starts
    # right of the corner (its own horizontal run, not just the shared corner).
    H_X0=$(( ( ph0x<ph1x ? ph0x : ph1x ) + PAD )); H_X1=$(( ( ph0x>ph1x ? ph0x : ph1x ) + PAD ))
    H_Y0=$(( ( ph0y<ph1y ? ph0y : ph1y ) - PAD )); H_Y1=$(( ( ph0y>ph1y ? ph0y : ph1y ) + PAD ))
    log "  predicted A bands: V=($V_X0,$V_Y0,$V_X1,$V_Y1) H=($H_X0,$H_Y0,$H_X1,$H_Y1)"
  else
    log "  WARN: B->A affine not available (PART1 A failed) — L A-bands fall back to whole crop"
    V_X0="$ACX0"; V_Y0="$ACY0"; V_X1="$ACX1"; V_Y1="$ACY1"
    H_X0="$ACX0"; H_Y0="$ACY0"; H_X1="$ACX1"; H_Y1="$ACY1"
  fi

  # A AFTER-L: poll until red appears along BOTH predicted bands, then assert.
  local lpoll=0 AL_AFTER_LINE="" AL_AFTER_CNT=0 SEG1_LINE="" SEG2_LINE="" SEG1_CNT=0 SEG2_CNT=0
  while [ "$lpoll" -lt "$A_RED_POLL_SECS" ]; do
    draw_screencap "$SERIAL_A" "$ARTIFACTS/A_L_after.png" || fail "A_L_after screencap failed"
    AL_AFTER_LINE="$(a_red "$ARTIFACTS/A_L_after.png" "$ACX0" "$ACY0" "$ACX1" "$ACY1")"
    AL_AFTER_CNT="$(parse_count "$AL_AFTER_LINE")"
    SEG1_LINE="$(a_red "$ARTIFACTS/A_L_after.png" "$V_X0" "$V_Y0" "$V_X1" "$V_Y1")"
    SEG1_CNT="$(parse_count "$SEG1_LINE")"
    SEG2_LINE="$(a_red "$ARTIFACTS/A_L_after.png" "$H_X0" "$H_Y0" "$H_X1" "$H_Y1")"
    SEG2_CNT="$(parse_count "$SEG2_LINE")"
    { [ "${SEG1_CNT:-0}" -ge "$A_SEG_MIN" ] && [ "${SEG2_CNT:-0}" -ge "$A_SEG_MIN" ]; } && break
    sleep 2; lpoll=$((lpoll+2))
  done
  log "  A_L_after (after ${lpoll}s poll): $AL_AFTER_LINE"
  log "    seg1(V) band=($V_X0,$V_Y0,$V_X1,$V_Y1): $SEG1_LINE"
  log "    seg2(H) band=($H_X0,$H_Y0,$H_X1,$H_Y1): $SEG2_LINE"

  local v_seg1="PASS" v_seg2="PASS"
  [ "${SEG1_CNT:-0}" -ge "$A_SEG_MIN" ] || v_seg1="FAIL"
  [ "${SEG2_CNT:-0}" -ge "$A_SEG_MIN" ] || v_seg2="FAIL"

  # The combined L red bbox must be L-shaped on A: both a tall extent AND a wide
  # extent (>=80px each) — proving it is not just a single line.
  local AL_BBOX AL_MINX AL_MINY AL_MAXX AL_MAXY AL_W AL_H
  AL_BBOX="$(parse_bbox "$AL_AFTER_LINE")"
  local v_span="PASS"
  if [ -n "$AL_BBOX" ]; then
    read -r AL_MINX AL_MINY AL_MAXX AL_MAXY <<<"$AL_BBOX"
    AL_W=$(( AL_MAXX - AL_MINX )); AL_H=$(( AL_MAXY - AL_MINY ))
    { [ "$AL_W" -ge 80 ] && [ "$AL_H" -ge 80 ]; } || v_span="FAIL"
  else
    AL_W="NA"; AL_H="NA"; v_span="FAIL"
  fi

  local L_B_VERDICT="PASS"; { [ "$L1_B_VERDICT" = PASS ] && [ "$L2_B_VERDICT" = PASS ]; } || L_B_VERDICT="FAIL"
  local L_A_VERDICT="PASS"; { [ "$v_lbefore" = PASS ] && [ "$v_seg1" = PASS ] && [ "$v_seg2" = PASS ] && [ "$v_span" = PASS ]; } || L_A_VERDICT="FAIL"

  {
    echo "--- PART 2: MULTI-SEGMENT L (display round-trip) ---"
    echo "A L: seg1 V ($LX,$LY_TOP)->($LX,$LY_BOT) ; seg2 H ($LX,$LY_BOT)->($LX_RIGHT,$LY_BOT)"
    echo "B seg1 [$L1_B_VERDICT]: $L1_B_DETAIL"
    echo "B seg2 [$L2_B_VERDICT]: $L2_B_DETAIL"
    echo "A_L_before red: $AL_BEFORE_LINE   (need <= $A_RED_BEFORE_MAX : $v_lbefore; cleared in ${clr}s)"
    echo "A_L_after  red (full crop): $AL_AFTER_LINE   L-shape bbox W=$AL_W H=$AL_H (both >=80 : $v_span)"
    echo "A_L_after  seg1(V) PREDICTED band=($V_X0,$V_Y0,$V_X1,$V_Y1): $SEG1_LINE   (need >= $A_SEG_MIN : $v_seg1)"
    echo "A_L_after  seg2(H) PREDICTED band=($H_X0,$H_Y0,$H_X1,$H_Y1): $SEG2_LINE   (need >= $A_SEG_MIN : $v_seg2)"
    echo "  (the V/H bands are PREDICTED from the PART-1 diagonal's B->A affine — cross-validation)"
    echo "L verdict: B=$L_B_VERDICT  A=$L_A_VERDICT"
    echo
  } >>"$EVID"
  log "  L: B=$L_B_VERDICT A=$L_A_VERDICT (seg1 A=$SEG1_CNT seg2 A=$SEG2_CNT L-bbox W=$AL_W H=$AL_H)"
  [ "$L_B_VERDICT" = PASS ] || all_pass=0
  [ "$L_A_VERDICT" = PASS ] || all_pass=0

  # ----- Artifacts -----------------------------------------------------------
  draw_read_file "$SERIAL_B" >"$ARTIFACTS/e2e_draw.txt" 2>/dev/null || true
  draw_screencap "$SERIAL_B" "$ARTIFACTS/screen-B-draw.png" 2>/dev/null || true
  {
    echo "B final draw file (after L):"
    draw_read_file "$SERIAL_B" 2>/dev/null || true
    echo
    echo "OVERALL: $( [ "$all_pass" -eq 1 ] && echo PASS || echo FAIL )"
  } >>"$EVID"
  log "==== evidence ($EVID) ===="; cat "$EVID" >&2; log "==== end evidence ===="

  kill "$LOGCATA_PID" "$LOGCATB_PID" >/dev/null 2>&1 || true
  [ "$all_pass" -eq 1 ] \
    || fail "D3 display round-trip FAILED — see $EVID (single stroke B/A and/or L B/A did not pass)"
  log "PASS: each stroke drawn on A was received by B AND displayed back red on A; the L is visible along both segments on A and recorded as 2 strokes on B."
  exit 0
}

# build_draw_apk — build the DRAW app OFFLINE with the baked gradle home.
build_draw_apk() {
  local draw_dir="$WORKSPACE/e2e/draw-app"
  local draw_apk="$draw_dir/app/build/outputs/apk/debug/app-debug.apk"
  if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$draw_apk" ]; then
    log "SKIP_BUILD=1 and draw APK present — reusing"; return 0
  fi
  local gradle_home="${GRADLE_USER_HOME:-/opt/gradle-home}"
  [ -d "$gradle_home/wrapper/dists" ] \
    || fail "offline GRADLE_USER_HOME not primed at $gradle_home — rebuild scrcpy-e2e:dev"
  export GRADLE_USER_HOME="$gradle_home"
  log "building draw-app APK (offline GRADLE_USER_HOME=$GRADLE_USER_HOME)"
  ( cd "$draw_dir" && ./gradlew --no-daemon --offline assembleDebug )
  [ -f "$draw_apk" ] || fail "draw-app APK not produced at $draw_apk"
  log "draw APK built: $(ls -la "$draw_apk")"
}

# ---------------------------------------------------------------------------
# INNER entry — reuse run.sh's cleanup trap + boot/build helpers, run inner_draw.
# ---------------------------------------------------------------------------
draw_inner() {
  mkdir -p "$ARTIFACTS"
  trap cleanup EXIT
  log "DRAW-DISPLAY INNER: $(uname -m); whoami=$(whoami); EMU_MEM=${EMU_MEM} BOOT_TIMEOUT=${BOOT_TIMEOUT} STREAM_SECS=${STREAM_SECS}"
  log "KVM: $(ls -l /dev/kvm 2>&1 || echo 'NO /dev/kvm')"
  inner_draw
}

# ===========================================================================
# Dispatch (only when executed directly — run.sh was sourced above).
# ===========================================================================
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --inner) shift; draw_inner "$@" ;;
    *)       draw_outer ;;
  esac
fi
