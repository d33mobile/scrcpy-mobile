# Plan — Drawing/stroke e2e: prove strokes work AND render back to the controller

Builds on the completed Android-controls-Android e2e (see `00-master-plan.md`,
`STATE.md` — that goal is DONE & audited). This adds a richer proof:

**Goal:** a one-script, hermetic, two-emulator e2e that (1) sets up a paint/drawing
app on the target device B, (2) injects **strokes** (multi-point gestures) on the
controller A's remote view and proves B receives them with correct geometry, and
(3) proves the **shapes drawn on B are actually displayed back on A** — i.e. the
red strokes appear in A's decoded remote-view screenshot (closing the video loop).

This exercises BOTH directions that the tap test only partially did: gesture/stroke
input fidelity (A→B), and the video stream carrying the drawn result (B→A render).

## Why this is a stronger test
The existing M3 test taps a point and reads B's recorded coordinate — it proves a
single touch arrives, but reads B's STATE, not B's PIXELS, and never checks that A
*displays* anything. The drawing test:
- uses **strokes** (DOWN→MOVE…→UP polylines), not single taps;
- asserts the **stroke geometry** on B (start/end/path within tolerance of the
  expected A→B mapping); and
- asserts the drawn shape is **visible in A's screenshot** (red-pixel delta +
  location), proving B rendered it and A decoded+displayed it.

## Environment / rules (reuse the proven harness)
Host `d-claude` (ssh), Docker `scrcpy-e2e:dev` + `--device /dev/kvm`, scratch
`/srv/work`. Reuse `e2e/lib-net.sh` (socat bridge → `10.0.2.2:6555`),
`lib-automation.sh` (A→B affine transform via 2 calibration taps), the connect flow
from `run.sh`. RULES: builds BLOCKING in-context (never background-and-return);
one e2e at a time, `mem=1536`; kill only stray `scrcpy-e2e` containers, never touch
`mf-e2e-*`/`redroid`/`ws-scrcpy`; self-clean; hermetic (bake new deps into the
image); push to `fork` branch `android-controls-android`, no `-a/-A/--no-verify`,
commit trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
Honesty rules: never fake green; record verbatim blockers.

## Design

### Drawing target app on B — `e2e/draw-app/` (`net.scrcpy.e2edraw`)
Fullscreen `DrawActivity`, **white** background, a custom View:
- Touch handling: ACTION_DOWN starts a stroke; ACTION_MOVE appends points and draws
  a thick **bright red `#FF0000`** line segment (strokeWidth ~12) onto a persistent
  Bitmap; ACTION_UP finalizes the stroke.
- Records per stroke: point count, start (x0,y0), end (xN,yN), bbox, all in DEVICE
  pixels. Channels (like the tap target app): internal file `filesDir/e2e_draw.txt`,
  logcat `E2E_DRAW: stroke #n points=K start=.. end=.. bbox=..`, and a summary
  (`strokes=N`).
- ALSO record single touches (DOWN+UP, 1-point stroke) as `taps=N last=X,Y` so the
  existing `lib-automation.sh` calibration (2 taps → A→B transform) works unchanged.
- The red strokes on white are deliberately high-contrast so they are detectable in
  a screenshot of A's decoded remote view.

### Stroke injection on A
`adb -s emulator-5556 shell input swipe ax0 ay0 ax1 ay1 <ms>` draws a straight
stroke on A's remote-view surface; scrcpy forwards DOWN/MOVE…/UP to B. For a richer
"shape", chain segments (e.g. an L or triangle = 2–3 swipes, or `input motionevent`
sequences). Compute expected B endpoints via the A→B transform.

### Assertions
1. **Control (A→B stroke geometry):** read B's recorded stroke; assert start≈
   expected_start and end≈expected_end within tolerance (e.g. max(30px,4%)), the
   stroke has multiple points (a real drag, not a tap), and is roughly straight
   (intermediate points near the start→end line). For multi-segment shapes, assert
   each segment.
2. **Display round-trip (B→A render):** `adb -s emulator-5556 exec-out screencap -p`
   BEFORE and AFTER the stroke. Detect red pixels (a small `python3`+Pillow analyzer
   baked into the image) in A's remote-view region: assert red-pixel count jumps from
   ~0 to a clear threshold AND the red blob's centroid/bbox is near the swipe path on
   A (within the surface region) — proving A is displaying the shape B drew.

### Hermetic additions
Bake into `e2e/Dockerfile`: the `draw-app` Gradle deps into the offline
`GRADLE_USER_HOME` (same priming pattern as `android-app`/`target-app`), and
`python3` + `python3-pil` (Pillow) for the screenshot color analysis. Keep image
build networked/one-time; the run stays `--network none`.

## Milestones (each an independently verifiable loop target)

### D1 — Drawing app on B + standalone stroke capture
Build `e2e/draw-app/`; install on a single emulator; inject `input swipe` DIRECTLY
on it; assert (a) the draw app recorded a multi-point stroke with start/end matching
the swipe, and (b) a screenshot of THAT emulator shows red pixels along the path.
Bake draw-app deps into the image. **Accept:** standalone swipe → recorded stroke +
visible red pixels, verified on d-claude.

### D2 — Stroke from A → control assertion on B
Two emulators, B running the draw app, A connected (A shows B's white canvas).
Derive the A→B transform (2 calibration taps via lib-automation). Inject a swipe on
A; assert B's draw app recorded a stroke whose start/end map within tolerance and is
a real multi-point straight drag. **Accept:** a stroke drawn on A is received by B
with correct geometry.

### D3 — Display round-trip: the shape is visible on A
In the same run, screenshot A before/after the stroke; with the baked
python3+Pillow analyzer assert the red stroke appears in A's remote-view region at
the expected location (red-pixel delta + centroid). Add a multi-segment shape
(e.g. an L/triangle) and assert both its geometry on B and its visibility on A.
**Accept:** the drawn shape is provably displayed on A (not just recorded on B).

### D4 — One script, reliable, audited
Consolidate into `e2e/run-draw.sh` (reusing run.sh infra + lib-net/lib-automation +
new `lib-draw.sh`), hermetic, inner `--network none` by default, artifacts (A+B
screenshots before/after, the analyzer output, stroke evidence) to the mounted dir,
correct exit codes. Reliably green ≥3 runs incl. one cold. **Final audit** re-runs it
from absolute scratch under `--network none`; on PASS declare the drawing-e2e goal
realized and STOP the loop.

## Working agreement
Same as the main loop: 1-min fg subagent loop reading `ai/plans/STATE-drawing.md`;
one task/iteration, blocking builds, commit+push each; per-milestone foreground
audit; final audit stops the loop. The existing tap e2e (`e2e/run.sh`) must remain
green — add alongside, don't break it.
