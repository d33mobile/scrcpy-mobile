# LIVE STATE — read this every loop iteration

This file is the single source of truth for the 1-min foreground loop. It is
editable mid-loop without restarting. Master plan: `ai/plans/00-master-plan.md`.

## How each loop iteration works
1. Read this file + `ai/plans/00-master-plan.md`.
2. Pick the **first unchecked task** under "Current milestone".
3. Do it in a focused way; run/verify; commit (no `-a`, no `--no-verify`).
4. Update the checkbox + "Progress log" below. Keep changes small.
5. If the whole milestone's accept-criteria are met, run the milestone's audit:
   spawn a **foreground** audit subagent. If it passes, advance "Current
   milestone" to the next one and copy in its tasks. If it fails, paste its
   findings as new tasks here.

Repo facts: branch `android-controls-android`; push to `fork` remote. e2e target
host = `d-claude` (ssh). Build/run scratch on d-claude under `/srv/work`.

---

## Current milestone: **M2 — Android client app wraps the native lib**

(M0 — Scaffolding & red-but-running pipeline — **PASSED audit 2026-06-01**.
M1 — Native stack cross-compiled for Android x86_64 — **PASSED audit 2026-06-01**;
all 7 tasks done; see progress log. `libscrcpy.so` + deps build green and the NDK
smoke exe runs `scrcpy_main --help` cleanly on the bionic linker.)

Accept: the android-app APK bundles `libscrcpy.so` + its runtime deps (`libSDL2.so`,
`libc++_shared.so`, etc.) and the SDL Java glue; installed on an x86_64 emulator A it
calls `scrcpy_main` against a target and the app process loads + runs the native
client (connection attempt visible) without crashing.

### Tasks
- [x] Integrate `libscrcpy.so` + deps (`libSDL2.so`, `libc++_shared.so`, the
      FFmpeg/openssl/adb already linked-in) + SDL Java glue
      (`porting/vendor/sdl-android-java` `org.libsdl.app.*`) into the android-app
      Gradle build (`jniLibs/x86_64` + `sourceSets`); app builds an APK that packages
      them.
- [x] Make `MainActivity` (or an `SDLActivity` subclass) load the SDL libs +
      `libscrcpy.so` and expose a JNI/native entrypoint that calls
      `scrcpy_main(argc,argv)` on a worker thread; implement the
      `ScrcpyUpdateStatus` callback to surface status to the UI/log.
- [x] Minimal UI: a screen to enter target `host:port` + Connect, then hand off to
      the SDL surface (remote view). Wire touches on the surface into scrcpy control
      (handled by the native SDL event loop).
- [x] Build the APK in `scrcpy-e2e:dev`; install it on an x86_64 emulator (use the
      e2e harness emulator A) and confirm via logcat that the app loads
      `libscrcpy.so` and enters `scrcpy_main` (a connection attempt to a `host:port`
      is logged) WITHOUT crashing. Capture logcat evidence.

