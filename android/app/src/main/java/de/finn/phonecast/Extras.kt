package de.finn.phonecast

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.VibrationEffect
import android.os.VibratorManager
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * v0.3 link extras:
 *  - Now playing: the phone's active media session -> EVENT {e:"media"}; the Mac sends "media.cmd".
 *  - Ring my phone: "phone.ring" plays the ringtone on the alarm stream (rings on silent) + vibrates.
 *  - New screenshots go to the Mac by themselves (file req = SCREENSHOT_REQ).
 */
class Extras(private val ctx: Context, private val hub: HubService) {

    companion object {
        private const val TAG = "PhoneCastExtras"
        /** File request id the Mac treats as "a new screenshot": copy to clipboard + banner. */
        const val SCREENSHOT_REQ = 9001
        const val ACTION_STOP_RING = "de.finn.phonecast.STOP_RING"
        private const val CHANNEL_RING = "ring"
        private const val RING_NOTIF = 7
    }

    private val thread = HandlerThread("extras").apply { start() }
    private val h = Handler(thread.looper)

    fun start() {
        h.post { startMedia() }
        h.post { startScreenshots() }
    }

    /** A Mac (re)connected: tell it what's playing right now. */
    fun connected() { h.post { lastSent = 0; sendMedia() } }

    // ---------------- now playing ----------------

