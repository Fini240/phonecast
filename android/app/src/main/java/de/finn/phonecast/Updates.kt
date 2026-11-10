package de.finn.phonecast

import android.content.Context
import java.net.HttpURLConnection
import java.net.URL

/** Once a day: is there a newer PhoneCast release on GitHub? (Shown on the Home tab.) */
object Updates {
    @Volatile var latest: String? = null
    @Volatile var url: String? = null

    fun current(c: Context): String = try { c.packageManager.getPackageInfo(c.packageName, 0).versionName ?: "0" } catch (_: Exception) { "0" }

    fun checkDaily(c: Context) {
        val prefs = c.getSharedPreferences("ui", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        // remember the last answer so the card shows right away
        prefs.getString("updLatest", null)?.let { if (newer(it, current(c))) { latest = it; url = prefs.getString("updUrl", null) } }
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
                app.getSharedPreferences("ui", Context.MODE_PRIVATE).edit()
                    .putLong("updChecked", now).putString("updLatest", v).putString("updUrl", page).apply()
                if (newer(v, current(app))) { latest = v; url = page } else latest = null
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
}
