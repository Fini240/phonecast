package de.finn.phonecast

import android.app.Activity
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

/**
 * QR pairing, phone side: scan the code a computer (Mac / Windows) shows and remember its secret.
 * Google's code scanner runs in Play services, so PhoneCast needs no camera permission.
 *
 * Code: phonecast:pair?v=1&id=<16 hex>&k=<64 hex secret>&n=<url-encoded computer name>
 * How the secret is used afterwards: see Auth (Q1 mirror login, hub proofs in both directions).
 */
object Pairing {
    /** Opens the scanner; [done] runs on the main thread with (paired?, message for the user). */
    fun scan(activity: Activity, done: (ok: Boolean, message: String) -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .enableAutoZoom()
            .build()
        GmsBarcodeScanning.getClient(activity, options).startScan()
            .addOnSuccessListener { code ->
                val r = pair(activity, code.rawValue ?: "")
                done(r.first, r.second)
            }
            .addOnCanceledListener { done(false, "Scanning cancelled") }
            .addOnFailureListener { e -> done(false, "The scanner didn't start (${e.message}). Is Google Play services up to date?") }
    }

    /** Stores the pairing from a scanned code. Returns (ok, message). */
    fun pair(activity: Activity, text: String): kotlin.Pair<Boolean, String> {
        val q = parse(text) ?: return false to "That's not a PhoneCast pairing code"
        if (q["v"] != "1") return false to "This pairing code is from a newer PhoneCast: update the phone app"
        val id = q["id"] ?: ""; val k = q["k"] ?: ""; val n = q["n"]?.takeIf { it.isNotBlank() } ?: "Computer"
        return if (Auth.addPair(activity, id.lowercase(), k.lowercase(), n)) true to "Paired with $n"
        else false to "The pairing code is damaged, try again"
    }

    /** "phonecast:pair?a=1&b=2" -> {a=1, b=2} (an opaque URI, so Uri.getQueryParameter can't read it). */
    fun parse(text: String): Map<String, String>? {
        val t = text.trim()
        if (!t.startsWith("phonecast:pair?")) return null
        return t.substringAfter('?').split('&').mapNotNull { kv ->
            val i = kv.indexOf('=')
            if (i <= 0) null else kv.substring(0, i) to java.net.URLDecoder.decode(kv.substring(i + 1), "UTF-8")
        }.toMap()
    }
}
