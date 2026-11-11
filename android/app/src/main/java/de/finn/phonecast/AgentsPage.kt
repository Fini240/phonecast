package de.finn.phonecast

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.provider.MediaStore
import android.text.Editable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.TypefaceSpan
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.ArrayAdapter
import android.widget.CheckBox
import android.widget.AutoCompleteTextView
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import kotlin.math.max

/**
 * The Agents tab: Claude Code / Codex chats running on the Mac. Folded: list → chat. Unfolded: list and
 * chat side by side. Chats in a PhoneCast terminal can be answered, stopped and their questions approved;
 * finished ones are reopened on the Mac when you reply.
 */
class AgentsPage(private val a: Activity, private val u: Ui) {
    private fun dp(v: Int) = u.dp(v)
    private val prefs = a.getSharedPreferences("agents", Activity.MODE_PRIVATE)

    val view = FrameLayout(a).apply { setBackgroundColor(u.bg) }
    private val split = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
    private val listPane = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
    private val chatPane = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(u.bg) }
    private val emptyChat = u.label("Pick a chat", 15f, secondary = true).apply { gravity = Gravity.CENTER }

    private var open: String? = prefs.getString("open", null)
    private var filter = prefs.getString("filter", "all")!!
    private var query = ""
    private val expanded = HashSet<String>()
    private val pins: MutableSet<String> get() = prefs.getStringSet("pins", emptySet())!!.toMutableSet()

    private val listener: (String) -> Unit = { what ->
        when (what) {
            "sessions", "host" -> { refreshList(); refreshChatHeader() }
            "msgs" -> renderMessages()
        }
    }

    fun destroy() { Agents.unlisten(listener) }

    /** The tab became (in)visible: only the visible chat counts as "seen" for notifications. */
    fun visible(on: Boolean) {
        Agents.foreground = if (on) open else null
        if (on) open?.let { Agents.clearNotification(a, it) }
    }

    /** System back: closes the chat on a folded phone. */
    fun back(): Boolean {
        if (!u.wide && open != null) { openChat(null); return true }
        return false
    }

    fun openChat(sid: String?) {
        open = sid
        prefs.edit().putString("open", sid).apply()
        Agents.foreground = sid
        sid?.let { Agents.clearNotification(a, it) }
        termMode = sid?.let { Agents.byId[it] }?.let { it.has("host") || it.optString("agent").let { a -> a != "claude" && a != "codex" } } ?: false
        changesMode = false; filesMode = false; filesPath = ""; filePath = null
        attached.clear(); attachedFiles.clear(); renderThumbs(); suggest(null)
        Agents.watch(sid)
        draftRestore()
        showPane(); refreshChatHeader(); renderMessages(); refreshList()
    }

    private fun showPane() {
        val hasChat = open != null
        if (u.wide) {
            chatPane.visibility = if (hasChat) View.VISIBLE else View.GONE
            emptyChat.visibility = if (hasChat) View.GONE else View.VISIBLE
        } else {
            listPane.visibility = if (hasChat) View.GONE else View.VISIBLE
            chatPane.visibility = if (hasChat) View.VISIBLE else View.GONE
        }
    }

    // ================================================================= list

    private val banner = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
    private val planBox = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
    private var planSig = ""
    private val chips = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
    private val rows = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, dp(24)) }
    private val rowCache = HashMap<String, Pair<String, View>>()
    private lateinit var searchBox: EditText

    private fun buildList() {
        val head = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(20), dp(16), dp(4))
            addView(u.label("Agents", 30f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
            addView(iconButton(R.drawable.ic_more, tr("Settings")) { settingsMenu(it) })
            addView(iconButton(R.drawable.ic_add, tr("New chat"), filled = true) { newChat() })
        }
        searchBox = EditText(a).apply {
            hint = tr("Search chats and folders"); textSize = 15f; setSingleLine(); imeOptions = EditorInfo.IME_ACTION_SEARCH
            setTextColor(u.text); setHintTextColor(u.text2)
            background = pill(u.surface, 22)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            setCompoundDrawablesRelativeWithIntrinsicBounds(tint(R.drawable.ic_search, u.text2), null, null, null)
            compoundDrawablePadding = dp(10)
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { query = s.toString().trim(); refreshList() }
                override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, af: Int) {}
                override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {}
            })
        }
        listPane.addView(head)
        listPane.addView(searchBox, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(16), dp(8), dp(16), dp(4)) })
        listPane.addView(HorizontalScrollView(a).apply {
            isHorizontalScrollBarEnabled = false
            addView(chips.apply { setPadding(dp(16), dp(6), dp(16), dp(6)) })
        })
        listPane.addView(ScrollView(a).apply {
            addView(LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                addView(planBox); addView(banner); addView(rows)
            })
        }, LinearLayout.LayoutParams(-1, 0, 1f))
    }

    private fun refreshChips(all: List<JSONObject>) {
        val tops = all.filter { !it.optBoolean("sub") }
        val counts = mapOf(
            "all" to tops.size, "you" to tops.count(Agents::needsYou), "active" to tops.count(Agents::isActive),
            "claude" to tops.count { it.optString("agent") == "claude" }, "codex" to tops.count { it.optString("agent") == "codex" })
        chips.removeAllViews()
        for ((id, name) in listOf("all" to "All", "you" to "Needs you", "active" to "Running", "claude" to "Claude", "codex" to "Codex")) {
            val n = counts[id] ?: 0
            if (id == "codex" && n == 0 && filter != id) continue
            val on = filter == id
            val warn = id == "you" && n > 0
            chips.addView(TextView(a).apply {
                text = if (id == "all") tr(name) else "${tr(name)}  $n"
                textSize = 14f; gravity = Gravity.CENTER
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setTextColor(if (on) u.onTonal else if (warn) u.orange else u.text2)
                background = RippleDrawable(ColorStateList.valueOf(0x22000000), pill(if (on) u.tonalBg else Color.TRANSPARENT, 18, if (on) 0 else u.divider), null)
                setPadding(dp(14), dp(7), dp(14), dp(7))
                setOnClickListener { filter = id; prefs.edit().putString("filter", id).apply(); refreshList() }
            }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(8) })
        }
    }

    private fun refreshList() {
        val all = Agents.sessions
        refreshChips(all)
        renderPlan()
        banner.removeAllViews()
        when {
            !Agents.connected -> banner.addView(note(tr("Agents live on your Mac"),
                tr("Open PhoneCast on the Mac. Your Claude Code and Codex chats show up here; you can reply, stop them and answer their questions.")))
            !Agents.integrationInstalled -> banner.addView(note(tr("Turn on terminal control"),
                tr("On the Mac: PhoneCast → Agents → Terminal integration. Then claude/codex started in a terminal can be answered from here. Chats are visible either way.")))
        }
        val p = pins
        val q = query.lowercase()
        fun match(s: JSONObject) = q.isEmpty() || s.optString("title").lowercase().contains(q) || s.optString("cwd").lowercase().contains(q)
        val tops = all.filter { !it.optBoolean("sub") && match(it) }.filter {
            when (filter) {
                "you" -> Agents.needsYou(it)
                "active" -> Agents.isActive(it)
                "claude", "codex" -> it.optString("agent") == filter
                else -> true
            }
        }
        val sections = linkedMapOf<String, MutableList<JSONObject>>(tr("Needs you") to mutableListOf(), tr("Pinned") to mutableListOf(),
            tr("Running") to mutableListOf(), tr("Recent") to mutableListOf())
        for (s in tops) {
            val k = when {
                Agents.needsYou(s) -> tr("Needs you")
                s.optString("id") in p -> tr("Pinned")
                Agents.isActive(s) -> tr("Running")
                else -> tr("Recent")
            }
            sections[k]!!.add(s)
        }
        val want = ArrayList<Pair<String, () -> View>>()   // key, builder
        val sigs = HashMap<String, String>()
        for ((name, list) in sections) {
            if (list.isEmpty()) continue
            want += "h:$name" to { sectionHeader(name) }; sigs["h:$name"] = name
            for (s in list) {
                val id = s.optString("id")
                val kids = Agents.children(id)
                val sig = rowSig(s) + kids.size + (id in expanded) + (id == open) + (id in p)
                want += "r:$id" to { row(s, kids, child = false) }; sigs["r:$id"] = sig
                if (id in expanded) for (k in kids) {
                    val kid = k.optString("id")
                    want += "c:$kid" to { row(k, emptyList(), child = true) }; sigs["c:$kid"] = rowSig(k) + (kid == open)
                }
            }
        }
        if (want.isEmpty() && Agents.connected) {
            rows.removeAllViews(); rowCache.clear()
            rows.addView(u.label(if (all.isEmpty()) "No chats yet. Start one with +." else "Nothing here.", 14f, secondary = true).apply {
                gravity = Gravity.CENTER; setPadding(dp(24), dp(48), dp(24), dp(24))
            })
            return
        }
        // keyed reuse: unchanged rows keep their views (no flicker, scroll position stays)
        val views = want.map { (key, make) ->
            val hit = rowCache[key]
            if (hit != null && hit.first == sigs[key]) hit.second else make().also { rowCache[key] = sigs[key]!! to it }
        }
        rowCache.keys.retainAll(want.map { it.first }.toSet())
        val same = rows.childCount == views.size && views.indices.all { rows.getChildAt(it) === views[it] }
        if (!same) {
            rows.removeAllViews()
            views.forEach { (it.parent as? ViewGroup)?.removeView(it); rows.addView(it) }
        }
    }

    /** "Usage left" card: each agent's plan windows as bars (used) with what's left and when it resets. */
    private fun renderPlan() {
        val p = Agents.plan
        val sig = p.toString() + (System.currentTimeMillis() / 60000)
        if (sig == planSig) return
        planSig = sig
        planBox.removeAllViews()
        if (!Agents.connected || p.length() == 0) return
        val card = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(12), dp(16), dp(10)); background = pill(u.surface, 20)
        }
        card.addView(u.label(tr("Usage left"), 13f, bold = true, secondary = true).apply { setPadding(0, 0, 0, dp(4)) })
        val now = System.currentTimeMillis() / 1000.0
        val tf = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT)
        // Claude: one block per account (the Mac groups chats by their account's weekly reset), labelled with
        // the chats that use it; Codex: its own limits
        val groups = ArrayList<Triple<String, String?, org.json.JSONArray>>()
        val accs = p.optJSONArray("claudeAccounts")
        if (accs != null && accs.length() > 0) {
            for (i in 0 until accs.length()) {
                val acc = accs.optJSONObject(i) ?: continue
                val ids = acc.optJSONArray("sessions")?.let { a2 -> (0 until a2.length()).map { a2.optString(it) }.toSet() } ?: emptySet()
                val chats = Agents.sessions.filter { !it.optBoolean("sub") && it.optString("nativeId") in ids }
                    .sortedByDescending { it.optLong("updatedAt") }.map { it.optString("title") }
                val who = if (accs.length() > 1) chats.take(2).joinToString(", ").ifEmpty { null }?.let { t -> tr("used by {0}", t) + if (chats.size > 2) " " + tr("+{0} more", chats.size - 2) else "" } else null
                val name = if (accs.length() > 1) tr("Claude account {0}", i + 1) + (if (acc.optBoolean("current")) " · " + tr("logged in now") else "") else "Claude"
                groups += Triple(name, who, acc.optJSONArray("limits") ?: org.json.JSONArray())
            }
        } else p.optJSONArray("claude")?.let { groups += Triple("Claude", null, it) }
        p.optJSONArray("codex")?.let { groups += Triple("Codex", null, it) }
        for ((name, who, arr) in groups) {
            if (who != null) card.addView(u.label(name, 13.5f, bold = true).apply { setPadding(0, dp(6), 0, 0) })
            if (who != null) card.addView(u.label(who, 11.5f, secondary = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END })
            for (i in 0 until arr.length()) {
                val w = arr.optJSONObject(i) ?: continue
                val used = w.optDouble("pct").coerceIn(0.0, 100.0)
                val resets = w.optDouble("resets")
                val passed = resets > 0 && resets < now
                val left = (100 - used).toInt()
                val whenTxt = when {
                    resets <= 0 -> ""
                    passed -> tr("reset at {0}", tf.format(java.util.Date((resets * 1000).toLong())))
                    resets - now < 86400 -> tr("resets {0}", tf.format(java.util.Date((resets * 1000).toLong())))
                    else -> tr("resets {0}", java.text.SimpleDateFormat("EEE HH:mm", java.util.Locale.getDefault()).format(java.util.Date((resets * 1000).toLong())))
                }
                val row = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(0, dp(4), 0, dp(4)) }
                row.addView(u.label(if (i == 0 && who == null) name else "", 13.5f, bold = true), LinearLayout.LayoutParams(dp(58), -2))
                row.addView(u.label(w.optString("label"), 12.5f, secondary = true), LinearLayout.LayoutParams(dp(52), -2))
                row.addView(ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100; progress = if (passed) 0 else used.toInt()
                    progressTintList = ColorStateList.valueOf(when { passed -> u.grey; used >= 90 -> u.red; used >= 70 -> u.orange; else -> u.green })
                    progressBackgroundTintList = ColorStateList.valueOf(u.divider)
                }, LinearLayout.LayoutParams(0, dp(6), 1f).apply { marginEnd = dp(10) })
                row.addView(u.label(if (passed) tr("fresh") else tr("{0}% left", left), 13f, bold = true).apply {
                    setTextColor(if (passed) u.text2 else if (used >= 90) u.red else u.text)
                }, LinearLayout.LayoutParams(dp(78), -2))
                card.addView(row)
                if (whenTxt.isNotEmpty()) card.addView(u.label(whenTxt, 11.5f, secondary = true).apply { setPadding(dp(110), 0, 0, dp(2)) })
            }
        }
        if (p.optJSONArray("claude") == null && !Agents.tap)
            card.addView(u.label(tr("Claude's limits appear after turning on “Cost & plan limits” (⋯ above)."), 12f, secondary = true).apply { setPadding(0, dp(4), 0, 0) })
        planBox.addView(card, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(16), dp(6), dp(16), dp(4)) })
    }

    private fun rowSig(s: JSONObject) = listOf("title", "status", "stage", "last", "updatedAt", "managed", "attached", "model").joinToString("|") { s.optString(it) } + s.has("ask")

    private fun sectionHeader(name: String) = u.label(name, 13f, bold = true, secondary = true).apply {
        setPadding(dp(22), dp(16), dp(20), dp(6)); letterSpacing = 0.04f
    }

    private fun row(s: JSONObject, kids: List<JSONObject>, child: Boolean): View {
        val id = s.optString("id")
        val status = s.optString("status")
        val r = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.TOP
            setPadding(dp(if (child) 44 else 16), dp(10), dp(16), dp(10))
            val sel = id == open && u.wide
            background = RippleDrawable(ColorStateList.valueOf(if (u.dark) 0x22FFFFFF else 0x14000000),
                if (sel) pill(u.tonalBg, 18) else null, pill(Color.WHITE, 18))
            isClickable = true
            setOnClickListener { openChat(id) }
            setOnLongClickListener { rowMenu(it, s); true }
        }
        r.addView(agentBadge(s.optString("agent"), status, if (child) 30 else 38), LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(12); topMargin = dp(2) })
        val col = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        val top = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        top.addView(u.label(s.optString("title"), if (child) 14f else 15.5f, bold = !child).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END },
            LinearLayout.LayoutParams(0, -2, 1f))
        top.addView(u.label(ago(s.optLong("updatedAt")), 12f, secondary = true).apply { setPadding(dp(8), 0, 0, 0) })
        col.addView(top)
        col.addView(u.label(subtitle(s), 13f, secondary = true).apply {
            maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            if (status == "needs_input" || s.has("ask")) setTextColor(u.orange) else if (status == "error") setTextColor(u.red)
        })
        val last = s.optString("last")
        if (last.isNotEmpty() && !child) col.addView(u.label(last, 13.5f, secondary = true).apply {
            maxLines = 2; ellipsize = TextUtils.TruncateAt.END; setPadding(0, dp(2), 0, 0)
        })
        if (kids.isNotEmpty()) {
            val busy = kids.count { it.optString("status") == "working" }
            col.addView(TextView(a).apply {
                text = (if (id in expanded) "▾ " else "▸ ") + tr(if (kids.size == 1) "{0} subagent" else "{0} subagents", kids.size) +
                    (if (busy > 0) " · " + tr("{0} working", busy) else "")
                textSize = 13f; setTextColor(u.accent)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                setPadding(0, dp(6), dp(12), dp(2))
                setOnClickListener { if (!expanded.add(id)) expanded.remove(id); refreshList() }
            })
        }
        r.addView(col, LinearLayout.LayoutParams(0, -2, 1f))
        return FrameLayout(a).apply { setPadding(dp(8), 0, dp(8), 0); addView(r) }
    }

    private fun subtitle(s: JSONObject): String {
        val st = s.optString("status")
        val stage = s.optString("stage")
        val what = when {
            s.has("ask") -> tr("Asks: {0}", s.optJSONObject("ask")?.optString("title") ?: "")
            st == "working" -> stage.ifEmpty { tr("Working…") }
            st == "needs_input" -> stage.ifEmpty { tr("Waiting for you") }
            st == "error" -> stage.ifEmpty { tr("Error") }
            st == "completed" -> tr("Done")
            st == "idle" -> tr(if (s.optBoolean("managed")) "Ready" else "Open in a terminal")
            st == "offline" -> tr("Finished")
            else -> stage.ifEmpty { tr("Running") }
        }
        val folder = (s.optString("cwd").substringAfterLast('/').ifEmpty { null })?.let { f -> s.optString("host").ifEmpty { null }?.let { "$f @ ${it.substringAfter('@')}" } ?: f }
        val role = s.optString("role").ifEmpty { null }
        return listOfNotNull(if (s.optBoolean("sub")) role else folder, modelName(s.optString("model")), what).joinToString(" · ")
    }

    /** "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929[1m]" → "Sonnet 4.5 (1M)", "gpt-6-luna" → "GPT-6 Luna". */
    fun modelName(id: String): String? {
        if (id.isEmpty() || id == "default") return null
        val long = if (id.contains("[1m]", true)) " (1M)" else ""
        val base = id.replace(Regex("\\[.*?]"), "")
        Regex("^claude-([a-z]+)-(\\d+)(?:-(\\d{1,2}))?(?:-\\d{6,})?$").find(base)?.let { m ->
            val v = m.groupValues[2] + (m.groupValues[3].takeIf { it.isNotEmpty() }?.let { ".$it" } ?: "")
            return m.groupValues[1].replaceFirstChar { it.uppercase() } + " " + v + long
        }
        return base.split('-').joinToString(" ") { p -> if (p.equals("gpt", true)) "GPT" else p.replaceFirstChar { it.uppercase() } }
            .replace(Regex("^GPT (\\d)"), "GPT-$1") + long
    }

    private fun agentBadge(agent: String, status: String, size: Int): View {
        val f = FrameLayout(a)
        val other = agent != "codex" && agent != "claude"
        val c = if (other) (if (u.dark) 0xFF2C3A5A.toInt() else 0xFFDCE6F8.toInt()) else if (agent == "codex") (if (u.dark) 0xFF2E3440.toInt() else 0xFF20232A.toInt()) else (if (u.dark) 0xFF5A3A2C.toInt() else 0xFFF3E1D7.toInt())
        f.addView(TextView(a).apply {
            text = if (other) agent.take(1).uppercase() else if (agent == "codex") "›_" else "✻"
            gravity = Gravity.CENTER; textSize = if (agent == "codex") size * 0.32f else size * 0.42f
            setTextColor(if (other) u.accent else if (agent == "codex") Color.WHITE else if (u.dark) 0xFFF4B490.toInt() else 0xFFC4602D.toInt())
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(c) }
        }, FrameLayout.LayoutParams(dp(size), dp(size)))
        val dot = when (status) {
            "working" -> u.green; "needs_input" -> u.orange; "error" -> u.red
            "idle", "completed" -> u.grey; else -> 0
        }
        if (dot != 0) f.addView(View(a).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(dot); setStroke(dp(2), u.bg) }
            if (status == "working") startAnimation(android.view.animation.AlphaAnimation(1f, 0.3f).apply {
                duration = 900; repeatMode = android.view.animation.Animation.REVERSE; repeatCount = android.view.animation.Animation.INFINITE
            })
        }, FrameLayout.LayoutParams(dp(12), dp(12), Gravity.END or Gravity.BOTTOM))
        return f
    }

    private fun rowMenu(anchor: View, s: JSONObject) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val id = s.optString("id")
        val m = PopupMenu(a, anchor)
        val p = pins
        if (!s.optBoolean("sub")) m.menu.add(0, 1, 0, tr(if (id in p) "Unpin" else "Pin to top"))
        if (s.optBoolean("managed")) m.menu.add(0, 2, 0, tr("Open in Terminal on the Mac"))
        m.menu.add(0, 3, 0, tr("Copy folder path"))
        m.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> { if (!p.add(id)) p.remove(id); prefs.edit().putStringSet("pins", p).apply(); refreshList() }
                2 -> Agents.request("open", JSONObject().put("sid", id)) { _, e -> e?.let(::toast) }
                3 -> copy(s.optString("cwd"))
            }
            true
        }
        m.show()
    }

    private fun note(title: String, body: String) = u.card(u.title(title), u.label(body, 14f, secondary = true)).apply {
        (layoutParams as LinearLayout.LayoutParams).setMargins(dp(16), dp(8), dp(16), dp(4))
    }

    // ================================================================= chat

    private val chatTitle = u.label("", 17f, bold = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    private val chatSub = u.label("", 12.5f, secondary = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE }
    private lateinit var stopBtn: View
    private lateinit var termBtn: ImageView
    private val workStrip = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
    private val workText = u.label("", 13f, secondary = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    private val askBox = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
    private var askSig = ""
    private val msgScroll = ScrollView(a)
    private val msgList = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), dp(8), dp(14), dp(16)) }
    private val rendered = ArrayList<String>()
    private var termMode = false
    /** The chat area shows the Changes view (git) instead of the messages. */
    private var changesMode = false
    private var filesMode = false
    private var filesPath = ""
    private var filePath: String? = null
    private val attachedFiles = ArrayList<Agents.Attachment>()
    private val suggestRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
    private val termPoll = object : Runnable { override fun run() { if (termMode && view.isShown) renderTerm(); view.postDelayed(this, 900) } }
    private var termBusy = false
    private var diffPath: String? = null
    private val voice = Voice(a)
    private lateinit var changesBtn: ImageView
    private val usageRow = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val modeChip = TextView(a)
    private val usageText = u.label("", 12f, secondary = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }
    private val keyStrip = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val thumbs = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
    private val attached = ArrayList<ByteArray>()
    private lateinit var input: EditText
    private lateinit var sendBtn: ImageView
    private val composeHint = u.label("", 12f, secondary = true)
    private var sending = false

    private fun buildChat() {
        val bar = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(8), dp(4), dp(8))
        }
        if (!u.wide) bar.addView(iconButton(R.drawable.ic_back, tr("Back")) { openChat(null) })
        bar.addView(LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(if (u.wide) 16 else 4), 0, dp(4), 0)
            addView(chatTitle); addView(chatSub)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        stopBtn = iconButton(R.drawable.ic_stop, tr("Stop")) { stop() }
        termBtn = iconButton(R.drawable.ic_terminal, tr("Terminal view")) { termMode = !termMode; changesMode = false; filesMode = false; renderMessages(force = true); refreshChatHeader() }
        changesBtn = iconButton(R.drawable.ic_changes, tr("Changes")) { changesMode = !changesMode; termMode = false; filesMode = false; diffPath = null; renderMessages(force = true); refreshChatHeader() }
        bar.addView(stopBtn); bar.addView(changesBtn); bar.addView(termBtn)
        bar.addView(iconButton(R.drawable.ic_more, tr("More")) { chatMenu(it) })
        chatPane.addView(bar)
        // usage and permission mode: one quiet line under the title
        modeChip.apply {
            textSize = 12f; setTextColor(u.onTonal); typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            background = RippleDrawable(ColorStateList.valueOf(0x22000000), pill(u.tonalBg, 12), null)
            setPadding(dp(10), dp(3), dp(10), dp(3))
            setOnClickListener { v -> v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); Agents.request("mode", JSONObject().put("sid", open)) { _, e -> e?.let(::toast) } }
        }
        usageRow.addView(modeChip, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(8) })
        usageRow.addView(usageText, LinearLayout.LayoutParams(0, -2, 1f))
        usageRow.setPadding(dp(if (u.wide) 16 else 52), 0, dp(12), dp(6))
        usageRow.setOnClickListener { usageSheet() }
        chatPane.addView(usageRow)

        workStrip.addView(ProgressBar(a, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true; indeterminateTintList = ColorStateList.valueOf(u.accent)
        }, LinearLayout.LayoutParams(-1, dp(4)))
        workStrip.addView(workText.apply { setPadding(dp(18), dp(4), dp(18), dp(4)) })
        chatPane.addView(workStrip)

        msgScroll.addView(msgList)
        msgScroll.isFillViewport = true
        chatPane.addView(msgScroll, LinearLayout.LayoutParams(-1, 0, 1f))
        chatPane.addView(askBox)

        // terminal keys (managed chats): for menus and pickers the TUI shows
        for ((k, label) in listOf("up" to "↑", "down" to "↓", "left" to "←", "right" to "→", "enter" to "Enter", "escape" to "Esc", "tab" to "Tab", "backspace" to "⌫", "ctrl-c" to "Ctrl-C")) {
            keyStrip.addView(TextView(a).apply {
                text = label; textSize = 14f; gravity = Gravity.CENTER; setTextColor(u.onTonal)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                background = RippleDrawable(ColorStateList.valueOf(0x22000000), pill(u.tonalBg, 14), null)
                setPadding(dp(14), dp(6), dp(14), dp(6))
                setOnClickListener { v -> v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    if (k == "ctrl-c") confirm(tr("Send Ctrl-C? Pressed twice at an empty prompt, it quits the agent.")) { key(k) } else key(k) }
            }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(8) })
        }
        chatPane.addView(HorizontalScrollView(a).apply {
            isHorizontalScrollBarEnabled = false
            addView(keyStrip.apply { setPadding(dp(14), dp(4), dp(14), dp(4)) })
        })
        chatPane.addView(HorizontalScrollView(a).apply { isHorizontalScrollBarEnabled = false; addView(thumbs.apply { setPadding(dp(14), 0, dp(14), 0) }) })

        val composer = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.BOTTOM
            setPadding(dp(10), dp(6), dp(10), dp(10))
        }
        composer.addView(iconButton(R.drawable.ic_slash, tr("Commands")) { commands() }.apply { layoutParams = LinearLayout.LayoutParams(dp(40), dp(44)) })
        composer.addView(iconButton(R.drawable.ic_photo, tr("Attach")) { v ->
            val m = PopupMenu(a, v)
            m.menu.add(0, 1, 0, tr("Photos")); m.menu.add(0, 2, 0, tr("Files"))
            m.setOnMenuItemClickListener { if (it.itemId == 1) pickPhotos() else pickFiles(); true }
            m.show()
        }.apply { layoutParams = LinearLayout.LayoutParams(dp(40), dp(44)) })
        input = EditText(a).apply {
            hint = tr("Message"); textSize = 16f; minLines = 1; maxLines = 6
            setTextColor(u.text); setHintTextColor(u.text2)
            background = pill(u.surface, 22)
            setPadding(dp(16), dp(11), dp(16), dp(11))
            inputType = EditorInfo.TYPE_CLASS_TEXT or EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE or EditorInfo.TYPE_TEXT_FLAG_CAP_SENTENCES
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { draftSave(); refreshSend(); atToken()?.let { suggest(it) } ?: suggest(null) }
                override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, af: Int) {}
                override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {}
            })
        }
        composer.addView(input, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, dp(6), 0) })
        sendBtn = ImageView(a).apply {
            setImageResource(R.drawable.ic_send); imageTintList = ColorStateList.valueOf(u.onAccent)
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(u.accent) }, null)
            setPadding(dp(12), dp(12), dp(12), dp(12)); contentDescription = tr("Send")
            setOnClickListener { if (input.text.isBlank() && attached.isEmpty() && attachedFiles.isEmpty()) dictate() else send() }
        }
        composer.addView(sendBtn, LinearLayout.LayoutParams(dp(46), dp(46)))
        chatPane.addView(HorizontalScrollView(a).apply { isHorizontalScrollBarEnabled = false; addView(suggestRow.apply { setPadding(dp(14), dp(4), dp(14), 0) }) })
        chatPane.addView(composeHint.apply { setPadding(dp(22), dp(2), dp(22), 0) })
        chatPane.addView(composer)
    }

    private fun current(): JSONObject? = open?.let { Agents.byId[it] }

    private fun refreshChatHeader() {
        val s = current() ?: run {
            if (open != null && Agents.connected && Agents.sessions.isNotEmpty()) chatSub.text = tr("This chat ended")
            return
        }
        chatTitle.text = s.optString("title")
        chatSub.text = listOfNotNull(
            if (s.optString("agent") == "codex") "Codex" else "Claude Code",
            modelName(s.optString("model")),
            s.optString("cwd").replace(Regex("^/Users/[^/]+"), "~").ifEmpty { null },
        ).joinToString(" · ")
        val st = s.optString("status")
        val managed = s.optBoolean("managed")
        val working = st == "working"
        u.gone(workStrip, !working)
        workText.text = s.optString("stage").ifEmpty { tr("Working…") }
        u.gone(stopBtn, !(managed && (working || st == "needs_input")))
        u.gone(termBtn, !managed)
        u.gone(changesBtn, s.optBoolean("sub") || s.optString("cwd").isEmpty())
        changesBtn.imageTintList = ColorStateList.valueOf(if (changesMode) u.accent else u.text2)
        val mode = s.optString("mode")
        modeChip.text = when (mode) {
            "", "default" -> tr("Ask before edits")
            "accept edits" -> tr("Auto-accept edits")
            "plan mode" -> tr("Plan mode")
            "bypass permissions" -> tr("Bypass permissions")
            else -> mode
        }
        u.gone(modeChip, !(managed && s.optString("agent") == "claude"))
        usageText.text = usageLine(s.optJSONObject("usage")) + (s.optString("over").ifEmpty { null }?.let { "  ·  ⚠ $it" } ?: "")
        if (s.has("over")) usageText.setTextColor(u.red) else usageText.setTextColor(u.text2)
        u.gone(usageRow, modeChip.visibility == View.GONE && usageText.text.isEmpty())
        termBtn.imageTintList = ColorStateList.valueOf(if (termMode) u.accent else u.text2)
        u.gone(keyStrip.parent as View, !managed || changesMode || filesMode)
        u.gone(askBox, changesMode || filesMode)
        val canSend = Agents.canSend(s)
        input.isEnabled = canSend; sendBtn.isEnabled = canSend
        if (termMode) { input.hint = tr("Type into the terminal"); input.isEnabled = managed; sendBtn.isEnabled = managed } else input.hint = tr(when {
            s.optBoolean("sub") -> "Subagents can't be messaged"
            !canSend -> "Open in another terminal — read only"
            working -> "Message — interrupts the current turn"
            !managed -> "Message — continues this chat on the Mac"
            else -> "Message"
        })
        val q = Agents.queued(a, s.optString("id"))
        composeHint.text = when {
            q > 0 -> tr(if (q == 1) "{0} message waits for the Mac" else "{0} messages wait for the Mac", q)
            !canSend && !s.optBoolean("sub") && s.optBoolean("live") -> tr("Started outside PhoneCast's terminal integration. Close it on the Mac to continue here.")
            else -> ""
        }
        u.gone(composeHint, composeHint.text.isEmpty())
        refreshSend()
        renderAsk(s)
        if (termMode && working) renderMessages(force = true)
    }

    private fun refreshSend() {
        val empty = input.text.isBlank() && attached.isEmpty() && attachedFiles.isEmpty()
        sendBtn.setImageResource(if (empty) R.drawable.ic_mic else R.drawable.ic_send)
        sendBtn.contentDescription = tr(if (empty) "Dictate" else "Send")
        val ok = !sending && input.isEnabled
        sendBtn.alpha = if (ok) 1f else 0.4f
        sendBtn.backgroundTintList = if (voice.listening) ColorStateList.valueOf(u.red) else null
    }

    private fun renderAsk(s: JSONObject) {
        val ask = s.optJSONObject("ask")
        val sig = ask?.toString() ?: ""
        if (sig == askSig) return
        askSig = sig
        askBox.removeAllViews()
        if (ask == null) return
        val card = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(12))
            background = pill(if (u.dark) 0xFF3A2E14.toInt() else 0xFFFFF4DF.toInt(), 22)
        }
        card.addView(u.label(tr("Needs you"), 12.5f, bold = true).apply { setTextColor(u.orange) })
        card.addView(u.label(ask.optString("title"), 16f, bold = true).apply { setPadding(0, dp(2), 0, dp(4)) })
        val detail = ask.optString("detail")
        if (detail.isNotBlank()) card.addView(u.mono(detail).apply {
            maxLines = 6; ellipsize = TextUtils.TruncateAt.END; textSize = 12.5f
            setOnClickListener { maxLines = if (maxLines == 6) 200 else 6 }
        })
        val choices = ask.optJSONArray("choices")
        for (i in 0 until (choices?.length() ?: 0)) {
            val c = choices!!.optJSONObject(i) ?: continue
            val label = c.optString("label")
            val negative = label.lowercase().let { it.startsWith("no") || it.contains("exit") || it.contains("cancel") }
            val b = if (i == 0) u.primary(label) {} else if (negative) u.quiet(label, u.text2) {} else u.tonal(label) {}
            b.setOnClickListener { v ->
                v.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
                setButtons(card, false)
                Agents.request("approve", JSONObject().put("sid", open).put("ask", ask.optString("id")).put("choice", c.optString("id"))) { _, err ->
                    if (err != null) { toast(err); setButtons(card, true) }
                }
            }
            card.addView(b)
        }
        askBox.addView(card, LinearLayout.LayoutParams(-1, -2).apply { setMargins(dp(12), dp(4), dp(12), dp(4)) })
    }

    private fun setButtons(g: ViewGroup, on: Boolean) { for (i in 0 until g.childCount) (g.getChildAt(i) as? android.widget.Button)?.isEnabled = on }

    private fun renderMessages(force: Boolean = false) {
        if (open == null) { msgList.removeAllViews(); rendered.clear(); return }
        if (changesMode) { if (force) renderChanges(); return }
        if (termMode) { renderTerm(); return }
        if (filesMode) { if (force) renderFiles(); return }
        val msgs = Agents.messages
        val ids = msgs.map { it.optString("id") }
        val atBottom = !msgScroll.canScrollVertically(1)
        val appendOnly = !force && rendered.isNotEmpty() && ids.size >= rendered.size && ids.subList(0, rendered.size) == rendered
        if (!appendOnly) {
            msgList.removeAllViews(); rendered.clear()
            if (Agents.moreOlder) msgList.addView(u.quiet("Load earlier messages") {
                Agents.older { err -> err?.let(::toast) }
            }.apply { tag = "older" })
            if (msgs.isEmpty()) msgList.addView(u.label(if (!Agents.connected) "Not connected" else if (Agents.loaded) "No messages yet" else "Loading…", 14f, secondary = true).apply {
                gravity = Gravity.CENTER; setPadding(0, dp(40), 0, 0); tag = "empty"
            })
        } else msgList.findViewWithTag<View>("empty")?.let { msgList.removeView(it) }
        var prevRole = if (rendered.isEmpty()) "" else msgs.getOrNull(rendered.size - 1)?.optString("r") ?: ""
        val speak = appendOnly && prefs.getBoolean("speak.$open", false)
        for (m in msgs.drop(rendered.size)) {
            if (speak && m.optString("r") == "assistant") Speech.speak(a, m.optString("t"))
            msgList.addView(bubble(m, prevRole))
            prevRole = m.optString("r")
            rendered += m.optString("id")
        }
        if (atBottom || !appendOnly) msgScroll.post { msgScroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun bubble(m: JSONObject, prevRole: String): View {
        val role = m.optString("r")
        val text = m.optString("t")
        val gap = dp(if (role == prevRole && role == "tool") 2 else 10)
        return when (role) {
            "user" -> FrameLayout(a).apply {
                setPadding(dp(48), gap, 0, 0)
                addView(u.label("", 15f).apply {
                    setText(text); setTextIsSelectable(true)
                    setTextColor(u.onTonal)
                    background = pill(u.tonalBg, 20)
                    setPadding(dp(14), dp(10), dp(14), dp(10))
                }, FrameLayout.LayoutParams(-2, -2, Gravity.END))
            }
            "tool" -> TextView(a).apply {
                val first = text.lineSequence().firstOrNull().orEmpty()
                val icon = when {
                    text.startsWith("Error") -> "✕"
                    m.optString("tool").isEmpty() -> "↳"
                    else -> "⚙"
                }
                setText("$icon  $first"); textSize = 12.5f; typeface = Typeface.MONOSPACE
                setTextColor(if (text.startsWith("Error")) u.red else u.text2)
                maxLines = 1; ellipsize = TextUtils.TruncateAt.END
                setPadding(dp(6), gap, dp(6), 0)
                var full = false
                setOnClickListener {
                    full = !full
                    if (full) { setText("$icon  $text"); maxLines = 40 } else { setText("$icon  $first"); maxLines = 1 }
                }
            }
            "system" -> u.label(text, 12.5f, secondary = true).apply {
                gravity = Gravity.CENTER; setPadding(dp(12), gap, dp(12), dp(2))
            }
            else -> markdown(text).apply { setPadding(dp(2), gap, dp(2), 0) }
        }
    }

    /** Assistant text: paragraphs, headings, lists, **bold**, `code` and fenced code blocks (copy on long press). */
    private fun markdown(src: String): View {
        val box = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        val parts = src.split("```")
        parts.forEachIndexed { i, part ->
            if (i % 2 == 1) {
                val code = part.substringAfter('\n', part).trimEnd()
                box.addView(HorizontalScrollView(a).apply {
                    background = pill(if (u.dark) 0xFF101114.toInt() else 0xFFE8E9EE.toInt(), 14)
                    addView(u.mono(code).apply { setTextColor(u.text); textSize = 12.5f; setPadding(dp(12), dp(10), dp(12), dp(10)); setTextIsSelectable(false)
                        setOnLongClickListener { copy(code); true } })
                }, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, dp(6), 0, dp(6)) })
            } else if (part.isNotBlank()) {
                box.addView(u.label("", 15f).apply {
                    setText(inline(part.trim('\n'))); setTextIsSelectable(true); setLineSpacing(0f, 1.2f)
                })
            }
        }
        return box
    }

    private fun inline(t: String): CharSequence {
        val sb = SpannableStringBuilder()
        val codeBg = if (u.dark) 0x33FFFFFF else 0x14000000
        t.lines().forEachIndexed { li, raw ->
            if (li > 0) sb.append('\n')
            var line = raw
            var heading = 0
            Regex("^(#{1,4})\\s+").find(line)?.let { heading = it.groupValues[1].length; line = line.substring(it.range.last + 1) }
            Regex("^(\\s*)[-*]\\s+").find(line)?.let { line = it.groupValues[1] + "•  " + line.substring(it.range.last + 1) }
            val start = sb.length
            var i = 0
            while (i < line.length) {
                when {
                    line.startsWith("**", i) && line.indexOf("**", i + 2) > i + 2 -> {
                        val e = line.indexOf("**", i + 2); val s = sb.length
                        sb.append(line, i + 2, e); sb.setSpan(StyleSpan(Typeface.BOLD), s, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE); i = e + 2
                    }
                    line[i] == '`' && line.indexOf('`', i + 1) > i + 1 -> {
                        val e = line.indexOf('`', i + 1); val s = sb.length
                        sb.append(line, i + 1, e)
                        sb.setSpan(TypefaceSpan("monospace"), s, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        sb.setSpan(BackgroundColorSpan(codeBg), s, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE); i = e + 1
                    }
                    else -> { sb.append(line[i]); i++ }
                }
            }
            if (heading > 0) {
                sb.setSpan(StyleSpan(Typeface.BOLD), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                sb.setSpan(RelativeSizeSpan(if (heading == 1) 1.25f else 1.12f), start, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        return sb
    }

    private var recoveryChat: Boolean? = null

    private fun chatMenu(anchor: View) {
        val s = current() ?: return
        if (s.optBoolean("managed")) Agents.request("recovery", JSONObject().put("sid", s.optString("id"))) { d, _ -> recoveryChat = d?.optBoolean("continue") }
        val m = PopupMenu(a, anchor)
        if (s.optBoolean("managed")) m.menu.add(0, 1, 0, tr("Open in Terminal on the Mac"))
        if (!s.optBoolean("managed") && s.optBoolean("canResume")) m.menu.add(0, 2, 0, tr("Reopen on the Mac"))
        m.menu.add(0, 3, 0, tr(if (s.optString("id") in pins) "Unpin" else "Pin to top"))
        m.menu.add(0, 4, 0, tr("Copy folder path"))
        if (!s.optBoolean("sub")) m.menu.add(0, 5, 0, tr("New chat in this folder"))
        m.menu.add(0, 7, 0, tr("Read answers aloud")).apply { isCheckable = true; isChecked = prefs.getBoolean("speak.${s.optString("id")}", false) }
        m.menu.add(0, 8, 0, tr(if (Speech.speaking) "Stop reading" else "Read last answer"))
        m.menu.add(0, 9, 0, tr("Usage and budget"))
        if (s.optString("cwd").isNotEmpty() && !s.optBoolean("sub")) m.menu.add(0, 10, 0, tr("Files"))
        if (s.optString("nativeId").isNotEmpty() && !s.optBoolean("sub") && s.optString("agent") in setOf("claude", "codex")) m.menu.add(0, 11, 0, tr("Fork this chat"))
        if (s.optBoolean("managed") && s.optString("agent") == "claude") m.menu.add(0, 12, 0, tr("Rename…"))
        m.menu.add(0, 13, 0, tr("Open dev server…"))
        m.menu.add(0, 15, 0, tr("Share chat…"))
        if (s.optBoolean("managed")) m.menu.add(0, 14, 0, tr("Continue after usage limits")).apply { isCheckable = true; isChecked = recoveryChat ?: false }
        s.optString("parent").ifEmpty { null }?.let { p -> m.menu.add(0, 6, 0, tr("Open parent chat")) }
        m.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> Agents.request("open", JSONObject().put("sid", s.optString("id"))) { _, e -> e?.let(::toast) }
                2 -> Agents.request("resume", JSONObject().put("sid", s.optString("id"))) { d, e -> if (e != null) toast(e) else d?.optString("sid")?.let(::openChat) }
                3 -> { val p = pins; val id = s.optString("id"); if (!p.add(id)) p.remove(id); prefs.edit().putStringSet("pins", p).apply(); refreshList() }
                4 -> copy(s.optString("cwd"))
                5 -> newChat(s.optString("cwd"), s.optString("agent"))
                6 -> openChat(s.optString("parent"))
                7 -> { val k = "speak.${s.optString("id")}"; val on = !prefs.getBoolean(k, false); prefs.edit().putBoolean(k, on).apply(); if (!on) Speech.stop() }
                8 -> if (Speech.speaking) Speech.stop() else Agents.messages.lastOrNull { it.optString("r") == "assistant" }?.let { Speech.speak(a, it.optString("t"), flush = true) }
                9 -> usageSheet()
                10 -> { filesMode = true; termMode = false; changesMode = false; filesPath = ""; filePath = null; renderFiles(); refreshChatHeader() }
                11 -> Agents.request("fork", JSONObject().put("sid", s.optString("id"))) { d, e -> if (e != null) toast(e) else d?.optString("sid")?.let { n -> view.postDelayed({ openChat(n) }, 800) } }
                12 -> {
                    val c = android.view.ContextThemeWrapper(a, dialogTheme())
                    val f = EditText(c).apply { setText(s.optString("title")); setTextColor(u.text); setSingleLine(); selectAll() }
                    themed().setTitle(tr("Rename chat")).setView(FrameLayout(c).apply { setPadding(dp(22), dp(8), dp(22), 0); addView(f) })
                        .setNegativeButton(tr("Cancel"), null).setPositiveButton(tr("Rename")) { _, _ ->
                            Agents.request("command", JSONObject().put("sid", s.optString("id")).put("text", "/rename " + f.text.toString().trim())) { _, e -> e?.let(::toast) }
                        }.show()
                }
                13 -> devServers(s)
                15 -> {
                    // the chat as Markdown (without tool lines) for any app: notes, mail, a friend
                    val md = "# " + s.optString("title") + "\n\n" + Agents.messages.filter { it.optString("r") != "tool" }.joinToString("\n\n") {
                        when (it.optString("r")) { "user" -> "**" + tr("You") + ":** " + it.optString("t"); "system" -> "_" + it.optString("t") + "_"; else -> it.optString("t") }
                    }
                    a.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_SUBJECT, s.optString("title")).putExtra(Intent.EXTRA_TEXT, md), tr("Share chat")))
                }
                14 -> { val on = !(recoveryChat ?: false); Agents.request("recovery", JSONObject().put("sid", s.optString("id")).put("chat", JSONObject().put("continue", on))) { d, e -> e?.let(::toast); recoveryChat = d?.optBoolean("continue") } }
            }
            true
        }
        m.show()
    }

    // ================================================================= actions

    private fun send() {
        val sid = open ?: return
        val text = input.text.toString().trim()
        if (sending || (text.isEmpty() && attached.isEmpty())) return
        sending = true; refreshSend()
        sendBtn.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        if (termMode && attached.isEmpty() && attachedFiles.isEmpty()) {
            // live terminal: type the text as keystrokes and press Enter
            Agents.request("type", JSONObject().put("sid", sid).put("text", text).put("enter", true)) { _, err ->
                sending = false; refreshSend()
                if (err != null) toast(err) else { input.setText(""); draftClear(sid); renderTerm() }
            }
            return
        }
        val imgs = ArrayList(attached)
        val files = ArrayList(attachedFiles)
        val wasQueued = !Agents.connected
        Agents.send(sid, text, imgs, files) { newSid, err ->
            if (wasQueued && err == null) toast(tr("Queued. It goes out when the Mac is back."))
            sending = false
            if (err != null) { toast(err); refreshSend(); return@send }
            input.setText(""); attached.clear(); attachedFiles.clear(); renderThumbs(); draftClear(sid)
            if (newSid != null && newSid != sid) openChat(newSid)
            refreshSend()
        }
    }

    private fun stop() {
        val sid = open ?: return
        stopBtn.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        Agents.request("stop", JSONObject().put("sid", sid)) { _, e -> e?.let(::toast) }
    }

    private fun key(k: String) {
        Agents.request("key", JSONObject().put("sid", open).put("key", k)) { _, e -> if (e != null) toast(e) else if (termMode) renderMessages(force = true) }
    }

    private fun newChat(folder: String? = null, agent: String? = null) {
        val theme = if (u.dark) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
        val c = android.view.ContextThemeWrapper(a, theme)
        val box = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(8), dp(22), 0) }
        var chosen = agent ?: prefs.getString("lastAgent", "claude")!!
        val models = HashMap<String, List<Pair<String, String>>>()
        val modelSpin = Spinner(c)
        fun fillModels() {
            val list = listOf(tr("Default model") to "") + (models[chosen] ?: emptyList())
            modelSpin.adapter = ArrayAdapter(c, android.R.layout.simple_spinner_dropdown_item, list.map { it.first })
            modelSpin.tag = list.map { it.second }
            val last = prefs.getString("lastModel.$chosen", "")
            modelSpin.setSelection(max(0, list.indexOfFirst { it.second == last }))
        }
        val names = mapOf("claude" to "Claude", "codex" to "Codex", "gemini" to "Gemini", "opencode" to "OpenCode", "kimi" to "Kimi")
        val segBox = FrameLayout(c)
        fun buildSeg(list: List<String>) {
            if (chosen !in list) chosen = list.first()
            val seg = u.Segmented("", list.map { (names[it] ?: it) to it }, { chosen }, { chosen = it; fillModels() })
            seg.refresh(); segBox.removeAllViews(); segBox.addView(seg.view)
        }
        buildSeg(listOf("claude", "codex"))
        box.addView(segBox)
        Agents.request("agents") { d, _ -> d?.optJSONArray("agents")?.let { arr -> buildSeg((0 until arr.length()).map { arr.optString(it) }) } }
        box.addView(u.hint("Model"))
        box.addView(modelSpin)
        var machine = prefs.getString("lastHost", "") ?: ""
        val machineBox = FrameLayout(c)
        box.addView(machineBox)
        Agents.request("hosts", timeoutMs = 40_000) { d, _ ->
            val arr = d?.optJSONArray("hosts") ?: return@request
            val hs = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.filter { it.optBoolean("up") }.map { it.optString("host") }
            if (hs.isEmpty()) return@request
            if (machine !in hs) machine = ""
            val seg = u.Segmented(tr("Machine"), listOf(tr("This Mac") to "") + hs.map { it.substringAfter('@') to it }, { machine }, { machine = it })
            seg.refresh(); machineBox.addView(seg.view)
        }
        box.addView(u.hint("Folder (on that machine)"))
        val folderBox = AutoCompleteTextView(c).apply {
            setText(folder ?: prefs.getString("lastFolder", "~")); textSize = 15f; setSingleLine(); threshold = 0
            setTextColor(u.text)
            setOnFocusChangeListener { v, f -> if (f) (v as AutoCompleteTextView).showDropDown() }
        }
        box.addView(folderBox)
        val ownTree = CheckBox(c).apply {
            text = tr("Own git worktree (new branch, so parallel chats don't edit the same files)")
            isChecked = prefs.getBoolean("lastWorktree", false); setTextColor(u.text)
        }
        box.addView(ownTree)
        box.addView(u.hint("First message (optional)"))
        val prompt = EditText(c).apply { textSize = 15f; minLines = 2; maxLines = 6; setTextColor(u.text); setHintTextColor(u.text2); hint = tr("What should it do?") }
        box.addView(prompt)
        fillModels()
        Agents.request("folders") { d, _ ->
            val arr = d?.optJSONArray("folders") ?: return@request
            val home = d.optString("home")
            folderBox.setAdapter(ArrayAdapter(c, android.R.layout.simple_dropdown_item_1line,
                (0 until arr.length()).map { arr.optString(it).replaceFirst(home, "~") }))
        }
        Agents.request("models", timeoutMs = 70_000) { d, _ ->
            val arr = d?.optJSONArray("agents") ?: return@request
            for (i in 0 until arr.length()) {
                val ag = arr.optJSONObject(i) ?: continue
                val ms = ag.optJSONArray("models") ?: continue
                models[ag.optString("id")] = (0 until ms.length()).mapNotNull { ms.optJSONObject(it) }
                    .filter { it.optString("id") != "default" }.map { it.optString("label") to it.optString("id") }
            }
            fillModels()
        }
        val dlg = AlertDialog.Builder(a, theme).setTitle(tr("New chat on the Mac")).setView(ScrollView(c).apply { addView(box) })
            .setNegativeButton(tr("Cancel"), null).setPositiveButton(tr("Start"), null).create()
        dlg.setOnShowListener {
            dlg.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { b ->
                b.isEnabled = false
                @Suppress("UNCHECKED_CAST") val model = (modelSpin.tag as? List<String>)?.getOrNull(modelSpin.selectedItemPosition) ?: ""
                val cwd = folderBox.text.toString().trim().ifEmpty { "~" }
                prefs.edit().putString("lastAgent", chosen).putString("lastFolder", cwd).putString("lastModel.$chosen", model).putString("lastHost", machine)
                    .putBoolean("lastWorktree", ownTree.isChecked).apply()
                Agents.request("start", JSONObject().put("agent", chosen).put("cwd", cwd).put("model", model).put("prompt", prompt.text.toString()).put("host", machine)
                    .put("worktree", ownTree.isChecked && machine.isEmpty()), 60_000) { d, err ->
                    if (err != null) { toast(err); b.isEnabled = true; return@request }
                    dlg.dismiss()
                    d?.optString("sid")?.let { sid -> view.postDelayed({ openChat(sid) }, 600) }
                }
            }
        }
        dlg.show()
    }

    // ---- photos ----

    private fun pickPhotos() {
        val i = Intent(MediaStore.ACTION_PICK_IMAGES).putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 6)
        @Suppress("DEPRECATION")
        try { a.startActivityForResult(i, REQ_PHOTOS) } catch (_: Exception) {
            a.startActivityForResult(Intent(Intent.ACTION_GET_CONTENT).setType("image/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), REQ_PHOTOS)
        }
    }

    fun onResult(req: Int, res: Int, data: Intent?): Boolean {
        if (req == REQ_FILES) {
            if (res != Activity.RESULT_OK || data == null) return true
            val uris = ArrayList<Uri>()
            data.clipData?.let { c -> for (i in 0 until c.itemCount) uris += c.getItemAt(i).uri }
            if (uris.isEmpty()) data.data?.let { uris += it }
            Thread {
                val got = uris.take(10).mapNotNull { u -> try {
                    val name = a.contentResolver.query(u, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: "file"
                    val bytes = a.contentResolver.openInputStream(u)?.use { it.readBytes() } ?: return@mapNotNull null
                    if (bytes.size > 25 shl 20) { view.post { toast(tr("{0} is over 25 MB", name)) }; null } else Agents.Attachment(name, bytes)
                } catch (_: Exception) { null } }
                view.post { attachedFiles += got; renderThumbs(); refreshSend() }
            }.start()
            return true
        }
        if (req != REQ_PHOTOS) return false
        if (res != Activity.RESULT_OK || data == null) return true
        val uris = ArrayList<Uri>()
        data.clipData?.let { c -> for (i in 0 until c.itemCount) uris += c.getItemAt(i).uri }
        if (uris.isEmpty()) data.data?.let { uris += it }
        Thread {
            val shrunk = uris.take(6 - attached.size).mapNotNull { shrink(it) }
            view.post { attached += shrunk; renderThumbs(); refreshSend() }
        }.start()
        return true
    }

    /** Longest side ≤ 2048 px, JPEG 85: small enough for the link, sharp enough for the model. */
    private fun shrink(uri: Uri): ByteArray? = try {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        a.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, o) }
        var sample = 1
        while (max(o.outWidth, o.outHeight) / sample > 4096) sample *= 2
        val bmp = a.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }!!
        val scale = minOf(1f, 2048f / max(bmp.width, bmp.height))
        val out = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true) else bmp
        ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    } catch (_: Exception) { null }

    private fun renderThumbs() {
        thumbs.removeAllViews()
        attachedFiles.forEachIndexed { i, f ->
            thumbs.addView(TextView(a).apply {
                text = "📄 " + f.name + "  ✕"; textSize = 13f; setTextColor(u.onTonal); maxLines = 1; ellipsize = TextUtils.TruncateAt.MIDDLE
                background = pill(u.tonalBg, 14); setPadding(dp(12), dp(8), dp(12), dp(8)); maxWidth = dp(220)
                setOnClickListener { attachedFiles.removeAt(i); renderThumbs(); refreshSend() }
            }, LinearLayout.LayoutParams(-2, -2).apply { setMargins(0, dp(6), dp(8), dp(2)) })
        }
        attached.forEachIndexed { i, bytes ->
            thumbs.addView(FrameLayout(a).apply {
                addView(ImageView(a).apply {
                    setImageBitmap(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = 8 }))
                    scaleType = ImageView.ScaleType.CENTER_CROP; clipToOutline = true
                    background = pill(u.surface, 12)
                }, FrameLayout.LayoutParams(dp(64), dp(64)))
                addView(ImageView(a).apply {
                    setImageResource(R.drawable.ic_close); imageTintList = ColorStateList.valueOf(Color.WHITE)
                    background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0x99000000.toInt()) }
                    setPadding(dp(3), dp(3), dp(3), dp(3))
                    setOnClickListener { attached.removeAt(i); renderThumbs(); refreshSend() }
                }, FrameLayout.LayoutParams(dp(22), dp(22), Gravity.END or Gravity.TOP))
            }, LinearLayout.LayoutParams(dp(64), dp(64)).apply { setMargins(0, dp(6), dp(8), dp(2)) })
        }
    }

    // ---- voice ----

    private fun dictate() {
        if (voice.listening) { voice.stop(); refreshSend(); return }
        val before = input.text.toString()
        val started = voice.start({ text, _ ->
            val sep = if (before.isBlank() || before.endsWith(" ")) "" else " "
            input.setText(before + sep + text); input.setSelection(input.text.length)
        }) { err -> err?.let(::toast); refreshSend() }
        if (started) sendBtn.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        refreshSend()
    }

    // ---- usage ----

    private fun fmtTok(n: Long) = when { n >= 1_000_000 -> String.format("%.1fM", n / 1e6); n >= 1000 -> "${n / 1000}k"; else -> "$n" }

    private fun usageLine(u: JSONObject?): String {
        if (u == null) return ""
        val parts = ArrayList<String>()
        if (u.has("ctxPct")) parts += tr("context {0}%", u.optDouble("ctxPct").toInt())
        val inT = u.optLong("in") + u.optLong("cached"); val outT = u.optLong("out")
        if (inT + outT > 0) parts += "${fmtTok(inT)} ↑ ${fmtTok(outT)} ↓"
        if (u.has("cost")) parts += String.format("$%.2f", u.optDouble("cost"))
        u.optJSONArray("limits")?.let { l -> for (i in 0 until l.length()) l.optJSONObject(i)?.let { parts += "${it.optString("label")} ${it.optDouble("pct").toInt()}%" } }
        return parts.joinToString("  ·  ")
    }

    private fun usageSheet() {
        val s = current() ?: return
        val theme = if (u.dark) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
        val c = android.view.ContextThemeWrapper(a, theme)
        val box = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(8), dp(22), 0) }
        val us = s.optJSONObject("usage") ?: JSONObject()
        fun row(k: String, v: String) = box.addView(LinearLayout(c).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(4), 0, dp(4))
            addView(u.label(k, 14f, secondary = true), LinearLayout.LayoutParams(0, -2, 1f))
            addView(u.label(v, 14f, bold = true))
        })
        if (us.has("ctxPct")) row(tr("Context used"), "${us.optDouble("ctxPct").toInt()}%" + (us.optLong("ctxSize").takeIf { it > 0 }?.let { " " + tr("of {0}", fmtTok(it)) } ?: ""))
        row(tr("Input tokens"), fmtTok(us.optLong("in")))
        if (us.optLong("cached") > 0) row(tr("Read from cache"), fmtTok(us.optLong("cached")))
        row(tr("Output tokens"), fmtTok(us.optLong("out")))
        if (us.has("cost")) row(tr("Cost (API prices)"), String.format("$%.2f", us.optDouble("cost")))
        us.optJSONArray("limits")?.let { l -> for (i in 0 until l.length()) l.optJSONObject(i)?.let {
            val resets = it.optLong("resets").takeIf { r -> r > 0 }?.let { r -> " · " + tr("resets {0}", java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT, java.text.DateFormat.SHORT).format(java.util.Date(if (r > 1e11) r else r * 1000))) } ?: ""
            row(tr("Plan limit {0}", it.optString("label")), "${it.optDouble("pct").toInt()}%$resets")
        } }
        if (!us.has("cost") && s.optString("agent") == "claude" && !Agents.tap)
            box.addView(u.hint(tr("Cost and plan limits appear after turning on “Cost & plan limits” in Agents → ⋯.")))
        box.addView(u.title(tr("Budget for this chat")).apply { setPadding(0, dp(16), 0, 0) })
        val b = us.optJSONObject("budget") ?: JSONObject()
        val usd = EditText(c).apply { hint = tr("Dollars (e.g. 5)"); inputType = EditorInfo.TYPE_CLASS_NUMBER or EditorInfo.TYPE_NUMBER_FLAG_DECIMAL; setTextColor(u.text); setHintTextColor(u.text2)
            if (b.has("usd")) setText(b.optDouble("usd").toString()) }
        val tok = EditText(c).apply { hint = tr("or thousand tokens (e.g. 500)"); inputType = EditorInfo.TYPE_CLASS_NUMBER; setTextColor(u.text); setHintTextColor(u.text2)
            if (b.has("tokens")) setText((b.optLong("tokens") / 1000).toString()) }
        val stopIt = android.widget.CheckBox(c).apply { text = tr("Stop the chat when it's reached"); isChecked = b.optBoolean("stop"); setTextColor(u.text) }
        box.addView(usd); box.addView(tok); box.addView(stopIt)
        box.addView(u.hint(tr("You get a notification when the budget is reached. Dollars need “Cost & plan limits” (Claude) — Codex counts tokens.")))
        AlertDialog.Builder(a, theme).setTitle(s.optString("title")).setView(ScrollView(c).apply { addView(box) })
            .setNegativeButton(tr("Close"), null)
            .setPositiveButton(tr("Save budget")) { _, _ ->
                val p = JSONObject().put("sid", s.optString("id")).put("stop", stopIt.isChecked)
                usd.text.toString().replace(',', '.').toDoubleOrNull()?.let { p.put("usd", it) }
                tok.text.toString().toLongOrNull()?.let { p.put("tokens", it * 1000) }
                Agents.request("budget", p) { _, e -> toast(e ?: tr("Budget saved")) }
            }.show()
    }

    // ---- commands ----

    private fun commands() {
        val s = current() ?: return
        if (!s.optBoolean("managed")) { toast(tr("Commands work in chats running in PhoneCast's terminal.")); return }
        val claude = s.optString("agent") == "claude"
        val items = ArrayList<Pair<String, () -> Unit>>()
        fun cmd(text: String, showTerminal: Boolean = false) {
            Agents.request("command", JSONObject().put("sid", open).put("text", text), 40_000) { _, e ->
                if (e != null) toast(e) else if (showTerminal) { termMode = true; changesMode = false; view.postDelayed({ renderMessages(force = true); refreshChatHeader() }, 900) }
            }
        }
        items += tr("Switch model…") to { pickModel(s) }
        if (claude) {
            items += tr("Effort…") to {
                val levels = listOf("low", "medium", "high", "max")
                themed().setTitle(tr("Effort")).setItems(levels.map { tr(it) }.toTypedArray()) { _, i -> cmd("/effort ${levels[i]}") }.show()
            }
            items += tr("Next permission mode (now: {0})", modeChip.text) to { Agents.request("mode", JSONObject().put("sid", open)) { _, e -> e?.let(::toast) } }
            items += tr("Compact the conversation") to { cmd("/compact") }
            items += tr("Usage limits (/usage)") to { cmd("/usage", true) }
            items += tr("Context (/context)") to { cmd("/context", true) }
            items += tr("Clear the conversation…") to { confirm(tr("Start fresh? The current conversation is kept in the history.")) { cmd("/clear") } }
        } else {
            items += tr("Compact the conversation") to { cmd("/compact") }
            items += tr("Status (/status)") to { cmd("/status", true) }
            items += tr("Approval mode (/approvals)") to { cmd("/approvals") }
            items += tr("Show the diff (/diff)") to { cmd("/diff", true) }
            items += tr("New conversation (/new)") to { confirm(tr("Start a new conversation in this terminal?")) { cmd("/new") } }
        }
        items += tr("Ask the agent to commit") to { Agents.send(s.optString("id"), tr("Please commit the current changes with a good commit message.")) { _, e -> e?.let(::toast) } }
        items += tr("Other command…") to {
            val c = android.view.ContextThemeWrapper(a, dialogTheme())
            val f = EditText(c).apply { setText("/"); setSelection(1); setTextColor(u.text); setSingleLine() }
            themed().setTitle(tr("Command")).setView(FrameLayout(c).apply { setPadding(dp(22), dp(8), dp(22), 0); addView(f) })
                .setNegativeButton(tr("Cancel"), null).setPositiveButton(tr("Send")) { _, _ -> cmd(f.text.toString().trim(), true) }.show()
        }
        themed().setTitle(tr("Commands")).setItems(items.map { it.first }.toTypedArray()) { _, i -> items[i].second() }.show()
    }

    private fun pickModel(s: JSONObject) {
        val agent = s.optString("agent")
        Agents.request("models", timeoutMs = 70_000) { d, err ->
            if (err != null) { toast(err); return@request }
            val arr = d?.optJSONArray("agents") ?: return@request
            val ms = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.firstOrNull { it.optString("id") == agent }?.optJSONArray("models") ?: return@request
            val list = (0 until ms.length()).mapNotNull { ms.optJSONObject(it) }
            themed().setTitle(tr("Switch model")).setItems(list.map { it.optString("label") + (it.optString("desc").ifEmpty { null }?.let { d2 -> "\n" + d2 } ?: "") }.toTypedArray()) { _, i ->
                val id = list[i].optString("id")
                // Claude takes the model as an argument; Codex opens its own picker (answer it in the chat)
                val text = if (agent == "claude") "/model $id" else "/model"
                Agents.request("command", JSONObject().put("sid", open).put("text", text), 40_000) { _, e -> toast(e ?: tr("Model: {0}", list[i].optString("label"))) }
            }.show()
        }
    }

    private fun dialogTheme() = if (u.dark) android.R.style.Theme_DeviceDefault_Dialog_Alert else android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
    private fun themed() = AlertDialog.Builder(a, dialogTheme())
    private fun confirm(text: String, yes: () -> Unit) = themed().setMessage(text).setNegativeButton(tr("Cancel"), null).setPositiveButton(tr("OK")) { _, _ -> yes() }.show()

    // ---- changes (git) ----

    private fun renderChanges() {
        val sid = open ?: return
        msgList.removeAllViews(); rendered.clear()
        msgList.addView(u.label(tr("Loading…"), 14f, secondary = true).apply { gravity = Gravity.CENTER; setPadding(0, dp(40), 0, 0) })
        val path = diffPath
        if (path != null) {
            Agents.request("diff", JSONObject().put("sid", sid).put("path", path)) { d, err ->
                if (!changesMode || open != sid || diffPath != path) return@request
                msgList.removeAllViews()
                msgList.addView(u.quiet("← " + tr("All changes")) { diffPath = null; renderChanges() }.apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
                msgList.addView(u.label(path, 14f, bold = true).apply { setPadding(dp(4), dp(4), dp(4), dp(8)) })
                msgList.addView(HorizontalScrollView(a).apply {
                    addView(TextView(a).apply {
                        text = diffSpans(d?.optString("v") ?: err ?: ""); typeface = Typeface.MONOSPACE; textSize = 11.5f
                        setTextColor(u.text); setTextIsSelectable(true); setPadding(dp(6), dp(6), dp(6), dp(6))
                    })
                })
                msgScroll.post { msgScroll.scrollTo(0, 0) }
            }
            return
        }
        Agents.request("changes", JSONObject().put("sid", sid)) { d, err ->
            if (!changesMode || open != sid || diffPath != null) return@request
            msgList.removeAllViews()
            if (err != null || d == null) { msgList.addView(u.label(err ?: "", 14f, secondary = true)); return@request }
            if (!d.optBoolean("repo")) { msgList.addView(u.label(tr("This folder isn't a git repository."), 14f, secondary = true).apply { gravity = Gravity.CENTER; setPadding(0, dp(40), 0, 0) }); return@request }
            val files = d.optJSONArray("files")
            val n = files?.length() ?: 0
            val head = listOfNotNull(
                tr("Branch {0}", d.optString("branch")),
                if (d.optInt("ahead") > 0) tr("{0} to push", d.optInt("ahead")) else null,
                if (d.optInt("behind") > 0) tr("{0} to pull", d.optInt("behind")) else null,
                if (n == 0) tr("no changes") else tr(if (n == 1) "{0} file changed" else "{0} files changed", n),
            ).joinToString("  ·  ")
            msgList.addView(u.label(head, 14f, bold = true).apply { setPadding(dp(4), dp(8), dp(4), dp(8)) })
            var add = 0; var del = 0
            for (i in 0 until n) {
                val f = files!!.optJSONObject(i) ?: continue
                add += f.optInt("add"); del += f.optInt("del")
                val kind = f.optString("kind")
                msgList.addView(LinearLayout(a).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(6), dp(9), dp(6), dp(9))
                    background = RippleDrawable(ColorStateList.valueOf(0x22000000), null, pill(Color.WHITE, 10))
                    addView(TextView(a).apply {
                        text = when (kind) { "new", "added" -> "A"; "deleted" -> "D"; "renamed" -> "R"; else -> "M" }
                        setTextColor(when (kind) { "new", "added" -> u.green; "deleted" -> u.red; else -> u.orange }); typeface = Typeface.MONOSPACE; textSize = 13f
                    }, LinearLayout.LayoutParams(dp(22), -2))
                    addView(u.label(f.optString("path"), 13.5f).apply { maxLines = 2; ellipsize = TextUtils.TruncateAt.START }, LinearLayout.LayoutParams(0, -2, 1f))
                    addView(TextView(a).apply {
                        val sb = SpannableStringBuilder()
                        if (f.optInt("add") > 0) { val st = sb.length; sb.append("+${f.optInt("add")} "); sb.setSpan(android.text.style.ForegroundColorSpan(u.green), st, sb.length, 0) }
                        if (f.optInt("del") > 0) { val st = sb.length; sb.append("−${f.optInt("del")}"); sb.setSpan(android.text.style.ForegroundColorSpan(u.red), st, sb.length, 0) }
                        text = sb; textSize = 12.5f; typeface = Typeface.MONOSPACE; setPadding(dp(8), 0, 0, 0)
                    })
                    setOnClickListener { diffPath = f.optString("path"); renderChanges() }
                })
            }
            if (n > 0) msgList.addView(u.label(tr("{0} lines added, {1} removed", add, del), 12.5f, secondary = true).apply { setPadding(dp(6), dp(6), 0, dp(4)) })
            // git actions
            val acts = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(8), 0, 0) }
            if (n > 0) acts.addView(u.primary(tr("Commit…")) { commitDialog() })
            if (n > 0) acts.addView(u.tonal(tr("Let the agent commit")) { Agents.send(sid, tr("Please commit the current changes with a good commit message.")) { _, e -> toast(e ?: tr("Asked the agent")) } })
            if (d.optInt("ahead") > 0 || (!d.optBoolean("upstream") && d.optString("remote").isNotEmpty())) acts.addView(u.tonal(tr("Push")) { gitOp("push") })
            if (d.optInt("behind") > 0) acts.addView(u.tonal(tr("Pull")) { gitOp("pull") })
            if (d.optBoolean("gh") && d.optString("remote").isNotEmpty() && d.optString("branch") !in setOf("main", "master")) acts.addView(u.tonal(tr("Create pull request")) { prDialog() })
            msgList.addView(acts)
        }
    }

    private fun diffSpans(t: String): CharSequence {
        val sb = SpannableStringBuilder()
        val addBg = if (u.dark) 0x3328A745 else 0x2228A745
        val delBg = if (u.dark) 0x33E5534B else 0x22E5534B
        t.lines().take(4000).forEach { l ->
            val st = sb.length
            sb.append(l).append('\n')
            val bg = when { l.startsWith("+++") || l.startsWith("---") -> 0; l.startsWith("+") -> addBg; l.startsWith("-") -> delBg; else -> 0 }
            if (bg != 0) sb.setSpan(BackgroundColorSpan(bg), st, sb.length, 0)
            if (l.startsWith("@@")) sb.setSpan(android.text.style.ForegroundColorSpan(u.accent), st, sb.length, 0)
            if (l.startsWith("diff ") || l.startsWith("index ")) sb.setSpan(android.text.style.ForegroundColorSpan(u.text2), st, sb.length, 0)
        }
        return sb
    }

    private fun gitOp(op: String, extra: JSONObject = JSONObject()) {
        toast(tr("Working…"))
        Agents.request("git", extra.put("sid", open).put("op", op), 150_000) { d, err ->
            toast(err ?: d?.optString("v") ?: tr("Done"))
            if (changesMode) renderChanges()
        }
    }

    private fun commitDialog() {
        val c = android.view.ContextThemeWrapper(a, dialogTheme())
        val f = EditText(c).apply { hint = tr("Commit message"); minLines = 2; setTextColor(u.text); setHintTextColor(u.text2) }
        themed().setTitle(tr("Commit all changes")).setView(FrameLayout(c).apply { setPadding(dp(22), dp(8), dp(22), 0); addView(f) })
            .setNegativeButton(tr("Cancel"), null)
            .setPositiveButton(tr("Commit")) { _, _ -> gitOp("commit", JSONObject().put("message", f.text.toString())) }.show()
    }

    private fun prDialog() {
        val c = android.view.ContextThemeWrapper(a, dialogTheme())
        val box = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(8), dp(22), 0) }
        val title = EditText(c).apply { hint = tr("Title (empty = from the commits)"); setTextColor(u.text); setHintTextColor(u.text2) }
        val draft = android.widget.CheckBox(c).apply { text = tr("Draft"); setTextColor(u.text) }
        box.addView(title); box.addView(draft)
        themed().setTitle(tr("Create pull request")).setView(box).setNegativeButton(tr("Cancel"), null)
            .setPositiveButton(tr("Create")) { _, _ -> gitOp("pr", JSONObject().put("title", title.text.toString()).put("draft", draft.isChecked)) }.show()
    }

    // ---- settings (list header ⋯) ----

    private fun settingsMenu(anchor: View) {
        val m = PopupMenu(a, anchor)
        m.menu.add(0, 1, 0, tr("Live status notification")).apply { isCheckable = true; isChecked = AgentsLive.enabled(a) }
        m.menu.add(0, 2, 0, tr("Read finished answers aloud")).apply { isCheckable = true; isChecked = prefs.getBoolean("speakDone", false) }
        m.menu.add(0, 3, 0, tr("Cost & plan limits (Claude statusline)")).apply { isCheckable = true; isChecked = Agents.tap }
        m.menu.add(0, 4, 0, tr("Continue chats after usage limits…"))
        m.menu.add(0, 5, 0, tr("Alert when an agent seems stuck…"))
        m.menu.add(0, 6, 0, tr("Other machines…"))
        m.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> { prefs.edit().putBoolean("live", !AgentsLive.enabled(a)).apply(); AgentsLive.cancel(a); AgentsLive.update(a) }
                2 -> prefs.edit().putBoolean("speakDone", !prefs.getBoolean("speakDone", false)).apply()
                3 -> {
                    val on = !Agents.tap
                    if (on) confirm(tr("PhoneCast wraps your Claude statusline (it keeps working as before) to read cost and plan limits. ~/.claude/settings.json is backed up first.")) {
                        Agents.request("tap", JSONObject().put("on", true)) { d, e -> e?.let(::toast); Agents.setTap(d?.optBoolean("v") == true) }
                    } else Agents.request("tap", JSONObject().put("on", false)) { d, e -> e?.let(::toast); Agents.setTap(d?.optBoolean("v") == true) }
                }
                4 -> Agents.request("recovery") { d, e ->
                    if (e != null) { toast(e); return@request }
                    val on = d?.optJSONObject("global")?.optBoolean("continue") ?: false
                    themed().setTitle(tr("Continue after usage limits"))
                        .setMessage(tr("When a chat stops at a usage limit, PhoneCast sends “continue” a minute after the limit resets. You can change it per chat (⋯ in the chat)."))
                        .setPositiveButton(tr(if (on) "Turn off for all chats" else "Turn on for all chats")) { _, _ ->
                            Agents.request("recovery", JSONObject().put("global", JSONObject().put("continue", !on))) { _, e2 -> toast(e2 ?: tr("Saved")) }
                        }.setNegativeButton(tr("Close"), null).show()
                }
                6 -> machines()
                5 -> {
                    val opts = listOf(5, 10, 20, 30, 0)
                    themed().setTitle(tr("Alert when an agent seems stuck")).setItems(opts.map { if (it == 0) tr("Never") else tr("After {0} min without progress", it) }.toTypedArray()) { _, i ->
                        Agents.request("recovery", JSONObject().put("global", JSONObject().put("stuckMin", if (opts[i] == 0) 100000 else opts[i]))) { _, e2 -> toast(e2 ?: tr("Saved")) }
                    }.show()
                }
            }
            true
        }
        m.show()
    }

    // ---- live terminal ----

    private fun renderTerm() {
        val sid = open ?: return
        if (termBusy) return
        termBusy = true
        Agents.request("live", JSONObject().put("sid", sid).put("lines", 160)) { d, err ->
            termBusy = false
            if (!termMode || open != sid) return@request
            val atBottom = !msgScroll.canScrollVertically(1) || msgList.childCount == 0 || msgList.getChildAt(0).tag != "term"
            val tv = (msgList.getChildAt(0)?.takeIf { it.tag == "term" } as? HorizontalScrollView)?.getChildAt(0) as? TextView
                ?: TextView(a).apply { typeface = Typeface.MONOSPACE; textSize = 10.5f; setTextColor(TERM_FG); setTextIsSelectable(true); setPadding(dp(10), dp(10), dp(10), dp(10)) }.also { t ->
                    msgList.removeAllViews(); rendered.clear()
                    // agents draw for a dark terminal: keep it dark in both themes
                    msgList.addView(HorizontalScrollView(a).apply { tag = "term"; background = pill(TERM_BG, 14); addView(t) })
                }
            tv.text = if (d != null) Ansi.spans(d.optString("ansi"), TERM_FG) else (err ?: "")
            if (atBottom) msgScroll.post { msgScroll.fullScroll(View.FOCUS_DOWN) }
        }
        view.removeCallbacks(termPoll); view.postDelayed(termPoll, 900)
    }

    // ---- files ----

    private fun renderFiles() {
        val sid = open ?: return
        msgList.removeAllViews(); rendered.clear()
        val fp = filePath
        val crumbs = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dp(4), dp(6), dp(4), dp(6)) }
        val parts = listOf("") + filesPath.split('/').filter { it.isNotEmpty() }
        parts.forEachIndexed { i, part ->
            crumbs.addView(TextView(a).apply {
                text = (if (i == 0) (current()?.optString("cwd")?.substringAfterLast('/') ?: "/") else part) + if (i < parts.size - 1 || fp != null) "  /  " else ""
                textSize = 14f; setTextColor(if (i < parts.size - 1 || fp != null) u.accent else u.text)
                setOnClickListener { filesPath = parts.subList(1, i + 1).joinToString("/"); filePath = null; renderFiles() }
            })
        }
        if (fp != null) crumbs.addView(u.label(fp.substringAfterLast('/'), 14f, bold = true))
        msgList.addView(HorizontalScrollView(a).apply { isHorizontalScrollBarEnabled = false; addView(crumbs) })
        if (fp != null) {
            Agents.request("file", JSONObject().put("sid", sid).put("path", fp)) { d, err ->
                if (!filesMode || filePath != fp) return@request
                val txt = when { err != null -> err; d?.optBoolean("binary") == true -> tr("Binary file ({0} KB)", (d.optLong("size") / 1024)); else -> d?.optString("text") ?: "" }
                msgList.addView(HorizontalScrollView(a).apply { addView(u.mono(txt).apply { textSize = 11.5f; setTextColor(u.text); setPadding(dp(6), dp(6), dp(6), dp(6)) }) })
                if (d?.optBoolean("cut") == true) msgList.addView(u.hint(tr("Only the first 400 KB are shown.")))
                msgList.addView(u.tonal(tr("Mention in the message")) { insertAt(fp) })
                msgScroll.post { msgScroll.scrollTo(0, 0) }
            }
            return
        }
        Agents.request("files", JSONObject().put("sid", sid).put("path", filesPath)) { d, err ->
            if (!filesMode || filePath != null) return@request
            if (err != null) { msgList.addView(u.label(err, 14f, secondary = true)); return@request }
            val items = d?.optJSONArray("items") ?: return@request
            for (i in 0 until items.length()) {
                val it = items.optJSONObject(i) ?: continue
                val dir = it.optBoolean("dir"); val name = it.optString("name")
                msgList.addView(LinearLayout(a).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(8), dp(10), dp(8), dp(10)); alpha = if (it.optBoolean("dim")) 0.5f else 1f
                    background = RippleDrawable(ColorStateList.valueOf(0x22000000), null, pill(Color.WHITE, 10))
                    addView(u.label(if (dir) "📁" else "📄", 15f), LinearLayout.LayoutParams(dp(30), -2))
                    addView(u.label(name, 14.5f), LinearLayout.LayoutParams(0, -2, 1f))
                    if (!dir) addView(u.label(fmtSize(it.optLong("size")), 12f, secondary = true))
                    val rel = if (filesPath.isEmpty()) name else "$filesPath/$name"
                    setOnClickListener { if (dir) filesPath = rel else filePath = rel; renderFiles() }
                    setOnLongClickListener { insertAt(rel); true }
                })
            }
            if (items.length() == 0) msgList.addView(u.label(tr("Empty folder"), 14f, secondary = true).apply { setPadding(dp(8), dp(12), 0, 0) })
            msgList.addView(u.hint(tr("Long-press a file to mention it in your message.")))
        }
    }

    private fun fmtSize(n: Long) = when { n >= 1 shl 20 -> String.format("%.1f MB", n / 1048576.0); n >= 1024 -> "${n / 1024} KB"; else -> "$n B" }

    // ---- @ mentions ----

    /** The "@word" being typed at the cursor, or null. */
    private fun atToken(): String? {
        val t = input.text.toString(); val c = input.selectionStart.coerceIn(0, t.length)
        val start = t.lastIndexOf('@', c - 1).takeIf { it >= 0 } ?: return null
        if (start > 0 && !t[start - 1].isWhitespace()) return null
        val tok = t.substring(start + 1, c)
        return if (tok.any { it.isWhitespace() }) null else tok
    }

    private var suggestSeq = 0
    private fun suggest(q: String?) {
        val sid = open
        if (q == null || sid == null || current()?.optString("cwd").isNullOrEmpty()) { suggestRow.removeAllViews(); return }
        val seq = ++suggestSeq
        view.postDelayed({
            if (seq != suggestSeq) return@postDelayed
            Agents.request("find", JSONObject().put("sid", sid).put("q", q)) { d, _ ->
                if (seq != suggestSeq) return@request
                suggestRow.removeAllViews()
                val arr = d?.optJSONArray("files") ?: return@request
                for (i in 0 until minOf(12, arr.length())) {
                    val f = arr.optString(i)
                    suggestRow.addView(TextView(a).apply {
                        text = f.substringAfterLast('/'); textSize = 13f; setTextColor(u.onTonal)
                        background = RippleDrawable(ColorStateList.valueOf(0x22000000), pill(u.tonalBg, 14), null)
                        setPadding(dp(12), dp(6), dp(12), dp(6)); contentDescription = f
                        setOnClickListener { replaceAt(f) }
                    }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(6) })
                }
            }
        }, 180)
    }

    private fun replaceAt(path: String) {
        val t = input.text.toString(); val c = input.selectionStart.coerceIn(0, t.length)
        val start = t.lastIndexOf('@', c - 1)
        if (start < 0) { insertAt(path); return }
        val n = t.substring(0, start) + "@" + path + " " + t.substring(c)
        input.setText(n); input.setSelection((start + path.length + 2).coerceAtMost(n.length)); suggest(null)
    }

    private fun insertAt(path: String) {
        if (filesMode) { filesMode = false; renderMessages(force = true); refreshChatHeader() }
        val t = input.text.toString()
        val n = (if (t.isEmpty() || t.endsWith(" ")) t else "$t ") + "@" + path + " "
        input.setText(n); input.setSelection(n.length); input.requestFocus()
    }

    private fun pickFiles() {
        @Suppress("DEPRECATION")
        a.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*").putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), REQ_FILES)
    }

    // ---- dev-server previews ----

    private fun devServers(s: JSONObject) {
        Agents.request("previews", JSONObject().put("sid", s.optString("id"))) { d, err ->
            if (err != null) { toast(err); return@request }
            val ports = d?.optJSONArray("ports")
            val list = (0 until (ports?.length() ?: 0)).mapNotNull { ports!!.optJSONObject(it) }
            val c = android.view.ContextThemeWrapper(a, dialogTheme())
            val f = EditText(c).apply { hint = tr("Port, e.g. 5173"); inputType = EditorInfo.TYPE_CLASS_NUMBER; setTextColor(u.text); setHintTextColor(u.text2) }
            val b = themed().setTitle(tr("Open a dev server on the phone"))
            if (list.isNotEmpty()) b.setItems(list.map { it.optString("url") }.toTypedArray()) { _, i -> openPreview(list[i].optInt("port"), list[i].optString("path", "/")) }
            else b.setMessage(tr("No local web address in this chat yet. Enter the port the server runs on:"))
            b.setView(FrameLayout(c).apply { setPadding(dp(22), dp(8), dp(22), 0); addView(f) })
                .setNegativeButton(tr("Cancel"), null)
                .setPositiveButton(tr("Open")) { _, _ -> f.text.toString().toIntOrNull()?.let { openPreview(it, "/") } }.show()
        }
    }

    private fun openPreview(port: Int, path: String) {
        val host = Agents.hostAddress() ?: run { toast(tr("The Mac isn't connected.")); return }
        Agents.request("preview", JSONObject().put("port", port)) { d, err ->
            if (err != null) { toast(err); return@request }
            val p = d?.optInt("port") ?: return@request
            val h = if (host.contains(':')) "[$host]" else host
            try { a.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("http://$h:$p$path"))) } catch (_: Exception) { toast(tr("No browser found.")) }
        }
    }

    /** ssh targets the Mac runs agents on (user@host, key login set up on the Mac). */
    private fun machines() {
        Agents.request("hosts", timeoutMs = 40_000) { d, err ->
            if (err != null) { toast(err); return@request }
            val arr = d?.optJSONArray("hosts")
            val list = (0 until (arr?.length() ?: 0)).mapNotNull { arr!!.optJSONObject(it) }
            val c = android.view.ContextThemeWrapper(a, dialogTheme())
            val box = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(8), dp(22), 0) }
            box.addView(u.label(tr("The Mac starts and watches agents on these machines over SSH (key login from the Mac, tmux and the agent installed there)."), 13.5f, secondary = true))
            for (h in list) box.addView(u.label("${if (h.optBoolean("up")) "●" else "○"}  ${h.optString("host")}  " +
                (if (h.optBoolean("up")) h.optJSONArray("tools")?.let { t -> (0 until t.length()).joinToString(", ") { t.optString(it) } }?.ifEmpty { tr("no tools found") } ?: "" else tr("not reachable")), 14f).apply { setPadding(0, dp(8), 0, 0) })
            val f = EditText(c).apply { setText(list.joinToString(", ") { it.optString("host") }); hint = "user@host, user@other"; setTextColor(u.text); setHintTextColor(u.text2) }
            box.addView(f)
            themed().setTitle(tr("Other machines")).setView(ScrollView(c).apply { addView(box) }).setNegativeButton(tr("Close"), null)
                .setPositiveButton(tr("Save")) { _, _ ->
                    val hs = org.json.JSONArray(f.text.split(',', ' ', '\n').map { it.trim() }.filter { it.isNotEmpty() })
                    Agents.request("hosts", JSONObject().put("set", hs), 40_000) { _, e -> toast(e ?: tr("Saved")) }
                }.show()
        }
    }

    fun onPermission(req: Int, granted: Boolean) { if (req == Voice.REQ_MIC && granted) dictate() }

    // ---- drafts (per chat, survive app restarts) ----

    private var restoring = false
    private fun draftSave() { if (!restoring) open?.let { prefs.edit().putString("draft.$it", input.text.toString()).apply() } }
    private fun draftRestore() { restoring = true; input.setText(open?.let { prefs.getString("draft.$it", "") } ?: ""); restoring = false }
    private fun draftClear(sid: String) = prefs.edit().remove("draft.$sid").apply()

    // ---- small helpers ----

    private fun pill(color: Int, r: Int, stroke: Int = 0) = GradientDrawable().apply {
        cornerRadius = dp(r).toFloat(); setColor(color); if (stroke != 0) setStroke(dp(1), stroke)
    }

    private fun tint(res: Int, color: Int) = a.getDrawable(res)!!.mutate().apply {
        setTint(color); setBounds(0, 0, dp(20), dp(20))
    }

    private fun iconButton(res: Int, desc: String, filled: Boolean = false, onClick: (View) -> Unit) = ImageView(a).apply {
        setImageResource(res); contentDescription = desc
        imageTintList = ColorStateList.valueOf(if (filled) u.onTonal else u.text2)
        background = RippleDrawable(ColorStateList.valueOf(if (u.dark) 0x33FFFFFF else 0x22000000),
            if (filled) GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(u.tonalBg) } else null,
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) })
        setPadding(dp(10), dp(10), dp(10), dp(10))
        layoutParams = LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginStart = dp(2) }
        setOnClickListener { onClick(it) }
    }

    private fun ago(ms: Long): String {
        if (ms <= 0) return ""
        val s = (System.currentTimeMillis() - ms) / 1000
        return when {
            s < 60 -> tr("now")
            s < 3600 -> tr("{0} min", s / 60)
            s < 86400 -> tr("{0} h", s / 3600)
            s < 7 * 86400 -> tr("{0} d", s / 86400)
            else -> java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault()).format(java.util.Date(ms))
        }
    }

    private fun copy(s: String) {
        a.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("PhoneCast", s))
    }

    private fun toast(s: String) = android.widget.Toast.makeText(a, tr(s), android.widget.Toast.LENGTH_LONG).show()

    /** Refresh relative times etc. (called once a second while visible). */
    fun tick() {
        if (++ticks % 30 == 0) { rowCache.clear(); refreshList() }
    }
    private var ticks = 0

    init {
        view.addView(split, FrameLayout.LayoutParams(-1, -1))
        buildList()
        buildChat()
        if (u.wide) {
            split.addView(listPane, LinearLayout.LayoutParams(0, -1, 0.42f))
            split.addView(View(a).apply { setBackgroundColor(u.divider) }, LinearLayout.LayoutParams(dp(1), -1))
            split.addView(FrameLayout(a).apply {
                addView(chatPane, FrameLayout.LayoutParams(-1, -1))
                addView(emptyChat, FrameLayout.LayoutParams(-1, -1))
            }, LinearLayout.LayoutParams(0, -1, 0.58f))
        } else {
            split.addView(listPane, LinearLayout.LayoutParams(-1, -1))
            split.addView(chatPane, LinearLayout.LayoutParams(-1, -1))
        }
        Agents.listen(listener)
        u.gone(workStrip, true)
        refreshList(); showPane()
        open?.let { Agents.watch(it); draftRestore(); refreshChatHeader(); renderMessages(force = true) }
    }

    companion object { const val REQ_PHOTOS = 7; const val REQ_FILES = 12; const val TERM_BG = 0xFF17181C.toInt(); const val TERM_FG = 0xFFD8D8DC.toInt() }
}
