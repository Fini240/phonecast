package de.finn.phonecast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The hub: an always-on connection to the Mac, separate from screen sharing.
 * Carries notifications, files, clipboard, device status, "cast now" signals and the
 * Mac's screen + input (phone controls the Mac).
 *
 * Both directions: [u8 type][u32 length][payload], big-endian. The Mac connects and sends
 * HELLO with the same PIN as screen sharing; nothing else is accepted before it matches.
 */
object HubProto {
    const val PORT = 27185
    const val SERVICE_TYPE = "_phonecasthub._tcp"

    const val HELLO = 1          // mac->phone: json {name, pin?, qr?, proof?} (qr = QR pairing id, see Auth)
    const val HELLO_OK = 2       // phone->mac: json {name}
    const val HELLO_BAD = 3
    const val PING = 4           // either way, echoed as PONG
    const val PONG = 5
    const val STATUS = 6         // json, both ways
    const val NONCE = 7          // phone->mac, first packet: 16 random bytes for the QR proofs (Auth)

    const val NOTIF = 10         // phone->mac json
    const val NOTIF_GONE = 11    // phone->mac utf8 key
    const val NOTIF_ACTION = 12  // mac->phone json {key, action: reply|dismiss|open, text}

    const val FILE_BEGIN = 20    // json {id, name, size}
    const val FILE_DATA = 21     // u32 id, bytes
    const val FILE_END = 22      // u32 id
    const val FILE_CANCEL = 23   // u32 id

    const val CLIP = 30          // utf8 text (lands on the other side's clipboard)

    const val CAST_READY = 40    // phone->mac: sharing started, connect the viewer now
    const val CAST_STOPPED = 41  // phone->mac
    const val CAST_REQUEST = 42  // mac->phone: please start sharing

    const val SCREEN_START = 50  // phone->mac: u16 long side, u8 Mbit/s
    const val SCREEN_STOP = 51   // phone->mac
    const val SCREEN_FORMAT = 52 // mac->phone: u32 w, u32 h
    const val SCREEN_CONFIG = 53 // mac->phone: SPS/PPS Annex B
    const val SCREEN_FRAME = 54  // mac->phone: u8 keyframe, Annex B access unit
    const val SCREEN_KEY = 55    // phone->mac: send a keyframe
    const val SCREEN_DENIED = 56 // mac->phone: utf8 reason (permissions missing)

    const val REQ = 70           // mac->phone json {id, m, p}: see Features
    const val RESP = 71          // phone->mac json {id, ok, data | error, message}
    const val EVENT = 72         // phone->mac json {e: "call", state, number, name}

    const val INPUT = 60         // phone->mac, first byte = INPUT_*
    const val MAC_ACTION = 61    // phone->mac utf8: volup voldown mute play next prev lock displaysleep screenshot
    const val IN_MOVE = 0        // u16 x, u16 y (0..65535 of the Mac screen)
    const val IN_DOWN = 1        // u8 button (0 left, 1 right), u16 x, u16 y
    const val IN_UP = 2          // same
    const val IN_SCROLL = 3      // i16 dx, i16 dy (pixels)
    const val IN_TEXT = 4        // u8 mods, utf8
    const val IN_KEY = 5         // u16 mac keycode, u8 mods

    const val MOD_CMD = 1; const val MOD_OPT = 2; const val MOD_CTRL = 4; const val MOD_SHIFT = 8
}

class HubService : Service() {

    companion object {
        private const val TAG = "PhoneCastHub"
        private const val NOTIF_ID = 2
        private const val CHANNEL = "hub"
        private const val CHANNEL_FILES = "files"
        private const val CHANNEL_CAST = "cast"
        const val ACTION_SEND_FILES = "de.finn.phonecast.SEND_FILES"
        const val ACTION_SEND_TEXT = "de.finn.phonecast.SEND_TEXT"
        /** File request id for "a copied picture" (both directions). */
        const val CLIP_IMAGE_REQ = 9002
        const val EXTRA_URIS = "uris"
        const val EXTRA_TEXT = "text"

        @Volatile var instance: HubService? = null
            private set

        fun start(c: Context) {
            try { c.startForegroundService(Intent(c, HubService::class.java)) }
            catch (e: Exception) { Log.w(TAG, "can't start hub", e) }
        }
    }

