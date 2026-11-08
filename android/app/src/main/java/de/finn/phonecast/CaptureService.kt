package de.finn.phonecast

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display

class CaptureService : Service(), StreamServer.Listener {

    companion object {
        const val ACTION_STOP = "de.finn.phonecast.STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val NOTIF_ID = 1
        private const val CHANNEL = "phonecast"

        @Volatile var instance: CaptureService? = null
            private set
        /** Sharing ended because the phone locked: offer to share again after the next unlock. */
        @Volatile var stoppedByLock = false
    }

    private val thread = HandlerThread("pc-display").apply { start() }
    private val handler = Handler(thread.looper)

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    @Volatile private var encoder: VideoEncoder? = null
    private var audio: AudioCapture? = null
    private var server: StreamServer? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    @Volatile var clientAddress: String? = null
        private set
    @Volatile var lastError: String? = null
        private set
    private var stopReason = Proto.STOP_USER

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (id == Display.DEFAULT_DISPLAY) handler.post { reconfigureIfNeeded() }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, notification("Waiting for the Mac…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        if (projection != null) return START_NOT_STICKY

        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (data == null) { stopSelf(); return START_NOT_STICKY }

        try {
            start(code, data)
            instance = this
        } catch (e: Exception) {
            Log.e("PhoneCast", "start failed", e)
            lastError = e.message
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun start(code: Int, data: Intent) {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val proj = mpm.getMediaProjection(code, data) ?: error("screen capture was not allowed")
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // Android ends screen capture when the phone locks (screen off, double tap...).
                val pm = getSystemService(android.os.PowerManager::class.java)
                val km = getSystemService(android.app.KeyguardManager::class.java)
                val locked = !pm.isInteractive || km.isKeyguardLocked
                stopReason = if (locked) Proto.STOP_LOCKED else Proto.STOP_USER
                stoppedByLock = locked
                handler.post { stopSelf() }
            }
        }, handler)
        projection = proj

        val srv = StreamServer(Prefs.pin(this), this)
        server = srv
        srv.start()

        // The virtual display has to be created right away, while this projection is
        // still the "current" one - before anything else touches it.
        startVideo()

        if (Prefs.audio(this) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            try { audio = AudioCapture(proj, srv) } catch (e: Exception) { Log.w("PhoneCast", "no audio", e) }
        }

        getSystemService(DisplayManager::class.java).registerDisplayListener(displayListener, handler)

        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        multicastLock = wifi.createMulticastLock("phonecast").apply { setReferenceCounted(false); acquire() }
        @Suppress("DEPRECATION")
        wifiLock = wifi.createWifiLock(
            if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            "phonecast"
        ).apply { setReferenceCounted(false); acquire() }

        registerNsd()
        UsbBridge.openExisting(this)
        InputService.onControlChanged = { available -> server?.onControlChanged(available) }
    }

    // ---- video ----

    private fun targetSize(): Triple<Int, Int, Int> {
        val d = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val m = DisplayMetrics()
        @Suppress("DEPRECATION") d.getRealMetrics(m)
        var w = m.widthPixels
        var h = m.heightPixels
        val max = Prefs.maxSize(this)
        if (max > 0 && maxOf(w, h) > max) {
            val s = max.toDouble() / maxOf(w, h)
            w = (w * s).toInt()
            h = (h * s).toInt()
        }
        return Triple(w and 7.inv(), h and 7.inv(), m.densityDpi)
    }

    private fun startVideo() {
        val proj = projection ?: return
        val srv = server ?: return
        val (w, h, dpi) = targetSize()
        val bitrate = Prefs.bitrateMbps(this) * 1_000_000
        srv.setFormat(w, h)
        val enc = VideoEncoder(w, h, bitrate, 60, srv)
        val old = encoder
        encoder = enc
        val vd = display
        if (vd == null) {
            display = proj.createVirtualDisplay(
                "PhoneCast", w, h, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                enc.surface, null, handler
            )
        } else {
            // Android 14+ allows only one virtual display per projection, so reuse it
            vd.resize(w, h, dpi)
            vd.surface = enc.surface
        }
        old?.release()
        updateNotification()
    }

    private fun reconfigureIfNeeded() {
        val enc = encoder ?: return
        val (w, h, _) = targetSize()
        if (w != enc.width || h != enc.height) safeStartVideo()
    }

    private fun safeStartVideo() {
        try {
            startVideo()
        } catch (e: Exception) {
            Log.e("PhoneCast", "video restart failed", e)
            lastError = e.message
        }
    }

    /** Called when quality settings change in the app. */
    fun restartVideo() = handler.post { safeStartVideo() }

    // ---- StreamServer.Listener ----

    override fun requestKeyFrame() { encoder?.requestKeyFrame() }

    override fun onClientChanged(address: String?) {
        clientAddress = address
        updateNotification()
    }

    override fun onInput(type: Int, payload: ByteArray) {
        InputService.instance?.handle(type, payload)
    }

    override fun onSettings(maxSize: Int, bitrateMbps: Int) {
        val b = bitrateMbps.coerceIn(2, 80)
        if (maxSize == Prefs.maxSize(this) && b == Prefs.bitrateMbps(this)) return
        Prefs.setMaxSize(this, maxSize)
        Prefs.setBitrateMbps(this, b)
        restartVideo()
    }

    override fun onResolution(w: Int, h: Int): Int = DisplaySize.apply(this, w, h)

    override fun controlAvailable(): Boolean = InputService.instance != null

    // ---- discovery ----

    private fun registerNsd() {
        val name = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = Proto.SERVICE_TYPE
            port = Proto.PORT
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {}
            override fun onRegistrationFailed(i: NsdServiceInfo, e: Int) { Log.w("PhoneCast", "nsd failed $e") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, e: Int) {}
        }
        try {
            getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
            nsdListener = l
        } catch (e: Exception) {
            Log.w("PhoneCast", "nsd", e)
        }
    }

    // ---- notification ----

    private fun notification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Streaming", NotificationManager.IMPORTANCE_LOW))
        }
        val stop = PendingIntent.getService(
            this, 0, Intent(this, CaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .setContentTitle("PhoneCast is sharing your screen")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun updateNotification() {
        val enc = encoder
        val text = buildString {
            append(clientAddress?.let { "Mac connected ($it)" } ?: "Waiting for the Mac…")
            if (enc != null) append(" · ${enc.width}×${enc.height}")
        }
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification(text))
    }

    override fun onDestroy() {
        instance = null
        InputService.onControlChanged = null
        InputService.instance?.handle(Proto.TOUCH, byteArrayOf(Proto.TOUCH_CANCEL_ALL.toByte(), 0, 0, 0, 0, 0))
        try { getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener) } catch (_: Exception) {}
        nsdListener?.let { try { getSystemService(NsdManager::class.java).unregisterService(it) } catch (_: Exception) {} }
        multicastLock?.release()
        wifiLock?.release()
        audio?.release()
        server?.stop(stopReason)
        val enc = encoder
        val vd = display
        val proj = projection
        handler.post {
            vd?.release()
            enc?.release()
            try { proj?.stop() } catch (_: Exception) {}
            thread.quitSafely()
        }
        super.onDestroy()
    }

}
