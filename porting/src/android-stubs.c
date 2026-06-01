//
//  android-stubs.c
//  scrcpy-mobile
//
//  Android (NDK) build only. On iOS these symbols are provided by the host
//  app (Swift/Objective-C) and the SDL2 iOS fork. The Android client app (M2)
//  will provide its own strong overrides; these weak defaults exist so that
//  libscrcpy.so links standalone (and the smoke executable runs) taking the
//  software-decode / no-hardware-layer path.
//
//  This file is compiled ONLY into the Android build (it is not in the iOS
//  porting/cmake source list), but guard the body with !__APPLE__ defensively
//  so it is a no-op should it ever be pulled into an Apple build.
//

#if !defined(__APPLE__)

#include <stdbool.h>

// --- video/decoder hooks (decoder-porting.c / demuxer-porting.c / display-porting.c)

// 0 => hardware decoding disabled => scrcpy's normal FFmpeg software decode +
// SDL_UpdateYUVTexture rendering path runs.
__attribute__((weak))
int ScrcpyEnableHardwareDecoding(void) {
    return 0;
}

__attribute__((weak))
void ScrcpyTryResetVideo(void) {
    // no-op: the Android client app handles reconnect/reset itself.
}

// Only called when ScrcpyEnableHardwareDecoding() > 0, which never happens on
// the software path; provide a definition so the symbol resolves at link time.
__attribute__((weak))
void *ScrcpyHandleFrame(void *pending_frame) {
    return pending_frame;
}

__attribute__((weak))
bool GetUpdateApplicationBackgroundState(bool update) {
    (void) update;
    return false;
}

// --- SDL2 iOS-fork extension (display-porting.c) -------------------------------
// In the upstream/Android SDL2 there is no SDL_UpdateCommandGeneration; it is
// only reached on the hardware-decode path (disabled on Android). Provide a
// weak no-op so libscrcpy.so links against stock libSDL2.so.
struct SDL_Renderer;
__attribute__((weak))
void SDL_UpdateCommandGeneration(struct SDL_Renderer *renderer) {
    (void) renderer;
}

// --- audio volume (audio_player-porting.c) -------------------------------------
__attribute__((weak))
float ScrcpyAudioVolumeScale(float update_scale) {
    (void) update_scale;
    return 1.0f;
}

// --- AOSP adb globals (libadb-full.a) ------------------------------------------
// adb's client/adb_client.cpp references __adb_argv/__adb_envp on its
// re-exec-the-server path. That path is dead in the in-process porting build
// (adb_commandline_porting never forks a separate server), but the symbols are
// defined in AOSP's client/main.cpp, which the port excludes. Provide them here
// so libscrcpy.so resolves at load (bionic binds eagerly: DT_FLAGS BIND_NOW).
// These are plain global variables (no C++ mangling), matching the unmangled
// dynamic symbol names the adb objects import.
const char **__adb_argv = 0;
const char **__adb_envp = 0;

#endif /* !__APPLE__ */
