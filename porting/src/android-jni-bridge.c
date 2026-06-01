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
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <android/log.h>

#include "scrcpy-porting.h"   // int scrcpy_main(int, char**); enum ScrcpyStatus

#define SCRCPY_LOG_TAG "scrcpy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  SCRCPY_LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  SCRCPY_LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, SCRCPY_LOG_TAG, __VA_ARGS__)

// scrcpy installs its own SDL log handler (sc_sdl_log_print) that writes every
// diagnostic to stdout/stderr via fprintf. On Android those fds are discarded,
// so scrcpy's own connect/server/tunnel errors are INVISIBLE in logcat. Redirect
// stdout+stderr into a pipe and pump it to logcat under the "scrcpy" tag so the
// native client's diagnostics (and any failure reason) are observable. Idempotent.
static void *
stdio_pump(void *arg) {
    int fd = (int) (intptr_t) arg;
    char buf[512];
    size_t used = 0;
    ssize_t n;
    while ((n = read(fd, buf + used, sizeof(buf) - 1 - used)) > 0) {
        used += (size_t) n;
        buf[used] = '\0';
        char *start = buf, *nl;
        while ((nl = strchr(start, '\n')) != NULL) {
            *nl = '\0';
            __android_log_write(ANDROID_LOG_INFO, SCRCPY_LOG_TAG, start);
            start = nl + 1;
        }
        // Shift any partial line to the front.
        used = strlen(start);
        memmove(buf, start, used + 1);
        if (used == sizeof(buf) - 1) {   // overlong line; flush it
            __android_log_write(ANDROID_LOG_INFO, SCRCPY_LOG_TAG, buf);
            used = 0;
        }
    }
    return NULL;
}

static void
redirect_stdio_to_logcat(void) {
    static int done = 0;
    if (done) {
        return;
    }
    done = 1;

    // Also tee scrcpy's stdout/stderr to a file under $HOME (the app's writable
    // cacheDir) so the diagnostics survive even if logd/the pump races with a
    // fast scrcpy_main exit — the harness pulls $HOME/scrcpy-stdio.log.
    const char *home = getenv("HOME");
    if (home && *home) {
        char path[512];
        snprintf(path, sizeof(path), "%s/scrcpy-stdio.log", home);
        int lf = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (lf >= 0) {
            setvbuf(stdout, NULL, _IONBF, 0);
            setvbuf(stderr, NULL, _IONBF, 0);
            dup2(lf, STDOUT_FILENO);
            dup2(lf, STDERR_FILENO);
            close(lf);
            LOGI("redirect_stdio_to_logcat: stdout/stderr -> %s", path);
            return;
        }
        LOGW("redirect_stdio_to_logcat: open(%s) failed: %s", path,
             strerror(errno));
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        LOGW("redirect_stdio_to_logcat: pipe() failed: %s", strerror(errno));
        return;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    dup2(pipefd[1], STDOUT_FILENO);
    dup2(pipefd[1], STDERR_FILENO);
    close(pipefd[1]);
    pthread_t t;
    if (pthread_create(&t, NULL, stdio_pump, (void *) (intptr_t) pipefd[0]) != 0) {
        LOGW("redirect_stdio_to_logcat: pthread_create failed");
        close(pipefd[0]);
        return;
    }
    pthread_detach(t);
    LOGI("redirect_stdio_to_logcat: stdout/stderr -> logcat tag '%s'",
         SCRCPY_LOG_TAG);
}

// Cached JavaVM, captured in JNI_OnLoad, used to forward status to Java.
static JavaVM *g_vm = NULL;

// Is `dir` an existing, writable directory?
static int
dir_is_writable(const char *dir) {
    if (!dir || !*dir) {
        return 0;
    }
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        return 0;
    }
    return access(dir, W_OK) == 0;
}

