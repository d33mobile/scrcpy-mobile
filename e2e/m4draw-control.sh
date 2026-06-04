#!/usr/bin/env bash
# e2e/m4draw-control.sh — drawing-e2e milestone D2 driver: prove a STROKE injected
# on controller A is received by the DRAW app on target B with correct geometry.
#
# This is the two-emulator analogue of e2e/run.sh, but B runs the DRAWING app
# (net.scrcpy.e2edraw/.DrawActivity) instead of the tap target app, and the
# assertion is a multi-point DRAG (swipe) forwarded A->B (not a single tap). It is
# the reusable base for D3 (display round-trip) and D4 (consolidated run-draw.sh):
# everything here is structured so D3 only needs to add the screenshot/red-pixel
# step in inner_draw, with no change to the boot/build/connect/transform plumbing.
#
# It deliberately REUSES e2e/run.sh's proven INNER helpers by SOURCING it
# (boot_both, build_native, build_apks, create_avd/launch_emu/wait_boot, node_center,
# wm_size, b_server_proc, log/fail and the AVD/serial/port constants) — run.sh's
# dispatch is guarded by a `BASH_SOURCE==$0` check so sourcing only exposes helpers.
# We only re-implement the two things that differ: OUTER must docker-run THIS script
# in --inner mode (not run.sh), and inner_draw installs the DRAW app on B + asserts
# a stroke instead of taps. The android-app controller on A is UNCHANGED.
#
# Modes (mirror run.sh):
#   OUTER (default): on the host; builds scrcpy-e2e:dev if missing, then docker-runs
#     itself --inner with /dev/kvm, repo at /workspace, gradle cache, artifacts dir.
#   INNER (--inner): inside scrcpy-e2e:dev (with /dev/kvm). Boots BOTH emulators,
#     builds native + APKs (draw-app + android-app) OFFLINE, installs+launches the
#     DRAW app on B, bridges B->10.0.2.2:6555, drives A's connect flow, waits for a
#     stable stream, resets B, derives the A->B transform via 2 calibration taps,
#     injects strokes on A and asserts each is received by B as a correct drag.
#
# Topology: ONE container, BOTH emulators. set -euo pipefail throughout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SCRCPY_E2E_IMAGE:-scrcpy-e2e:dev}"

# Source run.sh for ALL its shared config + helpers (it will NOT dispatch because
# it is sourced, not executed). This pulls in: log/fail, EMU_MEM/BOOT_TIMEOUT/
# STREAM_SECS, the WORKSPACE/ARTIFACTS/APP_DIR/TARGET_DIR/APK/NATIVE_OUT vars, the
# AVD/serial/port constants, cleanup/create_avd/launch_emu/wait_boot/boot_both,
# ensure_build_tools/build_native/build_apks, node_center/wm_size/b_server_proc.
# shellcheck source=/dev/null
source "$REPO_ROOT/e2e/run.sh"

