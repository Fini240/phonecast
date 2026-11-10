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
 * PC (Hermes dashboard: wake, sleep, boot, lights…; Moonlight), Cast (share this phone's screen) and Settings.
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

    override fun onResume() { super.onResume(); LauncherIcon.appVisible = true; tick() }
    override fun onPause() { super.onPause(); LauncherIcon.appVisible = false; ui.removeCallbacksAndMessages(null) }

    private lateinit var u: Ui

    private fun dp(v: Int) = u.dp(v)

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        // folding/unfolding or dark mode: rebuild so the columns and colours match
        val nowWide = newConfig.screenWidthDp >= 600
        val nowDark = (newConfig.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES
        if (nowWide != u.wide || nowDark != u.dark) { updaters.clear(); pages.clear(); tabViews.clear(); buildUi() }
    }

    private fun buildUi() {
        u = Ui(this)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(u.bg) }
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
            setBackgroundColor(u.barBg)
            setPadding(0, dp(10), 0, dp(10))
        }
        for ((id, icon, name) in listOf(
            Triple("home", R.drawable.ic_tab_home, "Home"), Triple("mac", R.drawable.ic_tab_mac, "Mac"),
            Triple("pc", R.drawable.ic_tab_pc, "PC"), Triple("cast", R.drawable.ic_tab_cast, "Cast"),
            Triple("settings", R.drawable.ic_tab_settings, "Settings"),
        )) {
            val tab = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                isClickable = true
                setOnClickListener { show(id) }
                contentDescription = name
                // Material 3 navigation: the selected icon sits in a pill
                addView(FrameLayout(this@MainActivity).apply {
                    addView(ImageView(this@MainActivity).apply { setImageResource(icon) },
                        FrameLayout.LayoutParams(dp(24), dp(24), Gravity.CENTER))
                }, LinearLayout.LayoutParams(dp(60), dp(32)))
                addView(TextView(this@MainActivity).apply { text = name; textSize = 12f; gravity = Gravity.CENTER; setPadding(0, dp(4), 0, 0) })
            }
            tabViews[id] = tab
            bar.addView(tab, LinearLayout.LayoutParams(0, -2, 1f))
        }
        root.addView(bar, LinearLayout.LayoutParams(-1, -2))
        setContentView(root)
        window.statusBarColor = u.bg
        window.navigationBarColor = u.barBg
        if (!u.dark) window.insetsController?.setSystemBarsAppearance(
            android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS)
        // the page starts below the status bar; the bar's colour runs down behind the gesture area
        root.setOnApplyWindowInsetsListener { v, ins ->
            val sb = ins.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.displayCutout())
            v.setPadding(sb.left, sb.top, sb.right, 0)
            bar.setPadding(0, dp(10), 0, dp(10) + sb.bottom)
            ins
        }
        show(current)
    }

    private fun show(id: String) {
        current = id
        getSharedPreferences("ui", MODE_PRIVATE).edit().putString("tab", id).apply()
        pages.forEach { (k, v) -> v.visibility = if (k == id) View.VISIBLE else View.GONE }
        tabViews.forEach { (k, t) ->
            val on = k == id
            val pill = t.getChildAt(0) as FrameLayout
            pill.background = if (on) GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(u.tonalBg) } else null
            (pill.getChildAt(0) as ImageView).setColorFilter(if (on) u.onTonal else u.text2)
            (t.getChildAt(1) as TextView).apply {
                setTextColor(if (on) u.text else u.text2)
                typeface = if (on) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.DEFAULT
            }
        }
        tick()
    }

    // ---- Home ----

    private fun homePage(): View {
        val status = u.Status()
        lateinit var castBtn: Button
        val transfer = u.label("", 13f, secondary = true)
        val devices = u.Rows()

        // setup checklist: only shown while something is missing
        val setupRows = u.Rows()
        val setupFix = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val setupCard = u.card(u.title("Finish setting up"), setupRows.view, setupFix)
        var setupSig = ""

        updaters += {
            val hub = HubService.instance
            val st = hub?.macStatus
            val sharing = CaptureService.instance != null
            when {
                hub == null -> status.set(u.grey, "Starting…", "")
                !hub.connected -> status.set(u.grey, "No computer connected",
                    "Open PhoneCast on the Mac. Same Wi-Fi or Tailscale; pair once in Settings.")
                else -> status.set(u.green, hub.macName ?: "Mac", listOfNotNull(
                    "Connected" + (st?.optInt("rtt", -1)?.takeIf { it >= 0 }?.let { " · $it ms" } ?: ""),
                    if (sharing) "screen shared" else null,
                    if (NotifListener.instance != null) "notifications on" else "notifications off",
                ).joinToString(" · "))
            }
            castBtn.text = if (sharing) "Stop casting" else "Cast this phone"
            transfer.text = hub?.transfer ?: ""
            u.gone(transfer, hub?.transfer == null)
            devices.set(deviceRows(st, all = true), "Shown once the Mac is connected.")

            // setup checklist
            val p = hub?.let { try { it.features.perms() } catch (_: Exception) { null } }
            val steps = listOf(
                Triple("Pair a computer", Auth.pairs(this).isNotEmpty() || hub?.connected == true) { show("settings") },
                Triple("Mouse & keyboard", InputService.instance != null) { openAccessibility() },
                Triple("Notifications", NotifListener.instance != null) { openNotificationAccess() },
                Triple("Messages, calls, photos", p?.let { q -> listOf("sms", "calls", "contacts", "photos").all { q.optBoolean(it) } } ?: true) { requestFeatures() },
            )
            val missing = steps.filter { !it.second }
            u.gone(setupCard, missing.isEmpty())
            setupRows.set(steps.map { (n, ok, _) -> Ui.Row(n, if (ok) "done" else "to do", if (ok) u.green else u.orange) })
            val sig = missing.joinToString { it.first }
            if (sig != setupSig) {
                setupSig = sig
                setupFix.removeAllViews()
                missing.firstOrNull()?.let { (n, _, f) -> setupFix.addView(u.primary("Set up: $n", f)) }
            }
        }
        val updateText = u.label("", 14f, secondary = true)
        lateinit var updateBtn: Button
        val updateCard = u.card(u.title("Update available"), updateText,
            u.primary("Install update") {
                if (Updates.apkUrl != null) Updates.install(this)
                else Updates.url?.let { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) }
            }.also { updateBtn = it },
            u.quiet("What's new") { Updates.url?.let { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) } })
        updaters += {
            val v = Updates.latest
            u.gone(updateCard, v == null)
            if (v != null) {
                updateText.text = Updates.installing ?: "PhoneCast $v is out (you have ${Updates.current(this)}). It installs over this app; your pairing stays."
                updateBtn.isEnabled = Updates.installing == null
                updateBtn.alpha = if (Updates.installing == null) 1f else 0.5f
            }
        }
        Updates.checkDaily(this)
        return u.page("PhoneCast",
            updateCard,
            u.card(status.view,
                u.primary("Cast this phone") { toggleCast() }.also { castBtn = it },
                u.grid(3,
                    "Mac screen" to { openMacControl() },
                    "Send files" to { pickFiles() },
                    "Clipboard" to { sendClipboard() },
                ), transfer),
            setupCard,
            u.card(u.title("Devices"), devices.view),
        )
    }

    private fun deviceRows(st: org.json.JSONObject?, all: Boolean, filter: (String) -> Boolean = { true }): List<Ui.Row> {
        if (st == null) return emptyList()
        val out = ArrayList<Ui.Row>()
        if (all) {
            val bat = st.optInt("battery", -1)
            out += Ui.Row(HubService.instance?.macName ?: "Mac",
                if (bat >= 0) "$bat %" + (if (st.optBoolean("charging")) " ⚡" else "") else "connected", u.green)
        }
        val devs = st.optJSONArray("devices")
        if (devs != null) for (i in 0 until devs.length()) {
            val d = devs.getJSONObject(i)
            val name = d.optString("name")
            if (!filter(name)) continue
            val ms = d.optInt("ms", -1)
            out += Ui.Row(name, if (ms >= 0) "$ms ms" else "offline", if (ms >= 0) u.green else u.grey)
        }
        return out
    }

    // ---- Mac ----

    private fun macAction(a: String) {
        val hub = HubService.instance
        if (hub?.connected != true) { toast("The Mac isn't connected"); return }
        hub.send(HubProto.MAC_ACTION, a.toByteArray())
    }

    private fun macPage(): View {
        val status = u.Status()
        val stats = u.Rows()
        updaters += {
            val hub = HubService.instance
            val st = hub?.macStatus
            if (hub?.connected == true) status.set(u.green, hub.macName ?: "Mac",
                st?.optInt("rtt", -1)?.takeIf { it >= 0 }?.let { "Connected · $it ms" } ?: "Connected")
            else status.set(u.grey, "Mac not connected", "Open PhoneCast on the Mac.")
            stats.set(if (st == null) emptyList() else buildList {
                st.optInt("battery", -1).takeIf { it >= 0 }?.let { add(Ui.Row("Battery", "$it %" + if (st.optBoolean("charging")) " · on power" else "")) }
                if (st.has("cpu")) add(Ui.Row("CPU", "${st.optInt("cpu")} %"))
                if (st.has("mem")) add(Ui.Row("Memory", "${st.optInt("mem")} %"))
                add(Ui.Row("Heat", st.optString("thermal", "—")))
            })
        }
        return u.page("Mac",
            u.card(status.view, stats.view),
            u.card(
                u.title("Control the Mac"),
                u.label("Tap = click, drag = drag, long press or two-finger tap = right click, two fingers = scroll.", 14f, secondary = true),
                u.primary("Open the Mac's screen") { openMacControl() },
            ),
            u.card(u.title("Keys"), u.grid(3,
                "Vol −" to { macAction("voldown") }, "Mute" to { macAction("mute") }, "Vol +" to { macAction("volup") },
                "⏮" to { macAction("prev") }, "⏯" to { macAction("play") }, "⏭" to { macAction("next") },
                "Lock" to { macAction("lock") }, "Screen off" to { macAction("displaysleep") }, "Screenshot" to { macAction("screenshot") },
            )),
            u.card(u.title("Send to the Mac"), u.grid(2,
                "Files" to { pickFiles() },
                "Clipboard" to { sendClipboard() },
            )),
        )
    }

    private fun openMacControl() {
        if (HubService.instance?.connected != true) { toast("The Mac isn't connected"); return }
        startActivity(Intent(this, MacViewActivity::class.java))
    }

    // ---- PC ----

    private fun pcPage(): View {
        val status = u.Status()
        val stats = u.Rows()
        val ai = u.Rows()
        val msg = u.label("", 13f, secondary = true)
        fun act(path: String, body: org.json.JSONObject, ask: String? = null) {
            val go = {
                msg.text = "…"
                Dashboard.action(path, body) { m -> ui.post { msg.text = m; tick() } }
            }
            if (ask == null) go() else AlertDialog.Builder(this).setTitle(ask)
                .setMessage("Anything unsaved on the PC may be lost.")
                .setPositiveButton("Do it") { _, _ -> go() }.setNegativeButton("Cancel", null).show()
        }
        fun j(vararg kv: Pair<String, Any>) = org.json.JSONObject().apply { kv.forEach { (k, v) -> put(k, v) } }
        fun gb(v: Double) = if (v > 0) "%.1f GB".format(v / 1e9) else "—"
        fun pct(v: Double) = v.takeIf { it >= 0 }?.let { "%.0f %%".format(it) } ?: "—"
        updaters += {
            if (current == "pc") Dashboard.poll()
            val pc = Dashboard.pc
            val st = Dashboard.stats
            val sub = Dashboard.error ?: st?.optJSONObject("boot")?.optString("message")?.takeIf { it != "null" } ?: ""
            when {
                st == null -> status.set(u.grey, "PC", sub.ifEmpty { "Waiting for the dashboard…" })
                Dashboard.online -> status.set(u.green, "PC · ${Dashboard.os.replaceFirstChar { it.uppercase() }}", sub)
                else -> status.set(u.grey, "The PC is asleep or off", sub)
            }
            stats.set(if (pc == null || !Dashboard.online) emptyList() else buildList {
                add(Ui.Row("GPU", pct(pc.optDouble("busy", -1.0))))
                add(Ui.Row("Video memory", gb(pc.optDouble("vram_used", 0.0)) + " / " + gb(pc.optDouble("vram_total", 0.0))))
                pc.optDouble("temp", Double.NaN).takeIf { !it.isNaN() }?.let { add(Ui.Row("GPU temp", "%.0f °C".format(it))) }
                pc.optDouble("power", Double.NaN).takeIf { !it.isNaN() }?.let { add(Ui.Row("GPU power", "%.0f W".format(it))) }
                add(Ui.Row("CPU", pct(pc.optDouble("cpu_pct", -1.0))))
                pc.optDouble("cpu_temp", Double.NaN).takeIf { !it.isNaN() }?.let { add(Ui.Row("CPU temp", "%.0f °C".format(it))) }
                add(Ui.Row("RAM", gb(pc.optDouble("mem_used", 0.0)) + " / " + gb(pc.optDouble("mem_total", 0.0))))
                pc.optLong("uptime", -1).takeIf { it >= 0 }?.let { add(Ui.Row("Up for", if (it > 3600) "${it / 3600} h ${it % 3600 / 60} min" else "${it / 60} min")) }
            })
            ai.set(st?.let { s ->
                val models = s.optJSONArray("ollama")
                val names = (0 until (models?.length() ?: 0)).joinToString(", ") { models!!.getJSONObject(it).optString("name") }
                listOf(Ui.Row("Engine", s.optString("engine").takeIf { it.isNotEmpty() && it != "null" } ?: "—"),
                    Ui.Row("Loaded", names.ifEmpty { "nothing" }))
            } ?: emptyList())
        }
        return u.page("PC",
            u.card(status.view, stats.view),
            u.card(u.title("Power"),
                u.primary("Wake") { if (Dashboard.stats == null && Prefs.pcMac(this).isNotEmpty()) wakePc() else act("wake", j()) },
                u.grid(2,
                    "Sleep" to { act("power", j("action" to "suspend"), "Put the PC to sleep?") },
                    "Shut down" to { act("power", j("action" to "poweroff"), "Shut the PC down?") },
                    "Start Linux" to { act("boot", j("os" to "linux"), "Restart into Linux?") },
                    "Start Windows" to { act("boot", j("os" to "windows"), "Restart into Windows?") },
                ), msg),
            u.card(u.title("Monitors & lights"), u.grid(2,
                "Monitors on" to { act("display", j("action" to "on")) },
                "Monitors off" to { act("display", j("action" to "off")) },
            ), u.swatches(
                0xFFEF4444.toInt() to { act("rgb", j("color" to "red")) },
                0xFFA855F7.toInt() to { act("rgb", j("color" to "purple")) },
                0xFF3B82F6.toInt() to { act("rgb", j("color" to "blue")) },
                0xFF22C55E.toInt() to { act("rgb", j("color" to "green")) },
                off = { act("rgb", j("color" to "off")) },
            ), u.tonal("Lights follow the PC's load") { act("rgbauto", j("on" to true)) }),
            u.card(u.title("AI"), ai.view, u.grid(2,
                "Ollama" to { act("engine", j("engine" to "ollama")) },
                "Strata" to { act("engine", j("engine" to "strata")) },
            ), u.hint("Switching engines works while the PC runs Linux.")),
            u.card(u.title("Use the PC"),
                u.label("Moonlight streams the PC (Sunshine) to this phone with touch, mouse and gamepad.", 14f, secondary = true),
                u.primary("Open Moonlight") { openMoonlight() },
                u.tonal("Full dashboard") { if (Dashboard.base.isNotEmpty()) startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Dashboard.base))) },
                u.hint("The controls only work over Tailscale (the dashboard refuses everything else).")),
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

    private fun askDashboard() {
        val f = EditText(this).apply { setText(Prefs.dashboard(this@MainActivity)); hint = "http://100.x.y.z:8765"; inputType = InputType.TYPE_TEXT_VARIATION_URI }
        AlertDialog.Builder(this).setTitle("Dashboard address")
            .setMessage("Empty = use the one set on the Mac.")
            .setView(f).setPositiveButton("Save") { _, _ -> Prefs.setDashboard(this, f.text.toString().trim()); tick() }
            .setNegativeButton("Cancel", null).show()
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
        val status = u.Status()
        val startBtn = u.primary("") { toggleCast() }
        val control = u.Status(16f)
        val controlBtn = u.tonal("") { openAccessibility() }
        val res = u.Segmented("Resolution (long side)", listOf("1280" to 1280, "1920" to 1920, "2560" to 2560, "Native" to 0),
            { Prefs.maxSize(this) }, { v -> Prefs.setMaxSize(this, v); CaptureService.instance?.restartVideo() }) { "$it px, set by the computer" }
        val rate = u.Segmented("Bitrate (Mbit/s)", listOf("8" to 8, "16" to 16, "24" to 24, "40" to 40),
            { Prefs.bitrateMbps(this) }, { v -> Prefs.setBitrateMbps(this, v); CaptureService.instance?.restartVideo() }) { "$it, set by the computer" }
        val audio = u.SwitchRow("Game audio", { Prefs.audio(this) }) { on ->
            Prefs.setAudio(this, on); tick()
            if (CaptureService.instance != null) toast("Takes effect next time you start sharing")
        }
        val shapeView = u.label("", 14f, secondary = true)
        val shapeNormalBtn = u.primary("Back to normal shape") { setShape(0, 0) }
        val shapeMacBtn = u.tonal("") { Prefs.lastShape(this)?.let { (w, h) -> setShape(w, h) } }
        val grantHelp = u.details("How to allow it",
            u.label("Once, from a computer with USB debugging on:", 13f, secondary = true),
            u.mono("adb shell pm grant $packageName android.permission.WRITE_SECURE_SETTINGS"))

        updaters += {
            val svc = CaptureService.instance
            when {
                svc == null -> status.set(u.grey, "Not sharing", "Faster next time: the “Cast to Mac” Quick Settings tile.")
                svc.clientAddress != null && UsbBridge.active && svc.clientAddress == "127.0.0.1" -> status.set(u.green, "Shown on the Mac", "over the USB cable")
                svc.clientAddress != null -> status.set(u.green, "Shown on a computer", svc.clientAddress ?: "")
                else -> status.set(u.orange, "Sharing", "Waiting for the Mac or PC to connect…")
            }
            startBtn.text = if (svc == null) "Cast this phone" else "Stop sharing"
            val enabled = accessibilityEnabled(); val connected = InputService.instance != null
            when {
                connected -> control.set(u.green, "On", "The Mac or PC can tap and type.")
                enabled -> control.set(u.orange, "Starting…", "")
                else -> control.set(u.grey, "Off", "The Mac or PC can only watch.")
            }
            controlBtn.text = if (connected) "Accessibility settings" else "Turn on mouse & keyboard"
            res.refresh(); rate.refresh(); audio.refresh()
            val allowed = DisplaySize.hasPermission(this)
            val changed = DisplaySize.changedSize(this)
            val last = Prefs.lastShape(this)
            shapeView.text = when {
                !allowed -> "The Mac can fit the phone's screen shape to its display. That needs a one-time permission."
                changed != null -> "Changed to fit the Mac (${changed.first}×${changed.second}). Set it back before using the phone on its own."
                else -> "Normal."
            }
            u.gone(grantHelp, allowed)
            u.gone(shapeNormalBtn, !(allowed && changed != null))
            u.gone(shapeMacBtn, !(allowed && changed == null && last != null))
            if (last != null) shapeMacBtn.text = "Fit the Mac again (${last.first}:${last.second})"
        }
        return u.page("Cast",
            u.card(status.view, startBtn),
            u.card(u.title("Mouse & keyboard"), control.view, controlBtn,
                u.details("Help",
                    u.hint("Uses an Accessibility service to tap for you. If Android says \"Restricted setting\": " +
                        "App info → ⋮ → Allow restricted settings, then try again."),
                    u.hint("Games may treat tap injection like a cheat tool. Test on a throwaway account first."))),
            u.card(u.title("Quality"), res.view, rate.view, audio.view,
                u.hint("A connected Mac or PC sets resolution and bitrate from its own Quality menu.")),
            u.card(u.title("Screen shape"), shapeView, grantHelp, shapeNormalBtn, shapeMacBtn),
        )
    }

    // ---- Settings ----

    private fun settingsPage(): View {
        val pinView = u.label("", 34f, bold = true).apply { letterSpacing = 0.18f; setTextIsSelectable(true); setPadding(0, dp(4), 0, dp(2)) }
        val addrRows = u.Rows()
        val keyView = u.mono()
        val notif = u.Status(16f)
        val notifBtn = u.tonal("Allow notification access") { openNotificationAccess() }
        val clip = u.SwitchRow("Copy to the Mac automatically", { Prefs.autoClip(this) }) { on -> Prefs.setAutoClip(this, on); tick() }
        val shots = u.SwitchRow("Send new screenshots to the Mac", { Prefs.autoShots(this) }) { on -> Prefs.setAutoShots(this, on); tick() }
        val featRows = u.Rows()
        val dashView = u.label("", 14f, secondary = true)
        val featBtn = u.primary("Allow messages, calls, contacts & photos") { requestFeatures() }
        val filesBtn = u.tonal("Allow browsing phone files") {
            try { startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))) }
            catch (_: Exception) { startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)) }
        }
        updaters += {
            pinView.text = Prefs.pin(this)
            addrRows.set(addressRows(), "No network. Connect to Wi-Fi.")
            if (NotifListener.instance != null) notif.set(u.green, "Notifications go to the Mac", "")
            else notif.set(u.grey, "Notifications stay on the phone", "")
            u.gone(notifBtn, NotifListener.instance != null)
            shots.refresh("They land in Downloads/PhoneCast and on the Mac's clipboard")
            clip.refresh(if (Prefs.autoClip(this) && InputService.instance == null) "Needs mouse & keyboard turned on (Cast tab)" else "Copy here, paste on the Mac")
            val p = HubService.instance?.let { try { it.features.perms() } catch (_: Exception) { null } }
            if (p != null) {
                val names = mapOf("sms" to "Messages", "calls" to "Calls", "callControl" to "Answer & dial", "contacts" to "Contacts",
                    "photos" to "Photos", "files" to "Files", "notifications" to "Notifications", "control" to "Mouse & keyboard")
                featRows.set(names.map { (k, v) -> val ok = p.optBoolean(k); Ui.Row(v, if (ok) "allowed" else "off", if (ok) u.green else u.grey) })
                u.gone(featBtn, listOf("sms", "calls", "callControl", "contacts", "photos").all { p.optBoolean(it) })
                u.gone(filesBtn, p.optBoolean("files"))
            } else featRows.set(emptyList(), "Starting…")
        }
        keyView.text = Auth.fingerprint()
        updaters += {
            dashView.text = if (Dashboard.base.isEmpty()) "Not set. With a Hermes-style dashboard, the PC tab shows your PC and its controls."
                else Dashboard.base + if (Prefs.dashboard(this).isEmpty()) "  (from the Mac)" else ""
        }
        val pairsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        var shownPairs: String? = null
        updaters += {
            val pairs = Auth.pairs(this).values.sortedBy { it.name.lowercase() }
            val sig = pairs.joinToString { it.id }
            if (sig != shownPairs) {       // rebuild the rows only when the list changed
                shownPairs = sig
                pairsBox.removeAllViews()
                if (pairs.isEmpty()) pairsBox.addView(u.hint("No computer paired yet."))
                for (pr in pairs) pairsBox.addView(LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, dp(6), 0, 0)
                    addView(View(this@MainActivity).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(u.green) } },
                        LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(10) })
                    addView(u.label(pr.name, 16f), LinearLayout.LayoutParams(0, -2, 1f))
                    addView(u.quiet("Remove", u.red) {
                        AlertDialog.Builder(this@MainActivity).setTitle("Remove ${pr.name}?")
                            .setMessage("It can't connect until you scan its code again (or enter the PIN).")
                            .setPositiveButton("Remove") { _, _ -> Auth.removePair(this@MainActivity, pr.id); tick() }
                            .setNegativeButton("Cancel", null).show()
                    }.apply { layoutParams = LinearLayout.LayoutParams(-2, -2) })
                })
            }
        }
        return u.page("Settings",
            u.card(u.title("Paired computers"), pairsBox,
                u.primary("Scan a computer's QR code") { Pairing.scan(this) { ok, msg -> toast(msg); if (ok) tick() } },
                u.hint("On the Mac or PC: PhoneCast → Settings shows the code. No PIN needed, and both sides prove a shared key on every connection."),
                u.details("Pair with a PIN instead",
                    u.label("Enter this on the computer once:", 14f, secondary = true),
                    pinView, addrRows.view,
                    u.label("Link key (the Mac shows the same in Settings)", 13f, secondary = true).apply { setPadding(0, dp(10), 0, dp(2)) },
                    keyView,
                    u.quiet("New PIN", u.red) {
                        AlertDialog.Builder(this).setTitle("Make a new PIN?")
                            .setMessage("Computers paired with the PIN have to enter the new one. QR-paired computers stay paired.")
                            .setPositiveButton("New PIN") { _, _ -> Prefs.newPin(this); toast("New PIN made"); tick() }
                            .setNegativeButton("Cancel", null).show()
                    })),
            u.card(u.title("On the Mac"), notif.view, notifBtn, clip.view, shots.view),
            u.card(u.title("Phone features on the Mac"), featRows.view, featBtn, filesBtn,
                u.hint("Sideloaded apps may first need App info → ⋮ → Allow restricted settings.")),
            u.card(u.title("PC dashboard (optional)"), dashView,
                u.tonal("Set the dashboard address…") { askDashboard() }),
        )
    }

    // ---- refresh ----

    private fun tick() {
        // the PC tab only exists for people with a Hermes dashboard (set here or on the Mac)
        Dashboard.base = Prefs.dashboard(this).ifEmpty { HubService.instance?.macStatus?.optString("dashboard") ?: "" }.trimEnd('/')
        val hasPc = Dashboard.base.isNotEmpty()
        tabViews["pc"]?.visibility = if (hasPc) View.VISIBLE else View.GONE
        if (!hasPc && current == "pc") show("home")
        updaters.forEach { it() }
        ui.removeCallbacksAndMessages(null)
        ui.postDelayed({ tick() }, 1000)
    }

    // ---- helpers ----

    /** The phone's addresses a computer can reach: Wi-Fi, Tailscale/VPN, Ethernet (mobile data is useless for this). */
    private fun addressRows(): List<Ui.Row> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { ni ->
                val kind = when {
                    ni.name.startsWith("wlan") || ni.name.startsWith("swlan") -> "Wi-Fi"
                    ni.name.startsWith("tun") -> "Tailscale / VPN"
                    ni.name.startsWith("eth") || ni.name.startsWith("usb") || ni.name.startsWith("rndis") || ni.name.startsWith("ncm") -> "Cable"
                    else -> null
                }
                if (kind == null) emptyList()
                else ni.inetAddresses.toList().filterIsInstance<Inet4Address>().map { Ui.Row(kind, it.hostAddress ?: "") }
            }
    } catch (_: Exception) { emptyList() }

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
        clip?.takeIf { it.itemCount > 0 && it.description.hasMimeType("image/*") }?.getItemAt(0)?.uri?.let { img ->
            HubService.instance?.takeIf { it.connected }?.sendClipImage(img) ?: toast("Not connected to the Mac"); return
        }
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
