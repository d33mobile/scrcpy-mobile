# e2e draw app — deterministic STROKE/drawing target for the drawing e2e (D1)

A minimal, standalone Gradle/Android project that installs on an emulator and
turns a touch **stroke** (DOWN -> MOVE* -> UP) into an unambiguous, queryable
state change AND an accumulating, high-contrast red drawing on a white canvas.
It is the assertion anchor for the drawing e2e: a swipe injected on the
controller A is forwarded by scrcpy to B, this app records the stroke geometry
(so we can assert A->B input fidelity) and renders it as bright-red pixels on
white (so we can assert the shape is displayed back on A by reading A's
screenshot).

- **Package / applicationId:** `net.scrcpy.e2edraw`
- **Activity:** `net.scrcpy.e2edraw.DrawActivity` (exported, LAUNCHER, full-screen
  `Theme.Light.NoTitleBar.Fullscreen` + explicit WHITE view background,
  `screenOrientation=sensor`, `FLAG_KEEP_SCREEN_ON`, system bars hidden).
- **Toolchain:** mirrors `target-app/` / `android-app/` — AGP 8.7.3 / Gradle 8.9 /
  Kotlin 2.0.21, `compileSdk=36`, `minSdk=26`, `buildToolsVersion=37.0.0`. No
  AndroidX/appcompat (deliberately minimal).

## Behaviour

A full-screen, deliberately **non-clickable** custom `DrawView` handles
`onTouchEvent` directly (a clickable view would consume `ACTION_DOWN` and we'd
never see MOVE/UP — the exact bug the tap target app hit; we keep the view
non-clickable and return `true` for the handled gesture). Per stroke:

- `ACTION_DOWN` starts a new stroke (point count = 1, records start).
- `ACTION_MOVE` appends a point and draws a thick bright-red (`#FF0000`,
  `strokeWidth=12`, ANTI_ALIAS, ROUND cap/join) segment from the previous point
  onto a **persistent Bitmap** (the drawing accumulates), then `invalidate()`s.
- `ACTION_UP` finalizes the stroke; a pure DOWN+UP stamps a single red dot.

Coordinates are recorded in **device pixels** via `event.getX()/getY()` rounded
to Int (the view is full-screen, so they equal the `adb input swipe/tap` coords
within rounding). Per stroke it records: point count, start `(x0,y0)`, end
`(xN,yN)`, bbox `(minx,miny,maxx,maxy)`.

### Tap vs stroke threshold

A stroke is classified as a **tap** when it has at most one move-distinct point
**and** its bbox spans `<= 16 px` (`TAP_SLOP_PX`) in **both** axes — i.e. a
DOWN+UP with negligible movement. 16 px is a few px above a typical
`ViewConfiguration` touch slop, absorbing `input tap` jitter while classifying
any real `input swipe` (tens-to-hundreds of px) as a stroke. Taps are recorded
ADDITIONALLY as `taps=N last=X,Y` so the existing `lib-automation.sh` 2-tap
calibration (A->B transform) keeps working against this app unchanged.

## State channels

`$S` = the device adb serial.

### 1. File (most robust for scripted parsing)

`filesDir/e2e_draw.txt`, **rewritten on every stroke** so it always reflects all
strokes so far. One `STROKE` line per stroke, then a `taps`/`last` line, then a
`strokes=N` summary:

```
STROKE 1 points=42 start=120,300 end=620,800 bbox=120,300,620,800
taps=0 last=-1,-1
strokes=1
```

```sh
adb -s "$S" shell run-as net.scrcpy.e2edraw cat files/e2e_draw.txt
```

### 2. Logcat

One line per stroke (and one per tap), tag `E2E_DRAW`:

```sh
adb -s "$S" logcat -d -s E2E_DRAW | grep -oE 'stroke #[0-9]+ points=[0-9]+ .*'
# stroke #1 points=42 start=120,300 end=620,800 bbox=120,300,620,800
adb -s "$S" logcat -d -s E2E_DRAW | grep -oE 'tap #[0-9]+ at [0-9-]+,[0-9-]+'
# tap #1 at 540,1000
```

### 3. On-screen text (uiautomator)

A small, top-left, semi-transparent TextView whose **text AND content-desc** =
`strokes=N` (placed/sized so it does not obscure the canvas the red-pixel
detector samples):

```sh
adb -s "$S" shell uiautomator dump /sdcard/e2e_ui.xml >/dev/null
adb -s "$S" shell cat /sdcard/e2e_ui.xml | grep -o 'strokes=[0-9]*' | head -1
```

## Build

```sh
cd e2e/draw-app && ./gradlew --no-daemon assembleDebug
# -> app/build/outputs/apk/debug/app-debug.apk
```

The FIRST build resolves the AGP/Kotlin/draw-app Gradle deps from the network
(persistent `scrcpy-gradle-cache` volume). Baking these into the offline
`GRADLE_USER_HOME` for hermetic `--offline` builds is a later D1 task.
