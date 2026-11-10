package de.finn.phonecast

import android.content.Context
import java.net.HttpURLConnection
import java.net.URL

/** Once a day: is there a newer PhoneCast release on GitHub? (Shown on the Home tab.) */
object Updates {
    @Volatile var latest: String? = null
    @Volatile var url: String? = null
    @Volatile var apkUrl: String? = null
    /** Progress text while downloading/installing, shown on the Home tab. */
    @Volatile var installing: String? = null

    fun current(c: Context): String = try { c.packageManager.getPackageInfo(c.packageName, 0).versionName ?: "0" } catch (_: Exception) { "0" }

    fun checkDaily(c: Context) {
        val prefs = c.getSharedPreferences("ui", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        // remember the last answer so the card shows right away
        prefs.getString("updLatest", null)?.let { if (newer(it, current(c))) { latest = it; url = prefs.getString("updUrl", null); apkUrl = prefs.getString("updApk", null) } }
        if (now - prefs.getLong("updChecked", 0) < 24 * 3600_000L) return
        val app = c.applicationContext
        Thread {
            try {
                val con = URL("https://api.github.com/repos/Fini240/phonecast/releases/latest").openConnection() as HttpURLConnection
                con.connectTimeout = 10_000; con.readTimeout = 10_000
                con.setRequestProperty("Accept", "application/vnd.github+json")
                val j = org.json.JSONObject(con.inputStream.bufferedReader().readText())
                val v = j.optString("tag_name").trimStart('v', 'V')
                val page = j.optString("html_url")
                val assets = j.optJSONArray("assets")
                val apk = (0 until (assets?.length() ?: 0)).map { assets!!.getJSONObject(it) }
                    .firstOrNull { it.optString("name").endsWith(".apk") }?.optString("browser_download_url")
                app.getSharedPreferences("ui", Context.MODE_PRIVATE).edit()
                    .putLong("updChecked", now).putString("updLatest", v).putString("updUrl", page).putString("updApk", apk).apply()
                if (newer(v, current(app))) { latest = v; url = page; apkUrl = apk } else latest = null
            } catch (_: Exception) {}
        }.start()
    }

    fun newer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }; val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val p = x.getOrElse(i) { 0 }; val q = y.getOrElse(i) { 0 }
            if (p != q) return p > q
        }
        return false
    }

    /**
     * Download the release APK and hand it to Android's installer (PackageInstaller session). Android
     * asks the user to confirm once; the same signature installs over this app, so pairing stays.
     */
    fun install(c: Context) {
        val src = apkUrl ?: return
        if (installing != null) return
        installing = tr("Downloading…")
        val app = c.applicationContext
        Thread {
            try {
                val con = URL(src).openConnection() as HttpURLConnection
                con.instanceFollowRedirects = true; con.connectTimeout = 15_000; con.readTimeout = 30_000
                val total = con.contentLengthLong
                val pi = app.packageManager.packageInstaller
                val params = android.content.pm.PackageInstaller.SessionParams(android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(app.packageName)
                val id = pi.createSession(params)
                pi.openSession(id).use { session ->
                    session.openWrite("phonecast.apk", 0, total).use { out ->
                        con.inputStream.use { ins ->
                            val buf = ByteArray(256 * 1024); var got = 0L; var last = -1
                            while (true) {
                                val n = ins.read(buf); if (n < 0) break
                                out.write(buf, 0, n); got += n
                                val pct = if (total > 0) (got * 100 / total).toInt() else -1
                                if (pct != last && pct >= 0) { last = pct; installing = tr("Downloading… {0} %", pct) }
                            }
                        }
                        session.fsync(out)
                    }
                    installing = tr("Installing…")
                    val done = android.app.PendingIntent.getBroadcast(app, 11, android.content.Intent(app, UpdateReceiver::class.java),
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_MUTABLE)
                    session.commit(done.intentSender)
                }
            } catch (e: Exception) {
                android.util.Log.w("PhoneCastUpdate", "install", e)
                installing = null
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    android.widget.Toast.makeText(app, tr("Update failed: {0}", e.message), android.widget.Toast.LENGTH_LONG).show()
                }
            }
        }.start()
    }
}

/** PackageInstaller's answer: show Android's confirm screen, or report the result. */
class UpdateReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(c: Context, i: android.content.Intent) {
        when (i.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS, -999)) {
            android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (android.os.Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(android.content.Intent.EXTRA_INTENT, android.content.Intent::class.java)
                    else @Suppress("DEPRECATION") i.getParcelableExtra(android.content.Intent.EXTRA_INTENT)
                confirm?.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)?.let { c.startActivity(it) }
            }
            android.content.pm.PackageInstaller.STATUS_SUCCESS -> Updates.installing = null
            else -> {
                Updates.installing = null
                val msg = i.getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "cancelled"
                android.widget.Toast.makeText(c, tr("Update not installed: {0}", msg), android.widget.Toast.LENGTH_LONG).show()
            }
        }
    }
}
