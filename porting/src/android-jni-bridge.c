//
//  android-jni-bridge.c
//  scrcpy-mobile (Android)
//
//  JNI bridge between the Android app (net.scrcpy.android.NativeBridge) and the
//  native scrcpy client. Compiled INTO libscrcpy.so (added to
//  scrcpy-android-CMakeLists.txt) so the bridge symbol is exported from the same
//  .so the app already loads — no separate JNI lib needed.
//
//  Provides:
//    * Java_net_scrcpy_android_NativeBridge_runScrcpy — converts a Java String[]
//      to argc/argv and calls scrcpy_main() on the calling (worker) thread.
//    * A STRONG ScrcpyUpdateStatus() override (the iOS app provides the iOS one;
//      the Android default in android-stubs.c is weak) that logs status + message
//      under the "scrcpy" logcat tag, and forwards to a Java callback when one is
//      registered.
//    * JNI_OnLoad — caches the JavaVM* for later native->Java callbacks.
//
//  iOS is untouched: this file is guarded by __ANDROID__ and is NOT in the iOS
//  CMakeLists.
//
#if defined(__ANDROID__)

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include "scrcpy-porting.h"   // int scrcpy_main(int, char**); enum ScrcpyStatus

#define SCRCPY_LOG_TAG "scrcpy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  SCRCPY_LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  SCRCPY_LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, SCRCPY_LOG_TAG, __VA_ARGS__)

// Cached JavaVM, captured in JNI_OnLoad, used to forward status to Java.
static JavaVM *g_vm = NULL;

JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void) reserved;
    g_vm = vm;
    LOGI("JNI_OnLoad: cached JavaVM=%p", (void *) vm);
    return JNI_VERSION_1_6;
}

// Convert a Java String[] into a NULL-terminated char** argv (argc out-param).
// Returns NULL on allocation failure. Caller frees with free_argv().
static char **
build_argv(JNIEnv *env, jobjectArray jargs, int *out_argc) {
    jsize n = (*env)->GetArrayLength(env, jargs);
    char **argv = calloc((size_t) n + 1, sizeof(char *));
    if (!argv) {
        return NULL;
    }
    int argc = 0;
    for (jsize i = 0; i < n; i++) {
        jstring js = (jstring) (*env)->GetObjectArrayElement(env, jargs, i);
        if (!js) {
            argv[argc++] = strdup("");
            continue;
        }
        const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
        argv[argc++] = strdup(utf ? utf : "");
        if (utf) {
            (*env)->ReleaseStringUTFChars(env, js, utf);
        }
        (*env)->DeleteLocalRef(env, js);
    }
    argv[argc] = NULL;
    *out_argc = argc;
    return argv;
}

static void
free_argv(char **argv, int argc) {
    if (!argv) {
        return;
    }
    for (int i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
}

// JNIEXPORT jint Java_net_scrcpy_android_NativeBridge_runScrcpy(String[] args)
// Runs scrcpy_main on the calling thread (the app calls this from a worker
// Thread). Blocks until scrcpy_main returns. Returns the int exit code, or -1 on
// argv build failure.
JNIEXPORT jint JNICALL
Java_net_scrcpy_android_NativeBridge_runScrcpy(JNIEnv *env, jclass clazz,
                                               jobjectArray jargs) {
    (void) clazz;
    int argc = 0;
    char **argv = build_argv(env, jargs, &argc);
    if (!argv) {
        LOGE("runScrcpy: failed to allocate argv");
        return -1;
    }

    LOGI("runScrcpy: entering scrcpy_main with argc=%d", argc);
    for (int i = 0; i < argc; i++) {
        LOGI("runScrcpy: argv[%d]=%s", i, argv[i]);
    }

    int rc = scrcpy_main(argc, argv);

    LOGI("runScrcpy: scrcpy_main returned %d", rc);
    free_argv(argv, argc);
    return (jint) rc;
}

// SDL Android entry point. SDLActivity.nativeRunMain() dlsym's this name (the
// ScrcpyActivity overrides getMainFunction() to return "scrcpy_android_main")
// from getMainSharedObject() (libscrcpy.so) and calls it on the dedicated SDL
// thread once the SDLActivity surface is ready. So SDL_CreateWindow() inside
// scrcpy_main returns the real SDLActivity surface, video renders into it, and
// the SDLSurface's touch events feed scrcpy's controller with no extra wiring.
//
// SDL passes argv[0] = the app/library name and argv[1..] = getArguments().
// Must be exported (default visibility) so SDLActivity can dlsym it.
__attribute__((visibility("default")))
JNIEXPORT int
scrcpy_android_main(int argc, char **argv) {
    LOGI("scrcpy_android_main: argc=%d", argc);
    for (int i = 0; i < argc; i++) {
        LOGI("scrcpy_android_main: argv[%d]=%s", i, argv[i] ? argv[i] : "(null)");
    }
    int rc = scrcpy_main(argc, argv);
    LOGI("scrcpy_android_main: scrcpy_main returned %d", rc);
    return rc;
}

// STRONG override of the weak ScrcpyUpdateStatus default (android-stubs.c).
// Logs the status enum + message, and forwards to a static Java callback
// net.scrcpy.android.NativeBridge.onScrcpyStatus(int, String) if it resolves.
// Logging is the must-have; the Java forward is best-effort and never throws.
void
ScrcpyUpdateStatus(enum ScrcpyStatus status, const char *message) {
    LOGI("ScrcpyUpdateStatus: status=%d message=%s",
         (int) status, message ? message : "(null)");

    if (!g_vm) {
        return;
    }

    JNIEnv *env = NULL;
    int attached = 0;
    jint gs = (*g_vm)->GetEnv(g_vm, (void **) &env, JNI_VERSION_1_6);
    if (gs == JNI_EDETACHED) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) {
            LOGW("ScrcpyUpdateStatus: AttachCurrentThread failed");
            return;
        }
        attached = 1;
    } else if (gs != JNI_OK || !env) {
        return;
    }

    jclass cls = (*env)->FindClass(env, "net/scrcpy/android/NativeBridge");
    if (cls) {
        jmethodID mid = (*env)->GetStaticMethodID(env, cls, "onScrcpyStatus",
                                                  "(ILjava/lang/String;)V");
        if (mid) {
            jstring jmsg = (*env)->NewStringUTF(env, message ? message : "");
            (*env)->CallStaticVoidMethod(env, cls, mid, (jint) status, jmsg);
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
            }
            if (jmsg) {
                (*env)->DeleteLocalRef(env, jmsg);
            }
        } else {
            // No Java callback registered yet; clear any pending lookup exception.
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
            }
        }
        (*env)->DeleteLocalRef(env, cls);
    } else {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
    }

    if (attached) {
        (*g_vm)->DetachCurrentThread(g_vm);
    }
}

#endif // __ANDROID__