    private var msm: MediaSessionManager? = null
    private var controller: MediaController? = null
    private var lastSent = 0
    private var artFor = ""
    private var artB64: String? = null

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { list -> h.post { pick(list) } }
    private val cb = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) { h.post { sendMedia() } }
        override fun onMetadataChanged(metadata: MediaMetadata?) { h.post { sendMedia() } }
        override fun onSessionDestroyed() { h.post { pick(msm?.getActiveSessions(listener())) } }
    }

    private fun listener() = ComponentName(ctx, NotifListener::class.java)

    private fun startMedia() {
        try {
            val m = ctx.getSystemService(MediaSessionManager::class.java)
            m.addOnActiveSessionsChangedListener(sessionsChanged, listener(), h)
            msm = m
            pick(m.getActiveSessions(listener()))
        } catch (e: SecurityException) {
            // needs notification access; retried when the Mac connects next time
            Log.i(TAG, "media sessions need notification access")
            h.postDelayed({ if (msm == null) startMedia() }, 30_000)
        }
    }

    /** The playing session wins, else the most recent one. */
    private fun pick(list: List<MediaController>?) {
        val best = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(cb)
            controller = best
            best?.registerCallback(cb, h)
        }
        sendMedia()
    }

    private fun sendMedia() {
        if (!hub.connected) return
        val c = controller
        val md = c?.metadata
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val o = JSONObject().put("e", "media")
        if (c == null || md == null || title.isNullOrEmpty()) {
            if (lastSent != -1) { lastSent = -1; hub.sendJson(HubProto.EVENT, o) }   // nothing playing
            return
        }
        val artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val playing = c.playbackState?.state == PlaybackState.STATE_PLAYING
        val app = try { ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(c.packageName, 0)).toString() } catch (_: Exception) { c.packageName }
        val key = "$title|$artist"
        if (key != artFor) {
            artFor = key
            val bmp = md.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md.getBitmap(MediaMetadata.METADATA_KEY_ART)
            artB64 = bmp?.let { small(it) }
        }
        val sig = listOf(key, playing, c.packageName).hashCode()
        if (sig == lastSent) return
        lastSent = sig
        o.put("title", title).put("artist", artist).put("app", app).put("pkg", c.packageName).put("playing", playing)
        md.getLong(MediaMetadata.METADATA_KEY_DURATION).takeIf { it > 0 }?.let { o.put("dur", it) }
        artB64?.let { o.put("art", it) }
        hub.sendJson(HubProto.EVENT, o)
    }

    private fun small(b: Bitmap): String? = try {
        val s = 160.0 / maxOf(b.width, b.height)
        val sb = Bitmap.createScaledBitmap(b, maxOf(1, (b.width * s).toInt()), maxOf(1, (b.height * s).toInt()), true)
        val out = ByteArrayOutputStream(); sb.compress(Bitmap.CompressFormat.JPEG, 82, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (_: Exception) { null }

    /** play | pause | toggle | next | prev */
    fun mediaCmd(a: String): Boolean {
        val c = controller ?: return false
        val t = c.transportControls
        when (a) {
            "play" -> t.play()
            "pause" -> t.pause()
            "toggle" -> if (c.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
            "next" -> t.skipToNext()
            "prev" -> t.skipToPrevious()
            else -> return false
        }
        return true
    }

    // ---------------- ring my phone ----------------

    private var player: MediaPlayer? = null
    private var oldAlarmVol = -1
    private val autoStop = Runnable { ring(false) }

    @Synchronized fun ring(on: Boolean): Boolean {
        val am = ctx.getSystemService(AudioManager::class.java)
        val vib = ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (!on) {
            player?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
            player = null
            vib?.cancel()
            if (oldAlarmVol >= 0) { am.setStreamVolume(AudioManager.STREAM_ALARM, oldAlarmVol, 0); oldAlarmVol = -1 }
            nm.cancel(RING_NOTIF)
            h.removeCallbacks(autoStop)
            if (hub.connected) hub.sendJson(HubProto.EVENT, JSONObject().put("e", "ring").put("on", false))
            return true
        }
        if (player != null) return true
        // the alarm stream rings even when the phone is on silent or vibrate
        oldAlarmVol = am.getStreamVolume(AudioManager.STREAM_ALARM)
        am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_RINGTONE)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        player = try {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(ctx, uri); isLooping = true; prepare(); start()
            }
        } catch (e: Exception) { Log.w(TAG, "ring", e); null }
        vib?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 700, 500), 0))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_RING, "Find my phone", NotificationManager.IMPORTANCE_HIGH))
        val stop = PendingIntent.getService(ctx, 7, Intent(ctx, HubService::class.java).setAction(ACTION_STOP_RING), PendingIntent.FLAG_IMMUTABLE)
        nm.notify(RING_NOTIF, Notification.Builder(ctx, CHANNEL_RING)
            .setSmallIcon(R.drawable.ic_stat_phonecast)
            .setContentTitle("Found it!")
            .setContentText("Your Mac is ringing this phone. Tap to stop.")
            .setContentIntent(stop).setDeleteIntent(stop).setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build())
        h.postDelayed(autoStop, 60_000)   // never rings forever
        if (hub.connected) hub.sendJson(HubProto.EVENT, JSONObject().put("e", "ring").put("on", true))
        return true
    }

    // ---------------- new screenshots -> Mac ----------------

    private val sentShots = LinkedHashSet<Long>()

    private fun startScreenshots() {
        val observer = object : ContentObserver(h) {
            override fun onChange(selfChange: Boolean, uri: Uri?) { h.removeCallbacks(checkShots); h.postDelayed(checkShots, 700) }
        }
        ctx.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
    }

    private val checkShots = Runnable {
        if (!Prefs.autoShots(ctx) || !hub.connected) return@Runnable
        val perm = if (android.os.Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        if (ctx.checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) return@Runnable
        val since = System.currentTimeMillis() / 1000 - 20
        try {
            ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.DISPLAY_NAME),
                "${MediaStore.Images.Media.DATE_ADDED} >= ? AND ${MediaStore.Images.Media.IS_PENDING} = 0",
                arrayOf(since.toString()), "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { cur ->
                while (cur.moveToNext()) {
                    val id = cur.getLong(0)
                    val path = cur.getString(1) ?: ""
                    val name = cur.getString(2) ?: ""
                    if (!path.contains("Screenshot", true) && !name.startsWith("Screenshot", true)) continue
                    if (!sentShots.add(id)) continue
                    while (sentShots.size > 50) sentShots.remove(sentShots.first())
                    Log.i(TAG, "new screenshot $name -> Mac")
                    hub.sendUriAsFile(android.content.ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id), SCREENSHOT_REQ)
                }
            }
        } catch (e: Exception) { Log.w(TAG, "screenshots", e) }
    }
}