### Progress log
- 2026-06-01: **M2 task 4 done — APK launched on a headless x86_64 emulator;
  libscrcpy.so loads, scrcpy_main is entered, the in-process adb host runs through
  its connection path, NO crash. M2 COMPLETE. Two REAL native bugs found + fixed
  along the way.**
  **Harness:** new single-emulator helper **`e2e/launch-app.sh`** (the M3-ready
  counterpart to `e2e/run.sh`'s two-emulator harness): inside `scrcpy-e2e:dev`
  with `--device /dev/kvm` it stages natives + `assembleDebug`s the APK, boots ONE
  pinned-v33.1.24 emulator (same AVD/flags/boot-wait as run.sh, mem=1536), installs
  the APK, drives the REAL user flow (`am start` the exported MainActivity → set
  host/port fields → `uiautomator dump`-located tap on Connect → ScrcpyActivity),
  captures 30s of filtered+full logcat to /artifacts, and PASS/FAILs on
  UnsatisfiedLinkError/dlopen/SIGSEGV/SIGABRT/FATAL/ANR vs scrcpy-entry evidence.
  (ScrcpyActivity is correctly `exported=false`, so a direct `am start` of it gives
  `SecurityException: not exported from uid` — hence the via-MainActivity flow.)
  **BUG 1 (FATAL, fixed): adb auth aborts — `Cannot mkdir '/data/.android'`.**
  First launch: libs loaded + scrcpy_main entered, then SIGABRT on the
  `scrcpy-server` thread. Verbatim:
  ```
  F libc  : Fatal signal 6 (SIGABRT) ... in tid N (scrcpy-server), pid M (SDLActivity)
  F DEBUG : Abort message: 'Cannot mkdir '/data/.android': Permission denied'
  F DEBUG : #04 ... adb_get_android_dir_path()+515
  F DEBUG : #05 ... get_user_key_path()+34
  F DEBUG : #06 ... adb_auth_init()+63
  F DEBUG : #07 ... adb_server_main(...)
  F DEBUG : #08 ... launch_server_thread(...)
  ```
  Root cause: scrcpy's in-process adb host (`launch_server`→`adb_server_main`→
  `adb_auth_init`) derives its key store from `adb_get_homedir_path()` =
  `getenv("HOME")` ?: passwd home; an Android app uid's passwd home is the
  unwritable `/data`, so `mkdir("$HOME/.android")` FATAL-aborts. **Fix:** point
  `$HOME` at the app's writable `cacheDir` BEFORE the native thread runs. Added
  `Java_net_scrcpy_android_ScrcpyActivity_nativeSetHome(String)` to
  `porting/src/android-jni-bridge.c` (`setenv("HOME", path, 1)` after verifying
  it's a writable dir) + a defensive `ensure_writable_home()` (falls back to
  `$TMPDIR`) called at the top of both `scrcpy_android_main` and `runScrcpy`;
  `ScrcpyActivity.onCreate` calls `nativeSetHome(cacheDir.absolutePath)` right after
  `super.onCreate()` (SDLActivity.loadLibraries has run, so the symbol is bound;
  the SDL thread that runs scrcpy_main starts later in handleResume). (The vendored
  AOSP `adb_utils.cpp` is NOT patched — fixed purely via the env from our side.)
  **BUG 2 (FATAL, fixed): OpenSSL↔BoringSSL allocator collision — Scudo abort.**
  After the HOME fix, adb_get_android_dir_path() succeeded and the flow advanced one
  step further, into `load_key()`/`hash_key()`, then aborted. Verbatim:
  ```
  F DEBUG : Abort message: 'Scudo ERROR: misaligned pointer when deallocating address 0x...'
  F DEBUG : #04 ... scudo::reportMisalignedPointer(...)
  F DEBUG : #05 ... scudo::Allocator<...>::deallocate(...)
  F DEBUG : #06 ... load_key(std::string const&)+214        // = hash_key()'s OPENSSL_free(pubkey)
  F DEBUG : #07 ... adb_auth_init()+295
  F DEBUG : #08 ... adb_server_main(...)
  ```
  Root cause: the scrcpy-android link pulled in BOTH the standalone OpenSSL
  (`libssl.a`/`libcrypto.a`, built in M1 t4) AND adb's bundled **BoringSSL** (inside
  `libadb-full.a`), reconciled with `-Wl,--allow-multiple-definition`. That let lld
  resolve crypto symbols per-symbol from EITHER provider, so adb's
  `i2d_RSA_PUBKEY` (BoringSSL `OPENSSL_malloc`) and `OPENSSL_free` could bind to
  DIFFERENT allocators — freeing a BoringSSL-malloc'd buffer with the wrong free
  trips bionic Scudo's misaligned-pointer check. (The M1 link comment literally
  flagged this as a TODO.) **Fix:** scrcpy itself has NO OpenSSL/TLS dependency
  (verified: no `<openssl>`/`SSL_`/`EVP_` refs in `scrcpy/app/src`; the iOS link
  doesn't link libssl/libcrypto either), and adb is the only crypto user — so
  **dropped `libssl.a`+`libcrypto.a` from the link** in
  `porting/scripts/scrcpy-android-CMakeLists.txt`, leaving BoringSSL as the sole,
  self-consistent crypto provider. (`--allow-multiple-definition` kept defensively
  for protobuf intra-archive overlaps; the crypto collision is gone.) APK shrank
  26.5MB→24.3MB (no second crypto lib).
  **RELINK (d-claude, `scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`):** 70/70 ninja, MAKE_RC=0 after each fix; final
  libscrcpy.so links clean without OpenSSL. APK rebuilt green (assembleDebug, 20s).
  **PASS RUN (verbatim key logcat, emulator-5554, target `--tcpip=127.0.0.1:5555`):**
  ```
  V SDL    : Running main function scrcpy_android_main from library /data/app/.../lib/x86_64/libscrcpy.so
  V SDL    : nativeRunMain()
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  I scrcpy : onScrcpyStatus: status=2 message=SDL Inited
  V SDL    : Finished main function
  V SDL    : SDLActivity thread ends
  ```
  Diagnostic greps over the FULL logcat: UnsatisfiedLinkError = none, dlopen
  failure = none, **SIGSEGV/Fatal signal/SIGABRT/Scudo = 0 occurrences**, FATAL
  EXCEPTION/ANR = none; app pid alive at +30s. So: **libscrcpy.so loaded (no link
  error), `scrcpy_android_main`→`scrcpy_main` entered, SDL initialized, the
  in-process adb host ran its `--tcpip=127.0.0.1:5555` connect path all the way
  through `adb_auth_init` (the exact spot that aborted twice before) WITHOUT
  crashing, and scrcpy returned/finished cleanly.** Harness exit 0; emulator killed,
  throwaway container self-removed, unrelated mf-e2e/redroid/ws-scrcpy untouched.
  Artifacts: `e2e/artifacts/{logcat-full.txt,logcat-scrcpy-launch.txt,
  screen-after-launch.png}` (gitignored).
  **Committed:** android-jni-bridge.c (nativeSetHome + ensure_writable_home),
  ScrcpyActivity.kt (onCreate→nativeSetHome), scrcpy-android-CMakeLists.txt (drop
  OpenSSL), e2e/launch-app.sh (new helper), STATE. NOT committed: relinked .so /
  APK / staged jniLibs / artifacts (gitignored). **M2 accept criteria fully
  satisfied → run M2 audit next.**
- 2026-06-01: **M2 task 3 done — ScrcpyActivity (extends SDLActivity) runs scrcpy
  under SDL's Android infra; launcher UI (host/port + Connect) hands off to it;
  bridge exports `scrcpy_android_main`; relinked .so + APK build green.**
  **Architecture (the correct one — implemented):** scrcpy runs as the SDL "main"
  under `org.libsdl.app.SDLActivity` so `SDL_CreateWindow` inside `scrcpy_main`
  returns the real SDLActivity surface — video renders into it and the SDLSurface's
  touch/key events feed scrcpy's controller with NO extra Java wiring.
  **New native entry (`porting/src/android-jni-bridge.c`):**
   • `__attribute__((visibility("default"))) JNIEXPORT int
     scrcpy_android_main(int argc, char **argv)` — LOGs argc/argv, calls
     `scrcpy_main(argc,argv)`, LOGs + returns rc. This is the symbol
     `SDLActivity.nativeRunMain()` dlsym's from `getMainSharedObject()`
     (libscrcpy.so) and invokes on the dedicated SDL thread once the surface is
     ready. (The task-2 `Java_..._runScrcpy`/`JNI_OnLoad`/`ScrcpyUpdateStatus`
     stay — unused by this SDL path but harmless.)
  **New `ScrcpyActivity.kt` (extends `org.libsdl.app.SDLActivity`), 4 overrides:**
   • `getLibraries()` → `["c++_shared","SDL2","scrcpy"]` (load order: c++_shared +
     SDL2 are NEEDED by libscrcpy.so, so first; scrcpy last = also the main .so).
     SDL's `loadLibraries()` `System.loadLibrary`'s each, so no separate loader.
   • `getMainSharedObject()` → `"${applicationInfo.nativeLibraryDir}/libscrcpy.so"`
     (absolute path to the packaged lib; default would derive `libmain.so`).
   • `getMainFunction()` → `"scrcpy_android_main"` (not the default `SDL_main`).
   • `getArguments()` → scrcpy argv from Intent `host`/`port` extras. **argv shape
     mirrors the iOS ADB-over-TCP client (`ScrcpyADBClient.m buildScrcpyArgs`):**
     same option set (`--video-codec=h264 --video-bit-rate=4M --video-buffer=0
     --audio-buffer=150 --audio-output-buffer=10 --print-fps --stay-awake
     --shortcut-mod=lctrl,rctrl,lalt,ralt`), but the **connection target is
     scrcpy's own `--tcpip=HOST:PORT`** (the in-process adb host in libscrcpy.so
     does the `adb connect`) instead of the iOS app's external `adb connect` +
     `--serial=HOST:PORT`. NOTE: the task brief suggested `--adb=tcp:...`, but that
     flag does not exist in scrcpy 3.3.4 (`cli.c`); `--tcpip=<addr>` is the correct
     single-arg ADB-over-TCP target. SDL prepends argv[0]. Defaults
     127.0.0.1:5555 if extras blank. `companion newIntent(ctx,host,port)`.
  **Launcher UI:** `MainActivity` rewritten — `res/layout/activity_main.xml`
  (title + host EditText[default 10.0.2.2] + port EditText[default 5555] + Connect
  Button); Connect validates non-empty then
  `startActivity(ScrcpyActivity.newIntent(this,host,port))`. The task-2
  auto-run-`--help`-on-launch path (and its NativeBridge wiring in MainActivity +
  the `wip_message` string) is DROPPED — MainActivity is now purely the launcher.
  (`NativeBridge.kt` left intact/unused — task-2 proof.) New strings:
  host_hint/port_hint/connect/error_empty_target.
  **Manifest:** registers `ScrcpyActivity` (`exported=false`,
  `alwaysRetainTaskState`, `hardwareAccelerated`, `launchMode=singleInstance`,
  `screenOrientation=user`, `theme=Theme.AppCompat.NoActionBar`, and the SDL
  sample's `configChanges=layoutDirection|locale|orientation|uiMode|screenLayout|
  screenSize|smallestScreenSize|keyboard|keyboardHidden|navigation`) so SDL keeps
  its surface across rotation/keyboard/resize. Added `<uses-permission INTERNET>`
  + `hardwareAccelerated` on `<application>`. MainActivity stays the LAUNCHER.
  **RELINK (d-claude, `scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`):** 70/70 ninja, MAKE_RC=0, libscrcpy.so = 15279880 B.
  **VERIFIED** (`llvm-nm -D`): **`T scrcpy_android_main`** now exported, alongside
  `T scrcpy_main`, `T Java_net_scrcpy_android_NativeBridge_runScrcpy`,
  `T JNI_OnLoad`, `T ScrcpyUpdateStatus`.
  **APK (stage-natives.sh → `./gradlew --no-daemon assembleDebug`):** BUILD
  SUCCESSFUL in 30s, app-debug.apk = 26.56 MB. **VERIFIED on the APK:**
   • `unzip -l`: `lib/x86_64/{libSDL2.so 6405544, libc++_shared.so 1617608,
     libscrcpy.so 15279880}` — the relinked .so packaged.
   • extracted `lib/x86_64/libscrcpy.so` `llvm-nm -D` → `T scrcpy_android_main` +
     `T scrcpy_main` (the export survives into the APK).
   • dex class map lists `Lnet/scrcpy/android/ScrcpyActivity;`,
     `Lnet/scrcpy/android/MainActivity;`, `Lorg/libsdl/app/SDLActivity;` (+ the
     full vendored `org.libsdl.app.*` glue) — the Kotlin overrides type-checked
     against SDLActivity's protected hooks (build success = compile-time proof the
     getLibraries/getMainSharedObject/getMainFunction/getArguments signatures
     match).
   • `aapt2 dump xmltree` of the packaged manifest: both
     `net.scrcpy.android.MainActivity` (line 28) and
     `net.scrcpy.android.ScrcpyActivity` (line 44) registered.
  (Did NOT launch the GUI Activity on-emulator — redroid on d-claude is
  GUI-degraded; the real launch-on-emulator-A connect proof is M2 task 4.)
  **Committed:** android-jni-bridge.c, ScrcpyActivity.kt, MainActivity.kt,
  AndroidManifest.xml, res/layout/activity_main.xml, res/values/strings.xml, STATE.
  NOT committed: relinked .so / APK / staged jniLibs (gitignored).
- 2026-06-01: **M2 task 2 done — JNI bridge in libscrcpy.so + Kotlin loader +
  worker-thread scrcpy_main(--help) call, proven through real ART on-device.**
  **Native bridge (`porting/src/android-jni-bridge.c`, `#if defined(__ANDROID__)`,
  added to `scrcpy-android-CMakeLists.txt` source list):**
   • `JNIEXPORT jint Java_net_scrcpy_android_NativeBridge_runScrcpy(JNIEnv*,
     jclass, jobjectArray)` — converts the Java `String[]` → NUL-terminated
     argc/argv (`GetStringUTFChars`+`strdup`, freed after the call), `LOGI`s
     entry + each argv, calls `scrcpy_main(argc,argv)` on the CALLING (worker)
     thread, `LOGI`s the return code, frees argv, returns the int.
   • STRONG `void ScrcpyUpdateStatus(enum ScrcpyStatus, const char*)` — overrides
     the weak default in `scrcpy-porting.c` (and the weak one in `android-stubs.c`);
     `__android_log_print`s status+message under tag "scrcpy", then best-effort
     forwards to `net.scrcpy.android.NativeBridge.onScrcpyStatus(int,String)`
     (GetEnv/AttachCurrentThread, never throws back across JNI).
   • `jint JNI_OnLoad(JavaVM*,void*)` caches the `JavaVM*` (for the status
     forward), returns `JNI_VERSION_1_6`.
   • Load order: libscrcpy.so NEEDs libSDL2.so + libc++_shared.so, so
     `NativeBridge.load()` does `System.loadLibrary("c++_shared")` →
     `"SDL2"` → `"scrcpy"` (idempotent, `@Synchronized`).
  **Kotlin:** new `NativeBridge.kt` (`object`, `external fun runScrcpy`,
  `@JvmStatic onScrcpyStatus`, `statusListener` for the UI); `MainActivity`
  spawns a `"scrcpy-native"` worker `Thread` → `load()` →
  `runScrcpy(arrayOf("scrcpy","--help"))`, logs the rc, surfaces status into a
  `TextView` via the listener.
  **RELINK (must-fix bug found + fixed):** rebuilt libscrcpy.so WITH the bridge
  on d-claude (`scrcpy-e2e:dev`, NDK 27.2.12479018, `make android-scrcpy
  TARGET_ABI=x86_64`, 70/70 ninja, MAKE_RC=0). First relink loaded fine for
  libc++_shared+libSDL2 but **`dlopen failed: cannot locate symbol "uncompress"`**
  (a real UnsatisfiedLinkError) when ART loaded libscrcpy.so: adb's libziparchive
  (in libadb-full.a) + FFmpeg pull zlib's `uncompress`/`inflate*`/`crc32`, but
  `libz.so` was NOT in NEEDED — the `--unresolved-symbols=ignore-all` link flag
  let the .so build anyway, and the M1 smoke exe tolerated it because `--help`
  exits before any zlib path AND the exe link differed. **Fix:** added `z` to the
  `target_link_libraries` system-lib list in `scrcpy-android-CMakeLists.txt`.
  Re-relink → `libz.so` now in NEEDED (verified `llvm-readelf -d`); bridge symbols
  still exported (`llvm-nm -D`: **`T Java_net_scrcpy_android_NativeBridge_runScrcpy`,
  `T JNI_OnLoad`, `T ScrcpyUpdateStatus`, `T scrcpy_main`**); ELF64/DYN/X86-64,
  NO TEXTREL.
  **APK REBUILD:** `stage-natives.sh` re-staged the 3 fresh libs →
  `./gradlew --no-daemon assembleDebug` → BUILD SUCCESSFUL (26.5 MB). VERIFIED
  the APK's `lib/x86_64/libscrcpy.so` (15279104 B, the relinked one) contains
  `T Java_net_scrcpy_android_NativeBridge_runScrcpy` + `T JNI_OnLoad`.
  **RUNTIME SANITY (real ART, on-device):** the redroid-11 x86_64 GUI stack on
  d-claude is too degraded to launch an Activity (surfaceflinger/sensors/health/
  wificond/logd HALs SIGABRT at boot → `sys.boot_completed` never flips, no
  launcher, `am start`/monkey never start the app process) — so instead of the
  GUI launch I drove the **exact JNI entrypoint through real ART** with
  `app_process64`: a tiny `NbTest` dex (built with the SDK `d8`, bundling the
  vendored `org.libsdl.app.*` glue so SDL2's own `JNI_OnLoad` — which registers
  natives against `org.libsdl.app.SDLActivity` — resolves) `System.load`s the 3
  libs in order and reflectively calls `net.scrcpy.android.NativeBridge
  .runScrcpy({"scrcpy","--help"})`. **VERBATIM stdout (688 lines):**
  ```
  [nbtest] loaded libc++_shared.so
  [nbtest] loaded libSDL2.so
  [nbtest] loaded libscrcpy.so
  [nbtest] NativeBridge class resolved: class net.scrcpy.android.NativeBridge
  [nbtest] calling runScrcpy(scrcpy --help) via JNI ...
  scrcpy 3.3.4 <https://github.com/Genymobile/scrcpy>
  Usage: scrcpy [options]
  ... [full scrcpy 3.3.4 usage] ...
  [nbtest] runScrcpy returned 0
  Exit status:
        0  Normal program termination
        1  Start failure
        2  Device disconnected while running
  ```
  → ART loaded all 3 native libs (NO UnsatisfiedLinkError after the libz fix),
  bound + invoked `Java_net_scrcpy_android_NativeBridge_runScrcpy`, control
  entered `scrcpy_main`, the full scrcpy 3.3.4 usage printed, and `runScrcpy
  returned 0` with `app_process` exit 0 — no crash/SIGSEGV. (The bridge's own
  `__android_log_print` "scrcpy"-tag lines could NOT be captured because logd is
  one of the redroid services that SIGABRTs at boot; the usage text reaches us via
  scrcpy's own `printf`/stdout, which is the authoritative proof the native method
  ran. Driving the real `MainActivity` Activity awaits a healthy emulator — M2
  task 4.) Throwaway redroids removed; `mf-e2e-redroid-1` untouched; host clean.
  **Committed:** android-jni-bridge.c, scrcpy-android-CMakeLists.txt (bridge in
  source list + `z` link), NativeBridge.kt, MainActivity.kt, STATE. NOT committed:
  the relinked `.so`/APK (gitignored) or the throwaway nbtest harness (under e2e/,
  on the build host only).
