package de.finn.phonecast

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Locale

/** Dictation into the composer (Android's own recognizer, live partial results). */
class Voice(private val a: Activity) {
    private var rec: SpeechRecognizer? = null
    var listening = false; private set

    /** false = microphone permission was just requested (tap again after allowing). */
    fun start(onText: (partial: String, final: Boolean) -> Unit, onEnd: (error: String?) -> Unit): Boolean {
        if (a.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            a.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC); return false
        }
        if (!SpeechRecognizer.isRecognitionAvailable(a)) { onEnd(tr("This phone has no speech recognition.")); return true }
        stop()
        val r = SpeechRecognizer.createSpeechRecognizer(a)
        rec = r; listening = true
        r.setRecognitionListener(object : RecognitionListener {
            override fun onPartialResults(b: Bundle) { b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { onText(it, false) } }
            override fun onResults(b: Bundle) {
                listening = false
                onText(b.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: "", true); onEnd(null)
            }
            override fun onError(e: Int) {
                listening = false
                onEnd(if (e == SpeechRecognizer.ERROR_NO_MATCH || e == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) null else tr("Speech recognition failed ({0})", e))
            }
            override fun onReadyForSpeech(p: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(v: Float) {}
            override fun onBufferReceived(b: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(t: Int, p: Bundle?) {}
        })
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L))
        return true
    }

    fun stop() { rec?.let { try { it.stopListening(); it.destroy() } catch (_: Exception) {} }; rec = null; listening = false }

    companion object { const val REQ_MIC = 8 }
}

/** Reads agent answers aloud (Android text-to-speech), without code blocks and markdown marks. */
object Speech {
    private var tts: TextToSpeech? = null
    private var ready = false
    private val queue = ArrayList<String>()

    fun speak(ctx: Context, text: String, flush: Boolean = false) {
        val t = clean(text)
        if (t.isBlank()) return
        if (tts == null) {
            tts = TextToSpeech(ctx.applicationContext) { st ->
                ready = st == TextToSpeech.SUCCESS
                if (ready) { tts?.language = Locale.getDefault(); queue.forEach { say(it, false) }; queue.clear() }
            }
        }
        if (!ready) { if (flush) queue.clear(); queue += t; return }
        say(t, flush)
    }

    private fun say(t: String, flush: Boolean) {
        // long answers are split: TTS engines cap one utterance at ~4000 chars
        t.chunked(3500).forEachIndexed { i, part ->
            tts?.speak(part, if (flush && i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, null, "pc${System.nanoTime()}")
        }
    }

    fun stop() { tts?.stop(); queue.clear() }
    val speaking: Boolean get() = tts?.isSpeaking == true

    fun clean(s: String): String = s
        .replace(Regex("```[\\s\\S]*?```"), " (code) ")
        .replace(Regex("`([^`]*)`"), "$1")
        .replace(Regex("\\*\\*|__|^#+\\s*", RegexOption.MULTILINE), "")
        .replace(Regex("\\[([^]]+)]\\([^)]*\\)"), "$1")
        .replace(Regex("https?://\\S+"), "")
        .replace(Regex("^\\s*[-*]\\s+", RegexOption.MULTILINE), "")
        .trim()
}

/**
 * Agents status outside the app: an ongoing "live" notification while agents work (promoted to the
 * status bar chip / Now Bar where the system allows), the Quick Settings tile and the home-screen widget.
 */
object AgentsLive {
    private const val CHANNEL = "agents_live"
    private const val NOTIF_ID = 4999
    private val main = Handler(Looper.getMainLooper())
    private var lastSig = ""
    private var pending = false

    fun enabled(ctx: Context) = ctx.getSharedPreferences("agents", Context.MODE_PRIVATE).getBoolean("live", true)

    data class Summary(val working: List<JSONObject>, val waiting: List<JSONObject>) {
        val any get() = working.isNotEmpty() || waiting.isNotEmpty()
        fun short(): String = listOfNotNull(
            if (waiting.isNotEmpty()) tr(if (waiting.size == 1) "{0} needs you" else "{0} need you", waiting.size) else null,
            if (working.isNotEmpty()) tr("{0} working", working.size) else null,
        ).joinToString(" · ")
    }

    fun summary(): Summary {
        val tops = Agents.sessions.filter { !it.optBoolean("sub") }
        return Summary(tops.filter { it.optString("status") == "working" && !Agents.needsYou(it) }, tops.filter(Agents::needsYou))
    }

    /** Called when the chat list changes (throttled to one refresh per second). */
    fun update(ctx: Context) {
        if (pending) return
        pending = true
        main.postDelayed({ pending = false; refresh(ctx.applicationContext) }, 1000)
    }

    private fun refresh(ctx: Context) {
        val s = summary()
        val sig = (s.working + s.waiting).joinToString("|") { it.optString("id") + it.optString("stage") + it.optString("status") } + Agents.connected
        if (sig == lastSig) return
        lastSig = sig
        notification(ctx, s)
        AgentsWidget.refresh(ctx)
        try { TileService.requestListeningState(ctx, ComponentName(ctx, AgentsTile::class.java)) } catch (_: Exception) {}
    }

