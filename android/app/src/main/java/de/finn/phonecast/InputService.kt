package de.finn.phonecast

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * Turns the Mac's mouse/keyboard into touches. Android only lets an app inject touches
 * through an accessibility service, as gestures. To get real multi-touch (joystick held
 * while aiming and shooting) every active finger is a "continued stroke": each update
 * dispatches one gesture that continues every finger that is still down. Updates that
 * arrive while a gesture is in flight are merged into the next one.
 */
class InputService : AccessibilityService() {

    companion object {
        @Volatile var instance: InputService? = null
            private set
        @Volatile var onControlChanged: ((Boolean) -> Unit)? = null

        private const val MOVE_MS = 4L
        private const val TAP_MS = 30L
    }

    private class Finger(var x: Float, var y: Float) {
        var lastX = x
        var lastY = y
        var stroke: GestureDescription.StrokeDescription? = null
        var up = false
        /** Where the finger first went down (the joystick's centre). */
        val downX = x
        val downY = y
        /** After a re-press, hold still until then so the game registers the touch before the slide. */
        var holdUntil = 0L
    }

    private val main = Handler(Looper.getMainLooper())
    private val fingers = HashMap<Int, Finger>()
    /** Fingers whose lift hasn't been sent yet but whose id was already reused for a new touch. */
    private val ending = ArrayList<Finger>()
    private var inFlight = false
    private var inFlightSince = 0L
    private var dirty = false
    private var stats = IntArray(4) // dispatched, completed, cancelled, rejected
    /**
     * Pointer ids MotionEventInjector has handed out since all fingers were last up. It never frees
     * an id while any finger stays down and gives out 0..9, then 10 for *every* further finger; two
     * of those at once corrupt InputDispatcher's state (phantom pointers, 07.11.2026). So before the
     * ids run out we lift every finger for one step and press the held ones again: that frees all ids.
     */
    private var idsUsed = 0
    /** Human-readable description of the last two gestures sent (debugging cancels). */
    private var lastDesc = ""
    private var prevDesc = ""

    /** If Android never answers a gesture, every later touch would wait forever. Unstick after 400 ms. */
    private val watchdog = object : Runnable {
        override fun run() {
            if (inFlight && android.os.SystemClock.uptimeMillis() - inFlightSince > 400) {
                android.util.Log.w("PhoneCastInput", "gesture stuck, resetting (stats ${stats.toList()})")
                // Keep the strokes: the next gesture must *continue* them. Restarting them as fresh
                // touches makes MotionEventInjector cancel its open gesture with a one-pointer
                // ACTION_CANCEL, which InputDispatcher rejects when 2+ fingers are down -> phantom
                // pointers that block every later injected touch. If Android really dropped the
                // gesture, the continuation is refused without any cancel event and onCancelled
                // restarts the fingers safely.
                inFlight = false
                if (dirty) flush()
            }
            main.postDelayed(this, 200)
        }
    }