- 2026-06-01: **M2 task 1 done — native libs + SDL Java glue integrated into the
  android-app Gradle build; APK packages all 3 .so + compiles `org.libsdl.app.*`.**
  This is BUILD-INTEGRATION ONLY (no `scrcpy_main` call / no UI yet — that's M2
  task 2/3); `MainActivity` left as-is (stub TextView).
  **`android-app/app/build.gradle.kts` changes (all additive):**
   • `defaultConfig.ndk { abiFilters += "x86_64" }` — packages only the x86_64 ABI
     (arm64-v8a deferred to M4); without this AGP would warn/expect every ABI.
   • `sourceSets.named("main")`: `java.srcDir("../../porting/vendor/sdl-android-java")`
     — that dir is the source ROOT (`org/libsdl/app/*.java` under it), so the
     `org.libsdl.app` package compiles straight into the app. Verified the glue is
     self-contained: single package decl `org.libsdl.app`, NO `R.*` resource refs,
     NO `BuildConfig`, no non-android/java/libsdl imports → compiles clean with the
     stub MainActivity still as launcher (SDLActivity not yet used). Also pinned
     `jniLibs.srcDir("src/main/jniLibs")` (AGP default, explicit).
  **Staging mechanism (reproducible, .so never committed):** new
  **`android-app/stage-natives.sh`** (executable) — copies the 3 prebuilt libs
  (`libscrcpy.so`, `libSDL2.so`, `libc++_shared.so`) from
  `output/android/<ABI>` into `app/src/main/jniLibs/<ABI>/` BEFORE `./gradlew
  assembleDebug`. Args: `stage-natives.sh [OUTPUT_DIR] [ABI]` (defaults
  `../output/android/x86_64`, `x86_64`); errors out if any lib is missing. The
  e2e/CI path calls it before gradlew. `android-app/.gitignore` now ignores
  `app/src/main/jniLibs/` (the .so are gitignored build artifacts; root .gitignore
  already swallows `*.so`/`output`). Verified `git check-ignore
  app/src/main/jniLibs/x86_64/libscrcpy.so` → ignored.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (persistent `scrcpy-gradle-cache`
  volume): rsync'd `android-app/` + `porting/vendor/` to
  `/srv/work/scrcpy-mobile-e2e`, ran `./stage-natives.sh /workspace/output/android/
  x86_64 x86_64 && ./gradlew --no-daemon assembleDebug` → **BUILD SUCCESSFUL in
  44s** (`:app:compileDebugJavaWithJavac` compiled the SDL glue;
  `:app:mergeDebugNativeLibs` packaged the .so; only a benign "Unable to strip"
  note for the 3 prebuilt .so). APK = `app/build/outputs/apk/debug/app-debug.apk`
  (26.5 MB, up from the 3.18 MB stub APK).
  **VERIFIED — APK CONTAINS the libs** (`unzip -l app-debug.apk | grep
  "lib/x86_64/"`):
  ```
    6405544  lib/x86_64/libSDL2.so
    1617608  lib/x86_64/libc++_shared.so
   15252168  lib/x86_64/libscrcpy.so
  ```
  **VERIFIED — SDL glue compiled into the dex:** APK has classes{,2,3}.dex; the
  multidex map in classes3.dex lists `Lorg/libsdl/app/SDLActivity;`,
  `Lorg/libsdl/app/SDLSurface;`, `Lorg/libsdl/app/SDLAudioManager;`,
  `Lorg/libsdl/app/SDLControllerManager;`, `Lorg/libsdl/app/SDLMain;`, the four
  `Lorg/libsdl/app/HIDDevice*;` and `Lnet/scrcpy/android/MainActivity;` — i.e. the
  full vendored `org.libsdl.app` package + the app's launcher Activity.
  **Committed** (build.gradle.kts, .gitignore, stage-natives.sh, STATE).
  **NOT committed:** the staged jniLibs/.so (gitignored) and the APK/build dir.
  MainActivity untouched.
