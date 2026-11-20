package de.finn.phonecast

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Internet relay (see relay/ and the Mac's Relay.swift): lets a paired computer reach this phone from
 * any network without Tailscale. The phone keeps one control socket open to the relay; when a computer
 * opens a connection, the relay says {"open": id, "port": p} and the phone joins it with a socket to its
 * own server on 127.0.0.1 (like the USB cable), so the normal PIN/QR/TLS checks still decide who gets in.
 *
 * Every tunnel is encrypted end to end (RelayCrypto, AES-256-GCM from the mirror key), so the relay sees
 * neither the picture nor the link. The room comes from the mirror key too, which only this phone and
 * its paired computers know. The phone also reports its public IPv6 addresses, so a computer can try
 * a direct connection first.
 *
 * Doze: the control socket dies while the phone sleeps, so it reconnects right away when the screen
 * turns on or the phone switches networks, instead of waiting for the next retry.
 * Flow control: "a:<bytes>" acknowledges what was delivered; at most 2 MB are in flight per direction.
 */
object Relay {
    private const val TAG = "PhoneCastRelay"
    const val DEFAULT_BASE = "wss://phonecast-relay.fini240.workers.dev"
    private const val WINDOW = 2 shl 20
    private const val ACK_EVERY = 256 shl 10
    private val PORTS = setOf(Proto.PORT, HubProto.PORT)

    @Volatile private var running = false
    @Volatile private var control: WebSocket? = null
    @Volatile var online = false
        private set
    /** The relay refused this phone (not on its ALLOWED list): no new tries before this time. */
    @Volatile var refusedUntil = 0L
        private set
    private val open = java.util.concurrent.atomic.AtomicInteger()
    /** Connections running through the relay right now. */
    val tunnels: Int get() = open.get()
    private val wake = Object()
    @Volatile private var woken = false
    private var app: Context? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var screenReceiver: BroadcastReceiver? = null
    @Volatile private var lastNetwork: Network? = null
    @Volatile private var lastAddrs = ""
    /** Bumped by every start: an old loop that's still sleeping ends instead of running twice. */
    @Volatile private var generation = 0
    @Volatile private var lastAlive = 0L

    fun room(c: Context): String {
        val h = MessageDigest.getInstance("SHA-256").digest(("phonecast-relay:" + Prefs.token(c)).toByteArray())
        return h.joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    fun start(c: Context) {
        if (running || !Prefs.relay(c)) return
        running = true
        val a = c.applicationContext
        app = a
        watch(a)
        val gen = ++generation
        Thread({ controlLoop(a, gen) }, "pc-relay").start()
    }

    @Synchronized
    fun stop() {
        running = false
        online = false
        control?.close()
        control = null
        app?.let { a ->
            netCallback?.let { try { a.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } catch (_: Exception) {} }
            screenReceiver?.let { try { a.unregisterReceiver(it) } catch (_: Exception) {} }
        }
        netCallback = null; screenReceiver = null; lastNetwork = null
        kick()
    }

    /** After the toggle, a new PIN (= new mirror key, new room) or a new relay address. */
    fun restart(c: Context) { stop(); refusedUntil = 0; start(c) }

    /** Try again now (the screen came on, or another network), skipping the back-off. */
    private fun kick() { synchronized(wake) { woken = true; wake.notifyAll() } }

    private fun watch(c: Context) {
        val cm = c.getSystemService(ConnectivityManager::class.java)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val before = lastNetwork
                lastNetwork = network
                if (before != null && before != network) {
                    Log.i(TAG, "network changed, reconnecting")
                    control?.close()   // that socket belonged to the old network
                }
                kick()
            }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) { sendAddrs() }
        }
        try { cm.registerDefaultNetworkCallback(cb); netCallback = cb } catch (e: Exception) { Log.w(TAG, "no network callback", e) }
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, i: Intent) { if (!online) kick() }
        }
        try { c.registerReceiver(r, IntentFilter(Intent.ACTION_SCREEN_ON).apply { addAction(Intent.ACTION_USER_PRESENT) }); screenReceiver = r }
        catch (e: Exception) { Log.w(TAG, "no screen receiver", e) }
    }

    /** Public (2000::/3) IPv6 addresses a computer could reach directly; not Tailscale's, not local ones. */
    fun publicIPv6(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.name.startsWith("tun") }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet6Address>()
            .filter { (it.address[0].toInt() and 0xE0) == 0x20 }
            .map { it.hostAddress!!.substringBefore('%') }
            .distinct().take(4)
    } catch (_: Exception) { emptyList() }

    /** Private IPv4 addresses (home Wi-Fi): lets a computer see the phone isn't on its network and use the relay first. */
    fun lanIPv4(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.name.startsWith("tun") && !it.name.startsWith("rmnet") }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<java.net.Inet4Address>().filter { it.isSiteLocalAddress }
            .map { it.hostAddress!! }.distinct().take(4)
    } catch (_: Exception) { emptyList() }

    private fun sendAddrs(force: Boolean = false) {
        val ws = control ?: return
        val a = publicIPv6(); val lan = lanIPv4()
        val sig = a.joinToString(",") + "|" + lan.joinToString(",")
        if (!force && sig == lastAddrs) return
        lastAddrs = sig
        try { ws.sendText(JSONObject().put("addrs", JSONArray(a)).put("lan", JSONArray(lan)).toString()) } catch (_: Exception) {}
    }

    private fun base(c: Context) = Prefs.relayUrl(c).ifEmpty { DEFAULT_BASE }

    private fun controlLoop(c: Context, gen: Int) {
        var delay = 2_000L
        while (running && gen == generation) {
            woken = false
            val now = System.currentTimeMillis()
            if (now < refusedUntil) { pause(refusedUntil - now); continue }
            try {
                val ws = WebSocket.connect("${base(c)}/v1/${room(c)}/phone")
                control = ws
                if (!running || gen != generation) { ws.close(); break }
                online = true
                delay = 2_000L
                Log.i(TAG, "online")
                sendAddrs(force = true)
                // keep-alive answered by the relay's own code (not the runtime): no "alive" within 15 s means
                // the relay doesn't use this socket any more (network gone, replaced), so reconnect
                lastAlive = System.currentTimeMillis()
                val pinger = Thread({
                    try {
                        while (running && control === ws) {
                            val sent = System.currentTimeMillis()
                            ws.sendText("alive?")
                            Thread.sleep(15_000)
                            if (control !== ws) break
                            if (lastAlive < sent) { Log.w(TAG, "the relay stopped answering, reconnecting"); ws.close(); break }
                            Thread.sleep(30_000)
                        }
                    } catch (_: Exception) {}
                }, "pc-relay-ping").apply { isDaemon = true; start() }
                ws.soTimeout = 90_000
                while (running && gen == generation) {
                    val m = ws.read() ?: break
                    if (m.text == "alive") { lastAlive = System.currentTimeMillis(); continue }
                    if (m.text == null || m.text == "pong") continue
                    val o = try { JSONObject(m.text) } catch (_: Exception) { continue }
                    val id = o.optString("open"); val port = o.optInt("port")
                    if (id.isNotEmpty() && port in PORTS) Thread({ tunnel(c, id, port) }, "pc-relay-tunnel").start()
                }
                pinger.interrupt()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "control: ${e.message}")
                if (e.message?.contains(" 403") == true) {
                    // this relay only serves the phones on its list (relay/allow.sh)
                    refusedUntil = System.currentTimeMillis() + 3_600_000
                    Log.w(TAG, "the relay refused this phone; trying again in an hour")
                }
            }
            if (gen != generation) break
            online = false
            control?.close(); control = null
            if (running) { pause(delay); delay = minOf(30_000L, delay * 2) }
        }
    }

    private fun pause(ms: Long) {
        synchronized(wake) { if (!woken) try { wake.wait(ms) } catch (_: InterruptedException) {} }
    }

    private fun tunnel(c: Context, id: String, port: Int) {
        var local: Socket? = null
        var ws: WebSocket? = null
        try {
            ws = WebSocket.connect("${base(c)}/v1/${room(c)}/accept?id=$id")
            ws.soTimeout = 15_000
            // the computer's first message: the salt for this tunnel's keys
            val first = ws.read()?.text
            require(first != null && first.startsWith("s:") && first.length == 34) { "no salt" }
            val crypto = RelayCrypto(Prefs.token(c), hex(first.substring(2)), phone = true)
            ws.soTimeout = 0   // the mirror can be quiet from the computer's side for minutes; the protocols' own pings decide
            local = Socket().apply { tcpNoDelay = true; connect(InetSocketAddress("127.0.0.1", port), 2_000) }
            open.incrementAndGet()
            Log.i(TAG, "tunnel to port $port open")
            val lock = Object()
            var unacked = 0
            val sOut = local.getOutputStream()
            val w = ws
            val l = local
            // computer -> phone server
            val down = Thread({
                var consumed = 0
                try {
                    while (true) {
                        val m = w.read() ?: break
                        if (m.data != null) {
                            val d = crypto.open(m.data) ?: throw SecurityException("a message failed the end-to-end check")
                            sOut.write(d); sOut.flush()
                            consumed += d.size
                            if (consumed >= ACK_EVERY) { w.sendText("a:$consumed"); consumed = 0 }
                        } else if (m.text != null && m.text.startsWith("a:")) {
                            val n = m.text.substring(2).toIntOrNull() ?: 0
                            synchronized(lock) { unacked -= n; lock.notifyAll() }
                        }
                    }
                } catch (e: Exception) { if (e is SecurityException) Log.w(TAG, e.message ?: "") }
                try { l.close() } catch (_: Exception) {}
                w.close()
                synchronized(lock) { lock.notifyAll() }
            }, "pc-relay-down")
            down.start()
            // phone server -> computer (video, link packets)
            val sIn = local.getInputStream()
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = sIn.read(buf)
                if (n < 0) break
                if (n == 0) continue
                synchronized(lock) {
                    // a slow network blocks here, so the stream server drops frames as on slow Wi-Fi
                    while (unacked > WINDOW && down.isAlive) lock.wait(1_000)
                    unacked += n
                }
                if (!down.isAlive) break
                val sealed = crypto.seal(buf, n)
                w.sendBinary(sealed, 0, sealed.size)
            }
        } catch (e: Exception) {
            Log.w(TAG, "tunnel to port $port: ${e.message}")
        } finally {
            try { local?.close() } catch (_: Exception) {}
            ws?.close()
            if (local != null) open.decrementAndGet()
        }
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/**
 * End-to-end encryption of one tunnel, the same as RelayCrypto in the Mac's Relay.swift:
 * base = HMAC-SHA256(mirrorKey, "phonecast-relay-e2e"); up = HMAC(base, salt‖"up") (computer→phone),
 * down = HMAC(base, salt‖"down"); AES-256-GCM, ciphertext‖tag, nonce = 4 zero bytes ‖ 64-bit counter.
 */
