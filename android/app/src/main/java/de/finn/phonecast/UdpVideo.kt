package de.finn.phonecast

import android.os.SystemClock
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer

/**
 * Wi-Fi video over UDP (like Moonlight): TCP stalls the whole stream until a lost packet is resent,
 * which on Wi-Fi shows up as 30–150 ms spikes. Here every frame is split into datagrams plus XOR
 * repair datagrams, so the Mac rebuilds lost pieces instead of waiting. A frame that can't be
 * rebuilt is dropped and the Mac asks for a keyframe (over TCP).
 *
 * Each viewer learns its own [token] over its authenticated TCP link and sends "PCU1"+token to
 * [Proto.UDP_PORT] every second; that tells us where to send its video. No hello for 3 s -> that
 * viewer goes back to TCP. Several viewers can watch at once; every frame goes to each of them.
 *
 * Datagram: u8 0xC5, u8 flags (1 = repair), u32 frame id, u16 index, u16 data count n,
 * u16 repair count p, u32 frame length, then up to [SHARD] bytes. Repair j is the XOR of the data
 * pieces i with i % p == j (zero-padded), so p lost pieces in a row can be rebuilt.
 */
class UdpVideo {
    companion object {
        const val SHARD = 1200
        private const val HEADER = 16
        private const val TAG = "PhoneCastUDP"
        /**
         * Pacing: a keyframe is up to ~900 datagrams; fired out at once they overflow the Wi-Fi
         * queue and its tail is lost. Above this rate (bytes/s) we wait a little between batches.
         */
        private const val PACE_BYTES_PER_S = 15_000_000L
        private const val BATCH = 16
        /** Repair overhead: ~25% of the data pieces. */
        fun repairCount(n: Int) = maxOf(1, (n + 3) / 4)
    }

    private val sock = DatagramSocket(null).apply {
        reuseAddress = true
        bind(InetSocketAddress(Proto.UDP_PORT))
        sendBufferSize = 4 shl 20
        soTimeout = 500
        trafficClass = 0xB8 // DSCP EF: Wi-Fi puts it in the voice/video queue
    }

    /** One watching viewer. [onTarget] tells its TCP connection that UDP video starts/stops. */
    private class Viewer(val onTarget: (Boolean) -> Unit) {
        @Volatile var target: SocketAddress? = null
        @Volatile var lastHello = 0L
        /** Frame ids per viewer: the viewer delivers frames strictly in order (id, id+1, ...). */
        var frameId = 0
        val recent = object : LinkedHashMap<Int, ByteArray>() {
            override fun removeEldestEntry(e: MutableMap.MutableEntry<Int, ByteArray>?) = size > 24
        }
    }
    private val viewers = java.util.concurrent.ConcurrentHashMap<Int, Viewer>()
    @Volatile private var open = true
    private val out = ByteArray(HEADER + SHARD)

    init {
        Thread({ receiveLoop() }, "pc-udp-in").start()
    }

    private fun isTag(buf: ByteArray, c: Char) =
        buf[0] == 'P'.code.toByte() && buf[1] == 'C'.code.toByte() && buf[2] == c.code.toByte() && buf[3] == '1'.code.toByte()

    private fun receiveLoop() {
        val buf = ByteArray(1500)
        val p = DatagramPacket(buf, buf.size)
        while (open) {
            try {
                p.length = buf.size
                sock.receive(p)
                val token = if (p.length >= 8) ByteBuffer.wrap(buf, 4, 4).int else 0
                val v = if (token != 0) viewers[token] else null
                if (v != null && p.length >= 8 && isTag(buf, 'U')) {
                    v.lastHello = SystemClock.uptimeMillis()
                    if (v.target != p.socketAddress) {
                        val first = v.target == null
                        v.target = p.socketAddress
                        Log.i(TAG, "video over UDP to ${p.socketAddress}")
                        if (first) v.onTarget(true)
                    }
                } else if (v != null && p.length >= 16 && isTag(buf, 'R')) {
                    // resend request: u32 frame id, then (u16 start, u16 count) ranges of data pieces
                    val bb = ByteBuffer.wrap(buf, 8, p.length - 8)
                    val id = bb.int
                    val ranges = ArrayList<Pair<Int, Int>>()
                    while (bb.remaining() >= 4) ranges.add((bb.short.toInt() and 0xffff) to (bb.short.toInt() and 0xffff))
                    resend(v, id, ranges)
                }
            } catch (_: SocketTimeoutException) {
            } catch (e: Exception) {
                if (open) Log.w(TAG, "receive", e)
            }
            val now = SystemClock.uptimeMillis()
            for (v in viewers.values) {
                if (v.target != null && now - v.lastHello > 3000) {
                    v.target = null
                    Log.i(TAG, "no hello from a viewer for 3 s: its video back to TCP")
                    v.onTarget(false)
                }
            }
        }
    }