// scrcpy's in-process adb host calls adb_get_android_dir_path(), which does
// `mkdir("$HOME/.android")` and FATAL-aborts (SIGABRT) if it can't — fatal on an
// Android app uid, whose default passwd home is the unwritable "/data". Ensure
// HOME points at an app-writable dir BEFORE scrcpy_main runs so the adb auth key
// store lands somewhere we can write.
//
// We never hardcode the package name in this generic lib: Android sets TMPDIR to
// the app's per-uid cache dir (e.g. /data/user/0/<pkg>/cache) for every app
// process, which is always app-writable. We honour an explicit, writable HOME if
// one is already set; otherwise we derive it from TMPDIR.
static void
ensure_writable_home(void) {
    const char *home = getenv("HOME");
    if (dir_is_writable(home)) {
        LOGI("ensure_writable_home: HOME=%s already writable", home);
        return;
    }

    const char *tmpdir = getenv("TMPDIR");
    if (!dir_is_writable(tmpdir)) {
        LOGW("ensure_writable_home: neither HOME='%s' nor TMPDIR='%s' is a "
             "writable dir; leaving HOME unset (adb auth may abort)",
             home ? home : "(null)", tmpdir ? tmpdir : "(null)");
        return;
    }

    if (setenv("HOME", tmpdir, 1) != 0) {
        LOGE("ensure_writable_home: setenv(HOME,%s) failed: %s",
             tmpdir, strerror(errno));
        return;
    }
    LOGI("ensure_writable_home: set HOME=%s (from TMPDIR) for adb auth store",
         tmpdir);
}

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

// JNIEXPORT void Java_net_scrcpy_android_ScrcpyActivity_nativeSetHome(String)
// Sets the process $HOME to a caller-provided, app-writable directory (the app
// passes its cacheDir). scrcpy's in-process adb host derives its auth key store
// from $HOME/.android and FATAL-aborts if it can't create it; an Android app
// uid's default passwd home is the unwritable "/data". The app calls this from
// ScrcpyActivity.onCreate() — i.e. BEFORE SDL starts the native thread that runs
// scrcpy_main — so the adb server thread sees a writable HOME.
JNIEXPORT void JNICALL
Java_net_scrcpy_android_ScrcpyActivity_nativeSetHome(JNIEnv *env, jclass clazz,
                                                     jstring jhome) {
    (void) clazz;
    if (!jhome) {
        LOGW("nativeSetHome: null path");
        return;
    }
    const char *home = (*env)->GetStringUTFChars(env, jhome, NULL);
    if (!home) {
        return;
    }
    if (dir_is_writable(home)) {
        if (setenv("HOME", home, 1) == 0) {
            LOGI("nativeSetHome: HOME=%s (app-writable, for adb auth store)", home);
        } else {
            LOGE("nativeSetHome: setenv(HOME,%s) failed: %s", home, strerror(errno));
        }
    } else {
        LOGW("nativeSetHome: '%s' is not a writable dir; HOME unchanged", home);
    }
    (*env)->ReleaseStringUTFChars(env, jhome, home);
}

// JNIEXPORT void Java_net_scrcpy_android_ScrcpyActivity_nativeSetServerPath(String)
// Sets the SCRCPY_SERVER_PATH env to a caller-provided path to the bundled
// scrcpy-server file. scrcpy's get_server_path() reads SCRCPY_SERVER_PATH and
// pushes that file to /data/local/tmp/scrcpy-server.jar on the target device.
// On Android there is no compiled-in install prefix that would hold the server,
// so the app must point scrcpy at the server it ships as an asset (copied to its
// filesDir). This mirrors the iOS app's setupScrcpyEnvs (ScrcpyADBClient.m).
// Called from ScrcpyActivity.onCreate() — BEFORE SDL starts the scrcpy_main
// thread — so server.c sees the env when it runs.
JNIEXPORT void JNICALL
Java_net_scrcpy_android_ScrcpyActivity_nativeSetServerPath(JNIEnv *env,
                                                           jclass clazz,
                                                           jstring jpath) {
    (void) clazz;
    if (!jpath) {
        LOGW("nativeSetServerPath: null path");
        return;
    }
    const char *path = (*env)->GetStringUTFChars(env, jpath, NULL);
    if (!path) {
        return;
    }
    struct stat st;
    if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) {
        if (setenv("SCRCPY_SERVER_PATH", path, 1) == 0) {
            LOGI("nativeSetServerPath: SCRCPY_SERVER_PATH=%s (%lld bytes)",
                 path, (long long) st.st_size);
        } else {
            LOGE("nativeSetServerPath: setenv(SCRCPY_SERVER_PATH,%s) failed: %s",
                 path, strerror(errno));
        }
    } else {
        LOGE("nativeSetServerPath: '%s' is not a regular file (scrcpy push "
             "will fail)", path);
    }
    (*env)->ReleaseStringUTFChars(env, jpath, path);
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

    ensure_writable_home();
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
    redirect_stdio_to_logcat();
    LOGI("scrcpy_android_main: argc=%d", argc);
    for (int i = 0; i < argc; i++) {
        LOGI("scrcpy_android_main: argv[%d]=%s", i, argv[i] ? argv[i] : "(null)");
    }
    ensure_writable_home();
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
