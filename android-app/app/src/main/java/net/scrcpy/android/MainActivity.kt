package net.scrcpy.android

import android.os.Bundle
import android.view.Gravity
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Stub launcher Activity for the scrcpy-android controller app (WIP).
 *
 * For now it only shows a placeholder TextView. Later milestones wrap the
 * native libscrcpy.so and render the remote device's screen here.
 */
class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this).apply {
            text = getString(R.string.wip_message)
            gravity = Gravity.CENTER
            textSize = 18f
        }
        setContentView(text)
    }
}