    /**
     * After an unlock: if sharing ended because the phone locked, open PhoneCast's "share screen"
     * prompt right away (an accessibility service may start activities from the background).
     */
    private val unlockReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(c: android.content.Context, i: android.content.Intent) {
            if (!CaptureService.stoppedByLock || CaptureService.instance != null) return
            CaptureService.stoppedByLock = false
            try {
                startActivity(android.content.Intent(c, MainActivity::class.java)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra(MainActivity.EXTRA_RESUME, true))
            } catch (e: Exception) { android.util.Log.w("PhoneCastInput", "couldn't reopen sharing", e) }
        }
    }

    override fun onServiceConnected() {
        instance = this
        val unlock = android.content.IntentFilter(android.content.Intent.ACTION_USER_PRESENT)
        if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(unlockReceiver, unlock, RECEIVER_EXPORTED)
        else registerReceiver(unlockReceiver, unlock)
        main.postDelayed(watchdog, 200)
        onControlChanged?.invoke(true)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        onControlChanged?.invoke(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        try { unregisterReceiver(unlockReceiver) } catch (_: Exception) {}
        instance = null
        onControlChanged?.invoke(false)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** Called from the network thread. */
    fun handle(type: Int, p: ByteArray) {
        main.post {
            try {
                when (type) {
                    Proto.TOUCH -> if (p.size >= 6) touch(p)
                    Proto.GLOBAL -> if (p.isNotEmpty()) global(p[0].toInt())
                    Proto.TEXT -> insertText(String(p, Charsets.UTF_8))
                    Proto.KEY -> if (p.isNotEmpty()) key(p[0].toInt())
                }
            } catch (_: Exception) {}
        }
    }

    // ---- touches ----

    private fun screen(): Pair<Int, Int> {
        val d = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val m = DisplayMetrics()
        @Suppress("DEPRECATION") d.getRealMetrics(m)
        return m.widthPixels to m.heightPixels
    }

    private fun touch(p: ByteArray) {
        val b = ByteBuffer.wrap(p)
        val action = b.get().toInt()
        val id = b.get().toInt()
        if (action != Proto.TOUCH_MOVE) {
            android.util.Log.i("PhoneCastInput", "touch ${listOf("down", "move", "up", "cancelAll")[action.coerceIn(0, 3)]} finger=$id fingersNow=${fingers.keys}")
        }
        if (action == Proto.TOUCH_CANCEL_ALL) {
            for (f in fingers.values) f.up = true
            schedule()
            return
        }
        val nx = (b.short.toInt() and 0xffff) / 65535f
        val ny = (b.short.toInt() and 0xffff) / 65535f
        val (w, h) = screen()
        // Whole pixels: stroke end points then come out of PathMeasure exactly, so a continuation
        // always starts bit-for-bit where Android thinks the previous stroke ended.
        val x = Math.round(nx * (w - 1)).toFloat().coerceIn(0f, w - 1f)
        val y = Math.round(ny * (h - 1)).toFloat().coerceIn(0f, h - 1f)

        when (action) {
            Proto.TOUCH_DOWN -> {
                val f = fingers[id]
                if (f != null && f.up && f.stroke != null) ending.add(f) // must still send its lift
                if (f == null || f.up) fingers[id] = Finger(x, y) else { f.x = x; f.y = y }
            }
            Proto.TOUCH_MOVE -> fingers[id]?.let { it.x = x; it.y = y }
            Proto.TOUCH_UP -> fingers[id]?.let { it.x = x; it.y = y; it.up = true }
        }
        schedule()
    }

    private fun schedule() {
        dirty = true
        if (!inFlight) flush()
    }

    private fun flush() {
        if (!dirty || (fingers.isEmpty() && ending.isEmpty())) { dirty = false; return }
        dirty = false

        val builder = GestureDescription.Builder()
        var count = 0
        // Android (MotionEventInjector.prepareToContinueOldGesture) counts *every* finger present at
        // t=0 of a continuing gesture and cancels unless that equals the fingers already down. So a
        // new finger may join a held gesture only if it starts after t=0.
        val continuing = fingers.values.any { it.stroke != null } || ending.isNotEmpty()
        // A finger whose id is being reused (look re-centre: lift + press again) must not overlap
        // its old stroke: with two touches in the look area at once, the game keeps following the old
        // one and ignores the new one, so aim cut out until the next re-centre. So new fingers start
        // after the lifts (t 4 ms) when anything is being lifted.
        val newStart = if (ending.isNotEmpty()) MOVE_MS + 2 else if (continuing) 2L else 0L
        // Order matters: MotionEventInjector.appendDownEvents uses the stroke's index in *our* list as the
        // new pointer's index in *its* list. That only lines up if every new finger comes after all
        // fingers that are already down. So: continuing fingers first, new fingers last.
        val all = ArrayList<Pair<Int?, Finger>>()
        for (f in ending) all.add(null to f)
        for ((k, f) in fingers.entries.sortedBy { it.key }) if (f.stroke != null) all.add(k to f)
        for ((k, f) in fingers.entries.sortedBy { it.key }) if (f.stroke == null) all.add(k to f)
        // A gesture in which no finger starts, ends or moves makes MotionEventInjector generate no
        // events at all, and it reports that as *cancelled*. onCancelled would then restart every
        // finger as a fresh touch -> one-pointer ACTION_CANCEL -> phantom pointers with 2+ fingers
        // (the "inputs stuck" bug, 07.11.2026). So never send such a gesture.
        val now = android.os.SystemClock.uptimeMillis()
        fun tx(f: Finger) = if (now < f.holdUntil) f.lastX else f.x
        fun ty(f: Finger) = if (now < f.holdUntil) f.lastY else f.y
        val holding = all.filter { (_, f) -> now < f.holdUntil }.maxOfOrNull { it.second.holdUntil }
        if (holding != null) main.postAtTime({ dirty = true; if (!inFlight) flush() }, holding + 1)
        if (ending.isEmpty() && all.all { (_, f) -> f.stroke != null && !f.up && abs(f.lastX - tx(f)) < 0.5f && abs(f.lastY - ty(f)) < 0.5f }) return
        val newCount = all.count { it.second.stroke == null }
        if (continuing && idsUsed + newCount > 9) { refresh(all); return }
        ending.clear()
        val desc = StringBuilder()
        for ((key, f) in all) {
            if (count >= GestureDescription.getMaxStrokeCount()) break
            val path = Path().apply {
                moveTo(f.lastX, f.lastY)
                lineTo(tx(f), ty(f))
            }
            val cont = !f.up
            val prev = f.stroke
            val stroke = if (prev == null) {
                GestureDescription.StrokeDescription(path, newStart, if (f.up) TAP_MS else 1L, cont)
            } else {
                // A held finger must still be active when the new ones go down: appendDownEvents
                // takes the new pointer's index from the strokes active at that moment.
                prev.continueStroke(path, 0, if (cont) maxOf(MOVE_MS, newStart + 1) else MOVE_MS, cont)
            }
            builder.addStroke(stroke)
            desc.append("[k=$key ${if (prev == null) "new" else "cont"} t=${stroke.startTime}+${stroke.duration} ${f.lastX},${f.lastY}->${tx(f)},${ty(f)}${if (cont) " c" else " END"}]")
            count++
            f.stroke = stroke
            // Android only accepts the next continuation if it starts *exactly* where it thinks this
            // stroke ended. Compute that end point exactly like GestureDescription does
            // (PathMeasure.getPosTan(length)), not the target we asked for.
            val end = androidEndPoint(path, stroke.duration)
            f.lastX = end?.get(0) ?: tx(f)
            f.lastY = end?.get(1) ?: ty(f)
            if (f.up && key != null && fingers[key] === f) fingers.remove(key)
        }
        if (count == 0) return
        idsUsed = if (fingers.isEmpty()) 0 else idsUsed + newCount
        send(builder, desc)
    }

    /** Lift every finger (t 0..4 ms), then press the held ones again (t 6 ms): frees all pointer ids. */
    private fun refresh(all: List<Pair<Int?, Finger>>) {
        ending.clear()
        val builder = GestureDescription.Builder()
        val desc = StringBuilder("REFRESH ")
        val press = ArrayList<Pair<Int?, Finger>>()
        for ((key, f) in all) {
            val prev = f.stroke
            if (prev != null) {
                val path = Path().apply { moveTo(f.lastX, f.lastY); lineTo(f.lastX, f.lastY) }
                builder.addStroke(prev.continueStroke(path, 0, MOVE_MS, false))
                desc.append("[k=$key END]")
            }
            if (key != null && fingers[key] === f) {
                if (f.up) fingers.remove(key)
                if (!f.up || prev == null) press.add(key to f)
            }
        }
        val start = MOVE_MS + 2
        for ((key, f) in press) {
            if (f.up) { // a tap that hadn't been sent yet
                builder.addStroke(GestureDescription.StrokeDescription(Path().apply { moveTo(f.x, f.y); lineTo(f.x, f.y) }, start, TAP_MS, false))
                f.stroke = null
                continue
            }
            // The joystick (Mac finger 1) goes back to its centre and slides out again after a pause,
            // because Fortnite's joystick only moves for a sliding finger. Everything else (look,
            // held buttons) is pressed again right where it is.
            val joy = key == 1
            val px = if (joy) f.downX else f.lastX
            val py = if (joy) f.downY else f.lastY
            val stroke = GestureDescription.StrokeDescription(Path().apply { moveTo(px, py); lineTo(px, py) }, start, 1L, true)
            builder.addStroke(stroke)
            desc.append("[k=$key new@$px,$py]")
            f.stroke = stroke
            f.lastX = px; f.lastY = py
            // Hold every re-pressed finger still briefly so the game registers the new touch before
            // it moves (otherwise the start of the movement is lost: aim "steps").
            f.holdUntil = android.os.SystemClock.uptimeMillis() + if (joy) 40 else 25
        }
        idsUsed = press.count { !it.second.up }
        dirty = true // whatever moved meanwhile, and the joystick slide, follow in the next gesture
        android.util.Log.i("PhoneCastInput", "pointer ids refreshed: $desc")
        send(builder, desc)
    }

    private fun send(builder: GestureDescription.Builder, desc: StringBuilder) {

        inFlight = true
        inFlightSince = android.os.SystemClock.uptimeMillis()
        stats[0]++
        prevDesc = lastDesc
        lastDesc = desc.toString()
        val ok = dispatchGesture(builder.build(), object : GestureResultCallback() {
            override fun onCompleted(g: GestureDescription?) {
                stats[1]++
                inFlight = false
                if (dirty) flush()
            }

            override fun onCancelled(g: GestureDescription?) {
                stats[2]++
                android.util.Log.w("PhoneCastInput", "gesture cancelled with ${fingers.size} fingers ${fingers.keys} (stats ${stats.toList()})\n  prev: $prevDesc\n  last: $lastDesc")
                inFlight = false
                // the system dropped our fingers (e.g. the user touched the real screen):
                // start the remaining ones again as fresh touches
                ending.clear()
                idsUsed = 0 // Android cleared its pointer ids with the cancel
                for (f in fingers.values) f.stroke = null
                dirty = fingers.isNotEmpty()
                if (dirty) flush()
            }
        }, main)
        if (!ok) {
            stats[3]++
            android.util.Log.w("PhoneCastInput", "gesture rejected (stats ${stats.toList()})")
            inFlight = false
            for (f in fingers.values) f.stroke = null
        }
    }

    private val endPos = FloatArray(2)
    /** null for a zero-length path (finger didn't move): then the end is simply the point itself. */
    private fun androidEndPoint(path: Path, duration: Long): FloatArray? {
        val pm = android.graphics.PathMeasure(path, false)
        if (pm.length <= 0f) return null
        // StrokeDescription.getPosForTime(endTime) = mPathMeasure.getPosTan(getLength(), ...)
        if (!pm.getPosTan(pm.length, endPos, null)) return null
        return floatArrayOf(endPos[0], endPos[1])
    }

    // ---- buttons & typing ----

    private fun global(a: Int) {
        when (a) {
            Proto.GLOBAL_BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            Proto.GLOBAL_HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            Proto.GLOBAL_RECENTS -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            Proto.GLOBAL_NOTIFICATIONS -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
        }
    }

    private fun focused(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun currentText(n: AccessibilityNodeInfo): String =
        if (n.isShowingHintText) "" else (n.text?.toString() ?: "")

    private fun setText(n: AccessibilityNodeInfo, text: String, cursor: Int) {
        n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        })
        n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
        })
    }

    private fun selection(n: AccessibilityNodeInfo, len: Int): Pair<Int, Int> {
        var s = n.textSelectionStart
        var e = n.textSelectionEnd
        if (s < 0 || e < 0) { s = len; e = len }
        if (s > e) { val t = s; s = e; e = t }
        return s.coerceIn(0, len) to e.coerceIn(0, len)
    }

    private fun insertText(s: String) {
        val n = focused() ?: return
        val cur = currentText(n)
        val (a, b) = selection(n, cur.length)
        setText(n, cur.substring(0, a) + s + cur.substring(b), a + s.length)
    }

    private fun key(k: Int) {
        val n = focused() ?: return
        when (k) {
            Proto.KEY_BACKSPACE -> {
                val cur = currentText(n)
                var (a, b) = selection(n, cur.length)
                if (a == b) {
                    if (a == 0) return
                    a = cur.offsetByCodePoints(a, -1)
                }
                setText(n, cur.substring(0, a) + cur.substring(b), a)
            }
            Proto.KEY_ENTER -> n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
        }
    }
}
