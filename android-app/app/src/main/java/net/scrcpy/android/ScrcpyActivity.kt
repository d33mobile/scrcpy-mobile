package net.scrcpy.android

import android.content.Intent
import android.os.Bundle
import android.util.Log
import org.libsdl.app.SDLActivity
import java.io.File

/**
 * Runs scrcpy under SDL's Android infrastructure.
 *
 * By extending [SDLActivity] we get the full SDL Android lifecycle: SDL creates
 * the GL/Surface-backed window from THIS Activity, spins up its native thread,
 * and then dlsym's [getMainFunction] ("scrcpy_android_main") from
 * [getMainSharedObject] (libscrcpy.so) and calls it on the SDL thread once the
 * surface is ready. So `SDL_CreateWindow` inside scrcpy_main returns the real
 * SDLSurface, video renders into it, and the SDLSurface's touch/key events feed
 * scrcpy's controller automatically — no extra wiring on the Java side.
 *
 * Launch with `host` + `port` String extras (an ADB-over-TCP target, e.g. the
 * emulator's `adb tcpip` endpoint). The argv mirrors the iOS ADB-over-TCP client
 * (ScrcpyADBClient.m): same option set, but the connection target is expressed as
 * scrcpy's own `--tcpip=HOST:PORT` (the in-process adb host in libscrcpy.so does
 * the `adb connect`), instead of the iOS app's pre-`adb connect` + `--serial`.
 */
class ScrcpyActivity : SDLActivity() {

    /**
     * Point the native process $HOME at our app-writable cacheDir BEFORE SDL
     * starts the thread that runs scrcpy_main. scrcpy's in-process adb host
     * derives its auth key store from $HOME/.android and FATAL-aborts (SIGABRT)
     * if it cannot create it; an app uid's default passwd home is the unwritable
     * "/data". super.onCreate() has already run SDLActivity.loadLibraries() (which
     * System.loadLibrary's libscrcpy.so, where this native method lives), so the
     * symbol is bound by the time we call it here.
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        nativeSetHome(cacheDir.absolutePath)
        nativeSetServerPath(deployServer())
    }

    private external fun nativeSetHome(home: String)

    /**
     * Sets SCRCPY_SERVER_PATH in the native environment. scrcpy reads this env
     * (server.c: get_server_path) to locate the local scrcpy-server file and
     * `adb push`es it to /data/local/tmp/scrcpy-server.jar on the target. There
     * is no install prefix on Android, so the app ships the server as an asset
     * and points scrcpy at the copy in its filesDir. Mirrors iOS setupScrcpyEnvs.
     */
    private external fun nativeSetServerPath(path: String)

    /**
     * Copy the bundled scrcpy-server asset into the app's filesDir (an
     * app-readable path the native lib can stat/read) and return its absolute
     * path. Re-copies if the asset size differs (cheap, idempotent across runs).
     */
    private fun deployServer(): String {
        val dest = File(filesDir, SERVER_FILENAME)
        try {
            assets.open(SERVER_FILENAME).use { input ->
                val bytes = input.readBytes()
                if (!dest.exists() || dest.length() != bytes.size.toLong()) {
                    dest.outputStream().use { it.write(bytes) }
                }
                Log.i("scrcpy", "deployServer: $dest (${dest.length()} bytes)")
            }
        } catch (t: Throwable) {
            Log.e("scrcpy", "deployServer: failed to stage scrcpy-server asset", t)
        }
        return dest.absolutePath
    }

    /**
     * Load order (each is `System.loadLibrary`'d by SDL.loadLibrary before the
     * main function runs): c++_shared and SDL2 are NEEDED by libscrcpy.so, so
     * they must come first; scrcpy last (it is also the main shared object, see
     * [getMainSharedObject]).
     */
    override fun getLibraries(): Array<String> =
        arrayOf("c++_shared", "SDL2", "scrcpy")

    /**
     * The main shared object that [getMainFunction] is dlsym'd from. Default SDL
     * derives `libmain.so` from the last [getLibraries] entry; here we point at
     * the packaged libscrcpy.so explicitly via its absolute path.
     */
    override fun getMainSharedObject(): String =
        "${applicationInfo.nativeLibraryDir}/libscrcpy.so"

    /**
     * Our exported native entry (porting/src/android-jni-bridge.c) instead of the
     * default `SDL_main`. It just calls `scrcpy_main(argc, argv)`.
     */
    override fun getMainFunction(): String = "scrcpy_android_main"

    /**
     * scrcpy argv (SDL prepends argv[0] = the app/library name). Mirrors the iOS
     * ADB-over-TCP argv from ScrcpyADBClient.m, with the target as `--tcpip`.
     */
    override fun getArguments(): Array<String> {
        val host = intent.getStringExtra(EXTRA_HOST)?.takeIf { it.isNotBlank() } ?: "127.0.0.1"
        val port = intent.getStringExtra(EXTRA_PORT)?.takeIf { it.isNotBlank() } ?: "5555"
        // --no-audio: the AVD/emulator has no usable audio-capture HAL, so the
        // server's audio capture fails ("Audio capture error") and aborts the
        // whole session before it reaches Connected. Audio is optional for the
        // remote-view/control path; disable it (overridable via the "noAudio"
        // extra). Without it, scrcpy never gets to ScrcpyStatusConnected here.
        val noAudio = intent.getBooleanExtra(EXTRA_NO_AUDIO, true)
        val args = mutableListOf(
            "--tcpip=$host:$port",
            "--video-codec=h264",
            "--video-bit-rate=4M",
            "--video-buffer=0",
            "--audio-buffer=150",
            "--audio-output-buffer=10",
            "--print-fps",
            "--stay-awake",
            "--shortcut-mod=lctrl,rctrl,lalt,ralt",
        )
        if (noAudio) args.add("--no-audio")
        return args.toTypedArray()
    }

    companion object {
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_NO_AUDIO = "noAudio"
        private const val SERVER_FILENAME = "scrcpy-server"

        fun newIntent(context: android.content.Context, host: String, port: String): Intent =
            Intent(context, ScrcpyActivity::class.java)
                .putExtra(EXTRA_HOST, host)
                .putExtra(EXTRA_PORT, port)
    }
}
