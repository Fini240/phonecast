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
 * One TCP server, one viewer at a time. A new paired viewer replaces the old one.
 * Video is pushed through a small queue; if the network can't keep up the queue is
 * dropped and we wait for the next keyframe instead of building up delay.
 */
class StreamServer(
    private val pin: String,
    private val listener: Listener,
) {
    interface Listener {
        fun requestKeyFrame()
        fun onClientChanged(address: String?)
        fun onInput(type: Int, payload: ByteArray)
        fun onSettings(maxSize: Int, bitrateMbps: Int)
        fun onResolution(w: Int, h: Int): Int
        fun controlAvailable(): Boolean
    }

    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var client: Client? = null
    @Volatile private var running = false

    @Volatile private var width = 0
    @Volatile private var height = 0
    @Volatile private var config: ByteArray? = null

    val clientAddress: String? get() = client?.address

    fun start() {
        running = true
        Thread({ acceptLoop() }, "pc-accept").start()
    }

    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: Exception) {}
        client?.close()
        client = null
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
            val type = input.readUnsignedByte()
            val len = input.readUnsignedShort()
            val payload = ByteArray(len).also { input.readFully(it) }
            if (type != Proto.HELLO || String(payload, Charsets.UTF_8) != pin) {
                Log.w(TAG, "rejected ${s.inetAddress}: bad pin")
                s.getOutputStream().write(packet(Proto.HELLO_BAD, ByteArray(0)))
                s.close()
                return
            }
            s.soTimeout = 0

            val c = Client(s)
            client?.close()
            client = c
            c.sendControl(packet(Proto.HELLO_OK, byteArrayOf(if (listener.controlAvailable()) 1 else 0)))
            if (width > 0) c.sendControl(formatPacket())
            config?.let { c.sendControl(packet(Proto.CONFIG, it)) }
            c.waitingForKey = true
            listener.requestKeyFrame()
            listener.onClientChanged(c.address)

            while (true) {
                val t = input.readUnsignedByte()
                val l = input.readUnsignedShort()
                val p = ByteArray(l).also { input.readFully(it) }
                if (t == Proto.KEYFRAME) {
                    c.waitingForKey = true
                    listener.requestKeyFrame()
                } else if (t == Proto.PING) {
                    c.sendControl(packet(Proto.PONG, p))
                    // heartbeat: tell the Mac whether tapping is available right now
                    c.sendControl(packet(Proto.CONTROL, byteArrayOf(if (listener.controlAvailable()) 1 else 0)))
                    c.sendControl(packet(Proto.STATS, ByteBuffer.allocate(4).putInt(c.resyncs).array()))
                } else if (t == Proto.RESOLUTION && p.size >= 4) {
                    val w = ((p[0].toInt() and 0xff) shl 8) or (p[1].toInt() and 0xff)
                    val h = ((p[2].toInt() and 0xff) shl 8) or (p[3].toInt() and 0xff)
                    c.sendControl(packet(Proto.RES_RESULT, byteArrayOf(listener.onResolution(w, h).toByte())))
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
            val wasCurrent = client?.socket === s
            try { s.close() } catch (_: Exception) {}
            if (wasCurrent) {
                client = null
                listener.onInput(Proto.TOUCH, byteArrayOf(Proto.TOUCH_CANCEL_ALL.toByte(), 0, 0, 0, 0, 0))
                listener.onClientChanged(null)
            }
        }
    }

    // ---- called by encoder / audio threads ----

    fun setFormat(w: Int, h: Int) {
        width = w; height = h
        config = null
        client?.sendControl(formatPacket())
    }

    fun onConfig(bytes: ByteArray) {
        config = bytes
        client?.sendControl(packet(Proto.CONFIG, bytes))
    }

    fun onFrame(bytes: ByteArray, key: Boolean) {
        val c = client ?: return
        val payload = ByteArray(bytes.size + 1)
        payload[0] = if (key) 1 else 0
        System.arraycopy(bytes, 0, payload, 1, bytes.size)
        c.sendVideo(packet(Proto.FRAME, payload), key)
    }

    fun onAudio(bytes: ByteArray) {
        client?.sendAudio(packet(Proto.AUDIO, bytes))
    }

    fun onControlChanged(available: Boolean) {
        client?.sendControl(packet(Proto.CONTROL, byteArrayOf(if (available) 1 else 0)))
    }

    private fun formatPacket(): ByteArray =
        packet(Proto.FORMAT, ByteBuffer.allocate(8).putInt(width).putInt(height).array())

    private fun packet(type: Int, payload: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    private inner class Client(val socket: Socket) {
        val address: String = socket.inetAddress?.hostAddress ?: "?"
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

    companion object { private const val TAG = "PhoneCast" }
}
