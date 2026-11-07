package de.finn.phonecast

import android.app.Activity
import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/** Android starts this (invisibly) when the Mac switches the phone into USB accessory mode. */
class AccessoryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val acc: UsbAccessory? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
        if (acc != null) UsbBridge.open(this, acc)
        finish()
        @Suppress("DEPRECATION") overridePendingTransition(0, 0)
    }
}

/**
 * The cable link: bytes from the USB accessory pipe are passed to the normal stream server on
 * 127.0.0.1 and back, so cable and Wi-Fi share exactly the same protocol and code.
 */
object UsbBridge {
    private const val TAG = "PhoneCastUSB"
    @Volatile private var pfd: ParcelFileDescriptor? = null
    @Volatile private var sock: Socket? = null
    @Volatile var active = false
        private set

    /** Also called when the app starts, in case the cable was plugged in before. */
    fun openExisting(ctx: Context) {
        if (pfd != null) return
        val um = ctx.getSystemService(UsbManager::class.java) ?: return
        val acc = um.accessoryList?.firstOrNull { it.manufacturer == "Finn" && it.model == "PhoneCast" } ?: return
        if (um.hasPermission(acc)) open(ctx, acc)
    }

    @Synchronized
    fun open(ctx: Context, acc: UsbAccessory) {
        close()
        val um = ctx.getSystemService(UsbManager::class.java)
        val p = try { um.openAccessory(acc) } catch (e: Exception) { Log.w(TAG, "open failed", e); null } ?: return
        pfd = p
        Thread({ run(p) }, "pc-usb").start()
    }

    @Synchronized
    private fun close() {
        try { sock?.close() } catch (_: Exception) {}
        try { pfd?.close() } catch (_: Exception) {}
        sock = null
        pfd = null
        active = false
    }

    private fun run(p: ParcelFileDescriptor) {
        val usbIn = FileInputStream(p.fileDescriptor)
        val usbOut = FileOutputStream(p.fileDescriptor)
        // wait for the stream server (it runs while sharing is on)
        var s: Socket? = null
        while (pfd === p && s == null) {
            try {
                s = Socket().apply {
                    tcpNoDelay = true
                    connect(InetSocketAddress("127.0.0.1", Proto.PORT), 500)
                }
            } catch (_: Exception) {
                Thread.sleep(400)
            }
        }
        if (s == null) return
        sock = s
        active = true
        Log.i(TAG, "cable link up")

        val sIn = s.getInputStream()
        val sOut = s.getOutputStream()
        val up = Thread({
            // Mac -> phone. Accessory reads must use a big buffer or data can be lost.
            val buf = ByteArray(16384)
            try {
                while (true) {
                    val n = usbIn.read(buf)
                    if (n < 0) break
                    if (n > 0) { sOut.write(buf, 0, n); sOut.flush() }
                }
            } catch (_: Exception) {}
            if (pfd === p) close()
        }, "pc-usb-in")
        up.start()

        val buf = ByteArray(65536)
        try {
            while (true) {
                val n = sIn.read(buf)
                if (n < 0) break
                if (n <= 0) continue
                // exact multiples of 512 bytes would leave the Mac waiting for a short packet
                if (n % 512 == 0) {
                    usbOut.write(buf, 0, n - 1)
                    usbOut.write(buf, n - 1, 1)
                } else {
                    usbOut.write(buf, 0, n)
                }
            }
        } catch (_: Exception) {}
        Log.i(TAG, "cable link down")
        if (pfd === p) close()
    }
}
