package de.finn.phonecast

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject

/**
 * "Share → Reel to Claude": sends a reel (or any link) to the reel-inbox Claude session on the Mac
 * (a Claude chat whose folder is ~/Documents/Claude/reel-digest; its CLAUDE.md says what to do with
 * links). No session there yet → starts one. The answer comes back as the usual "agent finished"
 * notification. Mac not connected → the link waits on the phone and goes out when it connects.
 */
object ReelShare {
    const val FOLDER = "~/Documents/Claude/reel-digest"
    private const val PREFS = "reelshare"
    private val main = Handler(Looper.getMainLooper())
    private var flushing = false

    /** The first link in a share text, Instagram links cleaned of tracking parameters. */
    fun link(text: String?): String? {
        if (text == null) return null
        Regex("https?://(?:www\\.)?instagram\\.com/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)").find(text)?.let {
            return "https://www.instagram.com/p/${it.groupValues[1]}/"
        }
        return Regex("https?://\\S+").find(text)?.value?.trimEnd('.', ',', ')', '"', '\'')
    }

    /** The inbox chat: a sendable Claude session in the reel-digest folder, running ones first. */
    private fun inbox(): JSONObject? = Agents.sessions
        .filter { !it.optBoolean("sub") && it.optString("agent", "claude") == "claude" && Agents.canSend(it)
            && it.optString("host").isEmpty() && it.optString("cwd").trimEnd('/').endsWith("/reel-digest") }
        .sortedWith(compareByDescending<JSONObject> { it.optBoolean("managed") }.thenByDescending { it.optBoolean("live") })
        .firstOrNull()

    fun share(ctx: Context, url: String) {
        val a = pending(ctx).put(url)
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("q", a.toString()).apply()
        flush(ctx.applicationContext)
    }

    private fun pending(ctx: Context) = try {
        JSONArray(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("q", "[]"))
    } catch (_: Exception) { JSONArray() }

    fun flush(ctx: Context) {
        if (flushing || !Agents.connected) return
        val q = pending(ctx)
        if (q.length() == 0) return
        val urls = (0 until q.length()).map { q.optString(it) }.filter { it.isNotBlank() }.distinct()
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("q", "[]").apply()
        flushing = true
        val text = urls.joinToString("\n")
        val done: (String?) -> Unit = { err ->
            flushing = false
            if (err != null) {
                // keep them for the next connection
                val back = pending(ctx); urls.forEach { back.put(it) }
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("q", back.toString()).apply()
                toast(ctx, tr("Reel to Claude failed: ") + err)
            } else toast(ctx, if (urls.size == 1) tr("Reel sent to Claude — the answer comes as a notification")
                              else tr("${urls.size} reels sent to Claude"))
        }
        val s = inbox()
        if (s != null) Agents.send(s.optString("id"), text) { _, err -> done(err) }
        else Agents.request("start", JSONObject().put("agent", "claude").put("cwd", FOLDER).put("model", "sonnet").put("prompt", text), 60_000) { _, err -> done(err) }
    }

    private fun toast(ctx: Context, msg: String) = main.post { Toast.makeText(ctx, msg, Toast.LENGTH_LONG).show() }
}

/** The share-sheet entry "Reel to Claude". No UI of its own. */
class ReelShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = ReelShare.link(intent?.getStringExtra(Intent.EXTRA_TEXT))
        if (url == null) {
            Toast.makeText(this, tr("No link to send"), Toast.LENGTH_SHORT).show()
        } else {
            // make sure the link service runs, then hand the link over (it waits for the Mac if needed)
            try { startForegroundService(Intent(this, HubService::class.java)) } catch (_: Exception) {}
            ReelShare.share(applicationContext, url)
            if (!Agents.connected) Toast.makeText(this, tr("Reel saved — it goes to Claude when the Mac connects"), Toast.LENGTH_LONG).show()
        }
        finish()
    }
}
