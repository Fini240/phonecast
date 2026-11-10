package de.finn.phonecast

import android.content.Context
import java.security.SecureRandom

/**
 * Wire protocol (all integers big-endian).
 *
 * Phone -> Mac:  [u8 type][u32 length][payload]
 * Mac -> Phone:  [u8 type][u16 length][payload]
 *
 * The first thing the Mac sends is HELLO with the pairing PIN. Nothing is
 * streamed and no input is accepted until the PIN matches.
 */
object Proto {
    const val PORT = 27183
    const val UDP_PORT = 27184     // Wi-Fi video datagrams (UdpVideo)
    const val SERVICE_TYPE = "_phonecast._tcp"

    // phone -> mac
    const val FORMAT: Int = 0      // u32 width, u32 height
    const val CONFIG: Int = 1      // H.264 SPS/PPS, Annex B
    const val FRAME: Int = 2       // u8 keyframe, then Annex B access unit
    const val AUDIO: Int = 3       // PCM s16le, 48 kHz, stereo
    const val HELLO_OK: Int = 4    // u8 controlAvailable
    const val HELLO_BAD: Int = 5
    const val CONTROL: Int = 6     // u8 controlAvailable (sent when it changes)
    const val PONG: Int = 7        // echo of PING payload
    const val RES_RESULT: Int = 8  // u8 DisplaySize result
    const val STATS: Int = 14      // u32 video resyncs since connecting, then PhoneStats (optional)
    const val STOPPED: Int = 19    // u8 reason (STOP_*): sharing ends now, the connection closes next
    const val UDP_TOKEN: Int = 20  // u32 token: send "PCU1"+token to UDP_PORT to get video over UDP
    const val UDP_ON: Int = 21     // video now arrives over UDP (FRAME stops on TCP)
    const val UDP_OFF: Int = 22    // video back on TCP
    const val NONCE: Int = 23      // 16 bytes, sent first: the Mac answers HELLO "T1:"+HMAC(mirror key, nonce) or the PIN
    const val STOP_USER = 0
    const val STOP_LOCKED = 1      // Android ends screen capture when the phone locks

    // mac -> phone
    const val HELLO: Int = 9       // utf8 PIN
    const val TOUCH: Int = 10      // u8 action, u8 pointer, u16 x, u16 y (0..65535 of the screen)
    const val GLOBAL: Int = 11     // u8 action
    const val TEXT: Int = 12       // utf8
    const val KEY: Int = 13        // u8 key
    const val KEYFRAME: Int = 15   // request a keyframe
    const val PING: Int = 16       // 8 bytes, echoed back as PONG
    const val SETTINGS: Int = 17   // u16 maxSize (0 = native), u8 bitrate Mbit/s
    const val RESOLUTION: Int = 18 // u16 w, u16 h: wanted landscape shape (0,0 = phone's normal shape),
                                   // optional u16 long side to render at (0 = the panel's own pixels)

    const val TOUCH_DOWN = 0
    const val TOUCH_MOVE = 1
    const val TOUCH_UP = 2
    const val TOUCH_CANCEL_ALL = 3

    const val GLOBAL_BACK = 1
    const val GLOBAL_HOME = 2
    const val GLOBAL_RECENTS = 3
    const val GLOBAL_NOTIFICATIONS = 4
    const val GLOBAL_QUICK_SETTINGS = 5
    const val GLOBAL_POWER_DIALOG = 6
    const val GLOBAL_LOCK = 7
    const val GLOBAL_SCREENSHOT = 8
    const val GLOBAL_SPLIT = 9
    const val GLOBAL_VOLUME_UP = 10
    const val GLOBAL_VOLUME_DOWN = 11
    const val GLOBAL_MUTE = 12
    const val GLOBAL_TORCH = 13

    const val KEY_BACKSPACE = 1
    const val KEY_ENTER = 2
}

object Prefs {
    private const val NAME = "phonecast"

    private fun p(c: Context) = c.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    fun pin(c: Context): String {
        val existing = p(c).getString("pin", null)
        if (existing != null) return existing
        val pin = (100000 + SecureRandom().nextInt(900000)).toString()
        p(c).edit().putString("pin", pin).apply()
        return pin
    }

    fun newPin(c: Context): String {
        p(c).edit().remove("pin").remove("token").apply()   // also forgets every paired Mac's mirror key
        return pin(c)
    }

    /** Random mirror key, handed to the Mac over the encrypted link (see Auth). */
    fun token(c: Context): String {
        p(c).getString("token", null)?.let { return it }
        val t = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        p(c).edit().putString("token", t).apply()
        return t
    }

    /** Copy on the phone -> Mac clipboard automatically (needs the accessibility service). */
    fun autoClip(c: Context): Boolean = p(c).getBoolean("autoClip", true)
    fun setAutoClip(c: Context, v: Boolean) = p(c).edit().putBoolean("autoClip", v).apply()

    /** Hermes dashboard address ("" = learn it from the Mac; no PC tab without one). */
    fun dashboard(c: Context): String = p(c).getString("dashboard", "") ?: ""
    fun setDashboard(c: Context, v: String) = p(c).edit().putString("dashboard", v).apply()

    /** The PC's network card address for Wake-on-LAN ("" = not set). */
    fun pcMac(c: Context): String = p(c).getString("pcMac", "") ?: ""
    fun setPcMac(c: Context, v: String) = p(c).edit().putString("pcMac", v).apply()

    /** Longest side of the video in pixels; 0 = native resolution. */
    fun maxSize(c: Context): Int = p(c).getInt("maxSize", 1920)
    fun setMaxSize(c: Context, v: Int) = p(c).edit().putInt("maxSize", v).apply()

    fun bitrateMbps(c: Context): Int = p(c).getInt("bitrate", 16)
    fun setBitrateMbps(c: Context, v: Int) = p(c).edit().putInt("bitrate", v).apply()

    /** The last screen shape the Mac asked for (landscape w:h), so the phone app can re-apply it. */
    fun lastShape(c: Context): Pair<Int, Int>? {
        val w = p(c).getInt("shapeW", 0); val h = p(c).getInt("shapeH", 0)
        return if (w > 0 && h > 0) w to h else null
    }
    fun setLastShape(c: Context, w: Int, h: Int) = p(c).edit().putInt("shapeW", w).putInt("shapeH", h).apply()
    /** Long side the Mac asked to render at (0 = panel pixels). */
    fun shapeLong(c: Context): Int = p(c).getInt("shapeLong", 0)
    fun setShapeLong(c: Context, v: Int) = p(c).edit().putInt("shapeLong", v).apply()

    fun audio(c: Context): Boolean = p(c).getBoolean("audio", true)
    fun setAudio(c: Context, v: Boolean) = p(c).edit().putBoolean("audio", v).apply()
}
