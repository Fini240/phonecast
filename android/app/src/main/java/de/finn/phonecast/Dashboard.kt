package de.finn.phonecast

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * my-pc through the Hermes dashboard on ZimaOS (its JSON API): stats, wake, sleep, shut down,
 * boot into Linux/Windows, monitors, RGB, AI engine. The dashboard only accepts controls from
 * Tailscale addresses, so its Tailscale address works best.
 */
object Dashboard {
    /** e.g. http://<zimaos>:8765 — set in Settings or passed on by the Mac; "" = no PC tab. */
    @Volatile var base = ""

    @Volatile var stats: JSONObject? = null
        private set
    @Volatile var error: String? = null
        private set
    @Volatile private var lastPoll = 0L
    @Volatile private var polling = false

    val pc: JSONObject? get() = stats?.optJSONObject("pc")
    val online: Boolean get() = stats?.optBoolean("online") == true
    val os: String get() = pc?.optString("os") ?: ""

    /** Fetch at most every 2 s, in the background. */
    fun poll() {
        val now = System.currentTimeMillis()
        if (polling || now - lastPoll < 2000) return
        lastPoll = now; polling = true
        Thread {
            try {
                val o = if (base.isEmpty()) null else get(base)
                if (o != null) { stats = o; error = null } else error = "Dashboard not reachable at $base"
            } finally { polling = false }
        }.start()
    }

    private fun get(base: String): JSONObject? = try {
        val c = URL("$base/api/stats").openConnection() as HttpURLConnection
        c.connectTimeout = 2500; c.readTimeout = 4000
        c.inputStream.use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
    } catch (_: Exception) { null }

    /** POST an action; [done] gets the dashboard's message (on a background thread). */
    fun action(path: String, body: JSONObject, done: (String) -> Unit) {
        Thread {
            val msg = try {
                if (base.isEmpty()) throw IllegalStateException("no dashboard address set")
                val c = URL("$base/api/$path").openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.doOutput = true
                c.connectTimeout = 4000; c.readTimeout = 30000
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toString().toByteArray()) }
                val code = c.responseCode
                val text = (if (code < 400) c.inputStream else c.errorStream)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
                val o = try { JSONObject(text) } catch (_: Exception) { null }
                o?.optString("message")?.takeIf { it.isNotEmpty() } ?: o?.optString("error")?.takeIf { it.isNotEmpty() }
                    ?: if (code == 403) "Refused: turn on Tailscale on the phone" else "HTTP $code"
            } catch (e: Exception) { "Couldn't reach the dashboard over Tailscale (${e.message})" }
            lastPoll = 0
            done(msg)
        }.start()
    }
}