    /** What the Mac last told us about itself (and the devices it watches). */
    @Volatile var macStatus: JSONObject? = null
        private set
    @Volatile var macName: String? = null
        private set
    val connected: Boolean get() = client != null
    @Volatile var transfer: String? = null   // "Sending photo.jpg 40 %" for the UI
        private set

    /** Last clipboard text that went either way (so an automatic copy isn't sent straight back). */
    @Volatile var lastClip: String? = null

    /** The activity showing the Mac's screen (gets SCREEN_* packets). */
    @Volatile var screenSink: ((Int, ByteArray) -> Unit)? = null

    @Volatile private var client: Client? = null
    @Volatile private var running = false
    private var serverSocket: ServerSocket? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val fileIds = AtomicInteger(1)
    lateinit var features: Features
        private set
    lateinit var extras: Extras
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Connection to the Mac", NotificationManager.IMPORTANCE_MIN))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_FILES, "Files from the Mac", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_CAST, "Cast requests from the Mac", NotificationManager.IMPORTANCE_HIGH))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        if (!running) {
            running = true
            instance = this
            Thread({ acceptLoop() }, "hub-accept").start()
            registerNsd()
            multicastLock = applicationContext.getSystemService(WifiManager::class.java)
                .createMulticastLock("phonecast-hub").apply { setReferenceCounted(false); acquire() }
            Thread({ statusLoop() }, "hub-status").start()
            features = Features(this, this)
            features.startCallWatch()
            extras = Extras(this, this)
            extras.start()
        }
        when (intent?.action) {
            ACTION_SEND_FILES -> {
                val uris = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(EXTRA_URIS, Uri::class.java)
                    else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(EXTRA_URIS)
                uris?.let { sendFiles(it) }
            }
            ACTION_SEND_TEXT -> intent.getStringExtra(EXTRA_TEXT)?.let { t ->
                // a shared link opens in the Mac's browser; other text goes to its clipboard
                val url = t.trim()
                if (Regex("^https?://\\S+$").matches(url) && client != null) sendJson(HubProto.EVENT, JSONObject().put("e", "open").put("url", url))
                else sendClip(t)
            }
            Extras.ACTION_STOP_RING -> if (::extras.isInitialized) extras.ring(false)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        instance = null
        if (::features.isInitialized) features.stopCallWatch()
        try { serverSocket?.close() } catch (_: Exception) {}
        client?.close()
        nsdListener?.let { try { getSystemService(NsdManager::class.java).unregisterService(it) } catch (_: Exception) {} }
        multicastLock?.release()
        super.onDestroy()
    }

    // ---- public API (any thread) ----

    fun send(type: Int, payload: ByteArray = ByteArray(0)) { client?.control(type, payload) }
    fun sendJson(type: Int, o: JSONObject) = send(type, o.toString().toByteArray())

    fun sendClip(text: String) {
        if (client == null) { toast("Not connected to the Mac"); return }
        lastClip = text
        send(HubProto.CLIP, text.toByteArray()); toast("Copied to the Mac")
    }

    /** A copied picture -> the Mac's clipboard (file req CLIP_IMAGE_REQ, the Mac keeps no copy in Downloads). */
    fun sendClipImage(u: Uri) {
        val c = client ?: run { toast("Not connected to the Mac"); return }
        Thread({
            try { sendOne(c, u, CLIP_IMAGE_REQ); toast("Picture copied to the Mac") }
            catch (e: Exception) { Log.w(TAG, "clip image", e) }
            transfer = null; updateNotification()
        }, "hub-clipimg").start()
    }

    fun castStarted() = send(HubProto.CAST_READY)
    fun castStopped() = send(HubProto.CAST_STOPPED)

    fun sendFiles(uris: List<Uri>) {
        val c = client
        if (c == null) { toast("Not connected to the Mac"); return }
        Thread({
            for (u in uris) {
                if (client !== c) break
                try { sendOne(c, u) } catch (e: Exception) { Log.w(TAG, "send $u", e); toast("Couldn't send a file: ${e.message}") }
            }
            transfer = null; updateNotification()
        }, "hub-send").start()
    }

    private fun sendOne(c: Client, u: Uri, req: Int = 0) {
        var name = "file"; var size = -1L
        contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cur ->
            if (cur.moveToFirst()) {
                cur.getString(0)?.let { name = it }
                if (!cur.isNull(1)) size = cur.getLong(1)
            }
        }
        sendStream(c, name, size, req) { contentResolver.openInputStream(u)!! }
    }

    /** The Mac asked for a photo/video ([req] = its request id, so it knows where the file belongs). */
    fun sendUriAsFile(u: Uri, req: Int) {
        val c = client ?: return
        Thread({ try { sendOne(c, u, req) } catch (e: Exception) { Log.w(TAG, "send $u", e) }; transfer = null; updateNotification() }, "hub-get").start()
    }

    /** A file or folder from the phone's storage (folders arrive as a .zip). */
    fun sendPathAsFile(rel: String, req: Int) {
        val c = client ?: return
        val f = java.io.File(features.storagePath(rel))
        Thread({
            try {
                if (f.isDirectory) {
                    val zip = java.io.File(cacheDir, f.name + ".zip")
                    java.util.zip.ZipOutputStream(zip.outputStream().buffered()).use { z ->
                        f.walkTopDown().filter { it.isFile }.forEach { file ->
                            z.putNextEntry(java.util.zip.ZipEntry(f.name + "/" + file.relativeTo(f).path))
                            file.inputStream().use { it.copyTo(z) }
                            z.closeEntry()
                        }
                    }
                    sendStream(c, zip.name, zip.length(), req) { zip.inputStream() }
                    zip.delete()
                } else sendStream(c, f.name, f.length(), req) { f.inputStream() }
            } catch (e: Exception) { Log.w(TAG, "send $rel", e) }
            transfer = null; updateNotification()
        }, "hub-get").start()
    }

    private fun sendStream(c: Client, name: String, size: Long, req: Int, open: () -> java.io.InputStream) {
        val id = fileIds.getAndIncrement()
        c.control(HubProto.FILE_BEGIN, JSONObject().put("id", id).put("name", name).put("size", size).put("req", req).toString().toByteArray())
        var sent = 0L; var lastPct = -1
        open().use { ins ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                if (client !== c) throw IllegalStateException("the Mac disconnected")
                val p = ByteBuffer.allocate(4 + n).putInt(id).put(buf, 0, n).array()
                c.bulk(HubProto.FILE_DATA, p)
                sent += n
                val pct = if (size > 0) (sent * 100 / size).toInt() else -1
                if (pct != lastPct) { lastPct = pct; transfer = "Sending $name" + if (pct >= 0) " $pct %" else ""; updateNotification() }
            }
        }
        c.bulk(HubProto.FILE_END, ByteBuffer.allocate(4).putInt(id).array())
    }

    // ---- server ----

    private fun acceptLoop() {
        try {
            // TLS 1.3, key kept in the phone's keystore (Auth)
            val ss = Auth.serverSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(HubProto.PORT))
            serverSocket = ss
            while (running) {
                val s = ss.accept()
                Thread({ handle(s) }, "hub-client").start()
            }
        } catch (e: Exception) {
            if (running) Log.e(TAG, "accept loop died", e)
        }
    }

    private fun readPacket(i: DataInputStream): Pair<Int, ByteArray> {
        val t = i.readUnsignedByte()
        val len = i.readInt()
        require(len in 0..(32 shl 20)) { "bad length $len" }
        return t to ByteArray(len).also { i.readFully(it) }
    }

    private fun handle(s: Socket) {
        var c: Client? = null
        try {
            s.tcpNoDelay = true
            s.soTimeout = 10_000
            val input = DataInputStream(s.getInputStream().buffered(64 * 1024))
            // a fresh nonce first, for QR-paired computers' proofs (older Macs just send HELLO anyway)
            val nonce = Auth.nonce()
            s.getOutputStream().apply { write(ByteBuffer.allocate(5 + nonce.size).put(HubProto.NONCE.toByte()).putInt(nonce.size).put(nonce).array()); flush() }
            val (t, p) = readPacket(input)
            val hello = try { JSONObject(String(p)) } catch (_: Exception) { JSONObject() }
            val qrId = hello.optString("qr")
            val qr = if (t == HubProto.HELLO && qrId.isNotEmpty()) Auth.checkHubQr(this, qrId, hello.optString("proof"), nonce) else null
            val pin = hello.optString("pin")
            val pinOk = qr == null && t == HubProto.HELLO && pin.isNotEmpty() && Auth.checkPin(this, pin)
            if (qr == null && !pinOk) {
                Log.w(TAG, "rejected ${s.inetAddress}: ${if (qrId.isNotEmpty() && pin.isEmpty()) "unknown QR pairing" else "bad pin"}")
                // "locked" = too many wrong PINs lately: the Mac waits and tries again instead of giving up;
                // "qr" = this computer's QR code wasn't scanned (or was removed): fall back to the PIN
                val why = when {
                    Auth.locked() -> "locked"
                    qrId.isNotEmpty() && pin.isEmpty() -> "qr"
                    else -> ""
                }.toByteArray()
                s.getOutputStream().write(ByteBuffer.allocate(5 + why.size).put(HubProto.HELLO_BAD.toByte()).putInt(why.size).put(why).array())
                s.close(); return
            }
            s.soTimeout = 8_000  // the Mac pings every second
            c = Client(s)
            client?.close()
            client = c
            macName = hello.optString("name", qr?.name ?: "Mac")
            // the mirror key: lets the mirror connect without sending the PIN in the clear
            val ok = JSONObject().put("name", deviceName()).put("mirrorKey", Prefs.token(this))
            if (qr != null) ok.put("proof", Auth.hubPhoneProof(qr, nonce)).put("qr", true)
            c.control(HubProto.HELLO_OK, ok.toString().toByteArray())
            if (CaptureService.instance != null) c.control(HubProto.CAST_READY, ByteArray(0))
            NotifListener.instance?.connected()
            updateNotification()
            pushStatus()
            extras.connected()

            val files = HashMap<Int, Incoming>()
            try {
                while (true) {
                    val (type, payload) = readPacket(input)
                    dispatch(c, type, payload, files)
                }
            } finally {
                files.values.forEach { it.abort() }
            }
        } catch (e: Exception) {
            Log.i(TAG, "client ended: ${e.message}")
        } finally {
            c?.close()
            if (client === c && c != null) {
                client = null; macStatus = null
                screenSink?.invoke(-1, ByteArray(0))
                updateNotification()
            }
            try { s.close() } catch (_: Exception) {}
        }
    }

    private fun dispatch(c: Client, type: Int, p: ByteArray, files: HashMap<Int, Incoming>) {
        when (type) {
            HubProto.PING -> c.control(HubProto.PONG, p)
            HubProto.PONG -> {}
            HubProto.STATUS -> { macStatus = try { JSONObject(String(p)) } catch (_: Exception) { null } }
            HubProto.CLIP -> {
                val text = String(p)
                lastClip = text
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From the Mac", text))
                toast("Copied from the Mac")
            }
            HubProto.NOTIF_ACTION -> NotifListener.instance?.action(JSONObject(String(p)))
            HubProto.CAST_REQUEST -> requestCast()
            HubProto.REQ -> features.handle(JSONObject(String(p)))
            HubProto.FILE_BEGIN -> {
                val o = JSONObject(String(p))
                files[o.getInt("id")] = Incoming(o.optString("name", "file"), o.optLong("size", -1), o.optString("dir").takeIf { it.isNotEmpty() },
                    clip = o.optBoolean("clip"))
            }
            HubProto.FILE_DATA -> {
                val id = ByteBuffer.wrap(p, 0, 4).int
                files[id]?.write(p, 4, p.size - 4)
            }
            HubProto.FILE_END -> files.remove(ByteBuffer.wrap(p, 0, 4).int)?.finish()
            HubProto.FILE_CANCEL -> files.remove(ByteBuffer.wrap(p, 0, 4).int)?.abort()
            HubProto.SCREEN_FORMAT, HubProto.SCREEN_CONFIG, HubProto.SCREEN_FRAME, HubProto.SCREEN_DENIED ->
                screenSink?.invoke(type, p)
        }
    }

    /** The Mac's "Cast phone": open the share prompt (an accessibility service may start activities). */
    private fun requestCast() {
        if (CaptureService.instance != null) { send(HubProto.CAST_READY); return }
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_RESUME, true)
        val viaA11y = InputService.instance?.let { svc ->
            try { svc.startActivity(open); true } catch (_: Exception) { false }
        } ?: false
        if (viaA11y) return
        // fallback: a heads-up notification the user taps
        val pi = PendingIntent.getActivity(this, 3, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        getSystemService(NotificationManager::class.java).notify(4, Notification.Builder(this, CHANNEL_CAST)
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .setContentTitle("The Mac wants to show this phone")
            .setContentText("Tap to start sharing")
            .setContentIntent(pi).setAutoCancel(true).build())
    }

    // ---- incoming files -> Download/PhoneCast ----

    private inner class Incoming(val name: String, val size: Long, dir: String?, val clip: Boolean = false) {
        private val uri: Uri?
        private val out: OutputStream?
        private var got = 0L
        private var lastPct = -1
        /** Upload into a folder the Mac's file browser is showing (needs "All files access"). */
        private val target: java.io.File? = dir?.takeIf { Environment.isExternalStorageManager() }?.let {
            val d = java.io.File(features.storagePath(it)); d.mkdirs()
            var f = java.io.File(d, name.replace('/', '_')); var n = 2
            while (f.exists()) { f = java.io.File(d, name.substringBeforeLast('.') + " $n" + (if ('.' in name) "." + name.substringAfterLast('.') else "")); n++ }
            f
        }

        init {
            if (target != null) {
                uri = null
                out = target.outputStream().buffered(256 * 1024)
            } else {
            val v = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/PhoneCast")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v)
            out = uri?.let { contentResolver.openOutputStream(it)?.buffered(256 * 1024) }
            }
        }

        fun write(b: ByteArray, off: Int, len: Int) {
            out?.write(b, off, len)
            got += len
            val pct = if (size > 0) (got * 100 / size).toInt() else -1
            if (pct != lastPct && pct % 5 == 0) { lastPct = pct; transfer = "Receiving $name $pct %"; updateNotification() }
        }

        fun finish() {
            try { out?.close() } catch (_: Exception) {}
            if (target != null) {
                android.media.MediaScannerConnection.scanFile(this@HubService, arrayOf(target.path), null, null)
                transfer = null; updateNotification(); return
            }
            val u = uri ?: return
            contentResolver.update(u, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            transfer = null; updateNotification()
            if (clip) {
                // a picture copied on the Mac: onto this phone's clipboard, ready to paste
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newUri(contentResolver, "Picture from the Mac", u))
                toast("Picture copied from the Mac")
                return
            }
            val mime = contentResolver.getType(u) ?: "*/*"
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(u, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(this@HubService, u.hashCode(), view, PendingIntent.FLAG_IMMUTABLE)
            getSystemService(NotificationManager::class.java).notify(u.hashCode(), Notification.Builder(this@HubService, CHANNEL_FILES)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("From the Mac: $name")
                .setContentText("Saved in Downloads/PhoneCast · ${human(got)}")
                .setContentIntent(pi).setAutoCancel(true).build())
        }

        fun abort() {
            try { out?.close() } catch (_: Exception) {}
            uri?.let { try { contentResolver.delete(it, null, null) } catch (_: Exception) {} }
            target?.delete()
            transfer = null; updateNotification()
        }
    }

    private fun human(b: Long) = when {
        b >= 1 shl 30 -> "%.1f GB".format(b / 1073741824.0)
        b >= 1 shl 20 -> "%.1f MB".format(b / 1048576.0)
        else -> "${b / 1024} KB"
    }

    // ---- status ----

    private fun statusLoop() {
        while (running) {
            try { if (client != null) pushStatus() } catch (e: Exception) { Log.w(TAG, "status", e) }
            Thread.sleep(2000)
        }
    }

    /** Send the status now (after a change the Mac made, e.g. Do Not Disturb). */
    fun refreshStatus() { Thread({ try { pushStatus() } catch (_: Exception) {} }, "hub-status-now").start() }

    private fun pushStatus() {
        val o = JSONObject()
        o.put("name", deviceName())
        val bat = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (bat != null) {
            val scale = bat.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1)
            o.put("battery", bat.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) * 100 / scale)
            o.put("charging", bat.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0)
            o.put("batteryTemp", bat.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) / 10.0)
        }
        val pm = getSystemService(PowerManager::class.java)
        o.put("thermal", pm.currentThermalStatus)
        val cm = getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        o.put("net", when {
            caps == null -> "offline"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            else -> "other"
        })
        if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
            @Suppress("DEPRECATION")
            val rssi = applicationContext.getSystemService(WifiManager::class.java).connectionInfo.rssi
            if (rssi in -120..-1) o.put("rssi", rssi)
        }
        try {
            val st = StatFs(Environment.getDataDirectory().path)
            o.put("freeGB", st.availableBytes / 1e9)
        } catch (_: Exception) {}
        o.put("casting", CaptureService.instance != null)
        o.put("control", InputService.instance != null)
        o.put("notifications", NotifListener.instance != null)
        // Do Not Disturb: the Mac stays quiet too
        val filter = getSystemService(NotificationManager::class.java).currentInterruptionFilter
        o.put("dnd", filter != NotificationManager.INTERRUPTION_FILTER_ALL && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN)
        o.put("perms", features.perms())
        transfer?.let { o.put("transfer", it) }
        sendJson(HubProto.STATUS, o)
    }

    fun deviceName(): String = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL

    // ---- discovery + notification ----

    private fun registerNsd() {
        val info = NsdServiceInfo().apply { serviceName = deviceName(); serviceType = HubProto.SERVICE_TYPE; port = HubProto.PORT }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) {}
            override fun onRegistrationFailed(i: NsdServiceInfo, e: Int) { Log.w(TAG, "nsd failed $e") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, e: Int) {}
        }
        try { getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, l); nsdListener = l }
        catch (e: Exception) { Log.w(TAG, "nsd", e) }
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val text = transfer ?: if (client != null) "Connected to ${macName ?: "the Mac"}" else "Waiting for the Mac"
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(if (client != null) R.drawable.ic_stat_phonecast else R.drawable.ic_stat_phonecast_off)
            .setContentTitle("PhoneCast link")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification() {
        LauncherIcon.request(this, client != null)
        try { getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification()) } catch (_: Exception) {}
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private fun toast(s: String) = main.post { android.widget.Toast.makeText(this, s, android.widget.Toast.LENGTH_SHORT).show() }

    /**
     * One Mac. Two send queues: control packets (pings, notifications, input echoes) always go
     * before bulk packets (file chunks), so a big transfer never delays a notification.
     */
    private class Client(val socket: Socket) {
        private val out = BufferedOutputStream(socket.getOutputStream(), 256 * 1024)
        private val ctrl = LinkedBlockingQueue<ByteArray>()
        private val bulkQ = ArrayBlockingQueue<ByteArray>(6)
        @Volatile private var open = true
        private val writer = Thread({ writeLoop() }, "hub-write").also { it.start() }

        private fun frame(type: Int, p: ByteArray) =
            ByteBuffer.allocate(5 + p.size).put(type.toByte()).putInt(p.size).put(p).array()

        fun control(type: Int, p: ByteArray) { if (open) ctrl.offer(frame(type, p)) }

        /** Blocks while the queue is full (back-pressure for file sends). */
        fun bulk(type: Int, p: ByteArray) {
            val f = frame(type, p)
            while (open) { if (bulkQ.offer(f, 200, TimeUnit.MILLISECONDS)) return }
            throw IllegalStateException("connection closed")
        }

        private fun writeLoop() {
            try {
                while (open) {
                    var f = ctrl.poll() ?: bulkQ.poll() ?: ctrl.poll(20, TimeUnit.MILLISECONDS)
                    while (f != null) {
                        out.write(f)
                        f = ctrl.poll() ?: if (ctrl.isEmpty()) bulkQ.poll() else null
                    }
                    out.flush()
                }
            } catch (e: Exception) {
                close()
            }
        }

        fun close() {
            if (!open) return
            open = false
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