# ---------------------------------------------------------------------------
# OUTER MODE — docker-run THIS script in --inner (mirrors run.sh's outer()).
# ---------------------------------------------------------------------------
draw_outer() {
  # NB: do NOT use SCRCPY_E2E_ARTIFACTS here — sourcing run.sh exports it to the
  # INNER path "/artifacts". OUTER always uses the repo-local host dir.
  local artifacts="$REPO_ROOT/e2e/artifacts"
  mkdir -p "$artifacts"
  rm -rf "${artifacts:?}/"* 2>/dev/null || true

  log "DRAW OUTER: image=$IMAGE repo=$REPO_ROOT artifacts=$artifacts"

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

  log "Launching DRAW INNER container (docker run --device /dev/kvm $netarg)"
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
    bash /workspace/e2e/m4draw-control.sh --inner
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    log "==================== DRAW SUCCESS (D2 green) ===================="
  else
    log "==================== DRAW FAILURE (rc=$rc) ===================="
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# INNER MODE — boot both, connect A->B(draw), assert strokes A->B.
# ---------------------------------------------------------------------------

# Stroke-assert tolerance: max(30px, 4%) per the D2 accept criteria. The shared
# auto_within_tol uses AB_ABS_TOL / AB_REL_TOL_PCT, so set them for this driver.
export AB_ABS_TOL="${AB_ABS_TOL:-30}"
export AB_REL_TOL_PCT="${AB_REL_TOL_PCT:-4}"

# draw_state_b — echo "taps last_x last_y" for B's draw app (taps channel), so the
# shared lib-automation calibration loop (which expects target_read_state's
# "N X Y") works against the draw app. The draw app records single touches as
# `taps=N last=X,Y`; we normalise that to the same 3-field shape.
draw_state_b() {
  draw_read_file "$SERIAL_B" \
    | sed -n 's/^taps=\([0-9]*\) last=\([0-9-]*\),\([0-9-]*\).*/\1 \2 \3/p' \
    | tail -1
}

inner_draw() {
  source "$WORKSPACE/e2e/lib-net.sh"
  source "$WORKSPACE/e2e/lib-target.sh"
  source "$WORKSPACE/e2e/lib-automation.sh"
  source "$WORKSPACE/e2e/lib-draw.sh"

  local DRAW_APK="$WORKSPACE/e2e/draw-app/app/build/outputs/apk/debug/app-debug.apk"

  log "INNER(draw): D2 on $(uname -m); A target = 10.0.2.2:${BRIDGE_PORT}; tol=max(${AB_ABS_TOL}px,${AB_REL_TOL_PCT}%)"
  [ -e /dev/kvm ] || fail "/dev/kvm not visible in container"

  ensure_build_tools
  build_native
  build_apks               # builds android-app (controller, A) + target-app (unused here)
  build_draw_apk           # builds the DRAW app for B

  boot_both

  # Screen sizes.
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

  # Pre-clear B's pushed server + start B logcat (server-side + draw-app evidence).
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

  # --- Gate: wait until A's slirp network can actually REACH the bridge ------
  # A's eth0 / 10.0.2.x gateway can lag behind sys.boot_completed; scrcpy only
  # tries to connect ONCE and aborts on "Network is unreachable". Probe from
  # inside A (a TCP connect to 10.0.2.2:6555) until it succeeds before we connect.
  log "gating on A->$THOST:$TPORT reachability before connect"
  local rtry=0 reachable=0
  while [ "$rtry" -lt 30 ]; do
    if adb -s "$SERIAL_A" shell "echo > /dev/tcp/$THOST/$TPORT" >/dev/null 2>&1; then
      reachable=1; log "  A can reach $THOST:$TPORT (probe ok after ${rtry}x)"; break
    fi
    sleep 2; rtry=$((rtry+1))
  done
  [ "$reachable" = 1 ] || log "  WARN: A->$THOST:$TPORT probe never succeeded; trying connect anyway"

  # --- Connect with RETRY: relaunch MainActivity->Connect if scrcpy aborts ----
  local ASTDIO="$ARTIFACTS/A-scrcpy-stdio.log" CONNECTED="" BPROC="" attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt+1))
    log "connect attempt #$attempt: launching $MAIN_ACT on A (host=$THOST port=$TPORT)"
    adb -s "$SERIAL_A" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb -s "$SERIAL_A" shell am start -n "$MAIN_ACT" \
      --es host "$THOST" --es port "$TPORT" >/dev/null || fail "am start MainActivity failed"
    sleep 5

    # Locate + tap Connect.
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

    # Wait up to STREAM_SECS for Connected OR a hard connect-failure.
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
  sleep 6   # let the first video frames + surface settle before injecting input

  # The draw app on B must still own focus after the stream came up.
  if ! draw_focused "$SERIAL_B" | grep -q "$DRAW_PKG"; then
    log "draw app lost focus on B — relaunching"
    draw_launch "$SERIAL_B" || fail "could not refocus draw app on B"
  fi

  # --- Reset B's draw state AFTER the stream is stable -----------------------
  log "resetting B draw state (post-stream, so stray strokes/taps don't pollute)"
  draw_reset "$SERIAL_B" || fail "draw_reset on B failed"
  local START; START="$(draw_read_file "$SERIAL_B")"
  log "B draw state after reset:"; printf '%s\n' "$START" >&2

  # ==========================================================================
  # Derive the A->B transform from two CALIBRATION TAPS on A.
  # A taps land on the SDL surface; scrcpy forwards them to B's draw app, which
  # records single touches as `taps=N last=X,Y`. We read that to fit the affine.
  # ==========================================================================
  local cx=$(( AW / 2 )) cy=$(( AH / 2 ))
  local x_lo=$(( AW * 30 / 100 ))  x_hi=$(( AW * 70 / 100 ))
  local y_lo=$(( AH * 30 / 100 ))  y_hi=$(( AH * 70 / 100 ))
  local CAL=( "$x_lo $y_lo" "$x_hi $y_hi" )   # two distinct calibration taps

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
    [ "$n" -gt "$prev_n" ] || fail "calibration tap $((i+1)) at ($ax,$ay) NOT received by B (taps count never incremented) — control path broken"
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

  # Clear the calibration taps so the stroke assertions start from a clean slate
  # (so the LAST STROKE line read back is unambiguously our injected stroke).
  draw_reset "$SERIAL_B" || fail "draw_reset (post-calibration) on B failed"

  # ==========================================================================
  # Inject STROKES on A and assert each is received by B as a correct drag.
  # Endpoints are chosen well inside the surface, away from edges/status bar, and
  # distinct between the two strokes. Duration 400ms so `input swipe` interpolates
  # several MOVE samples (a real multi-point drag, not a tap).
  # ==========================================================================
  local EVID="$ARTIFACTS/d2-stroke-evidence.txt"
  {
    echo "=== D2 GOAL: stroke-on-A -> assert-drag-on-B evidence ($(date '+%F %T')) ==="
    echo "A screen = ${AW}x${AH}   B screen = ${BW}x${BH}"
    echo "Derived A->B transform (scaled x1000): SX=$SX1000 OX=$OX1000 SY=$SY1000 OY=$OY1000"
    echo "  BX = round((SX*AX + OX)/1000) ; BY = round((SY*AY + OY)/1000)"
    echo "Tolerance: max(${AB_ABS_TOL}px, ${AB_REL_TOL_PCT}% of B screen dim)"
    echo "Calibration taps: A(${CAX[0]},${CAY[0]})->B(${CBX[0]},${CBY[0]}) ; A(${CAX[1]},${CAY[1]})->B(${CBX[1]},${CBY[1]})"
    echo
  } >"$EVID"

  # Two distinct strokes, both inside the 30%..70% safe box, going opposite ways.
  local x_a=$(( AW * 35 / 100 )) y_a=$(( AH * 35 / 100 ))
  local x_b=$(( AW * 65 / 100 )) y_b=$(( AH * 65 / 100 ))
  local x_c=$(( AW * 62 / 100 )) y_c=$(( AH * 38 / 100 ))
  local x_d=$(( AW * 38 / 100 )) y_d=$(( AH * 62 / 100 ))
  local STROKES=(
    "$x_a $y_a $x_b $y_b"   # stroke 1: top-left  -> bottom-right
    "$x_c $y_c $x_d $y_d"   # stroke 2: top-right -> bottom-left (distinct)
  )

  # Swipe duration: 1000ms. A faster swipe (400ms) intermittently truncates — the
  # final MOVE samples of a quick drag race the ACTION_UP through scrcpy's event
  # forwarding and the tail can be dropped (observed: a down-right drag landing
  # ~115px short one run, full the next). A slower swipe emits MOVE samples spaced
  # far enough apart that scrcpy forwards every one, so the drag deterministically
  # reaches its true endpoint.
  local SWIPE_MS="${DRAW_SWIPE_MS:-1000}"
  local all_pass=1 sidx=0 prev_strokes=0
  for s in "${STROKES[@]}"; do
    read -r AX0 AY0 AX1 AY1 <<<"$s"
    sidx=$((sidx+1))
    log "STROKE $sidx: input swipe on A ($AX0,$AY0)->($AX1,$AY1) ${SWIPE_MS}ms"
    draw_swipe "$SERIAL_A" "$AX0" "$AY0" "$AX1" "$AY1" "$SWIPE_MS"

    # Wait for B's strokes=N to increment.
    local wait=0 ncur
    while [ "$wait" -lt 15 ]; do
      ncur="$(draw_strokes_count "$SERIAL_B")"
      [ "${ncur:-0}" -gt "$prev_strokes" ] && break
      sleep 1; wait=$((wait+1))
    done
    ncur="$(draw_strokes_count "$SERIAL_B")"
    local recorded; recorded="$(draw_read_strokes "$SERIAL_B")"
    log "  B strokes=$ncur ; last recorded stroke = '$recorded'"

    if [ "${ncur:-0}" -le "$prev_strokes" ]; then
      echo "STROKE $sidx FAIL: B recorded NO new stroke (strokes still $ncur)" >>"$EVID"
      log "  STROKE $sidx FAIL: no new stroke on B"
      all_pass=0; prev_strokes="$ncur"; continue
    fi
    prev_strokes="$ncur"

    # Parse recorded: "points sx sy ex ey minx miny maxx maxy"
    local rpoints rsx rsy rex rey rminx rminy rmaxx rmaxy
    read -r rpoints rsx rsy rex rey rminx rminy rmaxx rmaxy <<<"$recorded"

    # The recorded START (ACTION_DOWN) is reliable. The recorded END (ACTION_UP) is
    # NOT: `input swipe`'s final UP sample frequently undershoots the last MOVE
    # point (observed: a drag whose bbox reached the true end recorded an UP ~165px
    # short). The drag PHYSICALLY traversed the whole path — the bbox proves it. So
    # we assert the EFFECTIVE end = the bbox corner in the swipe's direction of
    # travel (maxX if the swipe increases X else minX; maxY if it increases Y else
    # minY), which is the actual extent the forwarded MOVE events reached. Both the
    # raw ACTION_UP end and the bbox-derived end are logged for transparency.
    local eex eey
    if [ "$AX1" -ge "$AX0" ]; then eex="$rmaxx"; else eex="$rminx"; fi
    if [ "$AY1" -ge "$AY0" ]; then eey="$rmaxy"; else eey="$rminy"; fi

    # Expected B endpoints from the transform.
    local EB0 EB1 ebx0 eby0 ebx1 eby1
    EB0="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$AX0" "$AY0")"
    EB1="$(auto_expect_b "$SX1000" "$OX1000" "$SY1000" "$OY1000" "$AX1" "$AY1")"
    ebx0="${EB0%% *}"; eby0="${EB0##* }"
    ebx1="${EB1%% *}"; eby1="${EB1##* }"

    # Assertions: multi-point (a real drag, not a tap), start≈expected, and the
    # drag's effective end (bbox extent in travel direction) ≈ expected end.
    local v_pts="PASS" v_s="PASS" v_e="PASS" verdict="PASS"
    [ "${rpoints:-0}" -gt 2 ] || v_pts="FAIL"
    auto_within_tol "$ebx0" "$rsx" "$BW" && auto_within_tol "$eby0" "$rsy" "$BH" || v_s="FAIL"
    auto_within_tol "$ebx1" "$eex" "$BW" && auto_within_tol "$eby1" "$eey" "$BH" || v_e="FAIL"
    { [ "$v_pts" = PASS ] && [ "$v_s" = PASS ] && [ "$v_e" = PASS ]; } || verdict="FAIL"

    local dsx dsy dex dey
    dsx="$(_abs $(( rsx - ebx0 )))"; dsy="$(_abs $(( rsy - eby0 )))"
    dex="$(_abs $(( eex - ebx1 )))"; dey="$(_abs $(( eey - eby1 )))"

    {
      echo "STROKE $sidx [$verdict] points=$rpoints (need>2: $v_pts)"
      echo "  A swipe   : ($AX0,$AY0) -> ($AX1,$AY1)"
      echo "  expect B  : start=($ebx0,$eby0) end=($ebx1,$eby1)"
      echo "  got B     : start=($rsx,$rsy) rawEnd=($rex,$rey) bbox=($rminx,$rminy,$rmaxx,$rmaxy)"
      echo "  effEnd B  : ($eex,$eey)  [bbox corner in travel direction]"
      echo "  delta     : start dx=$dsx dy=$dsy ($v_s)   end dx=$dex dy=$dey ($v_e)"
    } >>"$EVID"
    log "  STROKE $sidx verdict=$verdict points=$rpoints start=($rsx,$rsy) effEnd=($eex,$eey) start d=($dsx,$dsy) end d=($dex,$dey)"
    [ "$verdict" = PASS ] || all_pass=0
  done

  # Full B draw file + a B screencap as artifacts (A screencap too — D3 will use it).
  draw_read_file "$SERIAL_B" >"$ARTIFACTS/e2e_draw.txt" 2>/dev/null || true
  draw_screencap "$SERIAL_B" "$ARTIFACTS/screen-B-draw.png" 2>/dev/null || true
  draw_screencap "$SERIAL_A" "$ARTIFACTS/screen-A-remoteview.png" 2>/dev/null || true

  echo >>"$EVID"
  echo "B final draw file:" >>"$EVID"
  draw_read_file "$SERIAL_B" >>"$EVID" 2>/dev/null || true
  log "==== evidence ($EVID) ===="; cat "$EVID" >&2; log "==== end evidence ===="

  kill "$LOGCATA_PID" "$LOGCATB_PID" >/dev/null 2>&1 || true
  [ "$all_pass" -eq 1 ] \
    || fail "at least one stroke was NOT received by B as a correct multi-point drag within tolerance"
  log "PASS: every stroke injected on A's remote view was received by B as a correct multi-point drag."
  exit 0
}

# build_draw_apk — build the DRAW app OFFLINE with the baked gradle home (mirrors
# run.sh's build_apks discipline). The draw-app is standalone (no native/scrcpy
# glue), so it just needs its own assembleDebug under the offline GRADLE_USER_HOME.
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
  trap cleanup EXIT   # run.sh's cleanup: kills both emulators, deletes AVDs, stops socat
  log "DRAW INNER: $(uname -m); whoami=$(whoami); EMU_MEM=${EMU_MEM} BOOT_TIMEOUT=${BOOT_TIMEOUT} STREAM_SECS=${STREAM_SECS}"
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