- 2026-06-01: **M1 AUDIT PASSED.** Skeptical audit re-verified everything with
  commands on d-claude (`scrcpy-e2e:dev`, NDK 27.2.12479018), did not trust the
  cached `.so`. Evidence:
  • **iOS intact:** every `porting/src`+`porting.h` edit is `#if defined(__APPLE__)`
    guarded (porting.h GLES include, demuxer-porting VideoToolbox hijack) or portable
    (controller-porting `#import`→`#include` of a guarded header — identical on
    clang/iOS); both new stub files are `#if !defined(__APPLE__)` wrapped;
    `Makefile.android` is additive (`include`d, nothing in the iOS `all` recipe
    references it). Submodule pointers NOT bumped: `.gitmodules` diff empty, scrcpy
    @fb6381f, adb-mobile @78c32c2 (the `-`-prefixed submodules are merely
    uninitialized, not re-pointed).
  • **Rebuilt from scratch:** deleted the cached `libscrcpy.so` + build dir, rsync'd
    `porting/`, ran `make android-scrcpy TARGET_ABI=x86_64` (with
    `ANDROID_NDK_ROOT=/opt/android-sdk/ndk/27.2.12479018`) → 69/69 ninja, `MAKE_RC=0`,
    fresh `libscrcpy.so` = 15.25 MB.
  • **Static verify** (llvm-readelf/llvm-nm): `ELF64 / DYN / X86-64`, SONAME
    `libscrcpy.so`, **NO TEXTREL** (FLAGS=SYMBOLIC only), exports `T scrcpy_main` +
    `T scrcpy_print_version`; NEEDED = libSDL2.so liblog.so libandroid.so libGLESv3.so
    libGLESv2.so libEGL.so libOpenSLES.so libm.so libc++_shared.so libdl.so libc.so.
  • **Smoke on bionic:** rebuilt `scrcpy-smoke` (RUNPATH `$ORIGIN`, NEEDED
    libscrcpy.so+libSDL2.so), pushed it + the 3 libs into a THROWAWAY redroid-11
    x86_64 container, ran it → bionic linker loaded all libs with no
    dlopen/textrel/missing-symbol error, entered `scrcpy_main`, printed full scrcpy
    3.3.4 usage/version, `[smoke] scrcpy_main returned 0`, `SMOKE_EXIT=0`. Throwaway
    container removed; unrelated `mf-e2e-redroid-1` untouched; host left clean.
  • **git:** all 6 M1 commits (`0200f63..d29023d`) pushed to `fork`, working tree
    clean, no built `.so`/`.a` tracked. **→ advancing to M2.**
