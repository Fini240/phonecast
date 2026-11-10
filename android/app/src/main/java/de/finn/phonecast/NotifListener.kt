package de.finn.phonecast

import android.app.ActivityOptions
import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Mirrors the phone's notifications to the Mac over the hub, and carries out what the Mac
 * answers (reply, dismiss, open). Needs "Notification access" for PhoneCast.
 */
class NotifListener : NotificationListenerService() {

    companion object {
        @Volatile var instance: NotifListener? = null
            private set
        private const val TAG = "PhoneCastNotif"
    }

    /** key -> hash of what we last sent, so updates that change nothing aren't re-sent. */
    private val sent = HashMap<String, Int>()
    /** Packages whose icon the Mac already has during this connection. */
    private val iconsSent = HashSet<String>()

    override fun onListenerConnected() {
        instance = this
        HubService.start(this)
    }

    override fun onListenerDisconnected() { instance = null }
    override fun onDestroy() { instance = null; super.onDestroy() }

    /** A Mac (re)connected: it has none of our icons yet. */
    @Synchronized fun connected() { iconsSent.clear(); sent.clear() }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val hub = HubService.instance ?: return
        if (!hub.connected) return
        val n = sbn.notification
        if (sbn.packageName == packageName) return
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        if (n.category == Notification.CATEGORY_PROGRESS || n.category == Notification.CATEGORY_TRANSPORT) return
        val (title, text) = content(n)
        if (title.isBlank() && text.isBlank()) return
        val hash = (title + "\u0000" + text).hashCode()
        synchronized(this) {
            if (sent[sbn.key] == hash) return
            sent[sbn.key] = hash
        }
        val o = JSONObject()
            .put("key", sbn.key)
            .put("pkg", sbn.packageName)
            .put("app", appLabel(sbn.packageName))
            .put("title", title)
            .put("text", text)
            .put("when", sbn.postTime)
            .put("reply", replyAction(n) != null)
        val needIcon = synchronized(this) { iconsSent.add(sbn.packageName) }
        if (needIcon) icon(sbn.packageName)?.let { o.put("icon", it) }
        hub.sendJson(HubProto.NOTIF, o)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val had = synchronized(this) { sent.remove(sbn.key) != null }
        if (had) HubService.instance?.send(HubProto.NOTIF_GONE, sbn.key.toByteArray())
    }

    private fun content(n: Notification): Pair<String, String> {
        val e = n.extras
        val title = (e.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?: e.getCharSequence(Notification.EXTRA_TITLE) ?: "").toString()
        // messaging apps: the newest message with its sender
        val msgs = e.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (!msgs.isNullOrEmpty()) {
            val last = msgs.last() as? Bundle
            val sender = last?.getCharSequence("sender")?.toString()
            val t = last?.getCharSequence("text")?.toString() ?: ""
            return title to (if (sender != null && sender != title) "$sender: $t" else t)
        }
        val text = (e.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT) ?: "").toString()
        return title to text
    }

    private fun replyAction(n: Notification): Notification.Action? =
        n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun icon(pkg: String): String? = try {
        val d = packageManager.getApplicationIcon(pkg)
        val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, 96, 96); d.draw(Canvas(b))
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

    /** What the Mac's user did with a mirrored notification. */
    fun action(o: JSONObject) {
        val key = o.optString("key")
        val sbn = try { activeNotifications?.firstOrNull { it.key == key } } catch (_: Exception) { null }
        if (sbn == null) { Log.i(TAG, "notification $key is gone"); return }
        try {
            when (o.optString("action")) {
                "dismiss" -> cancelNotification(key)
                "reply" -> {
                    val a = replyAction(sbn.notification) ?: return
                    val intent = Intent()
                    val results = Bundle()
                    a.remoteInputs.filter { it.allowFreeFormInput }.forEach { results.putCharSequence(it.resultKey, o.optString("text")) }
                    RemoteInput.addResultsToIntent(a.remoteInputs, intent, results)
                    a.actionIntent.send(this, 0, intent)
                }
                "open" -> sbn.notification.contentIntent?.let { send(it) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "action failed", e)
        }
    }

    private fun send(pi: PendingIntent) {
        if (Build.VERSION.SDK_INT >= 34) {
            val opts = ActivityOptions.makeBasic()
                .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            pi.send(this, 0, null, null, null, null, opts.toBundle())
        } else pi.send()
    }
}
