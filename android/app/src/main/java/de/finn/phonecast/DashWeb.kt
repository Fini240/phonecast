package de.finn.phonecast

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.DownloadManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.PermissionRequest
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * The dashboard's own pages for Chat, Builder and Studio, shown inside the PC tab
 * (`<dashboard>/?embed=chat|builder|studio`: the page drops its header and tab bar).
 * One WebView per view, made on first use and kept, so a running chat or render keeps
 * going while you look at another tab, and survives the fold/unfold rebuild of the UI.
 */
class DashWeb(private val a: Activity) {
    private val views = HashMap<String, WebView>()
    private val loadedFor = HashMap<String, String>()
    /** Hosts that are the dashboard (its address, plus where it redirected to); other links open in the browser. */
    private val dashHosts = HashSet<String>()
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var pendingMic: PermissionRequest? = null

    /** The view for [kind], loading it (again) when the dashboard address or the theme changed. */
    fun view(kind: String, base: String, u: Ui): WebView {
        val w = views.getOrPut(kind) { make() }
        // the page takes PhoneCast's look: its font, rounder cards and the phone's own (Material You) colours
        fun h(c: Int) = "%06x".format(c and 0xFFFFFF)
        val look = "theme=${if (u.dark) "dark" else "light"}&skin=phonecast&bg=${h(u.bg)}&surface=${h(u.surface)}&surface2=${h(u.barBg)}" +
            "&accent=${h(u.accent)}&onaccent=${h(u.onAccent)}&tint=${h(u.tonalBg)}&ontint=${h(u.onTonal)}" +
            "&ink=${h(u.text)}&muted=${h(u.text2)}&line=${if (u.dark) "34363c" else "dfe1e7"}"
        w.setBackgroundColor(u.bg)
        val url = "$base/?embed=$kind&$look"
        if (loadedFor[kind] != url) { loadedFor[kind] = url; Uri.parse(base).host?.let { dashHosts += it }; w.loadUrl(url) }
        (w.parent as? ViewGroup)?.removeView(w)
        return w
    }

    /** Back inside the page first (Builder's project previews, a chat opened from the list). */
    fun back(kind: String): Boolean {
        val w = views[kind] ?: return false
        if (!w.canGoBack()) return false
        w.goBack(); return true
    }

    fun reload(kind: String) { views[kind]?.reload() }

    @SuppressLint("SetJavaScriptEnabled")
    private fun make() = WebView(a).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true            // chats, model choice and theme live in localStorage
        settings.mediaPlaybackRequiresUserGesture = false   // voice answers play without a second tap
        settings.allowFileAccess = false
        settings.setSupportMultipleWindows(false)
        CookieManager.getInstance().setAcceptCookie(true)
        overScrollMode = View.OVER_SCROLL_NEVER
        webViewClient = object : WebViewClient() {
            // the dashboard itself (incl. its https redirect) stays here; anything else opens in the browser
            // (a redirect is the dashboard's own move, e.g. to its https name for the microphone: follow it and
            // remember that host as the dashboard too)
            override fun shouldOverrideUrlLoading(view: WebView, req: WebResourceRequest): Boolean {
                val host = req.url.host ?: return false
                if (req.isRedirect) { dashHosts += host; return false }
                if (host in dashHosts) return false
                try { a.startActivity(Intent(Intent.ACTION_VIEW, req.url)) } catch (_: Exception) {}
                return true
            }
            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                url?.let { Uri.parse(it).host }?.let { dashHosts += it }
            }
        }
        webChromeClient = object : WebChromeClient() {
            // the chat's attach button and Studio's reference pictures
            override fun onShowFileChooser(w: WebView, cb: ValueCallback<Array<Uri>>, p: FileChooserParams): Boolean {
                fileCallback?.onReceiveValue(null)
                fileCallback = cb
                val i = try { p.createIntent() } catch (_: Exception) { Intent(Intent.ACTION_GET_CONTENT).setType("*/*") }
                if (p.mode == FileChooserParams.MODE_OPEN_MULTIPLE) i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                return try {
                    @Suppress("DEPRECATION") a.startActivityForResult(i, REQ_FILE); true
                } catch (_: Exception) { fileCallback = null; false }
            }
            // voice chat: the page asks for the microphone, Android asks the user once
            override fun onPermissionRequest(req: PermissionRequest) {
                if (PermissionRequest.RESOURCE_AUDIO_CAPTURE !in req.resources) { req.deny(); return }
                if (a.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                    req.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE))
                else { pendingMic?.deny(); pendingMic = req; a.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC) }
            }
        }
        // Studio's "download": into Downloads, like the browser would
        setDownloadListener { url, ua, cd, mime, _ ->
            try {
                val name = URLUtil.guessFileName(url, cd, mime)
                val r = DownloadManager.Request(Uri.parse(url)).setMimeType(mime).addRequestHeader("User-Agent", ua)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name)
                CookieManager.getInstance().getCookie(url)?.let { r.addRequestHeader("Cookie", it) }
                a.getSystemService(DownloadManager::class.java).enqueue(r)
                android.widget.Toast.makeText(a, tr("Saving {0} to Downloads", name), android.widget.Toast.LENGTH_SHORT).show()
            } catch (_: Exception) {
                try { a.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } catch (_: Exception) {}
            }
        }
    }

    /** From MainActivity.onActivityResult; true when it was ours. */
    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_FILE) return false
        val cb = fileCallback ?: return true
        fileCallback = null
        val uris = ArrayList<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            data.clipData?.let { c -> for (i in 0 until c.itemCount) uris.add(c.getItemAt(i).uri) }
            if (uris.isEmpty()) data.data?.let { uris.add(it) }
        }
        cb.onReceiveValue(if (uris.isEmpty()) null else uris.toTypedArray())
        return true
    }

    /** From MainActivity.onRequestPermissionsResult; true when it was ours. */
    fun onPermission(requestCode: Int, granted: Boolean): Boolean {
        if (requestCode != REQ_MIC) return false
        val r = pendingMic ?: return true
        pendingMic = null
        if (granted) r.grant(arrayOf(PermissionRequest.RESOURCE_AUDIO_CAPTURE)) else r.deny()
        return true
    }

    fun pause() = views.values.forEach { it.onPause() }
    fun resume() = views.values.forEach { it.onResume() }

    companion object {
        const val REQ_FILE = 40
        const val REQ_MIC = 41
    }
}
