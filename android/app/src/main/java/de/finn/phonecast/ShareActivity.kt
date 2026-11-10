package de.finn.phonecast

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle

/** "Share → PhoneCast to Mac": files go to the Mac's Downloads, text/links to its clipboard. No UI. */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val i = intent
        val uris = ArrayList<Uri>()
        if (i.action == Intent.ACTION_SEND_MULTIPLE) {
            val l = if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            l?.let { uris.addAll(it) }
        } else {
            val u = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)
            u?.let { uris.add(it) }
        }
        // read permission for shared URIs belongs to this activity; take what we can for the service
        val svc = Intent(this, HubService::class.java)
        if (uris.isNotEmpty()) {
            svc.action = HubService.ACTION_SEND_FILES
            svc.putParcelableArrayListExtra(HubService.EXTRA_URIS, uris)
            svc.clipData = android.content.ClipData.newRawUri("", uris[0]).also { c -> uris.drop(1).forEach { c.addItem(android.content.ClipData.Item(it)) } }
            svc.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } else {
            val text = i.getStringExtra(Intent.EXTRA_TEXT)
            if (text != null) { svc.action = HubService.ACTION_SEND_TEXT; svc.putExtra(HubService.EXTRA_TEXT, text) }
        }
        try { startForegroundService(svc) } catch (_: Exception) {}
        finish()
    }
}
