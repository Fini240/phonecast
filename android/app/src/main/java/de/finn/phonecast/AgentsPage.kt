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
        termMode = false; attached.clear(); renderThumbs()
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
    private val chips = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
    private val rows = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, dp(24)) }
    private val rowCache = HashMap<String, Pair<String, View>>()
    private lateinit var searchBox: EditText

    private fun buildList() {
        val head = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(20), dp(16), dp(4))
            addView(u.label("Agents", 30f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
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
                addView(banner); addView(rows)
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
        val folder = s.optString("cwd").substringAfterLast('/').ifEmpty { null }
        val role = s.optString("role").ifEmpty { null }
        return listOfNotNull(if (s.optBoolean("sub")) role else folder, what).joinToString(" · ")
    }

    private fun agentBadge(agent: String, status: String, size: Int): View {
        val f = FrameLayout(a)
        val c = if (agent == "codex") (if (u.dark) 0xFF2E3440.toInt() else 0xFF20232A.toInt()) else (if (u.dark) 0xFF5A3A2C.toInt() else 0xFFF3E1D7.toInt())
        f.addView(TextView(a).apply {
            text = if (agent == "codex") "›_" else "✻"
            gravity = Gravity.CENTER; textSize = if (agent == "codex") size * 0.32f else size * 0.42f
            setTextColor(if (agent == "codex") Color.WHITE else if (u.dark) 0xFFF4B490.toInt() else 0xFFC4602D.toInt())
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
        termBtn = iconButton(R.drawable.ic_terminal, tr("Terminal view")) { termMode = !termMode; renderMessages(force = true) }
        bar.addView(stopBtn); bar.addView(termBtn)
        bar.addView(iconButton(R.drawable.ic_more, tr("More")) { chatMenu(it) })
        chatPane.addView(bar)

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
        for ((k, label) in listOf("up" to "↑", "down" to "↓", "enter" to "Enter", "escape" to "Esc", "tab" to "Tab")) {
            keyStrip.addView(TextView(a).apply {
                text = label; textSize = 14f; gravity = Gravity.CENTER; setTextColor(u.onTonal)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                background = RippleDrawable(ColorStateList.valueOf(0x22000000), pill(u.tonalBg, 14), null)
                setPadding(dp(14), dp(6), dp(14), dp(6))
                setOnClickListener { v -> v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); key(k) }
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
        composer.addView(iconButton(R.drawable.ic_photo, tr("Add photos")) { pickPhotos() })
        input = EditText(a).apply {
            hint = tr("Message"); textSize = 16f; minLines = 1; maxLines = 6
            setTextColor(u.text); setHintTextColor(u.text2)
            background = pill(u.surface, 22)
            setPadding(dp(16), dp(11), dp(16), dp(11))
            inputType = EditorInfo.TYPE_CLASS_TEXT or EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE or EditorInfo.TYPE_TEXT_FLAG_CAP_SENTENCES
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) { draftSave(); refreshSend() }
                override fun beforeTextChanged(s: CharSequence?, st: Int, c: Int, af: Int) {}
                override fun onTextChanged(s: CharSequence?, st: Int, b: Int, c: Int) {}
            })
        }
        composer.addView(input, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(4), 0, dp(6), 0) })
        sendBtn = ImageView(a).apply {
            setImageResource(R.drawable.ic_send); imageTintList = ColorStateList.valueOf(u.onAccent)
            background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(u.accent) }, null)
            setPadding(dp(12), dp(12), dp(12), dp(12)); contentDescription = tr("Send")
            setOnClickListener { send() }
        }
        composer.addView(sendBtn, LinearLayout.LayoutParams(dp(46), dp(46)))
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
            s.optString("model").ifEmpty { null }?.removePrefix("claude-"),
            s.optString("cwd").replace(Regex("^/Users/[^/]+"), "~").ifEmpty { null },
        ).joinToString(" · ")
        val st = s.optString("status")
        val managed = s.optBoolean("managed")
        val working = st == "working"
        u.gone(workStrip, !working)
        workText.text = s.optString("stage").ifEmpty { tr("Working…") }
        u.gone(stopBtn, !(managed && (working || st == "needs_input")))
        u.gone(termBtn, !managed)
        termBtn.imageTintList = ColorStateList.valueOf(if (termMode) u.accent else u.text2)
        u.gone(keyStrip.parent as View, !managed)
        val canSend = Agents.canSend(s)
        input.isEnabled = canSend; sendBtn.isEnabled = canSend
        input.hint = tr(when {
            s.optBoolean("sub") -> "Subagents can't be messaged"
            !canSend -> "Open in another terminal — read only"
            working -> "Message — interrupts the current turn"
            !managed -> "Message — continues this chat on the Mac"
            else -> "Message"
        })
        composeHint.text = when {
            !canSend && !s.optBoolean("sub") && s.optBoolean("live") -> tr("Started outside PhoneCast's terminal integration. Close it on the Mac to continue here.")
            else -> ""
        }
        u.gone(composeHint, composeHint.text.isEmpty())
        refreshSend()
        renderAsk(s)
        if (termMode && working) renderMessages(force = true)
    }

    private fun refreshSend() {
        val ok = !sending && (input.text.isNotBlank() || attached.isNotEmpty()) && input.isEnabled
        sendBtn.alpha = if (ok) 1f else 0.4f
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
        if (termMode) {
            Agents.request("terminal", JSONObject().put("sid", open)) { d, err ->
                if (!termMode) return@request
                msgList.removeAllViews(); rendered.clear()
                msgList.addView(HorizontalScrollView(a).apply {
                    addView(u.mono(d?.optString("v") ?: err ?: "").apply { textSize = 11f; setTextColor(u.text); setPadding(dp(4), dp(4), dp(4), dp(4)) })
                })
                msgScroll.post { msgScroll.fullScroll(View.FOCUS_DOWN) }
            }
            return
        }
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
        for (m in msgs.drop(rendered.size)) {
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

    private fun chatMenu(anchor: View) {
        val s = current() ?: return
        val m = PopupMenu(a, anchor)
        if (s.optBoolean("managed")) m.menu.add(0, 1, 0, tr("Open in Terminal on the Mac"))
        if (!s.optBoolean("managed") && s.optBoolean("canResume")) m.menu.add(0, 2, 0, tr("Reopen on the Mac"))
        m.menu.add(0, 3, 0, tr(if (s.optString("id") in pins) "Unpin" else "Pin to top"))
        m.menu.add(0, 4, 0, tr("Copy folder path"))
        if (!s.optBoolean("sub")) m.menu.add(0, 5, 0, tr("New chat in this folder"))
        s.optString("parent").ifEmpty { null }?.let { p -> m.menu.add(0, 6, 0, tr("Open parent chat")) }
        m.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> Agents.request("open", JSONObject().put("sid", s.optString("id"))) { _, e -> e?.let(::toast) }
                2 -> Agents.request("resume", JSONObject().put("sid", s.optString("id"))) { d, e -> if (e != null) toast(e) else d?.optString("sid")?.let(::openChat) }
                3 -> { val p = pins; val id = s.optString("id"); if (!p.add(id)) p.remove(id); prefs.edit().putStringSet("pins", p).apply(); refreshList() }
                4 -> copy(s.optString("cwd"))
                5 -> newChat(s.optString("cwd"), s.optString("agent"))
                6 -> openChat(s.optString("parent"))
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
        val imgs = ArrayList(attached)
        // optimistic: show it right away, the transcript replaces it
        Agents.send(sid, text, imgs) { newSid, err ->
            sending = false
            if (err != null) { toast(err); refreshSend(); return@send }
            input.setText(""); attached.clear(); renderThumbs(); draftClear(sid)
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
        val seg = u.Segmented("", listOf("Claude Code" to "claude", "Codex" to "codex"), { chosen }, { chosen = it; fillModels() })
        seg.refresh(); box.addView(seg.view)
        box.addView(u.hint("Model"))
        box.addView(modelSpin)
        box.addView(u.hint("Folder on the Mac"))
        val folderBox = AutoCompleteTextView(c).apply {
            setText(folder ?: prefs.getString("lastFolder", "~")); textSize = 15f; setSingleLine(); threshold = 0
            setTextColor(u.text)
            setOnFocusChangeListener { v, f -> if (f) (v as AutoCompleteTextView).showDropDown() }
        }
        box.addView(folderBox)
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
                prefs.edit().putString("lastAgent", chosen).putString("lastFolder", cwd).putString("lastModel.$chosen", model).apply()
                Agents.request("start", JSONObject().put("agent", chosen).put("cwd", cwd).put("model", model).put("prompt", prompt.text.toString())) { d, err ->
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

    companion object { const val REQ_PHOTOS = 7 }
}
