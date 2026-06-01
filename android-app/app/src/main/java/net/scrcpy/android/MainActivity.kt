package net.scrcpy.android

import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * Launcher screen for the scrcpy-android controller app.
 *
 * Enter the target `host:port` (an ADB-over-TCP endpoint) and Connect. Connect
 * hands off to [ScrcpyActivity], which runs scrcpy under SDL's Android infra so
 * the remote view renders into the SDLActivity surface and touches feed scrcpy's
 * controller automatically.
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val hostInput = findViewById<EditText>(R.id.hostInput)
        val portInput = findViewById<EditText>(R.id.portInput)
        val connectButton = findViewById<Button>(R.id.connectButton)

        // Allow pre-filling the target via Intent extras (used by the e2e harness
        // for deterministic input instead of fragile soft-keyboard typing):
        //   am start -n net.scrcpy.android/.MainActivity --es host H --es port P
        intent.getStringExtra("host")?.takeIf { it.isNotBlank() }?.let { hostInput.setText(it) }
        intent.getStringExtra("port")?.takeIf { it.isNotBlank() }?.let { portInput.setText(it) }
        // Optionally auto-connect once prefilled (harness convenience).
        if (intent.getBooleanExtra("autoConnect", false)) {
            val h = hostInput.text.toString().trim()
            val p = portInput.text.toString().trim()
            if (h.isNotEmpty() && p.isNotEmpty()) {
                startActivity(ScrcpyActivity.newIntent(this, h, p))
            }
        }

        connectButton.setOnClickListener {
            val host = hostInput.text.toString().trim()
            val port = portInput.text.toString().trim()
            if (host.isEmpty() || port.isEmpty()) {
                Toast.makeText(this, R.string.error_empty_target, Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            startActivity(ScrcpyActivity.newIntent(this, host, port))
        }
    }
}