- 2026-06-01: **M1 tasks 6 + 7 done — `libscrcpy.so` cross-compiled for android
  x86_64 and the NDK smoke exe runs `scrcpy_main --help` cleanly on-device. M1
  COMPLETE.**
  **porting/src #ifdef adaptations (all additive, iOS path kept under `__APPLE__`):**
   • `porting/include/porting.h`: the iOS `<OpenGLES/ES3/gl.h>`+`<OpenGLES/gltypes.h>`
     include is now under `#if defined(__APPLE__)`; the `#else` (Android) uses the
     NDK `<GLES3/gl3.h>`+`<GLES2/gl2ext.h>`. Dropped the iOS `typedef GLfloat
     GLdouble`/`GLclampd` on Android (the NDK gl2ext.h already typedefs them →
     would conflict) and the iOS `<SDL2/SDL_opengl_glext.h>` include (clashes with
     NDK gl2ext; not needed — opengl.c pulls GL via SDL).
   • `porting/src/demuxer-porting.c`: the VideoToolbox HW-decode hijack
     (`av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)`) is now under
     `#if defined(__APPLE__)`; the `#else` (Android) just returns the plain
     AVCodecContext → scrcpy's normal FFmpeg **software** decode +
     `SDL_UpdateYUVTexture` rendering runs (no Metal/VT).
   • `porting/src/controller-porting.c`: `#import "screen.h"` (ObjC-only syntax)
     → `#include "screen.h"` (compiles under the NDK C frontend; identical on iOS).
   • decoder-porting.c / display-porting.c / screen-porting.c needed NO source
     change — their hijacks already gate on `ScrcpyEnableHardwareDecoding()` (0 on
     Android via the stub below ⇒ the SW path), and SDL handles clipboard
     cross-platform (the `SDL_CLIPBOARDUPDATE` handler in screen-porting.c is
     SDL-generic). process-porting.cpp already uses `adb_public.h` → libadb-full.a.
   • **NEW `porting/src/android-stubs.c`** (Android-only, also `#if !__APPLE__`
     guarded): weak defaults for the symbols the iOS app/SDL-fork provides —
     `ScrcpyEnableHardwareDecoding`(→0, forces SW path), `ScrcpyTryResetVideo`,
     `ScrcpyHandleFrame`, `GetUpdateApplicationBackgroundState`,
     `SDL_UpdateCommandGeneration` (iOS-SDL-fork ext, no-op), `ScrcpyAudioVolumeScale`
     (→1.0), and the AOSP adb globals `__adb_argv`/`__adb_envp` (defined in AOSP
     client/main.cpp, which the port excludes). The M2 app will provide strong
     overrides.
   • **NEW `porting/src/android-adb-stubs.cpp`**: weak no-op stubs for adb
     **dead-path** entry points that libadb-full.a references but does not define
     (its bundle lacks the adb mDNS/bonjour/emulator-command/logd-pmsg and
     adb-wifi-pairing TUs): `using_bonjour`, `mdns_check`,
     `mdns_{list_discovered_services,get_connect_service_info,get_pairing_service_info}`,
     `adb_secure_connect_by_service_name`, `adb_send_emulator_command`,
     `Logd{Write,Close}`, `Pmsg{Write,Close}`, `adbwifi::pairing::PairingClient::Create`.
     scrcpy's adb host uses only `adb_commandline_porting`, which never reaches
     these — but bionic resolves non-lazy relocs eagerly at dlopen, so the .so
     must define them to LOAD. Signatures mirror adb's headers so the C++ mangled
     names line up exactly (verified: 0 adb dead-path UND symbols remain).
  **Android CMake build (mirrors porting/cmake/CMakeLists.txt, additive):**
   • **NEW `porting/scripts/scrcpy-android-CMakeLists.txt`** + driver
     **`porting/scripts/make-scrcpy-android.sh`** (wired into `Makefile.android`
     `android-scrcpy`, TODO stub replaced; iOS Makefile untouched). Same source
     list as the iOS cmake (the porting/src replacements + scrcpy/app/src/* core),
     minus the USB sources (mobile) and — unlike iOS — it does NOT compile
     `sys/unix/process.c`/`util/process_intr.c` standalone (process-porting.c
     already amalgamates them via `#include`; the iOS Mach-O link tolerates the
     resulting dup symbols, lld does not). Builds a **SHARED `libscrcpy.so`** via
     the NDK `android.toolchain.cmake` (`ANDROID_ABI=x86_64`,
     `ANDROID_PLATFORM=android-26`, `ANDROID_STL=c++_shared`, `-include porting.h`
     mirroring iOS `-include porting.h`). C++17 (adb mDNS sigs use
     `std::optional`/`string_view`).
   • **config.h handling:** the iOS build gets `scrcpy/x/app/config.h` from
     `meson setup x`. The Android cmake instead WRITES a static config.h into the
     build dir replicating exactly meson's emitted defines (per
     scrcpy/app/meson.build): `HAVE_SOCK_CLOEXEC=1` (bionic has it),
     `SCRCPY_VERSION="3.3.4"`, `PREFIX`, `DEFAULT_LOCAL_PORT_RANGE_FIRST/LAST
     27183/27199`. CRITICAL: scrcpy gates features with `#ifdef` and meson emits
     disabled bools as `#undef`, so `PORTABLE`/`SERVER_DEBUGGER`/`HAVE_V4L2`/
     `HAVE_USB` are intentionally LEFT UNDEFINED (defining them `=0` would still
     be truthy under `#ifdef` and pull in `<libusb-1.0/libusb.h>` etc).
   • **Link:** `--start-group` over the prebuilt static deps
     (libav*/libsw*/libssl/libcrypto/libadb-full) `--end-group` + `libSDL2.so` +
     android sys libs (`-llog -landroid -lGLESv3 -lGLESv2 -lEGL -lOpenSLES -lm`).
     Link flags that were load-bearing: **`-Bsymbolic`** (FFmpeg's internal data
     tables e.g. `ff_h264_cabac_tables` are referenced cross-object via PC32;
     binding them locally makes the PC32 link-time-resolvable with no runtime
     reloc — without it lld errors "recompile with -fPIC"),
     **`--allow-multiple-definition`** (libadb-full.a statically bundles BoringSSL
     whose X509_*/EVP_* symbols collide with scrcpy's OpenSSL libcrypto.a),
     **`--unresolved-symbols=ignore-all`** (the NDK toolchain forces
     `-Wl,--no-undefined`; libc++ runtime + a few protobuf-pulled abseil symbols
     on adb dead paths are satisfied at runtime by `libc++_shared.so` / never
     called), **`-z lazy`**.
  **Two dep fixes required to make the .so actually LOAD on Android (bionic):**
   1. **`make-ffmpeg-android.sh`**: added `FFMPEG_DISABLE_X86ASM=1` knob and
      rebuilt FFmpeg with **`--disable-x86asm`**. FFmpeg's x86_64 hand-written asm
      emits R_X86_64_PC32 **text relocations** → the .so gets `DT_TEXTREL`, which
      bionic (API≥23) REFUSES to load ("has text relocations"). x86asm-off = pure-C
      PIC FFmpeg ⇒ libscrcpy.so is TEXTREL-free (verified `llvm-readelf -d` shows
      no TEXTREL). (libavcodec.a 5.0M→3.8M.) Also fixed the script to **MERGE**
      headers into the shared `include/` instead of `rm -rf include` (it was
      wiping SDL2/openssl/adb headers that the other deps install there — made the
      build order-dependent).
   2. **`make-adb-mobile-android.sh`**: the bundle was missing **brotli** (built
      `.so` not `.a` → `BrotliDecoder*` undefined) and **abseil/utf8_range** (only
      libprotobuf.a was folded in, not its abseil deps → ~80 `absl::` undefined).
      Fixed: try brotli `*-static` targets then fall back to archiving brotli's
      compiled `.o`s; collect+bundle the `libabsl_*.a`/`libutf8_*.a` from the
      protobuf-android abseil build. libadb-full.a 22M→26M, brotli/absl now `T`.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** via `make android-scrcpy`
  (`make-scrcpy-android.sh`): 69/69 ninja, `[scrcpy-android] DONE`. apt deps
  per-run: `make` (+ `nasm pkg-config` for the ffmpeg rebuild, `golang-go
  build-essential patch` for the adb rebuild). cmake 3.22.1 + ninja auto-resolved
  from `$ANDROID_SDK_ROOT/cmake/*/bin`. **libscrcpy.so = 15.25 MB**; **VERIFIED**
  (llvm-readelf/llvm-nm): `ELF64 / DYN / X86-64`, SONAME `libscrcpy.so`, **NO
  TEXTREL**, `.note.android.ident`, exports `T scrcpy_main` + `T
  scrcpy_print_version`; **NEEDED** = `libSDL2.so liblog.so libandroid.so
  libGLESv3.so libGLESv2.so libEGL.so libOpenSLES.so libm.so libc++_shared.so
  libdl.so libc.so`. The driver also stages the NDK `libc++_shared.so` next to it
  (ANDROID_STL=c++_shared ⇒ NEEDED at runtime; M2 APK must bundle it).
  **SMOKE TEST** (`porting/scripts/scrcpy-smoke.c`: `extern int scrcpy_main(int,
  char**)`, calls it with `{"scrcpy","--help"}`): cross-compiled for android
  x86_64, linked vs libscrcpy.so+libSDL2.so (RUNPATH `$ORIGIN`), pushed into a
  throwaway **redroid Android-11 x86_64** container on d-claude (the scrcpy-e2e
  emulator wasn't needed — redroid shares the host kernel, boots an Android
  userspace + bionic linker in seconds) and RUN. **VERBATIM output (head):**
  ```
  [smoke] calling scrcpy_main --help
  scrcpy 3.3.4 <https://github.com/Genymobile/scrcpy>
  Usage: scrcpy [options]

  Options:

      --always-on-top
          Make scrcpy window always on top (above other windows).
  ... [full scrcpy usage incl. shortcuts, env vars] ...
  Exit status:
        0  Normal program termination
        1  Start failure
        2  Device disconnected while running
  EXIT=0
  ```
  ACCEPT met: the bionic dynamic linker loaded libscrcpy.so + its deps with NO
  "has text relocations" / "cannot locate symbol" / dlopen error, control entered
  `scrcpy_main`, the full scrcpy 3.3.4 usage/version text printed, and the process
  exited 0 (scrcpy's `--help` path calls `exit(0)` itself, so the post-call
  `[smoke] returned` line is not reached — a clean exit, not a crash). Throwaway
  redroid removed after capture (host left clean).
  **Committed:** the porting.h/demuxer/controller `#ifdef` edits, the two new
  android-stubs source files, the new android cmake + driver + smoke source, the
  Makefile.android wire-up, the ffmpeg/adb dep-script fixes, STATE. **NOT
  committed** (gitignore swallows): `output/` (`.so`/`.a`), `porting/build/`, the
  scrcpy submodule (pointer NOT bumped — stays @fb6381f). **M1 accept criteria
  fully satisfied → run M1 audit next.**
- 2026-06-01: **M1 task 5 done — adb-mobile (`libadb-full.a`) cross-compiled for
  android x86_64.** This is the in-process ADB host (`adb_commandline_porting` API)
  that pushes the scrcpy server + opens TCP tunnels, same role as the iOS build.
  **APPROACH (b): a standalone NDK driver, NOT adb-mobile's own ios-cmake build.**
  `external/adb-mobile`'s build (`make-adb.sh`) wires Google's adb sources through
  `nmeum/android-tools`'s CMake, which `pkg_check_modules(REQUIRED)` for
  brotli/lz4/pcre2/zstd/protobuf/libusb and compiles a pile of unrelated host tools
  (fastboot/e2fsprogs/...); the iOS port tolerates that via brew. Rather than fight
  it under the NDK, I wrote a small **standalone CMakeLists**
  (`porting/scripts/adb-mobile-android-CMakeLists.txt`) that compiles **exactly the
  iOS static-lib target set** (libadb + libbase/libcutils/liblog/libcrypto_utils/
  libdiagnoseusb/libziparchive/adb_crypto_defaults/adb_tls_connection_defaults + fmt)
  against the vendored AOSP sources + the `porting/adb/` client overrides, pulling
  **boringssl** in as a subdirectory (cross-compiles cleanly with NDK + host Go). The
  iOS targets in `external/adb-mobile` are 100% untouched (additive, alongside).
  Driver = **`porting/scripts/make-adb-mobile-android.sh`** (wired into
  `Makefile.android` `android-adb-mobile`, TODO stub replaced; iOS Makefile untouched).
  It (1) builds a **host protoc 28.3** from the pinned `external/protobuf` (apt's is
  the wrong ver) + uses it to generate adb's `*.pb.cc`; (2) cross-compiles **Android
  libprotobuf** and **lz4/zstd/brotli** (transport/incremental compression) via the
  NDK cmake toolchain; (3) **overlays `porting/adb/client/*` onto vendor/adb/client/**
  (the iOS mechanism — required so path-qualified `#include "client/file_sync_client.h"`
  resolves to the porting override, in-process no-fork server + extended do_sync_pull);
  (4) configures+builds the standalone project through the NDK; (5) bundles every `.a`
  (+ android libprotobuf + lz4/zstd/brotli) into **`output/android/x86_64/libadb-full.a`**
  via an `llvm-ar -M` MRI script, then `--strip-debug`. **adb_public.h** copied to the
  android `include/`.
  **Submodules initialized (pinned, NOT bumped):** `external/adb-mobile` @78c32c2 +
  its `external/{lz4,zstd,brotli,protobuf}` and `android-tools` vendor subset
  `{adb,core,libbase,libziparchive,boringssl,fmtlib,logging}` (+ protobuf's nested
  abseil-cpp/utf8_range). The big unused android-tools vendors (selinux/extras/
  e2fsprogs/f2fs/libusb/...) are intentionally left un-inited.
  **Key porting fixes (all in the driver/standalone CMake, none touch committed
  vendor files — overlay+patch happen on the build host's rsync'd tree which has no
  `.git`, so patches use idempotent GNU `patch --forward`, not `git am`):**
   • API floor **29** for this lib only (`ANDROID_API_ADB`, overrides the repo
     default 26): AOSP `libbase/unique_fd.h` hard-`#if`-gates fdsan on
     `__ANDROID_API__>=29`; the symbols are weak so the lib still loads on <29, and
     the adb host runs on the API-30 emulator anyway. (ffmpeg/sdl/openssl stay at 26.)
   • `-D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__` — liblog/adb reference bionic
     symbols `__INTRODUCED_IN(30)`; makes those weak refs instead of hard errors.
   • applied upstream adb patches **0007** (guard the sysdeps `write` macro so it
     doesn't clobber `std::ostream::write` that abseil str_format pulls in) and
     **0013** (disable fastdeploy → no `ApkEntry.pb.h` requirement).
   • `ZLIB_CONST` for libziparchive (NDK zlib `next_in` const mismatch); in-tree
     incfs_support + gtest_prod includes added.
   • guarded the porting `main.cpp`'s `#include "fdevent_poll.cpp"` behind
     `#if !defined(__linux__)` — it amalgamates BOTH poll and epoll backends; on iOS
     epoll is `__linux__`-excluded so poll wins, but Android IS `__linux__` → both
     compiled → `fdevent_interrupt` redefinition. Android uses the epoll backend.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** end-to-end via
  `make android-adb-mobile` (clean cmake/bundle rebuild): `MAKE_RC=0`,
  `[adb-mobile-android] DONE`. **apt deps (transient in the run cmd, NOT baked into
  the image):** `golang-go build-essential make patch` (go is needed for boringssl's
  codegen; build-essential for the host protoc; patch for the idempotent vendor
  patching). cmake 3.22.1 + ninja come from `$ANDROID_SDK_ROOT/cmake/*/bin` (script
  auto-prepends, same trick as the SDL build). **libadb-full.a = 6.1M** (stripped;
  22.7M unstripped; 980 object members). **VERIFIED Android x86_64** (llvm-nm /
  llvm-ar / llvm-readelf in the image): defined `T adb_commandline_porting`,
  `T adb_trace_init_porting`, `T adb_trace_enable_porting`, `T capture_printf`, and
  the in-process `T launch_server`/`launch_server_thread` overrides; an extracted
  member (`commandline.cpp.o`) is `ELF64 / X86-64 / REL`; brotli/lz4/zstd/protobuf
  symbols bundled; `adb_public.h` present in the android include dir.
  gitignore swallows `output/`+`build/`+`*.a` (only the driver script, the standalone
  CMakeLists, the Makefile.android edit + STATE committed; submodule pointer NOT
  bumped — adb-mobile stays @78c32c2).
- 2026-06-01: **M1 task 4 done — OpenSSL cross-compiled for android x86_64.** New
  `porting/scripts/make-openssl-android.sh` (mirrors the FFmpeg/SDL android-driver
  style; iOS untouched). **OpenSSL 1.1.1w** (matches the iOS OpenSSL-for-iPhone 1.1.1
  series, for ABI/API parity). Configured `./Configure android-x86_64
  -D__ANDROID_API__=26 no-shared no-tests` via the NDK clang (`x86_64-linux-
  android26-clang`, on PATH from android-defines.sh). Produced **libcrypto.a (5.2 MB)
  + libssl.a (1.0 MB)** + headers into `output/android/x86_64/` (the canonical
  output dir, same place ffmpeg/sdl land). VERIFIED on d-claude in `scrcpy-e2e:dev`:
  build rc=0 / "[openssl-android] DONE"; `nm` shows defined `T OPENSSL_init_crypto`
  (libcrypto) and `T SSL_new` (libssl); archive has 637 object members all compiled
  by the android NDK clang. apt deps `make perl` installed per-run.
  PROCESS NOTE: the first attempt was launched by the iteration subagent as a
  background task and got TORN DOWN when that subagent paused (un-resumable) — the
  build was re-launched as a parent-session harness-tracked task and finished clean.
  Going forward, heavy builds should run BLOCKING in the subagent's own context (or
  be launched by the parent) so they aren't killed.
- 2026-06-01: **M1 task 3 done — SDL2 cross-compiled for android x86_64 (native
  Android backend).** New `porting/scripts/make-libsdl-android.sh` (mirrors the
  iOS `make-libsdl.sh` STYLE but retargets the NDK; iOS script untouched). **Same
  SDL2 version as iOS: 2.32.8** (downloaded from libsdl.org, tarball cached under
  `porting/build/libsdl-android/`, re-runs reuse it). **Build method:** SDL2's own
  CMake build driven through the NDK `build/cmake/android.toolchain.cmake`
  (resolved by android-defines.sh) with `-DANDROID_ABI=x86_64
  -DANDROID_PLATFORM=android-26 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF`
  → **SHARED `libSDL2.so`** (the Android norm, loaded at runtime by SDLActivity in
  M2). cmake auto-selected the **Android backend** (configure summary: `Platform:
  Android-1`; compiled `src/core/android/SDL_android.c`, `audio/openslES`,
  `audio/aaudio`, `video/android/SDL_android{video,touch,events,clipboard,...}.c`,
  `joystick/android`, `sensor/android` — NOT the iOS UIKit path). Wired
  `android-libsdl` target in `porting/Makefile.android` to call the script (TODO
  stub replaced; iOS untouched). Outputs `output/android/x86_64/libSDL2.so` +
  `include/SDL2/*.h` (79 headers incl. generated SDL_config.h — iOS-compatible
  layout so libscrcpy can `#include <SDL.h>`).
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (`EXIT_CODE=0`, 265/265 ninja
  steps + install). **apt deps:** transiently `apt-get install make ninja-build`
  in the run command (NOT baked into the image, same as the FFmpeg task). **cmake:**
  the image's Android-SDK cmake 3.22.1 is NOT on PATH; the script auto-prepends
  `$ANDROID_SDK_ROOT/cmake/<ver>/bin` (which also supplies the bundled ninja) when
  `cmake` is absent — so the build is self-contained. **libSDL2.so size: 6.2M.**
  **VERIFIED Android x86_64** (`llvm-readelf`/`llvm-nm` in the image): `ELF64 / DYN
  (shared object) / X86-64`; SONAME `libSDL2.so`; NEEDED includes the Android
  system libs `libOpenSLES.so libandroid.so liblog.so libGLESv1_CM.so libGLESv2.so`
  (proves Android backend, not iOS); `.note.android.ident` present; `llvm-nm -D`
  finds `T SDL_Init`, `T SDL_CreateWindow`, `T SDL_GetPlatform`; SDL.h present.
  **SDL Android Java glue for M2:** vendored 9 files (SDLActivity, SDLSurface,
  SDLAudioManager, SDLControllerManager, SDL, HIDDevice*) from the SDL2-2.32.8
  tarball's `android-project/app/src/main/java/org/libsdl/app/` into
  `porting/vendor/sdl-android-java/org/libsdl/app/` (TRACKED — `.gitignore`
  ignores `porting/libs` but NOT `porting/vendor`; verified `git check-ignore`
  exit 1) + a `SOURCE.txt` provenance note. M2 imports this `org.libsdl.app`
  package so SDLActivity.loadLibraries() loads libSDL2.so at runtime. gitignore
  confirmed swallowing `output/` + `build/` + `*.so` (only script + Makefile edit
  + vendored java + STATE committed; no SDL tarball or libSDL2.so).
- 2026-06-01: **M1 task 2 done — FFmpeg cross-compiled for android x86_64.**
  New `porting/scripts/make-ffmpeg-android.sh` (mirrors the iOS `make-ffmpeg.sh` but
  retargets the NDK): same **FFmpeg release/6.0**, sources the M1-task-1
  `scripts/android-defines.sh` toolchain (CC=`x86_64-linux-android26-clang`,
  `--cross-prefix=$TOOLCHAIN/bin/llvm-`, `--sysroot`, `--target-os=android
  --arch=x86_64 --enable-cross-compile`). Source is git-cloned once and cached under
  `porting/build/ffmpeg-android/ffmpeg-source` (re-runs reuse it). **Static `.a`**
  (mirrors iOS: `--enable-static --disable-shared`); **no VideoToolbox/MediaCodec/JNI**
  (`--disable-videotoolbox --disable-mediacodec --disable-jni`), software decode only.
  **Lean config:** `--disable-everything` then enable avcodec/avformat/avutil/swscale/
  swresample + decoders h264,hevc,av1,aac,opus,flac,pcm_s16le + matching parsers +
  demuxers (h264/hevc/av1/aac/ogg/flac/pcm + matroska/mov/mpegts) + protocols
  file,pipe. (avfilter/avdevice also fall out of the build — kept; mirrors the iOS
  link list which includes both.) **x86 asm: nasm** (auto-detected; script falls back
  to `--disable-x86asm` if absent). Wired `android-ffmpeg` target in
  `porting/Makefile.android` to call the script (TODO stub replaced; iOS untouched).
  Outputs to `output/android/x86_64/lib*.a` + `include/` in the iOS layout.
  **BUILT GREEN on d-claude in `scrcpy-e2e:dev`** (apt-get installed make/nasm/
  pkg-config transiently in the run command — NOT baked into the Dockerfile, kept the
  image change-free): `EXIT_CODE=0`, "DONE. Libraries in: output/android/x86_64".
  Produced: libavcodec.a 5.0M, libavformat.a 844K, libavutil.a 1.2M, libswscale.a
  1.4M, libswresample.a 212K, libavfilter.a 197K, libavdevice.a 13K, + full include/
  tree (libav*/libsw*). **VERIFIED Android x86_64:** `llvm-readelf -h` on an extracted
  object shows `ELF64 / X86-64 / REL`; `llvm-nm libavcodec.a` finds `T
  avcodec_send_packet` and `D ff_h264_decoder` (H.264 software decoder compiled in).
  gitignore confirmed ignoring `output/` + `build/` + `*.a` (only script + Makefile +
  STATE committed; no FFmpeg sources or libs).
