package dev.aarav.s1toolkit

import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

/**
 * One screen: enter the scooter's link-local IPv6 address once, then tap
 * through to the stock Android screens that already exist on the head
 * unit (Settings, an AOSP browser if present) or run a one-off command.
 *
 * Nothing here downloads or installs a prebuilt APK from anywhere --
 * every action is just a short `am start` / `input` command sent over the
 * same root channel the python CLI uses.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var addressInput: EditText
    private lateinit var logView: TextView
    private lateinit var logScroll: ScrollView
    private var client: ScooterClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        addressInput = findViewById(R.id.addressInput)
        logView = findViewById(R.id.logView)
        logScroll = findViewById(R.id.logScroll)

        findViewById<Button>(R.id.connectButton).setOnClickListener { connect() }
        findViewById<Button>(R.id.settingsButton).setOnClickListener {
            runAction("Settings") { it.openIntent("android.settings.SETTINGS") }
        }
        findViewById<Button>(R.id.wifiButton).setOnClickListener {
            runAction("Wi-Fi settings") { it.openIntent("android.settings.WIFI_SETTINGS") }
        }
        findViewById<Button>(R.id.browserButton).setOnClickListener {
            runAction("browser") {
                val candidates = listOf(
                    "com.android.browser/.BrowserActivity",
                    "com.android.htmlviewer/.HTMLViewerActivity")
                var result = Pair(-1, "")
                for (c in candidates) {
                    result = it.openComponent(c)
                    if (result.first == 0 || result.first == 1) break
                }
                result
            }
        }
        findViewById<Button>(R.id.homeButton).setOnClickListener {
            runAction("home") { it.openComponent("com.olaelectric.hmiclient/.MainActivity") }
        }
        findViewById<Button>(R.id.backButton).setOnClickListener {
            runAction("back key") { it.sendKeyEvent(4) }
        }
        findViewById<Button>(R.id.infoButton).setOnClickListener {
            runAction("device info") { it.exec("getprop ro.build.version.release") }
        }

        val shellInput = findViewById<EditText>(R.id.shellInput)
        findViewById<Button>(R.id.shellRunButton).setOnClickListener {
            val cmd = shellInput.text.toString()
            if (cmd.isNotBlank()) {
                runAction("shell: $cmd") { it.shell(cmd) }
            }
        }
    }

    private fun connect() {
        val address = addressInput.text.toString().trim()
        if (address.isEmpty()) {
            Toast.makeText(this, "Enter the scooter's IPv6 address first", Toast.LENGTH_SHORT).show()
            return
        }
        log("Connecting to $address ...")
        lifecycleScope.launch {
            try {
                client?.close()
                val c = ScooterClient(address)
                c.connect()
                client = c
                log("Connected.")
            } catch (e: Exception) {
                log("Connection failed: ${e.message}")
            }
        }
    }

    private fun runAction(label: String, block: suspend (ScooterClient) -> Pair<Int, String>) {
        val c = client
        if (c == null) {
            Toast.makeText(this, "Connect first", Toast.LENGTH_SHORT).show()
            return
        }
        log("-> $label")
        lifecycleScope.launch {
            try {
                val (status, message) = block(c)
                log("   status=$status ${message.take(300)}")
            } catch (e: Exception) {
                log("   error: ${e.message}")
            }
        }
    }

    private fun log(line: String) {
        runOnUiThread {
            logView.append(line + "\n")
            logScroll.post { logScroll.fullScroll(android.view.View.FOCUS_DOWN) }
        }
    }

    override fun onDestroy() {
        client?.close()
        super.onDestroy()
    }
}
