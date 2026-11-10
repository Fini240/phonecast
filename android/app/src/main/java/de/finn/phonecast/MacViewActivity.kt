package de.finn.phonecast

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.hypot

/**
 * The Mac's screen on the phone, with touch as mouse:
 *   tap = click, double tap = double click, drag = drag with the left button held,
 *   long press = right click, two-finger tap = right click, two fingers moving = scroll.
 * The bar at the top has a keyboard plus Esc/Tab/arrows and sticky ⌘ ⌥ ⌃ ⇧.
 */
class MacViewActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var keys: KeyCatcher
    private lateinit var msg: TextView
    private var macW = 0
    private var macH = 0
    private var surfaceReady = false

    @Volatile private var codec: MediaCodec? = null
    private var config: ByteArray? = null
    @Volatile private var needKey = true
    private var drainThread: Thread? = null
    private var lastKeyReq = 0L
    private var frames = 0

    private var mods = 0
    private val modViews = HashMap<Int, TextView>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        msg = TextView(this).apply { setTextColor(Color.WHITE); textSize = 16f; gravity = Gravity.CENTER; text = "Connecting to the Mac…" }
        root.addView(msg, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
        keys = KeyCatcher(this)
        root.addView(keys, FrameLayout.LayoutParams(1, 1))
        root.addView(toolbar(), FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
        setContentView(root)
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        surfaceView.setOnTouchListener { _, e -> onTouch(e); true }
    }

    override fun onStart() {
        super.onStart()
        val hub = HubService.instance
        if (hub == null || !hub.connected) {
            msg.text = "Not connected to the Mac.\nOpen PhoneCast on the Mac first (it connects by itself)."
            return
        }
        hub.screenSink = { type, p -> onPacket(type, p) }
        val dm = resources.displayMetrics
        val long = maxOf(dm.widthPixels, dm.heightPixels).coerceIn(1280, 2560)
        hub.send(HubProto.SCREEN_START, ByteBuffer.allocate(3).putShort(long.toShort()).put(20.toByte()).array())
    }

    override fun onStop() {
        super.onStop()
        HubService.instance?.let { it.screenSink = null; it.send(HubProto.SCREEN_STOP) }
        releaseCodec()
    }

    // ---- video ----

    private fun onPacket(type: Int, p: ByteArray) {
        when (type) {
            -1 -> runOnUiThread { msg.visibility = View.VISIBLE; msg.text = "The Mac disconnected." }
            HubProto.SCREEN_DENIED -> runOnUiThread { msg.visibility = View.VISIBLE; msg.text = String(p) }
            HubProto.SCREEN_FORMAT -> {
                val b = ByteBuffer.wrap(p)
                macW = b.int; macH = b.int
                runOnUiThread { layoutSurface() }
            }
            HubProto.SCREEN_CONFIG -> {
                if (config?.contentEquals(p) != true) { config = p; releaseCodec() }
            }
            HubProto.SCREEN_FRAME -> frame(p)
        }
    }

    private fun layoutSurface() {
        if (macW == 0) return
        val vw = root.width; val vh = root.height
        if (vw == 0) { root.post { layoutSurface() }; return }
        val s = minOf(vw.toFloat() / macW, vh.toFloat() / macH)
        surfaceView.layoutParams = FrameLayout.LayoutParams((macW * s).toInt(), (macH * s).toInt(), Gravity.CENTER)
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        root.post { layoutSurface() }
    }

    private fun ensureCodec(): MediaCodec? {
        codec?.let { return it }
        val cfg = config ?: return null
        if (!surfaceReady || macW == 0) return null
        return try {
            val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, macW, macH)
            f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            f.setInteger(MediaFormat.KEY_PRIORITY, 0)
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            c.configure(f, surfaceView.holder.surface, null, 0)
            c.start()
            val i = c.dequeueInputBuffer(100_000)
            if (i >= 0) {
                c.getInputBuffer(i)!!.put(cfg)
                c.queueInputBuffer(i, 0, cfg.size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
            }
            codec = c
            needKey = true
            drainThread = Thread({ drain(c) }, "mac-decode").also { it.start() }
            c
        } catch (e: Exception) {
            Log.e("PhoneCastMac", "decoder", e); null
        }
    }

    private fun frame(p: ByteArray) {
        val key = p[0].toInt() == 1
        val c = ensureCodec() ?: return askKey()
        if (needKey && !key) return askKey()
        try {
            val i = c.dequeueInputBuffer(20_000)
            if (i < 0) { needKey = true; return askKey() }
            c.getInputBuffer(i)!!.put(p, 1, p.size - 1)
            c.queueInputBuffer(i, 0, p.size - 1, SystemClock.uptimeMillis() * 1000, 0)
            needKey = false
            if (frames++ == 0) runOnUiThread { msg.visibility = View.GONE }
        } catch (e: Exception) {
            Log.w("PhoneCastMac", "queue", e); releaseCodec()
        }
    }

    private fun askKey() {
        val now = SystemClock.uptimeMillis()
        if (now - lastKeyReq < 300) return
        lastKeyReq = now
        HubService.instance?.send(HubProto.SCREEN_KEY)
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (codec === c) {
                val o = c.dequeueOutputBuffer(info, 50_000)
                if (o >= 0) c.releaseOutputBuffer(o, true)
            }
        } catch (_: Exception) {}
    }

    private fun releaseCodec() {
        val c = codec ?: return
        codec = null
        try { drainThread?.join(200) } catch (_: Exception) {}
        try { c.stop() } catch (_: Exception) {}
        try { c.release() } catch (_: Exception) {}
        needKey = true
    }

    override fun surfaceCreated(h: SurfaceHolder) { surfaceReady = true; askKey() }
    override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
    override fun surfaceDestroyed(h: SurfaceHolder) { surfaceReady = false; releaseCodec() }

    // ---- touch -> mouse ----

    private var downX = 0f; private var downY = 0f; private var downAt = 0L
    private var dragging = false; private var moved = false
    private var twoFinger = false; private var twoMoved = false
    private var lastMidX = 0f; private var lastMidY = 0f
    private var scrollRestX = 0f; private var scrollRestY = 0f
    private val longPress = Runnable {
        if (!moved && !twoFinger) { click(1, downX, downY); longFired = true; vibrate() }
    }
    private var longFired = false

    private fun nx(x: Float) = (x / surfaceView.width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / surfaceView.height).coerceIn(0f, 1f)

    private fun pos(x: Float, y: Float): ByteArray {
        val ux = (nx(x) * 65535).toInt(); val uy = (ny(y) * 65535).toInt()
        return byteArrayOf((ux shr 8).toByte(), ux.toByte(), (uy shr 8).toByte(), uy.toByte())
    }

    private fun input(vararg parts: ByteArray) {
        val total = parts.sumOf { it.size }
        val b = ByteBuffer.allocate(total); parts.forEach { b.put(it) }
        HubService.instance?.send(HubProto.INPUT, b.array())
    }

    private fun move(x: Float, y: Float) = input(byteArrayOf(HubProto.IN_MOVE.toByte()), pos(x, y))
    private fun button(down: Boolean, btn: Int, x: Float, y: Float) =
        input(byteArrayOf((if (down) HubProto.IN_DOWN else HubProto.IN_UP).toByte(), btn.toByte()), pos(x, y))
    private fun click(btn: Int, x: Float, y: Float) { button(true, btn, x, y); button(false, btn, x, y) }

    private fun onTouch(e: MotionEvent) {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x; downY = e.y; downAt = SystemClock.uptimeMillis()
                moved = false; dragging = false; twoFinger = false; twoMoved = false; longFired = false
                move(e.x, e.y)
                surfaceView.postDelayed(longPress, 550)
            }
            MotionEvent.ACTION_POINTER_DOWN -> if (e.pointerCount == 2) {
                surfaceView.removeCallbacks(longPress)
                if (dragging) { button(false, 0, e.getX(0), e.getY(0)); dragging = false }
                twoFinger = true
                lastMidX = (e.getX(0) + e.getX(1)) / 2; lastMidY = (e.getY(0) + e.getY(1)) / 2
            }
            MotionEvent.ACTION_MOVE -> {
                if (twoFinger && e.pointerCount >= 2) {
                    val mx = (e.getX(0) + e.getX(1)) / 2; val my = (e.getY(0) + e.getY(1)) / 2
                    scrollRestX += mx - lastMidX; scrollRestY += my - lastMidY
                    lastMidX = mx; lastMidY = my
                    // phone pixels -> Mac pixels, natural scrolling (content follows the fingers)
                    val k = if (macW > 0) macW.toFloat() / surfaceView.width else 1f
                    val dx = (scrollRestX * k).toInt(); val dy = (scrollRestY * k).toInt()
                    if (abs(dx) >= 2 || abs(dy) >= 2) {
                        twoMoved = true
                        scrollRestX = 0f; scrollRestY = 0f
                        input(byteArrayOf(HubProto.IN_SCROLL.toByte()),
                            ByteBuffer.allocate(4).putShort(dx.coerceIn(-32000, 32000).toShort()).putShort(dy.coerceIn(-32000, 32000).toShort()).array())
                    }
                    return
                }
                if (twoFinger || longFired) return
                if (!moved && hypot(e.x - downX, e.y - downY) > 12 * resources.displayMetrics.density) {
                    moved = true
                    surfaceView.removeCallbacks(longPress)
                    button(true, 0, downX, downY); dragging = true
                }
                if (dragging) move(e.x, e.y)
            }
            MotionEvent.ACTION_UP -> {
                surfaceView.removeCallbacks(longPress)
                when {
                    twoFinger -> if (!twoMoved) click(1, downX, downY)
                    longFired -> {}
                    dragging -> button(false, 0, e.x, e.y)
                    else -> click(0, downX, downY)
                }
                dragging = false
            }
            MotionEvent.ACTION_CANCEL -> {
                surfaceView.removeCallbacks(longPress)
                if (dragging) button(false, 0, e.x, e.y)
                dragging = false
            }
        }
    }

    private fun vibrate() {
        surfaceView.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
    }

    // ---- keyboard ----

    fun sendText(t: String) {
        if (t.isEmpty()) return
        input(byteArrayOf(HubProto.IN_TEXT.toByte(), mods.toByte()), t.toByteArray())
        clearMods()
    }

    fun sendKey(code: Int) {
        input(byteArrayOf(HubProto.IN_KEY.toByte(), (code shr 8).toByte(), code.toByte(), mods.toByte()))
        clearMods()
    }

    private fun clearMods() {
        if (mods == 0) return
        mods = 0
        runOnUiThread { modViews.values.forEach { it.alpha = 0.55f } }
    }

    private fun toolbar(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(12, 6, 12, 6)
            background = GradientDrawable().apply { cornerRadius = 40f; setColor(Color.argb(170, 20, 20, 20)) }
        }
        fun b(label: String, onTap: (TextView) -> Unit) = TextView(this).apply {
            text = label; setTextColor(Color.WHITE); textSize = 15f
            setPadding(22, 12, 22, 12); alpha = 0.85f
            setOnClickListener { onTap(this) }
            row.addView(this)
        }
        b("⌨") { showKeyboard() }
        b("esc") { sendKey(53) }
        b("tab") { sendKey(48) }
        b("←") { sendKey(123) }; b("→") { sendKey(124) }; b("↑") { sendKey(126) }; b("↓") { sendKey(125) }
        for ((label, bit) in listOf("⌘" to HubProto.MOD_CMD, "⌥" to HubProto.MOD_OPT, "⌃" to HubProto.MOD_CTRL, "⇧" to HubProto.MOD_SHIFT)) {
            modViews[bit] = b(label) { v ->
                mods = mods xor bit
                v.alpha = if (mods and bit != 0) 1f else 0.55f
                v.setBackgroundColor(if (mods and bit != 0) Color.argb(120, 80, 140, 255) else Color.TRANSPARENT)
            }.also { it.alpha = 0.55f }
        }
        b("✕") { finish() }
        return HorizontalScrollView(this).apply { addView(row); isHorizontalScrollBarEnabled = false }
            .also { (it.layoutParams as? ViewGroup.MarginLayoutParams)?.topMargin = 8 }
    }

    private fun showKeyboard() {
        keys.requestFocus()
        getSystemService(InputMethodManager::class.java).showSoftInput(keys, 0)
    }

    /** Invisible view that takes the soft keyboard's input and forwards it to the Mac. */
    private class KeyCatcher(val a: MacViewActivity) : View(a) {
        init { isFocusable = true; isFocusableInTouchMode = true }
        override fun onCheckIsTextEditor() = true
        override fun onCreateInputConnection(out: EditorInfo): InputConnection {
            // "visible password" keeps keyboards from holding text back for autocorrect
            out.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_ACTION_NONE
            return object : BaseInputConnection(this, false) {
                override fun commitText(text: CharSequence, pos: Int): Boolean {
                    val s = text.toString()
                    if (s == "\n") a.sendKey(36) else a.sendText(s)
                    return true
                }
                override fun deleteSurroundingText(before: Int, after: Int): Boolean {
                    repeat(before.coerceAtMost(50)) { a.sendKey(51) }
                    repeat(after.coerceAtMost(50)) { a.sendKey(117) }
                    return true
                }
                override fun sendKeyEvent(e: KeyEvent): Boolean {
                    if (e.action == KeyEvent.ACTION_DOWN) handleKey(e)
                    return true
                }
                override fun performEditorAction(action: Int): Boolean { a.sendKey(36); return true }
            }
        }
        override fun onKeyDown(keyCode: Int, e: KeyEvent): Boolean = handleKey(e) || super.onKeyDown(keyCode, e)

        fun handleKey(e: KeyEvent): Boolean {
            val mac = when (e.keyCode) {
                KeyEvent.KEYCODE_DEL -> 51; KeyEvent.KEYCODE_FORWARD_DEL -> 117
                KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 36
                KeyEvent.KEYCODE_TAB -> 48; KeyEvent.KEYCODE_ESCAPE -> 53
                KeyEvent.KEYCODE_DPAD_LEFT -> 123; KeyEvent.KEYCODE_DPAD_RIGHT -> 124
                KeyEvent.KEYCODE_DPAD_UP -> 126; KeyEvent.KEYCODE_DPAD_DOWN -> 125
                else -> -1
            }
            if (mac >= 0) { a.sendKey(mac); return true }
            val ch = e.unicodeChar
            if (ch != 0) { a.sendText(String(Character.toChars(ch))); return true }
            return false
        }
    }
}
