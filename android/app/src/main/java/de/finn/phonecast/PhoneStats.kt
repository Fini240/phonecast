package de.finn.phonecast

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.os.SystemClock
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * Phone health for the Mac's stats overlay (appended to Proto.STATS after the u32 resyncs):
 *   i16 battery temperature in 0.1 °C, u8 battery %, u8 plugged (0/1),
 *   i16 battery power in 0.1 W (+ charging, - draining), u8 thermal status (PowerManager 0..6),
 *   u8 thermal headroom in % of the throttling point (255 = unknown),
 *   i16 hottest CPU sensor, i16 hottest GPU sensor in 0.1 °C (-32768 = not readable).
 * CPU/GPU come from /sys/class/thermal, which most phones hide from apps (some Samsungs don't).
 * The game's own frame rate can't be read without root.
 */
object PhoneStats {
    private var cached = ByteArray(0)
    private var at = 0L

    /** Cheap to call often: sampled at most every 2 s (thermal headroom is rate-limited anyway). */
    @Synchronized
    fun bytes(ctx: Context): ByteArray {
        val now = SystemClock.uptimeMillis()
        if (now - at < 2000 && cached.isNotEmpty()) return cached
        at = now
        cached = try { sample(ctx) } catch (_: Exception) { ByteArray(0) }
        return cached
    }

    private fun sample(ctx: Context): ByteArray {
        val bat = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val temp = bat?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0 // 0.1 °C
        val level = bat?.getIntExtra(BatteryManager.EXTRA_LEVEL, 0) ?: 0
        val scale = (bat?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100).coerceAtLeast(1)
        val plugged = (bat?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        val mv = bat?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0) ?: 0

        val bm = ctx.getSystemService(BatteryManager::class.java)
        var cur = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW).toLong() // µA (some phones: mA)
        if (cur == Long.MIN_VALUE || cur == Int.MIN_VALUE.toLong()) cur = 0
        if (abs(cur) in 1..19_999) cur *= 1000 // reported in mA
        val deciWatts = (cur * mv / 100_000_000L).toInt() // µA * mV = pW; 1e8 pW = 0.1 W

        val pm = ctx.getSystemService(PowerManager::class.java)
        val status = pm.currentThermalStatus
        val head = pm.getThermalHeadroom(0)
        val headPct = if (head.isNaN() || head < 0) 255 else (head * 100).toInt().coerceIn(0, 254)

        val (cpu, gpu) = chipTemps()
        return ByteBuffer.allocate(12)
            .putShort(temp.toShort())
            .put((level * 100 / scale).toByte())
            .put(if (plugged) 1 else 0)
            .putShort(deciWatts.coerceIn(-32768, 32767).toShort())
            .put(status.toByte())
            .put(headPct.toByte())
            .putShort(cpu)
            .putShort(gpu)
            .array()
    }

    private const val UNKNOWN: Short = -32768
    /** Thermal zone files by kind, found once; empty if the system doesn't let us read them. */
    private var zones: Map<String, List<java.io.File>>? = null

    private fun chipTemps(): Pair<Short, Short> {
        val z = zones ?: run {
            val found = HashMap<String, MutableList<java.io.File>>()
            java.io.File("/sys/class/thermal").listFiles { f -> f.name.startsWith("thermal_zone") }?.forEach { dir ->
                val type = try { java.io.File(dir, "type").readText().trim() } catch (_: Exception) { return@forEach }
                val kind = when {
                    type.startsWith("cpu-") || type.startsWith("cpuss") -> "cpu"
                    type.startsWith("gpu") -> "gpu"
                    else -> return@forEach
                }
                val t = java.io.File(dir, "temp")
                if (t.canRead() && (try { t.readText().trim().toInt(); true } catch (_: Exception) { false }))
                    found.getOrPut(kind) { mutableListOf() }.add(t)
            }
            android.util.Log.i("PhoneCast", "chip temperature sensors readable: ${found.mapValues { it.value.size }}")
            zones = found
            found
        }
        fun hottest(kind: String): Short {
            val milli = z[kind]?.mapNotNull { try { it.readText().trim().toInt() } catch (_: Exception) { null } }?.maxOrNull() ?: return UNKNOWN
            return (milli / 100).coerceIn(-32767, 32767).toShort() // m°C -> 0.1 °C
        }
        return hottest("cpu") to hottest("gpu")
    }
}
