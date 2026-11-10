package de.finn.phonecast

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper

/**
 * Home-screen icon follows the link: phone screen lit while the Mac is connected, dark when not.
 * Done by enabling one of two activity-aliases (LauncherOn / LauncherOff). The launcher redraws the
 * icon after a few seconds. To avoid flicker on Wi-Fi blips it only switches after the state has held
 * for [SETTLE_MS], and never while PhoneCast itself is open (disabling the alias you launched from can
 * close the app's task on some Android versions).
 */
object LauncherIcon {
    private const val SETTLE_MS = 20_000L
    private val main = Handler(Looper.getMainLooper())
    @Volatile var appVisible = false
    private var wanted: Boolean? = null
    private var app: Context? = null

    private val apply = object : Runnable {
        override fun run() {
            val c = app ?: return
            val on = wanted ?: return
            if (appVisible) { main.postDelayed(this, 5_000); return }
            val pm = c.packageManager
            val onC = ComponentName(c, "${c.packageName}.LauncherOn")
            val offC = ComponentName(c, "${c.packageName}.LauncherOff")
            val isOn = pm.getComponentEnabledSetting(onC) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            if (isOn == on) return
            // enable the new entry first, so there is never a moment with no launcher icon
            val (enable, disable) = if (on) onC to offC else offC to onC
            pm.setComponentEnabledSetting(enable, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
            pm.setComponentEnabledSetting(disable, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        }
    }

    /** Called whenever the Mac link connects or drops. */
    fun request(c: Context, connected: Boolean) {
        main.post {
            app = c.applicationContext
            if (wanted == connected) return@post
            wanted = connected
            main.removeCallbacks(apply)
            main.postDelayed(apply, SETTLE_MS)
        }
    }
}
