package de.finn.phonecast

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity() {

    private val ui = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var pinView: TextView
    private lateinit var addrView: TextView
    private lateinit var controlView: TextView
    private lateinit var startBtn: Button
    private lateinit var qualityBtn: Button
    private lateinit var bitrateBtn: Button
    private lateinit var audioBtn: Button
    private lateinit var controlBtn: Button
    private lateinit var shapeView: TextView
    private lateinit var shapeNormalBtn: Button
    private lateinit var shapeMacBtn: Button
    private lateinit var hubView: TextView
    private lateinit var devicesView: TextView
    private lateinit var notifBtn: Button
    private lateinit var featView: TextView
    private lateinit var clipBtn: Button
    private lateinit var featBtn: Button
    private lateinit var filesBtn: Button

    private val qualities = intArrayOf(1280, 1920, 2560, 0)
    private val bitrates = intArrayOf(8, 16, 24, 40)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
        HubService.start(this)
        resumeIfAsked(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        resumeIfAsked(intent)
    }

    /** Opened after an unlock because the lock had ended sharing: ask to share again right away. */
    private fun resumeIfAsked(i: Intent?) {
        if (i?.getBooleanExtra(EXTRA_RESUME, false) != true) return
        i.removeExtra(EXTRA_RESUME)
        if (CaptureService.instance == null) toggle()
    }

    override fun onResume() {
        super.onResume()
        tick()
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacksAndMessages(null)
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun buildUi() {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(28))
        }
        fun label(text: String, size: Float = 15f, bold: Boolean = false, alpha: Float = 1f) = TextView(this).apply {
            this.text = text
            textSize = size
            if (bold) typeface = Typeface.DEFAULT_BOLD
            this.alpha = alpha
            setPadding(0, dp(4), 0, dp(4))
        }
        fun card(vararg views: View) = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(Color.argb(28, 128, 128, 128))
            }
            views.forEach { addView(it) }
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(14) }
        }
        fun button(text: String, onClick: () -> Unit) = Button(this).apply {
            this.text = text
            isAllCaps = false
            setOnClickListener { onClick() }
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) }
        }

        col.addView(label("PhoneCast", 28f, bold = true))
        col.addView(label("Connects this phone and your Mac: screen both ways, notifications, files, clipboard.", 14f, alpha = 0.7f))

        hubView = label("", 17f, bold = true)
        devicesView = label("", 14f).apply { typeface = Typeface.MONOSPACE; textSize = 13f }
        notifBtn = button("Show phone notifications on the Mac") { openNotificationAccess() }
        col.addView(card(
            hubView,
            devicesView,
            button("Control the Mac from this phone") { startActivity(Intent(this, MacViewActivity::class.java)) },
            button("Send files to the Mac") { pickFiles() },
            button("Send clipboard to the Mac") { sendClipboard() },
            button("") { Prefs.setAutoClip(this, !Prefs.autoClip(this)); tick() }.also { clipBtn = it },
            notifBtn,
        ))

        featView = label("", 14f)
        featBtn = button("Allow messages, calls, contacts & photos") { requestFeatures() }
        filesBtn = button("Allow browsing phone files from the Mac") {
            try { startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))) }
            catch (_: Exception) { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) }
        }
        col.addView(card(label("Phone features on the Mac", 16f, bold = true), featView, featBtn, filesBtn))

        status = label("", 17f, bold = true)
        startBtn = button("Start sharing") { toggle() }
        col.addView(card(status, startBtn))

        pinView = label("", 30f, bold = true).apply { typeface = Typeface.MONOSPACE; letterSpacing = 0.15f }
        addrView = label("", 14f, alpha = 0.8f)
        col.addView(card(
            label("Pairing PIN (enter it on the Mac once)", 13f, alpha = 0.7f),
            pinView,
            addrView,
            label("Link key (the Mac shows the same one in Settings): " + Auth.fingerprint(), 12f, alpha = 0.6f).apply { typeface = Typeface.MONOSPACE },
            button("New PIN (unpairs every Mac)") { Prefs.newPin(this); toast("New PIN. Enter it on the Mac again."); tick() },
        ))

        controlView = label("", 14f)
        controlBtn = button("Turn on mouse & keyboard") { openAccessibility() }
        col.addView(card(
            label("Mouse & keyboard from the Mac", 16f, bold = true),
            controlView,
            controlBtn,
            label(
                "Uses an Accessibility service to tap for you. If Android says \"Restricted setting\": " +
                    "App info → ⋮ → Allow restricted settings, then try again. " +
                    "Fortnite may treat tap injection like a cheat tool — test on a throwaway account first.",
                12f, alpha = 0.6f
            ),
        ))

        qualityBtn = button("") {
            val i = (qualities.indexOf(Prefs.maxSize(this)) + 1) % qualities.size
            Prefs.setMaxSize(this, qualities[i]); CaptureService.instance?.restartVideo(); tick()
        }
        bitrateBtn = button("") {
            val i = (bitrates.indexOf(Prefs.bitrateMbps(this)) + 1) % bitrates.size
            Prefs.setBitrateMbps(this, bitrates[i]); CaptureService.instance?.restartVideo(); tick()
        }
        audioBtn = button("") {
            Prefs.setAudio(this, !Prefs.audio(this)); tick()
            if (CaptureService.instance != null) toast("Takes effect next time you start sharing")
        }
        col.addView(card(label("Quality", 16f, bold = true), qualityBtn, bitrateBtn, audioBtn))

        shapeView = label("", 14f)
        shapeNormalBtn = button("Back to normal shape") { setShape(0, 0) }
        shapeMacBtn = button("") { Prefs.lastShape(this)?.let { (w, h) -> setShape(w, h) } }
        col.addView(card(label("Screen shape", 16f, bold = true), shapeView, shapeNormalBtn, shapeMacBtn))

        setContentView(ScrollView(this).apply { addView(col) })
    }

    private fun tick() {
        tickHub()
        val svc = CaptureService.instance
        status.text = when {
            svc == null -> "Not sharing"
            svc.clientAddress != null && UsbBridge.active && svc.clientAddress == "127.0.0.1" -> "● Mac connected by cable"
            svc.clientAddress != null -> "● Mac connected over Wi-Fi (${svc.clientAddress})"
            else -> "● Sharing — waiting for the Mac"
        }
        startBtn.text = if (svc == null) "Start sharing" else "Stop sharing"
        pinView.text = Prefs.pin(this)
        addrView.text = addresses().ifEmpty { "No Wi-Fi address — connect to Wi-Fi" }

        val enabled = accessibilityEnabled()
        val connected = InputService.instance != null
        controlView.text = when {
            connected -> "On — the Mac can tap and type."
            enabled -> "Enabled, starting…"
            else -> "Off — the Mac can only watch."
        }
        controlBtn.text = if (connected) "Accessibility settings" else "Turn on mouse & keyboard"

        val q = Prefs.maxSize(this)
        qualityBtn.text = "Resolution: " + if (q == 0) "native" else "${q}p long side"
        bitrateBtn.text = "Bitrate: ${Prefs.bitrateMbps(this)} Mbit/s"
        audioBtn.text = "Game audio: " + if (Prefs.audio(this)) "on" else "off"

        val allowed = DisplaySize.hasPermission(this)
        val changed = DisplaySize.changedSize(this)
        val last = Prefs.lastShape(this)
        shapeView.text = when {
            !allowed -> "The Mac can fit the phone's screen shape to its display. Needs a one-time permission " +
                "from a computer with USB debugging:\nadb shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS"
            changed != null -> "Changed to fit the Mac (${changed.first}×${changed.second}). Set it back before using the phone on its own."
            else -> "Normal."
        }
        shapeNormalBtn.visibility = if (allowed && changed != null) View.VISIBLE else View.GONE
        shapeMacBtn.visibility = if (allowed && changed == null && last != null) View.VISIBLE else View.GONE
        if (last != null) shapeMacBtn.text = "Fit the Mac again (${last.first}:${last.second})"

        ui.removeCallbacksAndMessages(null)
        ui.postDelayed({ tick() }, 1000)
    }

    private fun tickHub() {
        val hub = HubService.instance
        val st = hub?.macStatus
        hubView.text = when {
            hub == null -> "Link to the Mac: starting…"
            !hub.connected -> "Mac: not connected\nOpen PhoneCast on the Mac (same PIN as below)."
            else -> "● " + (hub.macName ?: "Mac") + (st?.optInt("rtt", -1)?.takeIf { it >= 0 }?.let { "  ·  $it ms" } ?: "")
        }
        devicesView.text = if (st == null) (hub?.transfer ?: "") else buildString {
            val bat = st.optInt("battery", -1)
            if (bat >= 0) append("Mac      battery $bat %" + (if (st.optBoolean("charging")) " ⚡" else "") + "\n")
            if (st.has("cpu")) append("         CPU ${st.optInt("cpu")} %  ·  RAM ${st.optInt("mem")} %  ·  ${st.optString("thermal")}\n")
            val devs = st.optJSONArray("devices")
            if (devs != null) for (i in 0 until devs.length()) {
                val d = devs.getJSONObject(i)
                val ms = d.optInt("ms", -1)
                append(d.optString("name").take(16).padEnd(17) + (if (ms >= 0) "● $ms ms" else "○ offline") + "\n")
            }
            hub?.transfer?.let { append(it) }
        }.trimEnd()
        notifBtn.visibility = if (NotifListener.instance != null) View.GONE else View.VISIBLE
        clipBtn.text = "Copy to the Mac automatically: " + when {
            !Prefs.autoClip(this) -> "off"
            InputService.instance == null -> "on (needs mouse & keyboard turned on)"
            else -> "on"
        }
        val p = HubService.instance?.takeIf { true }?.let { try { it.features.perms() } catch (_: Exception) { null } }
        if (p != null) {
            val names = mapOf("sms" to "Messages", "calls" to "Calls", "callControl" to "Answer/dial", "contacts" to "Contacts",
                "photos" to "Photos", "files" to "Files", "notifications" to "Notifications", "control" to "Mouse & keyboard")
            featView.text = names.entries.joinToString("\n") { (k, v) -> (if (p.optBoolean(k)) "✓ " else "○ ") + v }
            featBtn.visibility = if (listOf("sms", "calls", "callControl", "contacts", "photos").all { p.optBoolean(it) }) View.GONE else View.VISIBLE
            filesBtn.visibility = if (p.optBoolean("files")) View.GONE else View.VISIBLE
        }
    }

    private fun requestFeatures() {
        val want = mutableListOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.READ_CONTACTS,
            Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_PHONE_STATE, Manifest.permission.CALL_PHONE,
            Manifest.permission.ANSWER_PHONE_CALLS)
        want += if (android.os.Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        requestPermissions(want.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }.toTypedArray(), REQ_FEATURES)
    }

    private fun openNotificationAccess() {
        try {
            startActivity(Intent("android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS")
                .putExtra("android.provider.extra.NOTIFICATION_LISTENER_COMPONENT_NAME",
                    ComponentName(this, NotifListener::class.java).flattenToString()))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
    }

    private fun pickFiles() {
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), REQ_FILES)
    }

    private fun sendClipboard() {
        val clip = getSystemService(android.content.ClipboardManager::class.java).primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        if (text.isNullOrEmpty()) { toast("The clipboard is empty"); return }
        HubService.instance?.sendClip(text) ?: toast("Not connected to the Mac")
    }

    private fun addresses(): String = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { ni -> ni.inetAddresses.toList().filterIsInstance<Inet4Address>().map { "${it.hostAddress}  (${ni.name})" } }
            .joinToString("\n")
    } catch (_: Exception) { "" }

    private fun accessibilityEnabled(): Boolean {
        val list = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(this, InputService::class.java)
        val splitter = TextUtils.SimpleStringSplitter(':').apply { setString(list) }
        return splitter.any { ComponentName.unflattenFromString(it) == me }
    }

    private fun openAccessibility() {
        try {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
        }
    }

    // ---- start / stop ----

    private fun toggle() {
        if (CaptureService.instance != null) {
            startService(Intent(this, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
            ui.postDelayed({ tick() }, 300)
            return
        }
        val need = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            need += Manifest.permission.POST_NOTIFICATIONS
        }
        if (Prefs.audio(this) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            need += Manifest.permission.RECORD_AUDIO
        }
        if (need.isNotEmpty()) requestPermissions(need.toTypedArray(), REQ_PERMS) else askCapture()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMS) askCapture()
        if (requestCode == REQ_FEATURES) HubService.instance?.features?.startCallWatch()
    }

    private fun askCapture() {
        val mpm = getSystemService(MediaProjectionManager::class.java)
        // Android 14+: ask for the whole screen directly (skips the "one app / entire screen" choice)
        val req = if (android.os.Build.VERSION.SDK_INT >= 34)
            mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
        else mpm.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(req, REQ_CAPTURE)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_FILES) {
            if (resultCode != RESULT_OK || data == null) return
            val uris = ArrayList<Uri>()
            data.clipData?.let { c -> for (i in 0 until c.itemCount) uris.add(c.getItemAt(i).uri) }
            if (uris.isEmpty()) data.data?.let { uris.add(it) }
            HubService.instance?.sendFiles(uris) ?: toast("Not connected to the Mac")
            return
        }
        if (requestCode != REQ_CAPTURE) return
        if (resultCode != RESULT_OK || data == null) {
            toast("Screen sharing was not allowed")
            return
        }
        startForegroundService(
            Intent(this, CaptureService::class.java)
                .putExtra(CaptureService.EXTRA_CODE, resultCode)
                .putExtra(CaptureService.EXTRA_DATA, data)
        )
        ui.postDelayed({ tick() }, 500)
    }

    private fun setShape(w: Int, h: Int) {
        when (DisplaySize.apply(this, w, h)) {
            DisplaySize.OK -> {}
            DisplaySize.NO_PERMISSION -> toast("Needs the one-time permission (see above)")
            else -> toast("Android refused to change the screen shape")
        }
        ui.postDelayed({ tick() }, 800)
    }

    private fun toast(s: String) = android.widget.Toast.makeText(this, s, android.widget.Toast.LENGTH_LONG).show()

    companion object {
        private const val REQ_PERMS = 1
        private const val REQ_CAPTURE = 2
        private const val REQ_FILES = 3
        private const val REQ_FEATURES = 4
        const val EXTRA_RESUME = "resume"
    }
}
