package de.finn.phonecast

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
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
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * The phone app: a bottom bar with Home (link + quick actions), Mac (control it, media keys),
 * PC (pc: Moonlight, wake), Cast (share this phone's screen) and Settings.
 */
class MainActivity : Activity() {

    private val ui = Handler(Looper.getMainLooper())
    private val pages = LinkedHashMap<String, View>()
    private val tabViews = HashMap<String, LinearLayout>()
    private var current = "home"
    /** Everything that refreshes once a second. */
    private val updaters = mutableListOf<() -> Unit>()

    private val qualities = intArrayOf(1280, 1920, 2560, 0)
    private val bitrates = intArrayOf(8, 16, 24, 40)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = savedInstanceState?.getString("tab") ?: getSharedPreferences("ui", MODE_PRIVATE).getString("tab", "home")!!
        buildUi()
        HubService.start(this)
        resumeIfAsked(intent)
    }

    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("tab", current) }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        resumeIfAsked(intent)
    }

    /** Opened to share the screen right away (Quick Settings tile, the Mac's "Mirror phone", after unlock). */
    private fun resumeIfAsked(i: Intent?) {
        if (i?.getBooleanExtra(EXTRA_RESUME, false) != true) return
        i.removeExtra(EXTRA_RESUME)
        if (CaptureService.instance == null) toggleCast()
    }

    override fun onResume() { super.onResume(); tick() }
    override fun onPause() { super.onPause(); ui.removeCallbacksAndMessages(null) }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val accent: Int by lazy {
        val tv = TypedValue(); theme.resolveAttribute(android.R.attr.colorAccent, tv, true); tv.data
    }

    // ---- building blocks ----

    private fun label(text: String, size: Float = 15f, bold: Boolean = false, alpha: Float = 1f) = TextView(this).apply {
        this.text = text; textSize = size
        if (bold) typeface = Typeface.DEFAULT_BOLD
        this.alpha = alpha
        setPadding(0, dp(3), 0, dp(3))
    }

    private fun card(vararg views: View) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        background = GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(Color.argb(28, 128, 128, 128)) }
        views.forEach { addView(it) }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) }
    }

    private fun button(text: String, onClick: () -> Unit) = Button(this).apply {
        this.text = text; isAllCaps = false
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) }
    }

    /** A grid of equal buttons (media keys, quick actions). */
    private fun grid(cols: Int, vararg items: Pair<String, () -> Unit>) = GridLayout(this).apply {
        columnCount = cols
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) }
        for ((t, f) in items) addView(Button(this@MainActivity).apply {
            text = t; isAllCaps = false; textSize = 14f
            setOnClickListener { f() }
            layoutParams = GridLayout.LayoutParams(GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f)).apply {
                width = 0; setMargins(dp(3), dp(3), dp(3), dp(3))
            }
        })
    }

    private fun page(title: String, vararg views: View): View {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(24), dp(18), dp(24))
            addView(label(title, 28f, bold = true))
            views.forEach { addView(it) }
        }
        return ScrollView(this).apply { addView(col); isFillViewport = true }
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val content = FrameLayout(this)
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))

        pages["home"] = homePage()
        pages["mac"] = macPage()
        pages["pc"] = pcPage()
        pages["cast"] = castPage()
        pages["settings"] = settingsPage()
        pages.values.forEach { content.addView(it, FrameLayout.LayoutParams(-1, -1)) }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(Color.argb(36, 128, 128, 128))
            setPadding(0, dp(6), 0, dp(6))
        }
        for ((id, icon, name) in listOf(
            Triple("home", R.drawable.ic_tab_home, "Home"), Triple("mac", R.drawable.ic_tab_mac, "Mac"),
            Triple("pc", R.drawable.ic_tab_pc, "PC"), Triple("cast", R.drawable.ic_tab_cast, "Cast"),
            Triple("settings", R.drawable.ic_tab_settings, "Settings"),
        )) {
            val tab = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(0, dp(4), 0, dp(4))
                isClickable = true
                setOnClickListener { show(id) }
                contentDescription = name
                addView(ImageView(this@MainActivity).apply { setImageResource(icon) }, LinearLayout.LayoutParams(dp(24), dp(24)))
                addView(TextView(this@MainActivity).apply { text = name; textSize = 12f; gravity = Gravity.CENTER })
            }
            tabViews[id] = tab
            bar.addView(tab, LinearLayout.LayoutParams(0, -2, 1f))
        }
        root.addView(bar, LinearLayout.LayoutParams(-1, -2))
        setContentView(root)
        // keep the bar above the gesture/navigation area
        root.setOnApplyWindowInsetsListener { v, ins ->
            val sb = ins.getInsets(android.view.WindowInsets.Type.systemBars())
            v.setPadding(sb.left, sb.top, sb.right, sb.bottom); ins
        }
        show(current)
    }

    private fun show(id: String) {
        current = id
        getSharedPreferences("ui", MODE_PRIVATE).edit().putString("tab", id).apply()
        pages.forEach { (k, v) -> v.visibility = if (k == id) View.VISIBLE else View.GONE }
        tabViews.forEach { (k, t) ->
            val on = k == id
            (t.getChildAt(0) as ImageView).setColorFilter(if (on) accent else Color.GRAY)
            (t.getChildAt(1) as TextView).apply { setTextColor(if (on) accent else Color.GRAY); typeface = if (on) Typeface.DEFAULT_BOLD else Typeface.DEFAULT }
        }
        tick()
    }

    // ---- Home ----

    private fun homePage(): View {
        val status = label("", 18f, bold = true)
        val sub = label("", 14f, alpha = 0.75f)
        val devices = label("", 12f).apply { typeface = Typeface.MONOSPACE }
        lateinit var castBtn: Button
        val transfer = label("", 13f, alpha = 0.8f)
        updaters += {
            val hub = HubService.instance
            val st = hub?.macStatus
            status.text = when {
                hub == null -> "Starting…"
                !hub.connected -> "○ Mac not connected"
                else -> "● " + (hub.macName ?: "Mac") + (st?.optInt("rtt", -1)?.takeIf { it >= 0 }?.let { "  ·  $it ms" } ?: "")
            }
            sub.text = when {
                hub?.connected == true -> listOfNotNull(
                    if (CaptureService.instance != null) "this phone is shared" else null,
                    if (NotifListener.instance != null) "notifications go to the Mac" else "notifications off",
                ).joinToString(" · ")
                else -> "Open PhoneCast on the Mac. Same Wi-Fi or Tailscale, PIN from Settings."
            }
            devices.text = deviceLines(st, all = true)
            castBtn.text = if (CaptureService.instance != null) "Stop casting" else "Cast this phone"
            transfer.text = hub?.transfer ?: ""
            transfer.visibility = if (hub?.transfer != null) View.VISIBLE else View.GONE
        }
        return page("PhoneCast",
            card(status, sub),
            card(label("Quick actions", 16f, bold = true), grid(2,
                "Cast this phone" to { toggleCast() },
                "Control the Mac" to { openMacControl() },
                "Send files" to { pickFiles() },
                "Send clipboard" to { sendClipboard() },
            ).also { g -> castBtn = g.getChildAt(0) as Button }, transfer),
            card(label("Devices", 16f, bold = true), devices),
        )
    }

    private fun deviceLines(st: org.json.JSONObject?, all: Boolean, filter: (String) -> Boolean = { true }): String {
        if (st == null) return "Shown once the Mac is connected."
        return buildString {
            if (all) {
                val bat = st.optInt("battery", -1)
                append("Mac".padEnd(22) + (if (bat >= 0) "$bat %" + (if (st.optBoolean("charging")) " ⚡" else "") else "") + "\n")
            }
            val devs = st.optJSONArray("devices")
            if (devs != null) for (i in 0 until devs.length()) {
                val d = devs.getJSONObject(i)
                val name = d.optString("name")
                if (!filter(name)) continue
                val ms = d.optInt("ms", -1)
                append(name.take(21).padEnd(22) + (if (ms >= 0) "● $ms ms" else "○ off") + "\n")
            }
        }.trimEnd()
    }

    // ---- Mac ----

    private fun macAction(a: String) {
        val hub = HubService.instance
        if (hub?.connected != true) { toast("The Mac isn't connected"); return }
        hub.send(HubProto.MAC_ACTION, a.toByteArray())
    }

    private fun macPage(): View {
        val head = label("", 18f, bold = true)
        val stats = label("", 14f).apply { typeface = Typeface.MONOSPACE }
        updaters += {
            val hub = HubService.instance
            val st = hub?.macStatus
            head.text = if (hub?.connected == true) hub.macName ?: "Mac" else "Mac not connected"
            stats.text = if (st == null) "" else buildString {
                st.optInt("battery", -1).takeIf { it >= 0 }?.let { append("Battery  $it %" + (if (st.optBoolean("charging")) " · on power" else "") + "\n") }
                if (st.has("cpu")) append("CPU      ${st.optInt("cpu")} %\n")
                if (st.has("mem")) append("Memory   ${st.optInt("mem")} %\n")
                append("Heat     ${st.optString("thermal", "-")}\n")
                st.optInt("rtt", -1).takeIf { it >= 0 }?.let { append("Link     $it ms") }
            }.trimEnd()
        }
        return page("Mac",
            card(head, stats),
            card(
                label("Control the Mac", 16f, bold = true),
                label("Its screen on this phone: tap = click, drag = drag, long press or two-finger tap = right click, two fingers = scroll.", 13f, alpha = 0.7f),
                button("Open the Mac's screen") { openMacControl() },
            ),
            card(label("Keys", 16f, bold = true), grid(3,
                "Vol −" to { macAction("voldown") }, "Mute" to { macAction("mute") }, "Vol +" to { macAction("volup") },
                "⏮" to { macAction("prev") }, "⏯" to { macAction("play") }, "⏭" to { macAction("next") },
                "Lock Mac" to { macAction("lock") }, "Screen off" to { macAction("displaysleep") }, "Screenshot" to { macAction("screenshot") },
            )),
            card(label("Send", 16f, bold = true), grid(2,
                "Files to the Mac" to { pickFiles() },
                "Clipboard to the Mac" to { sendClipboard() },
            )),
        )
    }

    private fun openMacControl() {
        if (HubService.instance?.connected != true) { toast("The Mac isn't connected"); return }
        startActivity(Intent(this, MacViewActivity::class.java))
    }

    // ---- PC ----

    private fun pcPage(): View {
        val status = label("", 12f).apply { typeface = Typeface.MONOSPACE }
        val macView = label("", 13f, alpha = 0.7f)
        updaters += {
            status.text = deviceLines(HubService.instance?.macStatus, all = false) { it.contains("pc", true) || it.contains("PC", false) }
                .ifEmpty { "Add the PC in the Mac's Settings → Devices to watch." }
            val mac = Prefs.pcMac(this)
            macView.text = if (mac.isEmpty()) "Wake-on-LAN: no network card address set." else "Wake-on-LAN: $mac"
        }
        return page("PC",
            card(label("my-pc", 16f, bold = true), status,
                label("Measured from the Mac every 5 seconds.", 12f, alpha = 0.6f)),
            card(
                label("Use the PC", 16f, bold = true),
                label("Moonlight streams the PC (Sunshine) to this phone with touch, mouse and gamepad.", 13f, alpha = 0.7f),
                button("Open Moonlight") { openMoonlight() },
                button("Wake the PC") { wakePc() },
                macView,
                button("Set the PC's network card address…") { askPcMac() },
            ),
            card(
                label("This phone on the PC", 16f, bold = true),
                label("PhoneCast for Windows shows this phone on the PC like the Mac app does: tap Cast, then connect on the PC.", 13f, alpha = 0.7f),
            ),
        )
    }

    private fun openMoonlight() {
        val i = packageManager.getLaunchIntentForPackage("com.limelight")
        if (i != null) startActivity(i)
        else startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.limelight")))
    }

    /** Wake-on-LAN magic packet (6×FF + 16× the MAC) to the local network, and to the Tailscale peer on port 9. */
    private fun wakePc() {
        val mac = Prefs.pcMac(this)
        if (mac.isEmpty()) { askPcMac(); return }
        val bytes = mac.split(':', '-').mapNotNull { it.toIntOrNull(16)?.toByte() }
        if (bytes.size != 6) { toast("That address doesn't look like AA:BB:CC:DD:EE:FF"); return }
        val packet = ByteArray(6) { 0xff.toByte() } + (0 until 16).flatMap { bytes }.toByteArray()
        Thread {
            var sent = 0
            try {
                DatagramSocket().use { s ->
                    s.broadcast = true
                    val targets = mutableListOf(InetAddress.getByName("255.255.255.255"))
                    NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                        .flatMap { it.interfaceAddresses }.mapNotNull { it.broadcast }.forEach { targets += it }
                    for (t in targets) for (port in intArrayOf(9, 7)) { s.send(DatagramPacket(packet, packet.size, t, port)); sent++ }
                }
            } catch (_: Exception) {}
            ui.post { toast(if (sent > 0) "Wake signal sent. The PC needs about 20 s to boot." else "Couldn't send (no Wi-Fi?)") }
        }.start()
    }

    private fun askPcMac() {
        val f = EditText(this).apply {
            setText(Prefs.pcMac(this@MainActivity)); hint = "AA:BB:CC:DD:EE:FF"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        }
        AlertDialog.Builder(this).setTitle("PC's network card address (MAC)")
            .setMessage("For Wake-on-LAN. On Linux: ip link · on Windows: getmac")
            .setView(f).setPositiveButton("Save") { _, _ -> Prefs.setPcMac(this, f.text.toString().trim().uppercase()); tick() }
            .setNegativeButton("Cancel", null).show()
    }

    // ---- Cast (this phone's screen) ----

    private fun castPage(): View {
        val status = label("", 17f, bold = true)
        val startBtn = button("") { toggleCast() }
        val controlView = label("", 14f)
        val controlBtn = button("") { openAccessibility() }
        val qualityBtn = button("") {
            val i = (qualities.indexOf(Prefs.maxSize(this)) + 1) % qualities.size
            Prefs.setMaxSize(this, qualities[i]); CaptureService.instance?.restartVideo(); tick()
        }
        val bitrateBtn = button("") {
            val i = (bitrates.indexOf(Prefs.bitrateMbps(this)) + 1) % bitrates.size
            Prefs.setBitrateMbps(this, bitrates[i]); CaptureService.instance?.restartVideo(); tick()
        }
        val audioBtn = button("") {
            Prefs.setAudio(this, !Prefs.audio(this)); tick()
            if (CaptureService.instance != null) toast("Takes effect next time you start sharing")
        }
        val shapeView = label("", 14f)
        val shapeNormalBtn = button("Back to normal shape") { setShape(0, 0) }
        val shapeMacBtn = button("") { Prefs.lastShape(this)?.let { (w, h) -> setShape(w, h) } }

        updaters += {
            val svc = CaptureService.instance
            status.text = when {
                svc == null -> "Not sharing"
                svc.clientAddress != null && UsbBridge.active && svc.clientAddress == "127.0.0.1" -> "● Shown on the Mac (cable)"
                svc.clientAddress != null -> "● Shown on ${svc.clientAddress}"
                else -> "● Sharing — waiting for the Mac or PC"
            }
            startBtn.text = if (svc == null) "Cast this phone" else "Stop sharing"
            val enabled = accessibilityEnabled(); val connected = InputService.instance != null
            controlView.text = when { connected -> "On — the Mac/PC can tap and type."; enabled -> "Enabled, starting…"; else -> "Off — they can only watch." }
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
        }
        return page("Cast",
            card(status, startBtn, label("Faster: the “Cast to Mac” Quick Settings tile.", 12f, alpha = 0.6f)),
            card(label("Mouse & keyboard from the Mac/PC", 16f, bold = true), controlView, controlBtn,
                label("Uses an Accessibility service to tap for you. If Android says \"Restricted setting\": " +
                    "App info → ⋮ → Allow restricted settings, then try again. " +
                    "Games may treat tap injection like a cheat tool — test on a throwaway account first.", 12f, alpha = 0.6f)),
            card(label("Quality", 16f, bold = true), qualityBtn, bitrateBtn, audioBtn),
            card(label("Screen shape", 16f, bold = true), shapeView, shapeNormalBtn, shapeMacBtn),
        )
    }

    // ---- Settings ----

    private fun settingsPage(): View {
        val pinView = label("", 30f, bold = true).apply { typeface = Typeface.MONOSPACE; letterSpacing = 0.15f }
        val addrView = label("", 14f, alpha = 0.8f)
        val keyView = label("", 12f, alpha = 0.6f).apply { typeface = Typeface.MONOSPACE }
        val notifBtn = button("Show phone notifications on the Mac") { openNotificationAccess() }
        val clipBtn = button("") { Prefs.setAutoClip(this, !Prefs.autoClip(this)); tick() }
        val featView = label("", 14f)
        val featBtn = button("Allow messages, calls, contacts & photos") { requestFeatures() }
        val filesBtn = button("Allow browsing phone files from the Mac") {
            try { startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))) }
            catch (_: Exception) { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) }
        }
        updaters += {
            pinView.text = Prefs.pin(this)
            addrView.text = addresses().ifEmpty { "No network address — connect to Wi-Fi" }
            notifBtn.visibility = if (NotifListener.instance != null) View.GONE else View.VISIBLE
            clipBtn.text = "Copy to the Mac automatically: " + when {
                !Prefs.autoClip(this) -> "off"
                InputService.instance == null -> "on (needs mouse & keyboard turned on)"
                else -> "on"
            }
            val p = HubService.instance?.let { try { it.features.perms() } catch (_: Exception) { null } }
            if (p != null) {
                val names = mapOf("sms" to "Messages", "calls" to "Calls", "callControl" to "Answer/dial", "contacts" to "Contacts",
                    "photos" to "Photos", "files" to "Files", "notifications" to "Notifications", "control" to "Mouse & keyboard")
                featView.text = names.entries.joinToString("\n") { (k, v) -> (if (p.optBoolean(k)) "✓ " else "○ ") + v }
                featBtn.visibility = if (listOf("sms", "calls", "callControl", "contacts", "photos").all { p.optBoolean(it) }) View.GONE else View.VISIBLE
                filesBtn.visibility = if (p.optBoolean("files")) View.GONE else View.VISIBLE
            }
        }
        keyView.text = "Link key (the Mac shows the same in Settings):\n" + Auth.fingerprint()
        return page("Settings",
            card(label("Pairing PIN (enter it on the Mac once)", 13f, alpha = 0.7f), pinView, addrView, keyView,
                button("New PIN (unpairs every Mac)") { Prefs.newPin(this); toast("New PIN. Enter it on the Mac again."); tick() }),
            card(label("On the Mac", 16f, bold = true), notifBtn, clipBtn),
            card(label("Phone features on the Mac", 16f, bold = true), featView, featBtn, filesBtn),
        )
    }

    // ---- refresh ----

    private fun tick() {
        updaters.forEach { it() }
        ui.removeCallbacksAndMessages(null)
        ui.postDelayed({ tick() }, 1000)
    }

    // ---- helpers ----

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
        try { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        catch (_: Exception) { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
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

    private fun requestFeatures() {
        val want = mutableListOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.READ_CONTACTS,
            Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_PHONE_STATE, Manifest.permission.CALL_PHONE,
            Manifest.permission.ANSWER_PHONE_CALLS)
        want += if (android.os.Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        requestPermissions(want.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }.toTypedArray(), REQ_FEATURES)
    }

    private fun pickFiles() {
        if (HubService.instance?.connected != true) { toast("The Mac isn't connected"); return }
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

    // ---- start / stop sharing ----

    private fun toggleCast() {
        if (CaptureService.instance != null) {
            startService(Intent(this, CaptureService::class.java).setAction(CaptureService.ACTION_STOP))
            ui.postDelayed({ tick() }, 300)
            return
        }
        val need = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) need += Manifest.permission.POST_NOTIFICATIONS
        if (Prefs.audio(this) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) need += Manifest.permission.RECORD_AUDIO
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
        if (resultCode != RESULT_OK || data == null) { toast("Screen sharing was not allowed"); return }
        startForegroundService(Intent(this, CaptureService::class.java)
            .putExtra(CaptureService.EXTRA_CODE, resultCode).putExtra(CaptureService.EXTRA_DATA, data))
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
