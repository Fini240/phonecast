package de.finn.phonecast

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile: one tap starts (or stops) showing the phone on the Mac. */
class CastTile : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = if (CaptureService.instance != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = "Cast to Mac"
            updateTile()
        }
    }

    override fun onClick() {
        if (CaptureService.instance != null) {
            startService(Intent(this, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
            qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
            return
        }
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_RESUME, true)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 5, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else @Suppress("DEPRECATION") startActivityAndCollapse(i)
    }
}

/** Keeps the link to the Mac up after a restart. */
class BootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(c: android.content.Context, i: Intent) { HubService.start(c) }
}

/** Quick Settings tile: send what's on the phone's clipboard to the Mac. */
class ClipTile : TileService() {
    override fun onClick() {
        val i = Intent(this, ClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 6, i, PendingIntent.FLAG_IMMUTABLE))
        else @Suppress("DEPRECATION") startActivityAndCollapse(i)
    }
}

class ClipActivity : android.app.Activity() {
    companion object { const val EXTRA_AUTO = "auto" }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        val auto = intent.getBooleanExtra(EXTRA_AUTO, false)
        val cm = getSystemService(android.content.ClipboardManager::class.java)
        val clip = cm.primaryClip
        // passwords from password managers are marked sensitive: never send those on their own
        val sensitive = android.os.Build.VERSION.SDK_INT >= 33 &&
            clip?.description?.extras?.getBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE) == true
        val hub = HubService.instance
        // a copied picture goes to the Mac's clipboard as a picture
        val img = clip?.takeIf { it.itemCount > 0 && it.description.hasMimeType("image/*") }?.getItemAt(0)?.uri
        if (img != null && !sensitive) {
            if (hub?.connected == true) hub.sendClipImage(img)
            finish(); overridePendingTransition(0, 0); return
        }
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        when {
            text.isNullOrEmpty() -> if (!auto) android.widget.Toast.makeText(this, "The clipboard is empty", android.widget.Toast.LENGTH_SHORT).show()
            auto && (sensitive || text == hub?.lastClip) -> {}
            else -> hub?.sendClip(text)
        }
        finish()
        overridePendingTransition(0, 0)
    }
}