- 2026-06-01: **M1 task 1 done — Android NDK build scaffold (scaffolding only).**
  Added `porting/scripts/android-defines.sh` (NDK locate honoring
  `$ANDROID_NDK_ROOT` / `$ANDROID_SDK_ROOT/ndk/27.2.12479018` / `$ANDROID_HOME`,
  **NDK pinned 27.2.12479018**, **TARGET_ABI=x86_64** default, **ANDROID_API=26**,
  unified-llvm toolchain paths, output `output/android/$TARGET_ABI/`),
  `porting/Makefile.android` (stub targets `android-ffmpeg/libsdl/openssl/adb-mobile/
  scrcpy` each echoing `TODO(M1)` + creating output dir, plus `android-libs` and a
  real `android-toolchain-check`; `SHELL := /bin/bash` for the bashy defines),
  `porting/scripts/README-android.md`. Wired into `porting/Makefile` purely
  additively (`SOURCE_ROOT := ...` + `include Makefile.android` appended after
  `server-diff`; nothing references the iOS `all` target). **iOS build UNCHANGED:**
  `make -n all` recipe output is byte-for-byte identical before/after (diff clean);
  no iOS script touched. **VERIFIED in `scrcpy-e2e:dev` on d-claude:** sourcing
  android-defines.sh resolves CC=`x86_64-linux-android26-clang`; it compiles+links a
  trivial C file into an Android x86_64 ELF — `llvm-readelf` shows `ELF64` /
  `X86-64` / PIE with a `.note.android.ident` (`r27c`, NDK build 12479018);
  `make android-toolchain-check` prints `[android] TOOLCHAIN_OK`; `make android-libs`
  runs all 5 stubs and creates `output/android/x86_64/`. ABI switch sanity-checked:
  `TARGET_ABI=arm64-v8a` resolves `aarch64-linux-android26-clang` (binary present).
  (Note: `scrcpy-e2e:dev` lacks `make`/`file`; installed transiently in the throwaway
  verify container — the toolchain-check recipe falls back to `llvm-readelf` when
  `file` is absent.)
