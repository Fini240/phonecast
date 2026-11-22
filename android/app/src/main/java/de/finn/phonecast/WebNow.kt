package de.finn.phonecast

import android.accessibilityservice.AccessibilityService
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/**
 * "Continue on the Mac": remembers which website the phone's browser shows, read from the browser's address bar
 * through the Accessibility service (InputService). It goes to the Mac in the hub STATUS as "web"; the Mac shows it
 * with an "Open on Mac" button. Only the address is kept, only in memory, and only the paired Mac gets it.
 */
object WebNow {
    data class Page(val url: String, val app: String, val pkg: String, val at: Long)

    @Volatile var last: Page? = null
        private set
    /** A browser is the app in front right now. */
    @Volatile var front = false
        private set
    private var lastRead = 0L

    /** Address-bar view ids of the common browsers (Chrome-based ones all use url_bar). */
    private val barIds = listOf("url_bar", "location_bar_edit_text", "mozac_browser_toolbar_url_view", "url_field",
        "omnibarTextInput", "search_box", "addressbarEdit", "url")
    private val browsers = mapOf(
        "com.android.chrome" to "Chrome", "com.chrome.beta" to "Chrome Beta", "com.chrome.dev" to "Chrome Dev",
        "com.sec.android.app.sbrowser" to "Samsung Internet", "com.sec.android.app.sbrowser.beta" to "Samsung Internet Beta",
        "org.mozilla.firefox" to "Firefox", "org.mozilla.firefox_beta" to "Firefox Beta", "org.mozilla.focus" to "Firefox Focus",
        "com.microsoft.emmx" to "Edge", "com.brave.browser" to "Brave", "com.opera.browser" to "Opera",
        "com.duckduckgo.mobile.android" to "DuckDuckGo", "com.vivaldi.browser" to "Vivaldi", "com.kiwibrowser.browser" to "Kiwi",
    )

    private fun isBrowser(pkg: String) = pkg in browsers || pkg.contains("browser")

    /** Windows that pop up over the browser without leaving it (keyboard, notification shade, our own invisible screens). */
    private fun isOverlay(pkg: String) = pkg == "com.android.systemui" || pkg.contains("inputmethod") ||
        pkg.contains("honeyboard") || pkg == "de.finn.phonecast"

    fun onEvent(svc: AccessibilityService, e: AccessibilityEvent) {
        val pkg = e.packageName?.toString() ?: return
        val stateChange = e.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        if (!isBrowser(pkg)) {
            if (stateChange && !isOverlay(pkg) && front) { front = false; HubService.instance?.refreshStatus() }
            return
        }
        if (stateChange && !front) { front = true; HubService.instance?.refreshStatus() }
        // content changes fire constantly while a page scrolls or loads: look at most every 1.5 s
        val now = SystemClock.uptimeMillis()
        if (!stateChange && now - lastRead < 1500) return
        lastRead = now
        val root = try { svc.rootInActiveWindow } catch (_: Exception) { null } ?: return
        if (root.packageName?.toString() != pkg) return
        val url = read(root, pkg) ?: return
        val prev = last
        last = Page(url, browsers[pkg] ?: appLabel(svc, pkg), pkg, System.currentTimeMillis())
        if (prev?.url != url) HubService.instance?.refreshStatus()
    }

    /** For the hub STATUS: the page the browser shows (front) or showed last (up to 6 h ago). */
    /** [screenOn]: a locked phone doesn't count as "open right now". */
    fun status(screenOn: Boolean): JSONObject? {
        val p = last ?: return null
        val ago = (System.currentTimeMillis() - p.at) / 1000
        if (ago > 6 * 3600) return null
        return JSONObject().put("url", p.url).put("app", p.app).put("front", front && screenOn).put("at", p.at / 1000)
    }

    private fun read(root: AccessibilityNodeInfo, pkg: String): String? {
        for (id in barIds) {
            val nodes = try { root.findAccessibilityNodeInfosByViewId("$pkg:id/$id") } catch (_: Exception) { null } ?: continue
            for (n in nodes) {
                // while you type in the address bar it holds your search text, not the page
                if (n.isFocused || n.isShowingHintText) continue
                normalise(n.text?.toString())?.let { return it }
            }
        }
        return scan(root)
    }

    /** Unknown browser: the first text near the top of the screen that looks like an address. */
    private fun scan(root: AccessibilityNodeInfo): String? {
        val r = android.graphics.Rect()
        root.getBoundsInScreen(r)
        val limit = r.top + r.height() / 4
        val queue = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var seen = 0
        while (queue.isNotEmpty() && seen < 250) {
            val n = queue.removeFirst(); seen++
            n.getBoundsInScreen(r)
            if (r.top > limit) continue
            val cls = n.className?.toString() ?: ""
            if ((cls.endsWith("EditText") || cls.endsWith("TextView")) && !n.isFocused && !n.isShowingHintText)
                normalise(n.text?.toString())?.let { return it }
            for (i in 0 until n.childCount) n.getChild(i)?.let { queue.add(it) }
        }
        return null
    }

    private val hostish = Regex("""^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(:\d+)?([/?#].*)?$""", RegexOption.IGNORE_CASE)

    /** Address-bar text → a full https URL, or null for search text, new-tab pages and internal pages. */
    fun normalise(raw: String?): String? {
        val t = raw?.trim()?.replace("‎", "")?.replace("‏", "") ?: return null
        if (t.isEmpty() || t.length > 4000 || t.contains(' ')) return null
        if (t.startsWith("http://", true) || t.startsWith("https://", true)) return t
        if (t.contains("://") || t.startsWith("about:") || t.startsWith("chrome:")) return null
        return if (hostish.matches(t)) "https://$t" else null
    }

    private fun appLabel(svc: AccessibilityService, pkg: String): String = try {
        val pm = svc.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }
}