    private fun notification(ctx: Context, s: Summary) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (!s.any || !enabled(ctx) || !Agents.connected) { nm.cancel(NOTIF_ID); return }
        if (nm.getNotificationChannel(CHANNEL) == null)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, tr("AI agents working (live)"), NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            })
        val open = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .setData(Uri.parse("phonecast://agents")).putExtra(Agents.EXTRA_SID, s.waiting.firstOrNull()?.optString("id") ?: "")
        val inbox = Notification.InboxStyle()
        (s.waiting + s.working).take(6).forEach { j ->
            val what = if (Agents.needsYou(j)) "⚠ " + (j.optJSONObject("ask")?.optString("title") ?: tr("Waiting for you")) else j.optString("stage").ifEmpty { tr("Working…") }
            inbox.addLine("${j.optString("title")} — $what")
        }
        val b = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_tab_agents)
            .setContentTitle(s.short())
            .setContentText((s.waiting + s.working).joinToString(", ") { it.optString("title") })
            .setStyle(inbox)
            .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(PendingIntent.getActivity(ctx, NOTIF_ID, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        if (s.working.isNotEmpty() && s.waiting.isEmpty()) b.setProgress(0, 0, true)
        // Android 16 "live update": asks for the status bar chip / Samsung Now Bar (ignored where unsupported)
        b.extras.putBoolean("android.requestPromotedOngoing", true)
        if (Build.VERSION.SDK_INT >= 36) try {
            Notification.Builder::class.java.getMethod("setShortCriticalText", String::class.java).invoke(b, s.short())
        } catch (_: Exception) {}
        nm.notify(NOTIF_ID, b.build())
    }

    fun cancel(ctx: Context) { ctx.getSystemService(NotificationManager::class.java).cancel(NOTIF_ID); lastSig = "" }
}

/** Quick Settings tile: how many agents work / need you; tap opens the Agents tab. */
class AgentsTile : TileService() {
    override fun onStartListening() {
        val s = AgentsLive.summary()
        qsTile?.apply {
            label = tr("Agents")
            subtitle = when {
                !Agents.connected -> tr("Mac not connected")
                s.any -> s.short()
                else -> tr("All quiet")
            }
            state = if (s.any) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(Agents.EXTRA_SID, AgentsLive.summary().waiting.firstOrNull()?.optString("id") ?: "")
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 9, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        else @Suppress("DEPRECATION") startActivityAndCollapse(i)
    }
}

/** Home-screen widget: up to four chats that work or need you; tap opens the chat. */
class AgentsWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, m: AppWidgetManager, ids: IntArray) = refresh(ctx)

    companion object {
        private val rows = intArrayOf(R.id.w_row0, R.id.w_row1, R.id.w_row2, R.id.w_row3)

        fun refresh(ctx: Context) {
            val m = AppWidgetManager.getInstance(ctx)
            val ids = m.getAppWidgetIds(ComponentName(ctx, AgentsWidget::class.java))
            if (ids.isEmpty()) return
            m.updateAppWidget(ids, views(ctx))
        }

        fun views(ctx: Context): RemoteViews {
            val s = AgentsLive.summary()
            val v = RemoteViews(ctx.packageName, R.layout.widget_agents)
            v.setTextViewText(R.id.w_title, tr("Agents"))
            v.setTextViewText(R.id.w_sub, when {
                !Agents.connected -> tr("Mac not connected")
                s.any -> s.short()
                else -> tr("All quiet")
            })
            val list = s.waiting + s.working + Agents.sessions.filter { !it.optBoolean("sub") && it !in s.waiting && it !in s.working }.take(4)
            rows.forEachIndexed { i, id ->
                val j = list.getOrNull(i)
                if (j == null) { v.setViewVisibility(id, View.GONE); return@forEachIndexed }
                v.setViewVisibility(id, View.VISIBLE)
                val dot = when { Agents.needsYou(j) -> "🟠"; j.optString("status") == "working" -> "🟢"; else -> "⚪" }
                val what = when {
                    Agents.needsYou(j) -> j.optJSONObject("ask")?.optString("title") ?: tr("Waiting for you")
                    j.optString("status") == "working" -> j.optString("stage").ifEmpty { tr("Working…") }
                    else -> j.optString("last").ifEmpty { j.optString("cwd").substringAfterLast('/') }
                }
                v.setTextViewText(id, "$dot  ${j.optString("title")}\n      $what")
                val open = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .setData(Uri.parse("phonecast://agent/w/" + Uri.encode(j.optString("id")))).putExtra(Agents.EXTRA_SID, j.optString("id"))
                v.setOnClickPendingIntent(id, PendingIntent.getActivity(ctx, 100 + i, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            val home = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra(Agents.EXTRA_SID, "")
            v.setOnClickPendingIntent(R.id.w_head, PendingIntent.getActivity(ctx, 99, home, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            return v
        }
    }
}
