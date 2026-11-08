package de.finn.phonecast

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.Log
import android.view.Display
import org.lsposed.hiddenapibypass.HiddenApiBypass

/**
 * Changes the phone's logical screen shape, like `adb shell wm size`, so the picture fits the Mac.
 * Android only allows this with WRITE_SECURE_SETTINGS, which has to be granted once over adb:
 *   adb shell pm grant de.finn.phonecast android.permission.WRITE_SECURE_SETTINGS
 * It stays granted after USB debugging is turned off (until the app is uninstalled).
 */
object DisplaySize {
    const val OK = 0
    const val NO_PERMISSION = 1
    const val FAILED = 2

    /**
     * [aw]:[ah] is the wanted landscape shape; 0:0 goes back to the phone's normal shape.
     * [long] > the panel's long side renders more pixels than the panel has (sharper on the Mac,
     * more work for the GPU). Android allows up to 2× the panel.
     */
    fun apply(c: Context, aw: Int, ah: Int, long: Int = Prefs.shapeLong(c)): Int {
        if (c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) != PackageManager.PERMISSION_GRANTED) {
            return NO_PERMISSION
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) HiddenApiBypass.addHiddenApiExemptions("L")
            val wm = Class.forName("android.view.WindowManagerGlobal")
                .getMethod("getWindowManagerService").invoke(null)!!
            if (aw <= 0 || ah <= 0) {
                wm.javaClass.getMethod("clearForcedDisplaySize", Int::class.java).invoke(wm, Display.DEFAULT_DISPLAY)
                Log.i("PhoneCast", "display size back to normal")
            } else {
                Prefs.setLastShape(c, aw, ah)
                Prefs.setShapeLong(c, long)
                val (w, h) = size(c, aw.toDouble() / ah, long)
                wm.javaClass.getMethod("setForcedDisplaySize", Int::class.java, Int::class.java, Int::class.java)
                    .invoke(wm, Display.DEFAULT_DISPLAY, w, h)
                Log.i("PhoneCast", "display size forced to ${w}x$h for aspect $aw:$ah")
            }
            OK
        } catch (e: Exception) {
            Log.e("PhoneCast", "changing the display size failed", e)
            FAILED
        }
    }

    fun hasPermission(c: Context) =
        c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** The current logical screen size if it differs from the panel (shape changed), else null. */
    fun changedSize(c: Context): Pair<Int, Int>? {
        val d = c.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val m = android.util.DisplayMetrics()
        @Suppress("DEPRECATION") d.getRealMetrics(m)
        val real = listOf(m.widthPixels, m.heightPixels).sorted()
        val panel = listOf(d.mode.physicalWidth, d.mode.physicalHeight).sorted()
        return if (real == panel) null else maxOf(m.widthPixels, m.heightPixels) to minOf(m.widthPixels, m.heightPixels)
    }

    /**
     * The largest size of [aspect] (long/short) inside the current panel, in its natural orientation,
     * scaled up (max 2×) until its long side reaches [want] if that is bigger.
     */
    private fun size(c: Context, aspect: Double, want: Int): Pair<Int, Int> {
        val mode = c.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).mode
        val pw = mode.physicalWidth
        val ph = mode.physicalHeight
        var long = maxOf(pw, ph).toDouble()
        var short = minOf(pw, ph).toDouble()
        if (aspect >= long / short) short = long / aspect else long = short * aspect
        val scale = (want / long).coerceIn(1.0, 2.0)
        val l = even(long * scale).coerceAtMost(2 * maxOf(pw, ph))
        val s = even(short * scale).coerceAtMost(2 * minOf(pw, ph))
        return if (pw < ph) s to l else l to s
    }

    private fun even(v: Double) = (Math.round(v / 2) * 2).toInt()
}
