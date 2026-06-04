package net.scrcpy.e2edraw

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Deterministic e2e DRAWING target (drawing-e2e milestone D1).
 *
 * A single full-screen WHITE Activity that captures touch STROKES (DOWN -> MOVE*
 * -> UP) via a custom non-clickable [DrawView.onTouchEvent], draws each stroke as
 * a thick bright-red (`#FF0000`) anti-aliased polyline onto a PERSISTENT Bitmap so
 * the drawing accumulates and is visible, and records the resulting geometry
 * through THREE independent channels (mirroring the tap [TargetActivity]):
 *
 *   1. FILE   — `filesDir/e2e_draw.txt`, rewritten on every stroke so it always
 *      reflects ALL strokes so far. One line per stroke:
 *        `STROKE n points=K start=x0,y0 end=xN,yN bbox=minx,miny,maxx,maxy`
 *      followed by a summary line `strokes=N`. Single touches (taps) ALSO get a
 *      `taps=N last=X,Y` line so `lib-automation.sh`'s 2-tap calibration still
 *      works against this app. Read on API 30+ via:
 *        `adb shell run-as net.scrcpy.e2edraw cat files/e2e_draw.txt`
 *   2. LOGCAT — per stroke `Log.i("E2E_DRAW", "stroke #n points=K start=.. end=.. bbox=..")`
 *      and per tap `Log.i("E2E_DRAW", "tap #N at X,Y")`.
 *   3. ON-SCREEN TEXT — a small, top-left, semi-transparent [TextView] whose text
 *      AND content-description = `strokes=N` (readable by `uiautomator dump`),
 *      sized/placed so it does NOT obscure the canvas the red-pixel detector reads.
 *
 * Coordinates are recorded in DEVICE PIXELS via [MotionEvent.getX]/getY (rounded
 * to Int). The view fills the whole screen, so the touch coordinate equals the
 * `adb shell input swipe/tap` coordinate (within rounding).
 *
 * TAP vs STROKE classification: a stroke is classified as a TAP when it has <= 1
 * recorded MOVE-distinct point AND its bbox is within [TAP_SLOP_PX] in both axes
 * (i.e. a DOWN+UP with negligible movement). Anything larger is a real stroke.
 *
 * Fullscreen white, no system bars, keepScreenOn, sensor orientation.
 */
class DrawActivity : Activity() {

    private lateinit var drawView: DrawView
    private lateinit var label: TextView

    /** All finalized strokes (each a list of device-px points). */
    private val strokes = ArrayList<Stroke>()
    /** Count of strokes classified as single taps (for lib-automation calibration). */
    private var taps = 0
    private var lastTapX = -1
    private var lastTapY = -1

    private val stateFile: File
        get() = File(filesDir, STATE_FILE_NAME)

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val root = FrameLayout(this)

        drawView = DrawView(this) { stroke -> onStrokeFinished(stroke) }
        root.addView(
            drawView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Small, top-left, semi-transparent overlay so it never obscures the
        // canvas region the red-pixel detector samples.
        label = TextView(this).apply {
            gravity = Gravity.START or Gravity.TOP
            textSize = 12f
            setTextColor(Color.argb(160, 0, 0, 0))
            setBackgroundColor(Color.argb(60, 255, 255, 255))
            setPadding(6, 2, 6, 2)
            isClickable = false
            isFocusable = false
        }
        root.addView(
            label,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.START or Gravity.TOP,
            ),
        )

        setContentView(root)

        hideSystemBars()
        render()
        // Reset persisted state on launch so the file channel starts clean.
        writeStateFile()
        Log.i(TAG, "DrawActivity created; ${summaryString()}")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun onStrokeFinished(stroke: Stroke) {
        strokes.add(stroke)
        val n = strokes.size
        val isTap = stroke.isTap()
        if (isTap) {
            taps += 1
            lastTapX = stroke.startX
            lastTapY = stroke.startY
            Log.i(TAG, "tap #$taps at $lastTapX,$lastTapY")
        }
        Log.i(
            TAG,
            "stroke #$n points=${stroke.points} " +
                "start=${stroke.startX},${stroke.startY} " +
                "end=${stroke.endX},${stroke.endY} " +
                "bbox=${stroke.minX},${stroke.minY},${stroke.maxX},${stroke.maxY}",
        )
        render()
        writeStateFile()
    }

    /** "strokes=N" — the on-screen / content-desc representation. */
    private fun summaryString(): String = "strokes=${strokes.size}"

    private fun render() {
        val s = summaryString()
        label.text = s
        label.contentDescription = s
    }

