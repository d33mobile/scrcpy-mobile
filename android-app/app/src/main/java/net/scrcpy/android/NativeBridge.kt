package net.scrcpy.android

import android.util.Log

/**
 * JNI bridge to the native scrcpy client (libscrcpy.so).
 *
 * The native side (porting/src/android-jni-bridge.c, compiled into
 * libscrcpy.so) exports [runScrcpy] and forwards scrcpy status updates to
 * [onScrcpyStatus]. Load order matters: libscrcpy.so NEEDs libSDL2.so and
 * libc++_shared.so, so those must be loaded first.
 */
object NativeBridge {
    private const val TAG = "scrcpy"

    @Volatile
    private var loaded = false

    /** Optional UI listener for status updates surfaced from native code. */
    @Volatile
    var statusListener: ((Int, String) -> Unit)? = null

    /**
     * Convert the Java String[] args to argc/argv and call scrcpy_main on the
     * CALLING thread (call this from a worker thread — it blocks until
     * scrcpy_main returns). Returns scrcpy's exit code.
     */
    external fun runScrcpy(args: Array<String>): Int

    /**
     * Load the native libraries in dependency order: libc++_shared.so and
     * libSDL2.so first (libscrcpy.so NEEDs them), then libscrcpy.so itself.
     * Idempotent.
     */
    @Synchronized
    fun load() {
        if (loaded) return
        // libscrcpy.so was linked with ANDROID_STL=c++_shared and NEEDs
        // libc++_shared.so + libSDL2.so. Load deps first so the loader resolves
        // libscrcpy.so cleanly.
        System.loadLibrary("c++_shared")
        System.loadLibrary("SDL2")
        System.loadLibrary("scrcpy")
        loaded = true
        Log.i(TAG, "NativeBridge: native libraries loaded (c++_shared, SDL2, scrcpy)")
    }

    /**
     * Invoked from native code (ScrcpyUpdateStatus). Keep robust — never throw
     * back across the JNI boundary.
     */
    @JvmStatic
    fun onScrcpyStatus(status: Int, message: String) {
        Log.i(TAG, "onScrcpyStatus: status=$status message=$message")
        try {
            statusListener?.invoke(status, message)
        } catch (t: Throwable) {
            Log.w(TAG, "onScrcpyStatus: listener threw", t)
        }
    }
}
