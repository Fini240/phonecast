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
import android.os.SystemClock
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

    const val HELLO = 1          // mac->phone: json {name, os?, pin?, qr?, proof?} (qr = QR pairing id, see Auth; os "windows" for the PC)
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
    const val IN_REL = 6         // i16 dx, i16 dy (Mac points): trackpad move from where the cursor is
    const val IN_HERE = 7        // u8 button, u8 down: click where the cursor is (trackpad)

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
        const val EXTRA_URIS = "uris"
        const val EXTRA_TEXT = "text"

        @Volatile var instance: HubService? = null
            private set

        fun start(c: Context) {
            try { c.startForegroundService(Intent(c, HubService::class.java)) }
            catch (e: Exception) { Log.w(TAG, "can't start hub", e) }
        }
    }

    /** What the Mac last told us about itself (and the devices it watches). Windows PCs don't count:
     *  this feeds the phone's Mac tab. */
    @Volatile var macStatus: JSONObject? = null
        private set
    /** Every connected computer's name ("Finn's MacBook Air + Finn-Windows"), null when none. */
    val macName: String? get() = clients.map { it.name }.takeIf { it.isNotEmpty() }?.joinToString(" + ")
    val connected: Boolean get() = clients.isNotEmpty()
    @Volatile var transfer: String? = null   // "Sending photo.jpg 40 %" for the UI
        private set

    /** Last clipboard text that went either way (so an automatic copy isn't sent straight back). */
    @Volatile var lastClip: String? = null

    /** The activity showing the Mac's screen (gets SCREEN_* packets). */
    @Volatile var screenSink: ((Int, ByteArray) -> Unit)? = null

    /** Every connected computer (a Mac and a Windows PC can be linked at the same time). Things the
     *  phone announces (notifications, status, clipboard, events) go to all of them; answers to a
     *  request and the files it asked for go back to the one that asked ([origin]). */
    private val clients = java.util.concurrent.CopyOnWriteArrayList<Client>()
    /** The computer whose request this thread is answering (set by Features for its request thread). */
    val origin = ThreadLocal<Any?>()
    /** The computer showing its screen on this phone (SCREEN_* packets), if any. */
    @Volatile private var screenClient: Client? = null
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
                if (Regex("^https?://\\S+$").matches(url) && connected) sendJson(HubProto.EVENT, JSONObject().put("e", "open").put("url", url))
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
        clients.forEach { it.close() }
        nsdListener?.let { try { getSystemService(NsdManager::class.java).unregisterService(it) } catch (_: Exception) {} }
        multicastLock?.release()
        super.onDestroy()
    }

    // ---- public API (any thread) ----

    fun send(type: Int, payload: ByteArray = ByteArray(0)) { clients.forEach { it.control(type, payload) } }
    fun sendJson(type: Int, o: JSONObject) = send(type, o.toString().toByteArray())
    /** To the computer [to] (an [origin]); to every computer when [to] is null. */
    fun sendJsonTo(to: Any?, type: Int, o: JSONObject) {
        val c = to as? Client
        if (c != null) c.control(type, o.toString().toByteArray()) else sendJson(type, o)
    }

    /** Who a file goes to: the computer that asked, else every connected one. */
    private fun targets(): List<Client> = (origin.get() as? Client)?.let { listOf(it) } ?: clients.toList()

    fun sendClip(text: String) {
        if (!connected) { toast("Not connected to the Mac"); return }
        lastClip = text
        send(HubProto.CLIP, text.toByteArray()); toast("Copied to the Mac")
    }

    /** A copied picture -> the Mac's clipboard (FILE_BEGIN kind "clipimg"; the Mac keeps no copy in Downloads). */
    fun sendClipImage(u: Uri) {
        val to = clients.toList()
        if (to.isEmpty()) { toast("Not connected to the Mac"); return }
        Thread({
            try { to.forEach { sendOne(it, u, 0, "clipimg") }; toast("Picture copied to the Mac") }
            catch (e: Exception) { Log.w(TAG, "clip image", e) }
            transfer = null; updateNotification()
        }, "hub-clipimg").start()
    }

    /** The picture this app last put on the clipboard (from the Mac), so it isn't sent straight back. */
    @Volatile var clipImageUri: Uri? = null
    @Volatile var clipImageSetAt = 0L

    fun castStarted() = send(HubProto.CAST_READY)
    fun castStopped() = send(HubProto.CAST_STOPPED)

    fun sendFiles(uris: List<Uri>) {
        val to = clients.toList()
        if (to.isEmpty()) { toast("Not connected to the Mac"); return }
        Thread({
            for (c in to) for (u in uris) {
                if (c !in clients) break
                try { sendOne(c, u) } catch (e: Exception) { Log.w(TAG, "send $u", e); toast("Couldn't send a file: ${e.message}") }
            }
            transfer = null; updateNotification()
        }, "hub-send").start()
    }

    private fun sendOne(c: Client, u: Uri, req: Int = 0, kind: String? = null) {
        var name = "file"; var size = -1L
        try {
            contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cur ->
                if (cur.moveToFirst()) {
                    cur.getString(0)?.let { name = it }
                    if (!cur.isNull(1)) size = cur.getLong(1)
                }
            }
        } catch (_: Exception) {}   // e.g. MMS parts have no name/size columns
        if (name == "file") {
            val ext = contentResolver.getType(u)?.let { android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            name = "picture" + (ext?.let { ".$it" } ?: "")
        }
        sendStream(c, name, size, req, kind) { contentResolver.openInputStream(u)!! }
    }

    /** The Mac asked for a photo/video ([req] = its request id, so it knows where the file belongs). */
    fun sendUriAsFile(u: Uri, req: Int, kind: String? = null) {
        val to = targets()
        if (to.isEmpty()) return
        Thread({ for (c in to) try { sendOne(c, u, req, kind) } catch (e: Exception) { Log.w(TAG, "send $u", e) }; transfer = null; updateNotification() }, "hub-get").start()
    }

    /** A file or folder from the phone's storage (folders arrive as a .zip). */
    fun sendPathAsFile(rel: String, req: Int) {
        val c = targets().firstOrNull() ?: return
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

    /** [kind] tells the Mac what an unrequested file is for ("screenshot", "clipimg"); [req] answers a request. */
    private fun sendStream(c: Client, name: String, size: Long, req: Int, kind: String? = null, open: () -> java.io.InputStream) {
        val id = fileIds.getAndIncrement()
        c.control(HubProto.FILE_BEGIN, JSONObject().put("id", id).put("name", name).put("size", size).put("req", req).apply { if (kind != null) put("kind", kind) }.toString().toByteArray())
        var sent = 0L; var lastPct = -1
        open().use { ins ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                if (c !in clients) throw IllegalStateException("the Mac disconnected")
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
            val cl = Client(s, hello.optString("name", qr?.name ?: "Mac"), hello.optString("os", "mac"))
            c = cl
            // the same computer reconnecting replaces its old connection; other computers stay
            clients.filter { it.name == cl.name && it.os == cl.os }.forEach { clients.remove(it); it.close() }
            clients.add(cl)
            Log.i(TAG, "${cl.os} '${cl.name}' linked (${clients.size} connected)")
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
            if (c != null && clients.remove(c)) {
                Log.i(TAG, "${c.os} '${c.name}' left (${clients.size} connected)")
                if (clients.none { it.os != "windows" }) macStatus = null
                if (screenClient === c) { screenClient = null; screenSink?.invoke(-1, ByteArray(0)) }
                updateNotification()
            }
            try { s.close() } catch (_: Exception) {}
        }
    }

    private fun dispatch(c: Client, type: Int, p: ByteArray, files: HashMap<Int, Incoming>) {
        when (type) {
            HubProto.PING -> c.control(HubProto.PONG, p)
            HubProto.PONG -> {}
            HubProto.STATUS -> if (c.os != "windows") { macStatus = try { JSONObject(String(p)) } catch (_: Exception) { null } }
            HubProto.CLIP -> {
                val text = String(p)
                lastClip = text
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From the Mac", text))
                toast("Copied from the Mac")
            }
            HubProto.NOTIF_ACTION -> NotifListener.instance?.action(JSONObject(String(p)))
            HubProto.CAST_REQUEST -> requestCast()
            HubProto.REQ -> features.handle(JSONObject(String(p)), c)
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
            HubProto.SCREEN_FORMAT, HubProto.SCREEN_CONFIG, HubProto.SCREEN_FRAME, HubProto.SCREEN_DENIED -> {
                screenClient = c
                screenSink?.invoke(type, p)
            }
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
            .setContentTitle(tr("The Mac wants to show this phone"))
            .setContentText(tr("Tap to start sharing"))
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
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + if (clip) "/PhoneCast/Clipboard" else "/PhoneCast")
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
                // a picture copied on the Mac: onto this phone's clipboard, ready to paste. Android pastes
                // pictures from a file, so it is kept in Downloads/PhoneCast/Clipboard, but only the newest one.
                clipImageSetAt = SystemClock.elapsedRealtime(); clipImageUri = u
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newUri(contentResolver, "Picture from the Mac", u))
                Prefs.lastClipImage(this@HubService)?.let { old -> if (old != u.toString()) try { contentResolver.delete(Uri.parse(old), null, null) } catch (_: Exception) {} }
                Prefs.setLastClipImage(this@HubService, u.toString())
                toast("Picture copied from the Mac")
                return
            }
            val mime = contentResolver.getType(u) ?: "*/*"
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(u, mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(this@HubService, u.hashCode(), view, PendingIntent.FLAG_IMMUTABLE)
            getSystemService(NotificationManager::class.java).notify(u.hashCode(), Notification.Builder(this@HubService, CHANNEL_FILES)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(tr("From the Mac: {0}", name))
                .setContentText(tr("Saved in Downloads/PhoneCast · {0}", human(got)))
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
            try { if (connected) pushStatus() } catch (e: Exception) { Log.w(TAG, "status", e) }
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
        val text = transfer ?: if (connected) tr("Connected to {0}", macName ?: "Mac") else tr("Waiting for the Mac")
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(if (connected) R.drawable.ic_stat_phonecast else R.drawable.ic_stat_phonecast_off)
            .setContentTitle(tr("PhoneCast link"))
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification() {
        LauncherIcon.request(this, connected)
        try { getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification()) } catch (_: Exception) {}
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private fun toast(s: String) = main.post { android.widget.Toast.makeText(this, tr(s), android.widget.Toast.LENGTH_SHORT).show() }

    /**
     * One Mac. Two send queues: control packets (pings, notifications, input echoes) always go
     * before bulk packets (file chunks), so a big transfer never delays a notification.
     */
    /** One linked computer; [os] "mac" or "windows" (from its HELLO). */
    private class Client(val socket: Socket, val name: String, val os: String) {
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