    /**
     * Channel 1: rewrite the WHOLE file each stroke so it always reflects every
     * stroke so far. One `STROKE ...` line per stroke, then a `taps=N last=X,Y`
     * line (for lib-automation calibration), then the `strokes=N` summary.
     */
    private fun writeStateFile() {
        try {
            val sb = StringBuilder()
            strokes.forEachIndexed { i, s ->
                sb.append("STROKE ").append(i + 1)
                    .append(" points=").append(s.points)
                    .append(" start=").append(s.startX).append(',').append(s.startY)
                    .append(" end=").append(s.endX).append(',').append(s.endY)
                    .append(" bbox=").append(s.minX).append(',').append(s.minY)
                    .append(',').append(s.maxX).append(',').append(s.maxY)
                    .append('\n')
            }
            sb.append("taps=").append(taps)
                .append(" last=").append(lastTapX).append(',').append(lastTapY)
                .append('\n')
            sb.append("strokes=").append(strokes.size).append('\n')
            stateFile.writeText(sb.toString())
        } catch (e: Exception) {
            Log.w(TAG, "could not write state file: ${e.message}")
        }
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { c ->
                c.hide(
                    android.view.WindowInsets.Type.statusBars() or
                        android.view.WindowInsets.Type.navigationBars(),
                )
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
        const val TAG = "E2E_DRAW"
        const val STATE_FILE_NAME = "e2e_draw.txt"

        /**
         * Movement threshold (device px) classifying a DOWN+UP as a TAP rather
         * than a stroke. If the bbox of the gesture spans <= this in BOTH axes
         * AND it has at most one move-distinct point, it is a tap. 16 px is a few
         * px larger than a typical ViewConfiguration touch slop, comfortably
         * absorbing jitter from `input tap` while still classifying any real
         * `input swipe` (which spans tens-to-hundreds of px) as a stroke.
         */
        const val TAP_SLOP_PX = 16
    }
}

/** A finalized stroke: geometry in device pixels. */
data class Stroke(
    val points: Int,
    val startX: Int,
    val startY: Int,
    val endX: Int,
    val endY: Int,
    val minX: Int,
    val minY: Int,
    val maxX: Int,
    val maxY: Int,
) {
    fun isTap(): Boolean =
        points <= 1 &&
            abs(maxX - minX) <= DrawActivity.TAP_SLOP_PX &&
            abs(maxY - minY) <= DrawActivity.TAP_SLOP_PX
}

/**
 * Custom, deliberately NON-clickable drawing view. A clickable/focusable view
 * would let `View.onTouchEvent` consume ACTION_DOWN and we'd never see MOVE/UP —
 * the exact bug the tap target app hit. We keep it non-clickable and return true
 * from [onTouchEvent] for the gesture we handle, so the whole DOWN->MOVE*->UP
 * sequence is delivered here.
 */
@SuppressLint("ViewConstructor")
class DrawView(
    context: android.content.Context,
    private val onStroke: (Stroke) -> Unit,
) : View(context) {

    private var bitmap: Bitmap? = null
    private var bitmapCanvas: Canvas? = null

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FF0000")
        style = Paint.Style.STROKE
        strokeWidth = 12f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    // Current stroke accumulation, in device px.
    private var count = 0
    private var startX = 0
    private var startY = 0
    private var lastX = 0
    private var lastY = 0
    private var minX = 0
    private var minY = 0
    private var maxX = 0
    private var maxY = 0

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0) {
            // Recreate the persistent bitmap, preserving any prior drawing.
            val old = bitmap
            val nb = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val nc = Canvas(nb)
            if (old != null) nc.drawBitmap(old, 0f, 0f, null)
            bitmap = nb
            bitmapCanvas = nc
            invalidate()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        val x = event.x.roundToInt()
        val y = event.y.roundToInt()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                count = 1
                startX = x; startY = y
                lastX = x; lastY = y
                minX = x; minY = y; maxX = x; maxY = y
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                // Draw the segment from the previous point onto the persistent bitmap.
                bitmapCanvas?.drawLine(
                    lastX.toFloat(), lastY.toFloat(), x.toFloat(), y.toFloat(), paint,
                )
                count += 1
                lastX = x; lastY = y
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                // Finalize. A pure DOWN+UP (no MOVE) leaves no segment; stamp a
                // dot so even taps leave a (small) visible mark and the canvas is
                // consistent with the recorded geometry.
                if (count <= 1) {
                    bitmapCanvas?.drawPoint(x.toFloat(), y.toFloat(), paint)
                }
                lastX = x; lastY = y
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
                invalidate()
                onStroke(
                    Stroke(
                        points = count,
                        startX = startX, startY = startY,
                        endX = x, endY = y,
                        minX = minX, minY = minY, maxX = maxX, maxY = maxY,
                    ),
                )
                return true
            }
            MotionEvent.ACTION_CANCEL -> return true
        }
        return super.onTouchEvent(event)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        // White canvas (the Light theme background is already white, but draw it
        // explicitly so the bitmap region is unambiguously white where unpainted).
        canvas.drawColor(Color.WHITE)
        bitmap?.let { canvas.drawBitmap(it, 0f, 0f, null) }
    }
}