class RelayCrypto(mirrorKey: String, salt: ByteArray, phone: Boolean) {
    private val sendKey: SecretKeySpec
    private val recvKey: SecretKeySpec
    private var sent = 0L
    private var received = 0L

    init {
        val base = hmac(mirrorKey.toByteArray(), "phonecast-relay-e2e".toByteArray())
        val up = SecretKeySpec(hmac(base, salt + "up".toByteArray()), "AES")
        val down = SecretKeySpec(hmac(base, salt + "down".toByteArray()), "AES")
        sendKey = if (phone) down else up
        recvKey = if (phone) up else down
    }

    private fun hmac(k: ByteArray, m: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(k, "HmacSHA256")); doFinal(m) }
    private fun nonce(n: Long) = GCMParameterSpec(128, ByteBuffer.allocate(12).putInt(0).putLong(n).array())

    fun seal(b: ByteArray, len: Int): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE, sendKey, nonce(sent++)); doFinal(b, 0, len) }

    fun open(b: ByteArray): ByteArray? = try {
        Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.DECRYPT_MODE, recvKey, nonce(received)); doFinal(b) }.also { received++ }
    } catch (_: Exception) { null }
}

/** Just enough of a WebSocket client (RFC 6455) for the relay: TLS, binary/text, ping/pong, close. */
class WebSocket private constructor(private val sock: SSLSocket) {
    class Msg(val data: ByteArray?, val text: String?)

