package de.finn.phonecast

import android.app.Activity
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/**
 * The phone app's small widget kit (no AndroidX): Material-3-like colours from the system's
 * dynamic palette (Android 12+), cards, filled/tonal buttons, switch rows, segmented choices,
 * label/value rows with status dots and collapsible details.
 */
class Ui(private val a: Activity) {

    val dark = (a.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private fun sys(id: Int, fallback: Int) = if (Build.VERSION.SDK_INT >= 31) a.getColor(id) else fallback

    val accent = if (dark) sys(android.R.color.system_accent1_200, 0xFF9DC1FF.toInt()) else sys(android.R.color.system_accent1_600, 0xFF2B5BB5.toInt())
    val onAccent = if (dark) sys(android.R.color.system_accent1_800, 0xFF0B2A5C.toInt()) else Color.WHITE
    val tonalBg = if (dark) sys(android.R.color.system_accent2_700, 0xFF33405A.toInt()) else sys(android.R.color.system_accent2_100, 0xFFDCE3F5.toInt())
    val onTonal = if (dark) sys(android.R.color.system_accent2_100, 0xFFDCE3F5.toInt()) else sys(android.R.color.system_accent2_800, 0xFF1F2A40.toInt())
    val bg = if (dark) sys(android.R.color.system_neutral1_900, 0xFF121316.toInt()) else sys(android.R.color.system_neutral1_50, 0xFFF6F6F9.toInt())
    val surface = if (dark) sys(android.R.color.system_neutral1_800, 0xFF1F2024.toInt()) else Color.WHITE
    val barBg = if (dark) sys(android.R.color.system_neutral2_800, 0xFF1A1C21.toInt()) else sys(android.R.color.system_neutral2_50, 0xFFEFF1F6.toInt())
    val text = if (dark) 0xFFE6E6EA.toInt() else 0xFF1B1B1F.toInt()
    val text2 = if (dark) 0xFFA4A6AE.toInt() else 0xFF5E6068.toInt()
    val divider = if (dark) 0x22FFFFFF else 0x1A000000
    val green = if (dark) 0xFF4ADE80.toInt() else 0xFF15A34A.toInt()
    val grey = if (dark) 0xFF6B6E76.toInt() else 0xFFB0B3BA.toInt()
    val orange = if (dark) 0xFFFBBF24.toInt() else 0xFFD97706.toInt()
    val red = if (dark) 0xFFF87171.toInt() else 0xFFDC2626.toInt()

    /** Wide screen (unfolded Fold, tablet): two columns of cards. */
    val wide = a.resources.configuration.screenWidthDp >= 600

    fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), a.resources.displayMetrics).toInt()
    fun dpf(v: Int) = dp(v).toFloat()

    private fun rounded(color: Int, radius: Int, stroke: Int = 0) = GradientDrawable().apply {
        cornerRadius = dpf(radius); setColor(color)
        if (stroke != 0) setStroke(dp(1), stroke)
    }

    private fun ripple(content: android.graphics.drawable.Drawable?, radius: Int) =
        RippleDrawable(ColorStateList.valueOf(if (dark) 0x33FFFFFF else 0x22000000), content, rounded(Color.WHITE, radius))

    // ---- text ----

    fun label(s: String = "", size: Float = 15f, bold: Boolean = false, secondary: Boolean = false) = TextView(a).apply {
        text = s; textSize = size
        setTextColor(if (secondary) text2 else this@Ui.text)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setLineSpacing(0f, 1.12f)
    }

    fun title(s: String) = label(s, 17f, bold = true).apply { setPadding(0, 0, 0, dp(6)) }
    fun hint(s: String) = label(s, 13f, secondary = true).apply { setPadding(0, dp(6), 0, 0) }

    // ---- containers ----

    fun card(vararg views: View) = LinearLayout(a).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(18), dp(16), dp(18), dp(16))
        background = rounded(surface, 22)
        views.forEach { addView(it) }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) }
    }

    /** Page: big title, then the cards (two columns on a wide screen), scrolling. */
    fun page(t: String, vararg cards: View): View {
        val col = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(20), dp(16), dp(24))
            addView(label(t, 30f, bold = true).apply { setPadding(dp(4), 0, 0, dp(4)) })
        }
        if (!wide) cards.forEach { col.addView(it) }
        else {
            val row = LinearLayout(a).apply { orientation = LinearLayout.HORIZONTAL }
            val left = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
            val right = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
            row.addView(left, LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(6) })
            row.addView(right, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(6) })
            cards.forEachIndexed { i, c -> (if (i % 2 == 0) left else right).addView(c) }
            col.addView(row)
        }
        return ScrollView(a).apply { addView(col); isFillViewport = true; setBackgroundColor(bg) }
    }

    // ---- buttons ----

    private fun baseButton(s: String, fill: Int, fg: Int, onClick: () -> Unit) = Button(a).apply {
        text = s; isAllCaps = false; textSize = 15f
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        setTextColor(fg)
        background = ripple(rounded(fill, 24), 24)
        stateListAnimator = null
        minHeight = dp(48); minimumHeight = dp(48)
        setPadding(dp(16), dp(10), dp(16), dp(10))
        maxLines = 2; ellipsize = TextUtils.TruncateAt.END
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) }
    }

    /** The one main action of a card. */
    fun primary(s: String, onClick: () -> Unit) = baseButton(s, accent, onAccent, onClick)
    /** Secondary actions. */
    fun tonal(s: String, onClick: () -> Unit) = baseButton(s, tonalBg, onTonal, onClick)
    /** Destructive or rare actions: text only. */
    fun quiet(s: String, color: Int = accent, onClick: () -> Unit) = baseButton(s, Color.TRANSPARENT, color, onClick)

    /** Equal tonal buttons in a grid. */
    fun grid(cols: Int, vararg items: Pair<String, () -> Unit>) = GridLayout(a).apply {
        columnCount = cols
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) }
        for ((t, f) in items) addView(tonal(t, f).apply {
            // one line, shrinking a little in narrow cells (cover screen) instead of wrapping
            maxLines = 1; setPadding(dp(6), dp(10), dp(6), dp(10))
            val symbol = t.length <= 2 && t.any { it.code > 0x2000 }
            setAutoSizeTextTypeUniformWithConfiguration(11, if (symbol) 22 else 14, 1, TypedValue.COMPLEX_UNIT_SP)
            layoutParams = GridLayout.LayoutParams(GridLayout.spec(GridLayout.UNDEFINED), GridLayout.spec(GridLayout.UNDEFINED, 1f)).apply {
                width = 0; setMargins(dp(4), dp(4), dp(4), dp(4))
            }
        })
    }

    /** Round colour swatches (lights). */
    fun swatches(vararg items: Pair<Int, () -> Unit>, off: (() -> Unit)? = null) = LinearLayout(a).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(10), 0, 0)
        for ((c, f) in items) addView(View(a).apply {
            background = ripple(GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(c); setStroke(dp(2), divider) }, 22)
            isClickable = true; setOnClickListener { f() }
        }, LinearLayout.LayoutParams(dp(44), dp(44)).apply { marginEnd = dp(12) })
        if (off != null) addView(tonal("Off", off).apply { layoutParams = LinearLayout.LayoutParams(-2, -2) })
    }

    // ---- switch row ----

    inner class SwitchRow(t: String, private val get: () -> Boolean, private val set: (Boolean) -> Unit) {
        val sub = label("", 13f, secondary = true)
        private var updating = false
        private val sw = Switch(a).apply {
            // "on" must read as on: bright accent thumb on an accent track (the track drawable dims it)
            thumbTintList = ColorStateList(arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()), intArrayOf(accent, if (dark) 0xFFB9BBC2.toInt() else Color.WHITE))
            trackTintList = ColorStateList(arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()), intArrayOf(accent, if (dark) 0xFF5A5D66.toInt() else 0xFFB4B7BF.toInt()))
            setOnCheckedChangeListener { _, on -> if (!updating) set(on) }
        }
        val view = LinearLayout(a).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, dp(8))
            minimumHeight = dp(52)
            isClickable = true; setOnClickListener { sw.toggle() }
            addView(LinearLayout(a).apply {
                orientation = LinearLayout.VERTICAL
                addView(label(t, 16f)); addView(sub)
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(sw)
        }
        fun refresh(subtitle: String? = null) {
            updating = true; sw.isChecked = get(); updating = false
            sub.text = subtitle ?: ""; sub.visibility = if (subtitle.isNullOrEmpty()) View.GONE else View.VISIBLE
        }
    }

    // ---- segmented choice ----

    inner class Segmented<T>(private val t: String, private val options: List<kotlin.Pair<String, T>>, private val get: () -> T, private val set: (T) -> Unit,
                             private val other: ((T) -> String)? = null) {
        private val cells = ArrayList<TextView>()
        private val head = label(t, 14f, secondary = true).apply { setPadding(0, 0, 0, dp(6)) }
        val view = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(6))
            addView(head)
            addView(LinearLayout(a).apply {
                orientation = LinearLayout.HORIZONTAL
                background = rounded(Color.TRANSPARENT, 20, stroke = if (dark) 0xFF4A4D55.toInt() else 0xFFC4C6CD.toInt())
                setPadding(dp(3), dp(3), dp(3), dp(3))
                for ((name, v) in options) {
                    val cell = TextView(a).apply {
                        text = name; textSize = 14f; gravity = Gravity.CENTER
                        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                        minHeight = dp(40)
                        isClickable = true
                        setOnClickListener { set(v); refresh() }
                    }
                    cells += cell
                    addView(cell, LinearLayout.LayoutParams(0, -2, 1f))
                }
            }, LinearLayout.LayoutParams(-1, -2))
        }
        fun refresh() {
            val cur = get()
            // a value set elsewhere (by the Mac) that isn't one of the buttons: say so in the heading
            head.text = if (other != null && options.none { it.second == cur }) "$t · now ${other.invoke(cur)}" else t
            options.forEachIndexed { i, (_, v) ->
                val on = v == cur
                cells[i].background = if (on) rounded(tonalBg, 17) else ripple(null, 17)
                cells[i].setTextColor(if (on) onTonal else text2)
            }
        }
    }

    // ---- label/value rows ----

    class Row(val label: String, val value: String, val dot: Int? = null)

    /** Rows like "Battery ........ 85 %"; only rebuilt when the number of rows changes. */
    inner class Rows {
        val view = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL }
        fun set(rows: List<Row>, empty: String? = null) {
            val list = if (rows.isEmpty() && empty != null) listOf(Row(empty, "")) else rows
            if (view.childCount != list.size) {
                view.removeAllViews()
                repeat(list.size) {
                    view.addView(LinearLayout(a).apply {
                        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                        setPadding(0, dp(7), 0, dp(7))
                        addView(View(a), LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(10) })
                        addView(label("", 15f, secondary = true).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END },
                            LinearLayout.LayoutParams(0, -2, 1f))
                        addView(label("", 15f).apply { gravity = Gravity.END })
                    })
                }
            }
            list.forEachIndexed { i, r ->
                val row = view.getChildAt(i) as LinearLayout
                val dot = row.getChildAt(0)
                if (r.dot == null) dot.visibility = View.GONE
                else { dot.visibility = View.VISIBLE; dot.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(r.dot) } }
                (row.getChildAt(1) as TextView).text = r.label
                (row.getChildAt(2) as TextView).text = r.value
            }
        }
    }

    // ---- status header ----

    /** Big status line with a coloured dot and a secondary line under it. */
    inner class Status(size: Float = 20f) {
        private val dot = View(a)
        val head = label("", size, bold = true)
        val sub = label("", 14f, secondary = true)
        val view = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            addView(LinearLayout(a).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                addView(dot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(10) })
                addView(head, LinearLayout.LayoutParams(0, -2, 1f))
            })
            addView(sub)
        }
        fun set(color: Int, h: String, s: String) {
            dot.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }
            head.text = h; sub.text = s; sub.visibility = if (s.isEmpty()) View.GONE else View.VISIBLE
        }
    }

    // ---- details ----

    /** "Details ▸" row that shows/hides its views. */
    fun details(t: String, vararg views: View): View {
        val box = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE; views.forEach { addView(it) } }
        val head = label("$t  ▸", 14f).apply {
            setTextColor(accent); setPadding(0, dp(12), 0, dp(4))
            isClickable = true
            setOnClickListener {
                val open = box.visibility != View.VISIBLE
                box.visibility = if (open) View.VISIBLE else View.GONE
                text = "$t  " + if (open) "▾" else "▸"
            }
        }
        return LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; addView(head); addView(box) }
    }

    fun mono(s: String = "") = label(s, 13f, secondary = true).apply { typeface = Typeface.MONOSPACE; setTextIsSelectable(true) }

    fun gone(v: View, hide: Boolean) { v.visibility = if (hide) View.GONE else View.VISIBLE }

    @Suppress("unused") fun match() = ViewGroup.LayoutParams(-1, -2)
}
