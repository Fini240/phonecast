package de.finn.phonecast

import android.content.Context
import android.provider.Settings
import android.util.Log

/**
 * "Dim the phone while it's shown on a computer": saves battery and heat, and people around you don't
 * see the screen. Android doesn't let an app turn the panel off while screen capture keeps running
 * (scrcpy does it as the shell user), so this goes as dark as an app may:
 *  - brightness to the minimum (needs "Modify system settings", granted once in the app),
 *  - plus Extra dim when WRITE_SECURE_SETTINGS was granted over adb (the same grant the screen
 *    shape uses). Extra dim is a display colour filter, so the Mac's picture stays normal.
 * The old values are kept in prefs, so a crash or reboot still puts them back (restoreLeftover).
 */
object Dimmer {
    private const val TAG = "PhoneCastDim"
    private const val P = "dim"
    @Volatile private var active = false

    fun enabled(c: Context) = c.getSharedPreferences(P, 0).getBoolean("on", false)
    fun setEnabled(c: Context, on: Boolean) {
        c.getSharedPreferences(P, 0).edit().putBoolean("on", on).apply()
        if (!on) update(c, false)
    }
    fun canWrite(c: Context) = Settings.System.canWrite(c)
    private fun canSecure(c: Context) =
        c.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) == android.content.pm.PackageManager.PERMISSION_GRANTED

    /** A computer started (true) or stopped (false) showing the phone. */
    @Synchronized fun update(c: Context, viewing: Boolean) {
        val want = viewing && enabled(c) && canWrite(c)
        if (want == active) return
        val cr = c.contentResolver
        val sp = c.getSharedPreferences(P, 0)
        try {
            if (want) {
                if (!sp.contains("bright")) sp.edit()
                    .putInt("bright", Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS, 128))
                    .putInt("mode", Settings.System.getInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, 0))
                    .putInt("xdim", if (canSecure(c)) Settings.Secure.getInt(cr, "reduce_bright_colors_activated", 0) else -1)
                    .commit()
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, 1)
                if (canSecure(c)) Settings.Secure.putInt(cr, "reduce_bright_colors_activated", 1)
                active = true
                Log.i(TAG, "dimmed")
            } else {
                restore(c)
                active = false
            }
        } catch (e: Exception) { Log.w(TAG, "dim failed", e) }
    }

    /** Puts brightness back if an earlier run dimmed and never got to undo it. */
    fun restoreLeftover(c: Context) { if (!active) try { restore(c) } catch (_: Exception) {} }

    private fun restore(c: Context) {
        val sp = c.getSharedPreferences(P, 0)
        if (!sp.contains("bright") || !canWrite(c)) return
        val cr = c.contentResolver
        Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS, sp.getInt("bright", 128))
        Settings.System.putInt(cr, Settings.System.SCREEN_BRIGHTNESS_MODE, sp.getInt("mode", 0))
        val x = sp.getInt("xdim", -1)
        if (x >= 0 && canSecure(c)) Settings.Secure.putInt(cr, "reduce_bright_colors_activated", x)
        sp.edit().remove("bright").remove("mode").remove("xdim").commit()
        Log.i(TAG, "restored")
    }
}