    private val ins = DataInputStream(BufferedInputStream(sock.getInputStream(), 64 * 1024))
    private val out: OutputStream = sock.getOutputStream()
    private val rnd = SecureRandom()
    @Volatile private var closed = false

    var soTimeout: Int
        get() = sock.soTimeout
        set(v) { sock.soTimeout = v }

    companion object {
        fun connect(url: String): WebSocket {
            val u = URI(url)
            val host = u.host
            val s = SSLSocketFactory.getDefault().createSocket() as SSLSocket
            s.connect(InetSocketAddress(host, if (u.port > 0) u.port else 443), 10_000)
            s.sslParameters = s.sslParameters.apply { serverNames = listOf(SNIHostName(host)) }
            s.tcpNoDelay = true
            s.soTimeout = 15_000
            s.startHandshake()
            val key = Base64.encodeToString(ByteArray(16).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP)
            val path = u.rawPath + (u.rawQuery?.let { "?$it" } ?: "")
            s.outputStream.write(("GET $path HTTP/1.1\r\nHost: $host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nUser-Agent: PhoneCast\r\n\r\n").toByteArray())
            s.outputStream.flush()
            val status = readLine(s.inputStream)
            while (readLine(s.inputStream).isNotEmpty()) { /* headers */ }
            if (!status.contains(" 101")) { s.close(); throw java.io.IOException("relay: $status") }
            return WebSocket(s)
        }

        private fun readLine(i: InputStream): String {
            val sb = StringBuilder()
            while (true) {
                val b = i.read()
                if (b < 0) throw java.io.EOFException()
                if (b == '\n'.code) return sb.toString().trimEnd('\r')
                sb.append(b.toChar())
                if (sb.length > 8192) throw java.io.IOException("header too long")
            }
        }
    }