- 2026-06-01: **M0 AUDIT PASSED.** Fresh authoritative run on d-claude (after
  killing two overlapping/racing harness containers that were starving RAM —
  single clean run only): `AUDIT_RC=0`, SUCCESS banner, both `emulator-5554` and
  `emulator-5556` reached `device`, all placeholder asserts passed (both online +
  settings round-trip on B + `am start` moved `mCurrentFocus` to Settings + input
  keyevent/tap dispatched), `cleanup done (rc=0)`, host left clean (0 scrcpy
  containers). Cold runtime ~3.5 min. Advancing to M1. NOTE for future runs: only
  ONE e2e run at a time on d-claude — host shares ~8 GB RAM with unrelated long-
  running mf-e2e/redroid/ws-scrcpy containers, so concurrent runs OOM/phantom.
- 2026-06-01: Repo forked → `d33mobile/scrcpy-mobile`; branch
  `android-controls-android` created; README overwritten (WIP + goal); master plan
  + research written. Starting M0.
- 2026-06-01: M0 task 1 done. `e2e/Dockerfile` + `e2e/README.md` written and built
  green on d-claude as `scrcpy-e2e:dev` (7.96 GB). Verified inside the image:
  emulator, avdmanager, sdkmanager, adb, NDK 27.2.12479018, cmake 3.22.1,
  build-tools 37.0.0, platforms;android-36, system-images;android-30;google_apis;
  x86_64 all present. Image requires `--device /dev/kvm` to run the emulators.
