package net.scrcpy.android

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Launcher Activity for the scrcpy-android controller app (WIP).
 *
 * M2 task 2: load the native libs (libSDL2.so + libscrcpy.so) and invoke
 * scrcpy_main(argc, argv) on a worker thread via [NativeBridge]. For this task
 * we pass `scrcpy --help` so the native entrypoint returns without needing a
 * device (the real target args + remote view come in M2 task 3). Status updates
 * surfaced from native code (ScrcpyUpdateStatus) are shown in the TextView.
 */
class MainActivity : AppCompatActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var statusView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        statusView = TextView(this).apply {
            text = getString(R.string.wip_message)
            gravity = Gravity.CENTER
            textSize = 16f
        }
        setContentView(statusView)

        // Surface native status updates onto the UI thread.
        NativeBridge.statusListener = { status, message ->
            mainHandler.post {
                statusView.text = "scrcpy status=$status\n$message"
            }
        }

        // Load libs + call scrcpy_main on a worker thread (it blocks).
        Thread({
            try {
                NativeBridge.load()
                setStatus("Native libs loaded; calling scrcpy_main --help")
                Log.i(TAG, "Calling NativeBridge.runScrcpy(scrcpy --help)")
                val rc = NativeBridge.runScrcpy(arrayOf("scrcpy", "--help"))
                Log.i(TAG, "NativeBridge.runScrcpy returned $rc")
                setStatus("scrcpy_main --help returned $rc")
            } catch (t: Throwable) {
                Log.e(TAG, "runScrcpy failed", t)
                setStatus("runScrcpy failed: ${t.message}")
            }
        }, "scrcpy-native").start()
    }

    private fun setStatus(text: String) {
        mainHandler.post { statusView.text = text }
    }

    companion object {
        private const val TAG = "scrcpy"
    }
}