    fun sendText(t: String) { val b = t.toByteArray(); frame(0x1, b, 0, b.size) }
    fun sendBinary(b: ByteArray, off: Int, len: Int) = frame(0x2, b, off, len)

    @Synchronized
    private fun frame(op: Int, b: ByteArray, off: Int, len: Int) {
        if (closed) throw java.io.IOException("closed")
        val head = java.io.ByteArrayOutputStream(14)
        head.write(0x80 or op)
        when {
            len < 126 -> head.write(0x80 or len)
            len < 65536 -> { head.write(0x80 or 126); head.write(len shr 8); head.write(len and 0xff) }
            else -> { head.write(0x80 or 127); for (i in 7 downTo 0) head.write(((len.toLong() shr (8 * i)) and 0xff).toInt()) }
        }
        val mask = ByteArray(4).also { rnd.nextBytes(it) }
        head.write(mask)
        val p = ByteArray(len)
        for (i in 0 until len) p[i] = (b[off + i].toInt() xor mask[i and 3].toInt()).toByte()
        out.write(head.toByteArray()); out.write(p); out.flush()
    }

    /** The next data message, or null when the socket closed. */
    fun read(): Msg? {
        var op = 0
        var acc: java.io.ByteArrayOutputStream? = null
        while (true) {
            val b0 = ins.read()
            if (b0 < 0) return null
            val b1 = ins.readUnsignedByte()
            val fin = b0 and 0x80 != 0
            val opcode = b0 and 0x0f
            var len = (b1 and 0x7f).toLong()
            if (len == 126L) len = ins.readUnsignedShort().toLong() else if (len == 127L) len = ins.readLong()
            if (len < 0 || len > (16 shl 20)) throw java.io.IOException("frame too big")
            val mask = if (b1 and 0x80 != 0) ByteArray(4).also { ins.readFully(it) } else null
            val p = ByteArray(len.toInt()).also { ins.readFully(it) }
            if (mask != null) for (i in p.indices) p[i] = (p[i].toInt() xor mask[i and 3].toInt()).toByte()
            when (opcode) {
                0x8 -> { close(); return null }
                0x9 -> { frame(0xA, p, 0, p.size); continue }
                0xA -> continue
                0x0 -> acc?.write(p)
                else -> { op = opcode; acc = java.io.ByteArrayOutputStream(p.size).also { it.write(p) } }
            }
            if (fin && acc != null) {
                val d = acc.toByteArray()
                return if (op == 0x1) Msg(null, String(d)) else Msg(d, null)
            }
        }
    }

    fun close() {
        if (closed) return
        try { synchronized(this) { out.write(byteArrayOf(0x88.toByte(), 0x82.toByte(), 0, 0, 0, 0, 0x03, 0xE8.toByte())); out.flush() } } catch (_: Exception) {}
        closed = true
        try { sock.close() } catch (_: Exception) {}
    }
}
