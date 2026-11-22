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
        if (e.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {
            // a tapped link carries its full address; the page it opens gets that address (see read())
            if (isBrowser(pkg)) linkOf(e.source)?.let { pending = Pending(it, SystemClock.uptimeMillis(), lastTitle) }
            return
        }
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

    // Samsung Internet (and Chrome on some setups) shows only the domain in the address bar. The page itself
    // doesn't expose its address, but a tapped link does (Chromium's "targetUrl"). So: remember the link you
    // tapped, and when the next page with a new title loads on the same site, that title gets the link's address.
    // Going back to an earlier page finds it again by its title.
    private class Pending(val url: String, val at: Long, val titleBefore: String?)
    private var pending: Pending? = null
    private var lastTitle: String? = null
    private val byTitle = object : LinkedHashMap<String, String>(64, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, String>?) = size > 200
    }

    private fun linkOf(node: AccessibilityNodeInfo?): String? {
        var n = node
        repeat(4) {                       // the tap may land on text inside the link
            val u = n?.extras?.getCharSequence("AccessibilityNodeInfo.targetUrl")?.toString()
            if (u != null && (u.startsWith("https://") || u.startsWith("http://"))) return u
            n = n?.parent ?: return null
        }
        return null
    }

    /** The page title: Chromium's web root node ("rootWebArea") has it as its text. */
    private fun title(root: AccessibilityNodeInfo): String? {
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var seen = 0
        while (q.isNotEmpty() && seen < 150) {
            val n = q.removeFirst(); seen++
            // while a page loads there can be an empty web root next to the real one: keep looking
            if (n.extras?.getString("AccessibilityNodeInfo.chromeRole") == "rootWebArea" || n.className == "android.webkit.WebView")
                n.text?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
            for (i in 0 until n.childCount) n.getChild(i)?.let { q.add(it) }
        }
        return null
    }

    private fun site(u: String): String {
        val host = try { java.net.URI(u).host ?: "" } catch (_: Exception) { "" }
        return host.lowercase().split('.').takeLast(2).joinToString(".")
    }
    private fun hasPath(u: String): Boolean = try {
        val x = java.net.URI(u); (x.rawPath ?: "").length > 1 || x.rawQuery != null
    } catch (_: Exception) { false }

    // Second way (when no tap was reported): once per page, collect its links (text -> address) in the background.
    // When the next page's title contains a link's text from the page before (a Kleinanzeigen ad, a news story,
    // a shop item), that link's address is the page's address.
    private class Link(val text: String, val url: String)
    @Volatile private var prevLinks: List<Link> = emptyList()
    @Volatile private var curLinks: List<Link> = emptyList()
    private var harvestedTitle: String? = null
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor()

    private fun norm(t: String) = t.lowercase().replace(Regex("[^\\p{L}\\p{N}]+"), " ").trim()

    private fun harvest(root: AccessibilityNodeInfo): List<Link> {
        val out = ArrayList<Link>()
        val q = ArrayDeque<AccessibilityNodeInfo>().apply { add(root) }
        var seen = 0
        while (q.isNotEmpty() && seen < 1500 && out.size < 300) {
            val n = q.removeFirst(); seen++
            val ex = n.extras
            val u = ex?.getCharSequence("AccessibilityNodeInfo.targetUrl")?.toString()
            if (u != null && (u.startsWith("https://") || u.startsWith("http://"))) {
                val text = (n.contentDescription ?: n.text)?.toString().orEmpty().ifBlank { linkText(n) }
                if (text.length >= 6) out += Link(text, u)
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { q.add(it) }
        }
        return out
    }
    private fun linkText(n: AccessibilityNodeInfo): String {
        val sb = StringBuilder()
        for (i in 0 until minOf(n.childCount, 6)) n.getChild(i)?.let { c -> (c.text ?: c.contentDescription)?.let { sb.append(it).append(' ') } }
        return sb.toString().trim()
    }

    /** The link from the page before whose text best matches this page's title. */
    private fun matchTitle(title: String, site: String): String? {
        val t = norm(title)
        // page titles are usually "<what you opened> | <site>" or "<what> - <site>"
        val head = norm(title.split(" | ", " – ", " - ", " · ").first())
        return prevLinks.asSequence()
            .filter { site(it.url) == site && !it.url.contains('#') }
            .map { it to norm(it.text) }
            .filter { (_, n) -> n.length >= 8 && (t.contains(n) || (head.length >= 8 && n.contains(head))) }
            .maxByOrNull { (_, n) -> n.length }?.first?.url
    }

    private fun read(root: AccessibilityNodeInfo, pkg: String): String? {
        val bar = barUrl(root, pkg) ?: return null
        val t = title(root)
        val now = SystemClock.uptimeMillis()
        val p = pending
        var url = if (hasPath(bar)) bar else {
            // only the domain is shown: use the tapped link once the new page is there
            if (p != null && t != null && t != p.titleBefore && site(p.url) == site(bar) && now - p.at < 60_000) {
                byTitle[t] = p.url; pending = null
            }
            t?.let { byTitle[it] }?.takeIf { site(it) == site(bar) } ?: bar
        }
        if (t != null && hasPath(url)) byTitle[t] = url
        if (t != null && t != harvestedTitle) {
            // a new page: if the bar didn't tell us, try the previous page's links; then collect this page's links
            harvestedTitle = t
            prevLinks = curLinks
            if (!hasPath(url)) matchTitle(t, site(bar))?.let { byTitle[t] = it; url = it }
            worker.execute { curLinks = try { harvest(root) } catch (_: Exception) { emptyList() } }
        }
        if (p != null && now - p.at > 60_000) pending = null
        lastTitle = t
        return url
    }

    private fun barUrl(root: AccessibilityNodeInfo, pkg: String): String? {
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
