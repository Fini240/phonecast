package de.finn.phonecast

import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan

/** Terminal text with ANSI SGR colours (16, 256 and true colour, bold, dim, italic, underline, inverse) → spans. */
object Ansi {
    private val base16 = intArrayOf(
        0xFF1E1E1E.toInt(), 0xFFE5534B.toInt(), 0xFF57AB5A.toInt(), 0xFFC69026.toInt(), 0xFF539BF5.toInt(), 0xFFB083F0.toInt(), 0xFF39C5CF.toInt(), 0xFFD0D0D0.toInt(),
        0xFF767676.toInt(), 0xFFFF6B66.toInt(), 0xFF6BC46D.toInt(), 0xFFDAAA3F.toInt(), 0xFF6CB6FF.toInt(), 0xFFDCBDFB.toInt(), 0xFF56D4DD.toInt(), 0xFFFFFFFF.toInt(),
    )

    private fun c256(n: Int): Int = when {
        n < 16 -> base16[n]
        n < 232 -> { val i = n - 16; val r = i / 36; val g = (i / 6) % 6; val b = i % 6
            fun v(x: Int) = if (x == 0) 0 else 55 + x * 40
            (0xFF shl 24) or (v(r) shl 16) or (v(g) shl 8) or v(b) }
        else -> { val v = 8 + (n - 232) * 10; (0xFF shl 24) or (v shl 16) or (v shl 8) or v }
    }

    private val sgr = Regex("\u001B\\[([0-9;:]*)m")
    private val other = Regex("\u001B(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u0007\u001B]*(\u0007|\u001B\\\\)|[@-Z\\\\-_])")

    /** [fg] is the default text colour (dark/light theme); dim text is drawn at half opacity. */
    fun spans(text: String, fg: Int): CharSequence {
        val sb = SpannableStringBuilder()
        var cur: Int? = null; var bg: Int? = null; var bold = false; var dim = false; var italic = false; var under = false; var inverse = false
        var runStart = 0
        fun flush() {
            if (sb.length == runStart) return
            var f = cur ?: fg; var b = bg
            if (inverse) { val t = f; f = b ?: (fg xor 0x00FFFFFF); b = t }
            if (dim) f = (f and 0x00FFFFFF) or (0x80 shl 24)
            if (f != fg || dim) sb.setSpan(ForegroundColorSpan(f), runStart, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (b != null) sb.setSpan(BackgroundColorSpan(b), runStart, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (bold || italic) sb.setSpan(StyleSpan(if (bold && italic) Typeface.BOLD_ITALIC else if (bold) Typeface.BOLD else Typeface.ITALIC), runStart, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (under) sb.setSpan(UnderlineSpan(), runStart, sb.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            runStart = sb.length
        }
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            if (ch == '\u001B') {
                val m = sgr.matchAt(text, i)
                if (m != null) {
                    flush()
                    val p = m.groupValues[1].split(';', ':').map { it.toIntOrNull() ?: 0 }
                    var k = 0
                    while (k < p.size) {
                        when (val v = p[k]) {
                            0 -> { cur = null; bg = null; bold = false; dim = false; italic = false; under = false; inverse = false }
                            1 -> bold = true; 2 -> dim = true; 3 -> italic = true; 4 -> under = true; 7 -> inverse = true
                            22 -> { bold = false; dim = false }; 23 -> italic = false; 24 -> under = false; 27 -> inverse = false
                            in 30..37 -> cur = base16[v - 30]; 39 -> cur = null
                            in 40..47 -> bg = base16[v - 40]; 49 -> bg = null
                            in 90..97 -> cur = base16[v - 90 + 8]; in 100..107 -> bg = base16[v - 100 + 8]
                            38, 48 -> {
                                val col = if (p.getOrNull(k + 1) == 5) { k += 2; c256(p.getOrElse(k) { 0 }) }
                                    else if (p.getOrNull(k + 1) == 2) { k += 4; (0xFF shl 24) or (p.getOrElse(k - 2) { 0 } shl 16) or (p.getOrElse(k - 1) { 0 } shl 8) or p.getOrElse(k) { 0 } }
                                    else null
                                if (v == 38) cur = col else bg = col
                            }
                        }
                        k++
                    }
                    i = m.range.last + 1; continue
                }
                val o = other.matchAt(text, i)
                if (o != null) { i = o.range.last + 1; continue }
                i++; continue
            }
            sb.append(ch); i++
        }
        flush()
        // trailing blank lines of the pane
        var end = sb.length
        while (end > 0 && (sb[end - 1] == '\n' || sb[end - 1] == ' ')) end--
        return sb.subSequence(0, end)
    }
}
