package de.finn.phonecast

import android.util.Log
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * One TCP server, up to [MAX_VIEWERS] viewers at once (e.g. the Mac and a Windows PC). The picture is
 * encoded once and every frame goes to each viewer (UDP or TCP per viewer); all of them can control
 * the phone. Each viewer gets its own range of finger ids ([FINGER_SLOT] per viewer), so their
 * touches never collide, and "cancel all" from one viewer only lifts that viewer's fingers.
 * A viewer reconnecting from the same address replaces its old connection.
 * Video is pushed through a small queue per viewer; if the network can't keep up the queue is
 * dropped and that viewer waits for the next keyframe instead of building up delay.
 */
class StreamServer(
    private val ctx: android.content.Context,
    private val listener: Listener,
) {
    interface Listener {
        fun requestKeyFrame()
        fun onClientChanged(address: String?)
        fun onInput(type: Int, payload: ByteArray)
        fun onSettings(maxSize: Int, bitrateMbps: Int)
        fun onResolution(w: Int, h: Int, long: Int): Int
        fun controlAvailable(): Boolean
        /** Extra phone health appended to STATS (PhoneStats). */
        fun phoneStats(): ByteArray = ByteArray(0)
    }

    @Volatile private var serverSocket: ServerSocket? = null
    private val clients = java.util.concurrent.CopyOnWriteArrayList<Client>()
    @Volatile private var running = false

    @Volatile private var width = 0
    @Volatile private var height = 0
    @Volatile private var config: ByteArray? = null

    /** Every connected viewer's address ("192.168.1.5 + 127.0.0.1"), null when nobody watches. */
    val clientAddress: String? get() = describe()

    private fun describe(): String? = clients.map { it.address }.takeIf { it.isNotEmpty() }?.joinToString(" + ")

    /** Wi-Fi only: video over UDP once a viewer answers (the cable keeps TCP). */
    private var udp: UdpVideo? = null

    private fun onUdpTarget(c: Client, on: Boolean) {
        if (c !in clients) return
        c.udpOn = on
        c.sendControl(packet(if (on) Proto.UDP_ON else Proto.UDP_OFF, ByteArray(0)))
        c.waitingForKey = true
        listener.requestKeyFrame()
    }

    fun start() {
        running = true
        udp = try { UdpVideo() } catch (e: Exception) { Log.w(TAG, "no UDP video", e); null }
        Thread({ acceptLoop() }, "pc-accept").start()
        Thread({ watchdog() }, "pc-watchdog").start()
    }

    /** Viewers ping every 0.5 s. One that went silent (network gone without a FIN) is dropped, so it
     *  doesn't hold a slot or slow the others down. */
    private fun watchdog() {
        while (running) {
            try { Thread.sleep(2000) } catch (_: InterruptedException) { return }
            val now = android.os.SystemClock.uptimeMillis()
            for (c in clients) if (now - c.lastSeen > 15_000) { Log.i(TAG, "viewer ${c.address} silent, dropping"); retire(c) }
        }
    }

    /** [reason]: tell the Mac why first (Proto.STOP_*), so it doesn't sit on a black screen. */
    fun stop(reason: Int? = null) {
        running = false
        udp?.close(); udp = null
        try { serverSocket?.close() } catch (_: Exception) {}
        val all = clients.toList()
        clients.clear()
        if (all.isEmpty()) return
        if (reason == null) { all.forEach { it.close() }; return }
        all.forEach { it.sendControl(packet(Proto.STOPPED, byteArrayOf(reason.toByte()))) }
        Thread({ Thread.sleep(300); all.forEach { it.close() } }, "pc-bye").start() // let the send loops flush it
    }

    private fun acceptLoop() {
        try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(Proto.PORT))
            serverSocket = ss
            while (running) {
                val s = ss.accept()
                Thread({ handshake(s) }, "pc-client").start()
            }
        } catch (e: Exception) {
            if (running) Log.e(TAG, "accept loop died", e)
        }
    }

    private fun handshake(s: Socket) {
        try {
            s.tcpNoDelay = true
            s.soTimeout = 10_000
            s.sendBufferSize = 1 shl 20
            val input = DataInputStream(s.getInputStream())
            val nonce = Auth.nonce()
            s.getOutputStream().write(packet(Proto.NONCE, nonce))
            val type = input.readUnsignedByte()
            val len = input.readUnsignedShort()
            val payload = ByteArray(len).also { input.readFully(it) }
            if (type != Proto.HELLO || !Auth.checkMirrorHello(ctx, String(payload, Charsets.UTF_8), nonce)) {
                Log.w(TAG, "rejected ${s.inetAddress}: bad pin")
                s.getOutputStream().write(packet(Proto.HELLO_BAD, ByteArray(0)))
                s.close()
                return
            }
            s.soTimeout = 0

            // The same viewer reconnecting (Wi-Fi change, restart) replaces its old connection;
            // past MAX_VIEWERS the oldest one goes.
            val addr = s.inetAddress?.hostAddress ?: "?"
            val c: Client
            synchronized(clients) {
                clients.filter { it.address == addr }.forEach { retire(it) }
                while (clients.size >= MAX_VIEWERS) retire(clients[0])
                val used = clients.map { it.slot }.toSet()
                c = Client(s, (0 until MAX_VIEWERS).first { it !in used })
                clients.add(c)
            }
            c.sendControl(packet(Proto.HELLO_OK, byteArrayOf(if (listener.controlAvailable()) 1 else 0)))
            if (width > 0) c.sendControl(formatPacket())
            config?.let { c.sendControl(packet(Proto.CONFIG, it)) }
            c.waitingForKey = true
            listener.requestKeyFrame()
            listener.onClientChanged(describe())
            Log.i(TAG, "viewer ${c.address} joined (slot ${c.slot}, ${clients.size} watching)")
            // Wi-Fi: offer video over UDP (the cable arrives via 127.0.0.1 and stays on TCP)
            val u = udp
            if (u != null && !s.inetAddress.isLoopbackAddress) {
                val token = java.security.SecureRandom().nextInt().let { if (it == 0) 1 else it }
                c.udpToken = token
                u.add(token) { on -> onUdpTarget(c, on) }
                c.sendControl(packet(Proto.UDP_TOKEN, ByteBuffer.allocate(6).putInt(token).putShort(Proto.UDP_PORT.toShort()).array()))
            }

            while (true) {
                val t = input.readUnsignedByte()
                val l = input.readUnsignedShort()
                val p = ByteArray(l).also { input.readFully(it) }
                c.lastSeen = android.os.SystemClock.uptimeMillis()
                if (t == Proto.TOUCH && p.size >= 2) {
                    // this viewer's own finger ids (cancel-all then only lifts this viewer's fingers)
                    p[1] = (c.slot * FINGER_SLOT + (p[1].toInt() and (FINGER_SLOT - 1))).toByte()
                    listener.onInput(t, p)
                } else if (t == Proto.KEYFRAME) {
                    c.waitingForKey = true
                    listener.requestKeyFrame()
                } else if (t == Proto.PING) {
                    c.sendControl(packet(Proto.PONG, p))
                    // heartbeat: tell the Mac whether tapping is available right now
                    c.sendControl(packet(Proto.CONTROL, byteArrayOf(if (listener.controlAvailable()) 1 else 0)))
                    val extra = listener.phoneStats()
                    c.sendControl(packet(Proto.STATS, ByteBuffer.allocate(4 + extra.size).putInt(c.resyncs).put(extra).array()))
                } else if (t == Proto.RESOLUTION && p.size >= 4) {
                    val w = ((p[0].toInt() and 0xff) shl 8) or (p[1].toInt() and 0xff)
                    val h = ((p[2].toInt() and 0xff) shl 8) or (p[3].toInt() and 0xff)
                    val long = if (p.size >= 6) ((p[4].toInt() and 0xff) shl 8) or (p[5].toInt() and 0xff) else 0
                    c.sendControl(packet(Proto.RES_RESULT, byteArrayOf(listener.onResolution(w, h, long).toByte())))
                } else if (t == Proto.SETTINGS && p.size >= 3) {
                    val max = ((p[0].toInt() and 0xff) shl 8) or (p[1].toInt() and 0xff)
                    listener.onSettings(max, p[2].toInt() and 0xff)
                } else {
                    listener.onInput(t, p)
                }
            }
        } catch (_: EOFException) {
        } catch (e: Exception) {
            Log.i(TAG, "client ended: ${e.message}")
        } finally {
            try { s.close() } catch (_: Exception) {}
            clients.firstOrNull { it.socket === s }?.let { retire(it) }
        }
    }

    // ---- called by encoder / audio threads ----

    fun setFormat(w: Int, h: Int) {
        width = w; height = h
        config = null
        val f = formatPacket()
        clients.forEach { it.sendControl(f) }
    }

    fun onConfig(bytes: ByteArray) {
        // (UDP keyframes carry it too: a datagram can overtake the TCP CONFIG)
        config = bytes
        val p = packet(Proto.CONFIG, bytes)
        clients.forEach { it.sendControl(p) }
    }

    fun onFrame(bytes: ByteArray, key: Boolean) {
        if (clients.isEmpty()) return
        // built once, shared by every viewer
        var udpPayload: ByteArray? = null
        var tcpPacket: ByteArray? = null
        for (c in clients) {
            if (c.udpOn && c.udpToken != 0) {
                if (udpPayload == null) {
                    // (UDP keyframes carry the config too: a datagram can overtake the TCP CONFIG)
                    val cfg = if (key) config else null
                    udpPayload = ByteArray(1 + (cfg?.size ?: 0) + bytes.size).also {
                        it[0] = if (key) 1 else 0
                        if (cfg != null) System.arraycopy(cfg, 0, it, 1, cfg.size)
                        System.arraycopy(bytes, 0, it, 1 + (cfg?.size ?: 0), bytes.size)
                    }
                }
                if (udp?.send(c.udpToken, udpPayload) == true) continue
            }
            if (tcpPacket == null) {
                tcpPacket = ByteBuffer.allocate(5 + 1 + bytes.size)
                    .put(Proto.FRAME.toByte()).putInt(1 + bytes.size).put(if (key) 1.toByte() else 0.toByte()).put(bytes).array()
            }
            c.sendVideo(tcpPacket, key)
        }
    }

    fun onAudio(bytes: ByteArray) {
        if (clients.isEmpty()) return
        val p = packet(Proto.AUDIO, bytes)
        clients.forEach { it.sendAudio(p) }
    }

    fun onControlChanged(available: Boolean) {
        val p = packet(Proto.CONTROL, byteArrayOf(if (available) 1 else 0))
        clients.forEach { it.sendControl(p) }
    }

    private fun formatPacket(): ByteArray =
        packet(Proto.FORMAT, ByteBuffer.allocate(8).putInt(width).putInt(height).array())

    private fun packet(type: Int, payload: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    /** A viewer leaves (closed, replaced by its own reconnect, or silent): lift its fingers, stop its
     *  UDP video and close it. Safe to call more than once. */
    private fun retire(c: Client) {
        if (!clients.remove(c)) return
        if (c.udpToken != 0) udp?.remove(c.udpToken)
        listener.onInput(Proto.TOUCH, byteArrayOf(Proto.TOUCH_CANCEL_ALL.toByte(), (c.slot * FINGER_SLOT).toByte(), 0, 0, 0, 0))
        c.close()
        Log.i(TAG, "viewer ${c.address} left (${clients.size} watching)")
        listener.onClientChanged(describe())
    }

    private inner class Client(val socket: Socket, val slot: Int) {
        val address: String = socket.inetAddress?.hostAddress ?: "?"
        @Volatile var udpOn = false
        @Volatile var udpToken = 0
        @Volatile var lastSeen = android.os.SystemClock.uptimeMillis()
        private val queue = ArrayBlockingQueue<ByteArray>(48)
        private val queuedVideo = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile var waitingForKey = false
        /** How often video fell behind and frames were skipped up to the next keyframe. */
        @Volatile var resyncs = 0
        @Volatile private var open = true
        private val out = BufferedOutputStream(socket.getOutputStream(), 1 shl 16)

        init {
            Thread({ sendLoop() }, "pc-send").start()
        }

        private fun sendLoop() {
            try {
                while (open) {
                    val first = queue.poll(500, TimeUnit.MILLISECONDS) ?: continue
                    write(first)
                    // batch whatever is already waiting, then flush once
                    while (true) {
                        val next = queue.poll() ?: break
                        write(next)
                    }
                    out.flush()
                }
            } catch (_: Exception) {
                close()
            }
        }

        private fun write(pkt: ByteArray) {
            if (pkt[0].toInt() == Proto.FRAME) queuedVideo.decrementAndGet()
            out.write(pkt)
        }

        fun sendVideo(pkt: ByteArray, key: Boolean) {
            if (waitingForKey) {
                if (!key) return
                waitingForKey = false
            }
            // More than a few frames waiting means the network is behind: showing old
            // frames late is worse than skipping ahead, so drop and resync on a keyframe.
            if (!key && queuedVideo.get() >= 3) {
                resyncs++
                waitingForKey = true
                listener.requestKeyFrame()
                return
            }
            queuedVideo.incrementAndGet()
            if (!queue.offer(pkt)) {
                queuedVideo.decrementAndGet()
                // network is behind: throw away the backlog and resync on a keyframe
                queue.clear()
                resyncs++
                waitingForKey = true
                listener.requestKeyFrame()
            }
        }

        fun sendAudio(pkt: ByteArray) {
            if (queue.remainingCapacity() > 12) queue.offer(pkt)
        }

        fun sendControl(pkt: ByteArray) {
            if (!queue.offer(pkt)) {
                queue.clear()
                queuedVideo.set(0)
                queue.offer(pkt)
                waitingForKey = true
                listener.requestKeyFrame()
            }
        }

        fun close() {
            open = false
            try { socket.close() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "PhoneCast"
        const val MAX_VIEWERS = 4
        /** Finger ids per viewer: viewer k uses k*16 .. k*16+15 (a viewer itself uses 0..9). */
        const val FINGER_SLOT = 16
    }
}
