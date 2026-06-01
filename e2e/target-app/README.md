# e2e target app — deterministic input target for the two-emulator e2e (M3)

A minimal, standalone Gradle/Android project that installs on emulator **B**
(the target) and turns a tap at a known coordinate into an unambiguous,
queryable state change. It is the assertion anchor for the GUI-automation e2e:
emulator A renders B's screen via scrcpy, UI automation taps A's surface, and
the test reads this app's state on B to prove the tap reached B at the expected
coordinate.

- **Package / applicationId:** `net.scrcpy.e2etarget`
- **Activity:** `net.scrcpy.e2etarget.TargetActivity` (exported, LAUNCHER,
  full-screen `Theme.Black.NoTitleBar.Fullscreen`, `screenOrientation=sensor`,
  `FLAG_KEEP_SCREEN_ON`, system bars hidden).
- **Toolchain:** mirrors `android-app/` — AGP 8.7.3 / Gradle 8.9 / Kotlin 2.0.21,
  `compileSdk=36`, `minSdk=26`. No AndroidX/appcompat (deliberately minimal so
  uiautomator dumps have nothing extraneous).

## Behaviour

A single full-screen `TextView` is the content view. The Activity overrides
`dispatchTouchEvent` (NOT `onTouchEvent`) so it records EVERY touch before any
view can consume it. On each `ACTION_DOWN` it:

- increments `taps` (launch / `onCreate` resets to 0),
- records `lastX,lastY` = `Math.round(rawX/rawY)` in **device pixels** (the view
  is full-screen, so the raw touch coord equals the `input tap X Y` coord, within
  rounding — this lets the test assert WHERE the tap landed, not just that one
  happened),

and exposes the new state through THREE independent channels.

## State channels & exact assertion queries (used by M3 task 4)

`$S` = B's adb serial (e.g. `emulator-5554`).

### 1. On-screen text (uiautomator)

The TextView's **text AND content-desc** = `taps=N last=X,Y`.

```sh
adb -s "$S" shell uiautomator dump /sdcard/e2e_ui.xml >/dev/null
adb -s "$S" shell cat /sdcard/e2e_ui.xml \
  | grep -o 'taps=[0-9]* last=[0-9-]*,[0-9-]*' | head -1
# -> "taps=2 last=540,1000"   parse: N=2 X=540 Y=1000
```

### 2. Logcat

One line per tap, tag `E2E_TARGET`:

```sh
adb -s "$S" logcat -d -s E2E_TARGET | grep -oE 'tap #[0-9]+ at [0-9-]+,[0-9-]+' | tail -1
# -> "tap #2 at 540,1000"      parse: N=2 X=540 Y=1000
```

### 3. File (most robust for scripted parsing)

The latest `N X Y` line is written to the app's **internal** files dir
(`filesDir/e2e_state.txt`). On API 30+ the adb shell user cannot read an app's
external files dir, so the internal dir + `run-as` (debuggable build) is the
reliable channel:

```sh
adb -s "$S" shell run-as net.scrcpy.e2etarget cat files/e2e_state.txt
# -> "2 540 1000"              already space-separated: N X Y
```

## Helper library

`e2e/lib-target.sh` wraps all of the above:

- `target_install <serial> <apk>` — `adb install -r -g`
- `target_launch <serial>` — `am start` + wait for `mCurrentFocus` == target (also resets taps to 0)
- `target_reset <serial>` — force-stop + relaunch (== reset)
- `target_read_state <serial> [file|ui|logcat]` — echoes normalised `"N X Y"`
- `target_tap <serial> <x> <y>` — `input tap` (self-test helper; task 4 taps A's surface)
- `target_focused <serial>` — echoes the `mCurrentFocus` line

## Build

```sh
cd e2e/target-app && ./gradlew --no-daemon assembleDebug
# -> app/build/outputs/apk/debug/app-debug.apk
```

## Self-test

`e2e/m3-target-selftest.sh` (run INSIDE `scrcpy-e2e:dev` with `--device /dev/kvm`)
builds the APK, boots one emulator, installs + launches the target, taps two
known coordinates, and asserts all three channels agree and the recorded coords
match the input coords. Verified PASS 2026-06-01 (taps at (200,400) and
(540,1000) recorded exactly on all three channels).