    /** A new viewer (its TCP connection hands it [token]). */
    fun add(token: Int, onTarget: (Boolean) -> Unit) { viewers[token] = Viewer(onTarget) }

    /** The viewer's TCP connection closed. */
    fun remove(token: Int) {
        val v = viewers.remove(token) ?: return
        if (v.target != null) { v.target = null; v.onTarget(false) }
    }

    @Volatile var resent = 0
        private set
    private val resendOut = ByteArray(HEADER + SHARD)

    private fun resend(v: Viewer, id: Int, ranges: List<Pair<Int, Int>>) {
        val to = v.target ?: return
        val frame = synchronized(v.recent) { v.recent[id] } ?: return
        val n = (frame.size + SHARD - 1) / SHARD
        val p = repairCount(n)
        var k = 0
        try {
            synchronized(resendOut) {
                for ((start, count) in ranges) {
                    for (i in start until minOf(n, start + count)) {
                        val off = i * SHARD
                        val len = minOf(SHARD, frame.size - off)
                        ByteBuffer.wrap(resendOut, 0, HEADER)
                            .put(0xC5.toByte()).put(0).putInt(id)
                            .putShort(i.toShort()).putShort(n.toShort()).putShort(p.toShort()).putInt(frame.size)
                        System.arraycopy(frame, off, resendOut, HEADER, len)
                        sock.send(DatagramPacket(resendOut, HEADER + len, to))
                        resent++
                        if (++k % BATCH == 0) java.util.concurrent.locks.LockSupport.parkNanos(BATCH * 1300L * 1_000_000_000L / PACE_BYTES_PER_S)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "resend failed: ${e.message}")
        }
    }

    /** Called by the encoder thread. Returns false if this viewer has no UDP target (use TCP). */
    @Synchronized
    fun send(token: Int, frame: ByteArray): Boolean {
        val v = viewers[token] ?: return false
        val to = v.target ?: return false
        val id = ++v.frameId
        synchronized(v.recent) { v.recent[id] = frame }
        val n = (frame.size + SHARD - 1) / SHARD
        // (more repair for keyframes was tried: the bigger burst made Wi-Fi drop more, 08.11.2026)
        val p = repairCount(n)
        val repair = Array(p) { ByteArray(SHARD) }
        val t0 = System.nanoTime()
        var sent = 0L
        var count = 0
        fun pace(bytes: Int) {
            sent += bytes
            if (++count % BATCH != 0) return
            val due = t0 + sent * 1_000_000_000L / PACE_BYTES_PER_S
            val wait = due - System.nanoTime()
            if (wait > 50_000) java.util.concurrent.locks.LockSupport.parkNanos(wait)
        }
        try {
            for (i in 0 until n) {
                val off = i * SHARD
                val len = minOf(SHARD, frame.size - off)
                val r = repair[i % p]
                for (k in 0 until len) r[k] = (r[k].toInt() xor frame[off + k].toInt()).toByte()
                header(0, id, i, n, p, frame.size)
                System.arraycopy(frame, off, out, HEADER, len)
                sock.send(DatagramPacket(out, HEADER + len, to))
                pace(HEADER + len)
            }
            for (j in 0 until p) {
                header(1, id, j, n, p, frame.size)
                System.arraycopy(repair[j], 0, out, HEADER, SHARD)
                sock.send(DatagramPacket(out, HEADER + SHARD, to))
                pace(HEADER + SHARD)
            }
        } catch (e: Exception) {
            Log.w(TAG, "send failed: ${e.message}")
        }
        return true
    }

    private fun header(flags: Int, id: Int, index: Int, n: Int, p: Int, len: Int) {
        ByteBuffer.wrap(out, 0, HEADER)
            .put(0xC5.toByte()).put(flags.toByte()).putInt(id)
            .putShort(index.toShort()).putShort(n.toShort()).putShort(p.toShort()).putInt(len)
    }

    fun close() {
        open = false
        viewers.clear()
        try { sock.close() } catch (_: Exception) {}
    }
}