- 2026-06-01: M0 task 2 done. Scaffolded `android-app/` Kotlin-DSL Gradle project:
  AGP 8.7.3, Gradle 8.9, Kotlin 2.0.21, compileSdk/targetSdk 36, minSdk 26,
  applicationId `net.scrcpy.android`, stub `MainActivity` (AppCompat, TextView WIP
  message), deps androidx.core-ktx 1.13.1 + appcompat 1.7.0. `.gitignore` added
  (build/, .gradle/, local.properties, *.iml, .idea/, .kotlin/, .cxx/). Built green
  on d-claude in `scrcpy-e2e:dev` via the persistent `scrcpy-gradle-cache` volume:
  `./gradlew --no-daemon assembleDebug` → BUILD SUCCESSFUL (exit 0), APK at
  `/srv/work/scrcpy-e2e/android-app/app/build/outputs/apk/debug/app-debug.apk`
  (3.18 MB). Note: AGP 8.7.3 emits a non-fatal warning for compileSdk 36 (tested up
  to 35) and auto-pulled build-tools 34.0.0 as its default — build still green.
- 2026-06-01: M0 tasks 3 + 4 done. `e2e/run.sh` (OUTER `docker run --device /dev/kvm`
  → INNER) + `e2e/run-on-d-claude.sh` (rsync + remote invoke + pull artifacts)
  written and **ran green on d-claude (exit 0)**.
  - TOPOLOGY: one container, BOTH emulators. B=target console 5554 / adb 5555,
    A=controller 5556 / adb 5557. Created from `system-images;android-30;
    google_apis;x86_64`. Flags: `-no-window -gpu swiftshader_indirect -no-snapshot
    -no-audio -no-boot-anim -accel on -memory 1536 -partition-size 2048`.
  - MEMORY settled on **1536MB/emulator** (host is 8GB, ~2GB free alongside the
    pre-existing mf-e2e containers; 2x2048 wouldn't fit, 2x1536 boots reliably).
  - PLACEHOLDER assertion (all passed): both serials show `device` in `adb
    devices`; `settings put/get system e2e_probe` round-trips on B; `am start -n
    com.android.settings/.Settings` moves B's `dumpsys window mCurrentFocus` from
    NexusLauncher → com.android.settings.Settings; `input keyevent`/`input tap`
    dispatch to B (final screenshot shows the home-screen long-press popup, i.e.
    the tap landed). Proves the harness can drive an emulator end-to-end.
  - RUNTIME ~3.5 min cold (B booted +91s, A +98s from launch; asserts ~20s;
    self-cleaning trap kills emulators + deletes AVDs → host returns to 0 qemu).
  - Artifacts to mounted `/artifacts` → pulled to `e2e/artifacts/` (gitignored):
    adb-devices.txt, logcat-*.txt, emulator-*.log, screen-*.png (1080x1920).
  - KEY FIX / GOTCHA: the emulator sdkmanager currently installs (**v36.5.11**)
    SEGFAULTS under KVM-in-Docker on d-claude — every launch (any -gpu/-cpu/
    -feature combo, even a single emulator, RAM ample, KVM RW-accessible to root)
    stalls all vCPU threads ("detected a hanging thread 'QEMU2 CPU0 thread'. No
    response for ~19000 ms") right after "Starting QEMU main loop" then core-dumps
    at ~40s, so it never boots. Pinned the emulator binary to build **11237101
    (v33.1.24)** in `e2e/Dockerfile` (overlay sdkmanager's emulator, keep its
    package.xml) — boots API 30 cleanly. Also dropped `-no-metrics` (v33.x rejects
    it). run.sh's `wait_boot` was hardened: every adb poll wrapped in `timeout 15`
    and it bails if the emulator PID dies, so a crashed emulator can never hang the
    harness on `adb wait-for-device` (the original first-run failure mode).

---

## Backlog (next milestones — see master plan for full accept criteria)
- M1 — Native stack cross-compiled for Android x86_64 — **DONE (audit passed
  2026-06-01)**; arm64-v8a still TODO (deferred to M4).
- M2 — Android client app wraps `libscrcpy.so` (connects to B, shows screen,
  touches propagate).
- M3 — Full GUI-automation e2e: uiautomator taps A's remote view, assert B reacts.
- M4 — Reproducibility/flake-hunt/arm64/review until audit says fully realized.
