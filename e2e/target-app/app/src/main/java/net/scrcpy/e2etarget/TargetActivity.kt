package net.scrcpy.e2etarget

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import java.io.File

/**
 * Deterministic e2e input target (M3 task 2).
 *
 * A single full-screen Activity that captures EVERY touch ([onTouchEvent]
 * ACTION_DOWN) and makes the resulting state observable through THREE
 * independent channels so a tap at a known coordinate is an unambiguous,
 * assertable state change:
 *
 *   1. ON-SCREEN TEXT  — a full-screen [TextView] whose text AND
 *      content-description are set to  "taps=N last=X,Y"  (readable by
 *      `uiautomator dump`; the node's text/content-desc carries the value).
 *   2. LOGCAT          — `Log.i("E2E_TARGET", "tap #N at X,Y")` per tap
 *      (grep `logcat -d -s E2E_TARGET`).
 *   3. FILE            — the latest "N X Y" line written to the app's INTERNAL
 *      `filesDir/e2e_state.txt`. On API 30+ the adb shell user cannot read an
 *      app's external files dir, so we use the internal dir, which a debuggable
 *      build exposes via run-as:
 *      `adb shell run-as net.scrcpy.e2etarget cat files/e2e_state.txt`.
 *
 * Coordinates are recorded in DEVICE PIXELS via [MotionEvent.getRawX]/getRawY
 * (rounded to Int). The view fills the whole screen, so the raw coordinate of a
 * tap equals the `adb shell input tap X Y` coordinate (within rounding). This
 * lets task 4 assert the tap landed where expected, not merely that *a* tap
 * happened.
 *
 * Fullscreen, no system bars, keepScreenOn, sensor orientation.
 */
class TargetActivity : Activity() {

    private lateinit var label: TextView

    private var taps = 0
    private var lastX = -1
    private var lastY = -1

    // Internal files dir (/data/data/<pkg>/files): adb-readable via `run-as` on a
    // debuggable build, unlike the external files dir which API 30+ shell can't read.
    private val stateFile: File
        get() = File(filesDir, STATE_FILE_NAME)

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep the screen on and never let it sleep during the test.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        label = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 24f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.BLACK)
            // NOT clickable/focusable: a clickable view would consume ACTION_DOWN
            // in View.onTouchEvent and the event would never reach the Activity's
            // onTouchEvent. We capture touches at the Activity level instead (see
            // dispatchTouchEvent), so every tap is recorded regardless of view.
            isClickable = false
            isFocusable = false
        }
        setContentView(label)

        hideSystemBars()
        render()
        // Reset persisted state on launch so the file channel starts clean.
        writeStateFile()
        Log.i(TAG, "TargetActivity created; state=${stateString()}")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    // dispatchTouchEvent is invoked on the Activity for EVERY touch BEFORE the
    // view hierarchy gets a chance to consume it, so we record the tap here
    // unconditionally (then still let the event flow through via super).
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            taps += 1
            lastX = Math.round(event.rawX)
            lastY = Math.round(event.rawY)
            render()
            writeStateFile()
            // Channel 2: logcat. Exact, greppable, one line per tap.
            Log.i(TAG, "tap #$taps at $lastX,$lastY")
        }
        return super.dispatchTouchEvent(event)
    }

    /** "taps=N last=X,Y" — the on-screen / content-desc representation. */
    private fun stateString(): String = "taps=$taps last=$lastX,$lastY"

    /** Channel 1: on-screen TextView text + content-description. */
    private fun render() {
        val s = stateString()
        label.text = s
        label.contentDescription = s
    }

    /** Channel 3: persist the latest "N X Y" to the external files dir. */
    private fun writeStateFile() {
        try {
            stateFile.writeText("$taps $lastX $lastY\n")
        } catch (e: Exception) {
            Log.w(TAG, "could not write state file: ${e.message}")
        }
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { c ->
                c.hide(android.view.WindowInsets.Type.statusBars() or
                        android.view.WindowInsets.Type.navigationBars())
                c.systemBarsBehavior =
                    android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
    }

    companion object {
        const val TAG = "E2E_TARGET"
        const val STATE_FILE_NAME = "e2e_state.txt"
    }
}
