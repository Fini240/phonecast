package de.finn.phonecast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicInteger

/**
 * Agents: the Claude Code / Codex chats on the Mac (AgentHub.swift there), over the PhoneCast link.
 * The Mac pushes the chat list when it changes, the messages of the chat being looked at, and alerts
 * (done / error / needs you / agent notes). Requests go to the computer that said hello.
 * State lives here (process-wide) so notifications work without the app open; the UI listens.
 */
object Agents {
    const val CHANNEL = "agents"
    const val EXTRA_SID = "agentSid"
    private const val ACTION_REPLY = "de.finn.phonecast.AGENT_REPLY"
    private const val ACTION_CHOOSE = "de.finn.phonecast.AGENT_CHOOSE"
    private const val KEY_TEXT = "text"

    private val main = Handler(Looper.getMainLooper())
    private val nextId = AtomicInteger(1)
    private val pending = HashMap<Int, (JSONObject?, String?) -> Unit>()

    /** The computer (HubService client) that hosts the agents; null = none linked. */
    @Volatile var host: Any? = null; private set
    var hostName: String = ""; private set
    var integrationInstalled = true; private set
    /** The Mac reads Claude's statusline data (cost, context, plan limits). */
    var tap = false; private set
    fun setTap(on: Boolean) { tap = on; fire("host") }

    var sessions: List<JSONObject> = emptyList(); private set
    val byId = HashMap<String, JSONObject>()

    /** The chat the UI shows and its messages (oldest first). */
    var watched: String? = null; private set
    val messages = ArrayList<JSONObject>()
    var moreOlder = false; private set
    /** The Mac answered the watch (an empty list then really means no messages yet). */
    var loaded = false; private set
    /** The chat the user is looking at right now (no notification for it). */
    @Volatile var foreground: String? = null

    private val listeners = LinkedHashSet<(what: String) -> Unit>()
    fun listen(l: (String) -> Unit) { listeners += l }
    fun unlisten(l: (String) -> Unit) { listeners -= l }
    private fun fire(what: String) = main.post { listeners.toList().forEach { it(what) } }

    val connected: Boolean get() = host != null

    // ---- link ----

    fun packet(ctx: Context, client: Any, type: Int, p: ByteArray, name: String) {
        val o = try { JSONObject(String(p)) } catch (_: Exception) { return }
        when (type) {
            HubProto.AGENT_RESP -> {
                val cb = synchronized(pending) { pending.remove(o.optInt("id")) } ?: return
                main.post { if (o.optBoolean("ok")) cb(o.opt("data") as? JSONObject ?: JSONObject().put("v", o.opt("data")), null) else cb(null, o.optString("message", "Failed")) }
            }
            HubProto.AGENT_EVENT -> event(ctx, client, o, name)
        }
    }

    private fun event(ctx: Context, client: Any, o: JSONObject, name: String) {
        when (o.optString("e")) {
            "hello" -> {
                host = client; hostName = name
                integrationInstalled = o.optBoolean("installed", true)
                tap = o.optBoolean("tap", false)
                watched?.let { sid -> request("watch", JSONObject().put("sid", sid)) }
                fire("host")
                main.postDelayed({ flushQueue(ctx) }, 1500)
            }
            "sessions" -> {
                if (host == null) { host = client; hostName = name }
                val arr = o.optJSONArray("list") ?: JSONArray()
                val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
                main.post {
                    sessions = list
                    byId.clear(); list.forEach { byId[it.optString("id")] = it }
                    fire("sessions")
                    AgentsLive.update(ctx)
                }
            }
            "msgs" -> main.post {
                if (o.optString("sid") != watched) return@post
                if (o.optBoolean("reset")) { messages.clear(); moreOlder = o.optBoolean("more"); loaded = true }
                val add = o.optJSONArray("add") ?: JSONArray()
                val have = messages.mapTo(HashSet()) { it.optString("id") }
                for (i in 0 until add.length()) add.optJSONObject(i)?.let { if (it.optString("id") !in have) messages += it }
                if (messages.size > 600) messages.subList(0, messages.size - 600).clear()
                fire("msgs")
            }
            "alert" -> main.post { alert(ctx, o) }
        }
    }

