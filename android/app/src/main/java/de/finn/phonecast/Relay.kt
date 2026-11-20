package de.finn.phonecast

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Internet relay (see relay/ and the Mac's Relay.swift): lets a paired computer reach this phone from
 * any network without Tailscale. The phone keeps one control socket open to the relay; when a computer
 * opens a connection, the relay says {"open": id, "port": p} and the phone joins it with a socket to its
 * own server on 127.0.0.1 (like the USB cable), so the normal PIN/QR/TLS checks still decide who gets in.
 *
 * The room comes from the mirror key, which only this phone and its paired computers know.
 * Flow control: "a:<bytes>" acknowledges what was delivered; at most 2 MB are in flight per direction.
 */
object Relay {
    private const val TAG = "PhoneCastRelay"
    private const val BASE = "wss://phonecast-relay.fini240.workers.dev"
    private const val WINDOW = 2 shl 20
    private const val ACK_EVERY = 256 shl 10
    private val PORTS = setOf(Proto.PORT, HubProto.PORT)

    @Volatile private var running = false
    @Volatile private var control: WebSocket? = null
    @Volatile var online = false
        private set
    private val open = java.util.concurrent.atomic.AtomicInteger()
    /** Connections running through the relay right now. */
    val tunnels: Int get() = open.get()

    fun room(c: Context): String {
        val h = MessageDigest.getInstance("SHA-256").digest(("phonecast-relay:" + Prefs.token(c)).toByteArray())
        return h.joinToString("") { "%02x".format(it) }
    }

    @Synchronized
    fun start(c: Context) {
        if (running || !Prefs.relay(c)) return
        running = true
        val app = c.applicationContext
        Thread({ controlLoop(app) }, "pc-relay").start()
    }

    @Synchronized
    fun stop() {
        running = false
        online = false
        control?.close()
        control = null
    }

    /** After the toggle or a new PIN (= new mirror key, new room). */
    fun restart(c: Context) { stop(); start(c) }

    private fun controlLoop(c: Context) {
        var delay = 2_000L
        while (running) {
            try {
                val ws = WebSocket.connect("$BASE/v1/${room(c)}/phone")
                control = ws
                if (!running) { ws.close(); break }
                online = true
                delay = 2_000L
                Log.i(TAG, "online")
                val pinger = Thread({
                    try { while (running && control === ws) { Thread.sleep(30_000); ws.sendText("ping") } } catch (_: Exception) {}
                }, "pc-relay-ping").apply { isDaemon = true; start() }
                ws.soTimeout = 75_000   // a ping goes out every 30 s and the relay answers "pong"
                while (running) {
                    val m = ws.read() ?: break
                    if (m.text == null || m.text == "pong") continue
                    val o = try { JSONObject(m.text) } catch (_: Exception) { continue }
                    val id = o.optString("open"); val port = o.optInt("port")
                    if (id.isNotEmpty() && port in PORTS) Thread({ tunnel(c, id, port) }, "pc-relay-tunnel").start()
                }
                pinger.interrupt()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "control: ${e.message}")
            }
            online = false
            control?.close(); control = null
            if (running) { try { Thread.sleep(delay) } catch (_: InterruptedException) {}; delay = minOf(30_000L, delay * 2) }
        }
    }

    private fun tunnel(c: Context, id: String, port: Int) {
        var local: Socket? = null
        var ws: WebSocket? = null
        try {
            local = Socket().apply { tcpNoDelay = true; connect(InetSocketAddress("127.0.0.1", port), 2_000) }
            ws = WebSocket.connect("$BASE/v1/${room(c)}/accept?id=$id")
            ws.soTimeout = 0   // the mirror can be quiet from the computer's side for minutes; the protocols' own pings decide
            open.incrementAndGet()
            Log.i(TAG, "tunnel to port $port open")
            val lock = Object()
            var unacked = 0
            val sOut = local.getOutputStream()
            val w = ws
            // computer -> phone server
            val down = Thread({
                var consumed = 0
                try {
                    while (true) {
                        val m = w.read() ?: break
                        if (m.data != null) {
                            sOut.write(m.data); sOut.flush()
                            consumed += m.data.size
                            if (consumed >= ACK_EVERY) { w.sendText("a:$consumed"); consumed = 0 }
                        } else if (m.text != null && m.text.startsWith("a:")) {
                            val n = m.text.substring(2).toIntOrNull() ?: 0
                            synchronized(lock) { unacked -= n; lock.notifyAll() }
                        }
                    }
                } catch (_: Exception) {}
                try { local.close() } catch (_: Exception) {}
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
                w.sendBinary(buf, 0, n)
            }
        } catch (e: Exception) {
            Log.w(TAG, "tunnel to port $port: ${e.message}")
        } finally {
            try { local?.close() } catch (_: Exception) {}
            ws?.close()
            if (ws != null) open.decrementAndGet()
        }
    }
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