    /** The host computer went away. */
    fun lost(client: Any) {
        if (host !== client) return
        host = null
        main.post {
            HubService.instance?.let { AgentsLive.update(it) }
            synchronized(pending) { pending.values.toList().also { pending.clear() } }.forEach { it(null, "The Mac disconnected.") }
            fire("host")
        }
    }

    fun request(m: String, p: JSONObject = JSONObject(), timeoutMs: Long = 30_000, cb: (JSONObject?, String?) -> Unit = { _, _ -> }) {
        if (host === DEMO) { main.postDelayed({ demoAnswer(m, p, cb) }, 300); return }
        val hub = HubService.instance
        val h = host
        if (hub == null || h == null) { main.post { cb(null, tr("The Mac isn't connected.")) }; return }
        val id = nextId.getAndIncrement()
        synchronized(pending) { pending[id] = cb }
        hub.sendAgent(h, JSONObject().put("id", id).put("m", m).put("p", p).toString().toByteArray())
        main.postDelayed({ synchronized(pending) { pending.remove(id) }?.invoke(null, tr("The Mac didn't answer in time.")) }, timeoutMs)
    }

    fun watch(sid: String?) {
        if (watched == sid) return
        watched = sid
        messages.clear(); moreOlder = false; loaded = false
        request("watch", JSONObject().put("sid", sid ?: ""))
        fire("msgs")
    }

    fun older(cb: (String?) -> Unit) {
        val sid = watched ?: return
        request("older", JSONObject().put("sid", sid).put("have", messages.size)) { d, err ->
            if (d != null && watched == sid) {
                val arr = d.optJSONArray("add") ?: JSONArray()
                messages.clear()
                for (i in 0 until arr.length()) arr.optJSONObject(i)?.let { messages += it }
                moreOlder = d.optBoolean("more")
                fire("msgs")
            }
            cb(err)
        }
    }

    /** A file to attach: its name and bytes. */
    class Attachment(val name: String, val bytes: ByteArray)

    /** Send text (+ JPEG/PNG bytes, + other files) to a chat; offline chats are reopened on the Mac first.
     *  Without a Mac link, text-only messages wait in a queue and go out on the next connection. */
    fun send(sid: String, text: String, images: List<ByteArray> = emptyList(), files: List<Attachment> = emptyList(), cb: (newSid: String?, err: String?) -> Unit) {
        if (!connected && images.isEmpty() && files.isEmpty() && text.isNotBlank()) {
            val ctx = HubService.instance
            if (ctx != null) { queue(ctx, sid, text); cb(null, null); fire("queue"); return }
        }
        val p = JSONObject().put("sid", sid).put("text", text)
        if (images.isNotEmpty()) p.put("images", JSONArray(images.map { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) }))
        if (files.isNotEmpty()) p.put("files", JSONArray(files.map { JSONObject().put("name", it.name).put("b64", android.util.Base64.encodeToString(it.bytes, android.util.Base64.NO_WRAP)) }))
        request("send", p, 90_000) { d, err -> cb(d?.optString("sid"), err) }
    }

    // ---- offline queue (messages written while the Mac was away) ----

    private fun queueArr(ctx: Context) = try { JSONArray(ctx.getSharedPreferences("agents", Context.MODE_PRIVATE).getString("queue", "[]")) } catch (_: Exception) { JSONArray() }
    fun queued(ctx: Context, sid: String? = null): Int { val a = queueArr(ctx); return (0 until a.length()).count { sid == null || a.optJSONObject(it)?.optString("sid") == sid } }
    private fun queue(ctx: Context, sid: String, text: String) {
        val a = queueArr(ctx).put(JSONObject().put("sid", sid).put("text", text).put("at", System.currentTimeMillis()))
        ctx.getSharedPreferences("agents", Context.MODE_PRIVATE).edit().putString("queue", a.toString()).apply()
    }
    private fun flushQueue(ctx: Context) {
        val a = queueArr(ctx)
        if (a.length() == 0) return
        ctx.getSharedPreferences("agents", Context.MODE_PRIVATE).edit().putString("queue", "[]").apply()
        val items = (0 until a.length()).mapNotNull { a.optJSONObject(it) }
        fun next(i: Int) {
            if (i >= items.size) { fire("queue"); return }
            val it = items[i]
            send(it.optString("sid"), it.optString("text"), cb = { _, err ->
                if (err != null) { queue(ctx, it.optString("sid"), it.optString("text")) }
                main.postDelayed({ next(i + 1) }, 400)
            })
        }
        next(0)
    }

    /** The Mac's address as the phone sees it (for dev-server previews). */
    fun hostAddress(): String? = HubService.instance?.agentHostAddress(host)

    // ---- helpers for the UI ----

    fun needsYou(s: JSONObject) = s.optString("status") == "needs_input" || s.has("ask")
    fun isActive(s: JSONObject) = s.optBoolean("live") || s.optString("status") == "working"
    fun children(sid: String) = sessions.filter { it.optString("parent") == sid }
    fun canSend(s: JSONObject) = !s.optBoolean("sub") && (s.optBoolean("managed") || s.optBoolean("canResume"))

    // ---- notifications ----

    fun channel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, tr("AI agents on the Mac"), NotificationManager.IMPORTANCE_HIGH).apply {
                description = tr("When Claude Code or Codex finishes, fails or needs you")
            })
    }

    private fun notifId(sid: String) = 5000 + (sid.hashCode() and 0xFFFF)

    private fun alert(ctx: Context, o: JSONObject) {
        val sid = o.optString("sid")
        // hands-free: read finished answers aloud (Agents → ⋯ → Read finished answers aloud)
        if (o.optString("kind") == "completed" && ctx.getSharedPreferences("agents", Context.MODE_PRIVATE).getBoolean("speakDone", false))
            Speech.speak(ctx, tr("{0} is done.", o.optString("title")) + " " + o.optString("body"))
        if (sid.isNotEmpty() && sid == foreground) return     // already on screen
        channel(ctx)
        val kind = o.optString("kind")
        val title = o.optString("title").ifEmpty { "Agent" }
        val head = when (kind) {
            "completed" -> tr("Done")
            "error" -> tr("Error")
            "input" -> tr("Needs you")
            "budget" -> tr("Budget reached")
            "stuck" -> tr("Stuck?")
            "limit" -> tr("Usage limit")
            else -> o.optString("agent").replaceFirstChar { it.uppercase() }.ifEmpty { tr("Agent") }
        }
        val open = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .setData(Uri.parse("phonecast://agent/" + Uri.encode(sid))).putExtra(EXTRA_SID, sid)
        val b = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_tab_agents)
            .setContentTitle("$head · $title")
            .setContentText(o.optString("body"))
            .setStyle(Notification.BigTextStyle().bigText(o.optString("body")))
            .setContentIntent(PendingIntent.getActivity(ctx, notifId(sid), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .setAutoCancel(true)
            .setCategory(if (kind == "input") Notification.CATEGORY_REMINDER else Notification.CATEGORY_STATUS)
            .setGroup("agents")
        val s = byId[sid]
        val ask = o.optJSONObject("ask")
        if (ask != null) {
            // answer the question right from the notification (unlock required)
            val choices = ask.optJSONArray("choices") ?: JSONArray()
            for (i in 0 until minOf(3, choices.length())) {
                val c = choices.optJSONObject(i) ?: continue
                val pi = PendingIntent.getBroadcast(ctx, notifId(sid) * 8 + i,
                    Intent(ctx, AgentReceiver::class.java).setAction(ACTION_CHOOSE).setData(Uri.parse("phonecast://agent/$sid/$i"))
                        .putExtra("sid", sid).putExtra("ask", ask.optString("id")).putExtra("choice", c.optString("id")),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                b.addAction(Notification.Action.Builder(null, c.optString("label").take(40), pi).setAuthenticationRequired(true).build())
            }
        } else if (sid.isNotEmpty() && (s == null || canSend(s) || o.optBoolean("managed"))) {
            val pi = PendingIntent.getBroadcast(ctx, notifId(sid),
                Intent(ctx, AgentReceiver::class.java).setAction(ACTION_REPLY).setData(Uri.parse("phonecast://agent/$sid")).putExtra("sid", sid),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            b.addAction(Notification.Action.Builder(null, tr("Reply"), pi)
                .addRemoteInput(RemoteInput.Builder(KEY_TEXT).setLabel(tr("Reply to {0}", title)).build())
                .setAuthenticationRequired(true).build())
        }
        ctx.getSystemService(NotificationManager::class.java).notify(notifId(sid), b.build())
    }

    fun clearNotification(ctx: Context, sid: String) = ctx.getSystemService(NotificationManager::class.java).cancel(notifId(sid))

    /** Updates the notification with the outcome of a reply/choice made from it. */
    private fun settle(ctx: Context, sid: String, text: String) {
        channel(ctx)
        ctx.getSystemService(NotificationManager::class.java).notify(notifId(sid), Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_tab_agents).setContentTitle(byId[sid]?.optString("title") ?: tr("Agent"))
            .setContentText(text).setTimeoutAfter(if (text.startsWith("✓")) 4000 else 0).setOnlyAlertOnce(true).build())
    }

    class AgentReceiver : BroadcastReceiver() {
        override fun onReceive(ctx: Context, i: Intent) {
            val sid = i.getStringExtra("sid") ?: return
            val done = goAsync()
            val finish: (String?) -> Unit = { err -> settle(ctx, sid, if (err == null) "✓ " + tr("Sent") else tr("Not sent: {0}", err)); done.finish() }
            when (i.action) {
                ACTION_REPLY -> {
                    val text = RemoteInput.getResultsFromIntent(i)?.getCharSequence(KEY_TEXT)?.toString()?.trim()
                    if (text.isNullOrEmpty()) { done.finish(); return }
                    send(sid, text) { _, err -> finish(err) }
                }
                ACTION_CHOOSE -> request("approve", JSONObject().put("sid", sid).put("ask", i.getStringExtra("ask")).put("choice", i.getStringExtra("choice"))) { _, err -> finish(err) }
                else -> done.finish()
            }
        }
    }

    // ---- demo data for screenshots (debuggable builds only: adb shell am start ... --ez agentsDemo true) ----

    private val DEMO = Any()

    fun demo(ctx: Context) {
        if (ctx.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        host = DEMO; hostName = "Mac"; integrationInstalled = true
        val now = System.currentTimeMillis()
        fun s(id: String, agent: String, title: String, status: String, ago: Long, cwd: String, extra: JSONObject.() -> Unit = {}) =
            JSONObject().put("id", id).put("agent", agent).put("title", title).put("status", status).put("updatedAt", now - ago * 1000)
                .put("cwd", cwd).put("managed", status != "offline").put("live", status != "offline").put("canResume", status == "offline").apply(extra)
        sessions = listOf(
            s("t:a1", "claude", "Release v0.4 of PhoneCast", "needs_input", 40, "/Users/me/code/phonecast") {
                put("model", "claude-opus-5-5"); put("stage", "Do you want to run this command?"); put("mode", "accept edits")
                put("usage", JSONObject("{\"ctxPct\":38,\"ctxSize\":1000000,\"in\":412000,\"cached\":8200000,\"out\":96000,\"cost\":4.87,\"limits\":[{\"label\":\"5 h\",\"pct\":43},{\"label\":\"7 days\",\"pct\":54}]}"))
                put("ask", JSONObject().put("id", "ap_1").put("title", "Do you want to proceed?")
                    .put("detail", "Bash command\n  gh release create v0.4.0 dist/PhoneCast.apk dist/PhoneCast-mac-arm64.zip\n  Publish the release")
                    .put("choices", JSONArray().put(JSONObject().put("id", "1").put("label", "Yes"))
                        .put(JSONObject().put("id", "2").put("label", "Yes, and don't ask again for gh release commands"))
                        .put(JSONObject().put("id", "3").put("label", "No, and tell Claude what to do differently (esc)"))))
            },
            s("t:a2", "claude", "Bakery website: contact form", "working", 5, "/Users/me/code/bakery-site") {
                put("model", "claude-sonnet-5-5"); put("stage", "Running tests… (1m 12s · ↓ 4.1k tokens)"); put("last", "Running the form tests on all three screen sizes now.")
            },
            s("claude-sub:k1", "claude", "Check form on 390 px", "working", 3, "/Users/me/code/bakery-site") { put("sub", true); put("parent", "t:a2"); put("role", "Explore"); put("stage", "Bash: npx playwright test") },
            s("claude-sub:k2", "claude", "Check form on 1440 px", "completed", 50, "/Users/me/code/bakery-site") { put("sub", true); put("parent", "t:a2"); put("role", "Explore") },
            s("t:a3", "codex", "KVM: fix clipboard sync", "idle", 900, "/Users/me/code/kvm") { put("model", "gpt-6-luna"); put("last", "Clipboard sync now debounces at 150 ms and both sides pass the round-trip test.") },
            s("claude:h1", "claude", "Internship application", "offline", 86400 * 2, "/Users/me/school") { put("last", "The letter is saved as anschreiben.docx.") },
            s("codex:h2", "codex", "Drone frame stress test", "offline", 86400 * 5, "/Users/me/code/drone-frame"),
        )
        byId.clear(); sessions.forEach { byId[it.optString("id")] = it }
        fire("sessions")
        AgentsLive.update(ctx)
        watched?.let { request("watch", JSONObject().put("sid", it)) }
        main.postDelayed({
            try { val v = AgentsWidget.views(ctx).apply(ctx, android.widget.FrameLayout(ctx)); android.util.Log.i("AgentsDemo", "widget ok: " + (v as android.view.ViewGroup).childCount) }
            catch (e: Exception) { android.util.Log.e("AgentsDemo", "widget failed", e) }
        }, 2000)
    }

    private fun demoAnswer(m: String, p: JSONObject, cb: (JSONObject?, String?) -> Unit) {
        when (m) {
            "watch" -> {
                val now = System.currentTimeMillis()
                fun msg(id: String, r: String, t: String, tool: String? = null) = JSONObject().put("id", id).put("r", r).put("t", t).put("ts", now).apply { tool?.let { put("tool", it) } }
                messages.clear(); loaded = true
                messages += listOf(
                    msg("1", "user", "Bump the version to 0.4.0, build everything and publish the release."),
                    msg("2", "assistant", "I'll do this in three steps:\n\n1. **Bump** `versionName` to `0.4.0` in both apps\n2. Build the Mac zip, the APK and the Windows zip\n3. Publish the GitHub release\n\n```\nPHONECAST_SIGN_ID=- NO_INSTALL=1 mac/build.sh\n./gradlew assembleRelease\n```"),
                    msg("3", "tool", "Edit: android/app/build.gradle.kts", "Edit"),
                    msg("4", "tool", "Bash: ./gradlew assembleRelease\nBUILD SUCCESSFUL in 41s", "Bash"),
                    msg("5", "tool", "Error: gh: not logged in", "Bash"),
                    msg("6", "system", "Context compacted"),
                    msg("7", "assistant", "All three builds are done. Publishing needs your OK for the `gh release` command."),
                )
                moreOlder = true
                fire("msgs"); cb(JSONObject(), null)
            }
            "models" -> cb(JSONObject("{\"agents\":[{\"id\":\"claude\",\"models\":[{\"id\":\"opus\",\"label\":\"Opus 5.5\"},{\"id\":\"sonnet\",\"label\":\"Sonnet 5.5\"}]},{\"id\":\"codex\",\"models\":[{\"id\":\"gpt-6-luna\",\"label\":\"GPT-6 Luna\"}]}]}"), null)
            "folders" -> cb(JSONObject().put("home", "/Users/me").put("folders", JSONArray(listOf("/Users/me/code/phonecast", "/Users/me/code/bakery-site"))), null)
            "changes" -> cb(JSONObject("{\"repo\":true,\"branch\":\"release-0.4\",\"ahead\":2,\"behind\":0,\"upstream\":true,\"remote\":\"origin\",\"gh\":true,\"files\":[{\"path\":\"android/app/build.gradle.kts\",\"kind\":\"modified\",\"add\":2,\"del\":2},{\"path\":\"mac/Info.plist\",\"kind\":\"modified\",\"add\":1,\"del\":1},{\"path\":\"CHANGELOG.md\",\"kind\":\"new\",\"add\":14,\"del\":0}]}"), null)
            "diff" -> cb(JSONObject().put("v", "diff --git a/android/app/build.gradle.kts b/android/app/build.gradle.kts\nindex 1a2b3c4..5d6e7f8 100644\n--- a/android/app/build.gradle.kts\n+++ b/android/app/build.gradle.kts\n@@ -10,8 +10,8 @@ android {\n     defaultConfig {\n         applicationId = \"de.finn.phonecast\"\n         minSdk = 30\n-        versionCode = 12\n-        versionName = \"0.3.2\"\n+        versionCode = 13\n+        versionName = \"0.4.0\"\n     }"), null)
            "live" -> cb(JSONObject().put("ansi", "\u001b[38;5;174m ▐▛███▜▌\u001b[39m   \u001b[1mClaude Code\u001b[22m v2.1.322\n\u001b[38;5;174m▝▜█████▛▘\u001b[39m  Opus 5.5 · Claude Max\n\n\u001b[2m> Bump the version to 0.4.0\u001b[22m\n\n\u001b[32m⏺\u001b[39m Update(\u001b[1mandroid/app/build.gradle.kts\u001b[22m)\n  ⎿  \u001b[48;5;52m-        versionCode = 12\u001b[49m\n     \u001b[48;5;22m+        versionCode = 13\u001b[49m\n\n\u001b[38;5;174m✻\u001b[39m Publishing… \u001b[2m(12s · esc to interrupt)\u001b[22m\n\u001b[2m────────────────────────────────────────\u001b[22m\n❯ \n\u001b[2m────────────────────────────────────────\u001b[22m"), null)
            "files" -> cb(JSONObject("{\"items\":[{\"name\":\"android\",\"dir\":true},{\"name\":\"mac\",\"dir\":true},{\"name\":\"node_modules\",\"dir\":true,\"dim\":true},{\"name\":\"README.md\",\"dir\":false,\"size\":24310},{\"name\":\"LICENSE\",\"dir\":false,\"size\":1071}]}"), null)
            "file" -> cb(JSONObject().put("text", "# PhoneCast\n\nConnects an Android phone and a Mac.\n"), null)
            "find" -> cb(JSONObject().put("files", JSONArray(listOf("README.md", "mac/Sources/AgentHub.swift", "android/app/src/main/java/de/finn/phonecast/AgentsPage.kt"))), null)
            "agents" -> cb(JSONObject().put("agents", JSONArray(listOf("claude", "codex", "gemini", "opencode"))), null)
            "terminal" -> cb(JSONObject().put("v", "╭───────────────────────────╮\n│ ✻ Welcome to Claude Code! │\n╰───────────────────────────╯\n\n❯ Bump the version…\n\n● All three builds are done."), null)
            else -> cb(JSONObject(), null)
        }
    }
}
