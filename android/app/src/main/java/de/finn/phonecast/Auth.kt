package de.finn.phonecast

import android.content.Context
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.security.auth.x500.X500Principal

/**
 * Pairing security.
 *  - The link (HubService) is TLS 1.3 with a key that never leaves the phone's keystore. The Mac
 *    remembers its fingerprint the first time (shown in the phone app to compare).
 *  - Over that encrypted link the phone hands the Mac a random 256-bit mirror key. The mirror then
 *    proves itself with HMAC(key, nonce) instead of sending the PIN in the clear. The PIN alone still
 *    works for a Mac that has no key yet (first pairing, cable).
 *  - QR pairing: the computer shows a QR code with its id and a random 256-bit secret; the phone scans
 *    it (Pairing.kt). From then on both sides prove they know the secret (HMAC over a fresh nonce),
 *    in both directions, so neither a guessed PIN nor a fake phone on the network gets in.
 *  - Wrong PINs / proofs: 5 tries, then 5 minutes locked (for both connections).
 */
object Auth {
    private const val ALIAS = "phonecast-hub-tls"

    // ---- guessing limit ----

    private var failures = 0
    private var lockedUntil = 0L

    @Synchronized fun locked(): Boolean = SystemClock.elapsedRealtime() < lockedUntil

    @Synchronized fun failed() {
        failures++
        if (failures >= 5) { lockedUntil = SystemClock.elapsedRealtime() + 5 * 60_000L; failures = 0 }
    }

    @Synchronized fun succeeded() { failures = 0 }

    // ---- mirror key ----

    fun nonce(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

    fun hmacHex(key: String, nonce: ByteArray): String {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(key.toByteArray(), "HmacSHA256"))
        m.update(nonce); m.update("phonecast-mirror".toByteArray())
        return m.doFinal().joinToString("") { "%02x".format(it) }
    }

    /** HELLO from the mirror: "Q1:<id>:<hmac hex>" (QR-paired), "T1:<hmac hex>" (mirror key) or the plain PIN. */
    fun checkMirrorHello(c: Context, hello: String, nonce: ByteArray): Boolean {
        if (locked()) return false
        if (hello.startsWith("Q1:")) {
            // not counted towards the PIN limit: a 256-bit key can't be guessed, and a computer that
            // doesn't know yet whether the phone scanned its code mustn't use up the tries
            return qrMirrorKey(c, hello)?.let { k ->
                MessageDigest.isEqual(hello.substringAfterLast(':').toByteArray(), hex(mac(k, nonce, "phonecast-mirror".toByteArray())).toByteArray())
            } ?: false
        }
        val ok = when {
            hello.startsWith("T1:") -> MessageDigest.isEqual(hello.substring(3).toByteArray(), hmacHex(Prefs.token(c), nonce).toByteArray())
            else -> MessageDigest.isEqual(hello.toByteArray(), Prefs.pin(c).toByteArray())
        }
        if (ok) succeeded() else failed()
        return ok
    }

    /** For a QR-paired viewer: the phone's own proof (appended to HELLO_OK), so the viewer knows it
     *  reached the real phone. Empty for PIN / mirror-key logins. */
    fun mirrorProof(c: Context, hello: String, nonce: ByteArray): ByteArray =
        qrMirrorKey(c, hello)?.let { mac(it, nonce, "phonecast-phone".toByteArray()) } ?: ByteArray(0)

    private fun qrMirrorKey(c: Context, hello: String): ByteArray? {
        if (!hello.startsWith("Q1:")) return null
        val id = hello.removePrefix("Q1:").substringBefore(':')
        return pairs(c)[id]?.key
    }

    // ---- QR pairing ----

    class Pair(val id: String, val key: ByteArray, val name: String, val time: Long)

    private fun prefs(c: Context) = c.getSharedPreferences("phonecast", Context.MODE_PRIVATE)

    /** Computers paired by QR code (id -> secret + name). */
    fun pairs(c: Context): Map<String, Pair> {
        val o = try { org.json.JSONObject(prefs(c).getString("pairs", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        val out = LinkedHashMap<String, Pair>()
        for (id in o.keys()) {
            val e = o.optJSONObject(id) ?: continue
            val k = unhex(e.optString("k")) ?: continue
            out[id] = Pair(id, k, e.optString("n", "Computer"), e.optLong("t"))
        }
        return out
    }

    @Synchronized fun addPair(c: Context, id: String, keyHex: String, name: String): Boolean {
        if (!id.matches(Regex("[0-9a-f]{16}")) || unhex(keyHex)?.size != 32) return false
        val o = try { org.json.JSONObject(prefs(c).getString("pairs", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        o.put(id, org.json.JSONObject().put("k", keyHex).put("n", name.take(60)).put("t", System.currentTimeMillis()))
        prefs(c).edit().putString("pairs", o.toString()).apply()
        return true
    }

    @Synchronized fun removePair(c: Context, id: String) {
        val o = try { org.json.JSONObject(prefs(c).getString("pairs", "{}")!!) } catch (_: Exception) { return }
        o.remove(id)
        prefs(c).edit().putString("pairs", o.toString()).apply()
    }

    /** The link's HELLO {qr, proof} from a QR-paired computer; returns the pair or null.
     *  The proof covers the certificate fingerprint the computer saw: relayed through anyone else's
     *  TLS certificate it no longer matches ours. Not counted towards the PIN limit (see above). */
    fun checkHubQr(c: Context, id: String, proofHex: String, nonce: ByteArray): Pair? {
        val p = pairs(c)[id] ?: return null
        val want = hex(mac(p.key, nonce, "phonecast-hub".toByteArray(), certSha256Hex().toByteArray()))
        return if (MessageDigest.isEqual(proofHex.lowercase().toByteArray(), want.toByteArray())) p else null
    }

    /** The phone's answer on the link: binds the secret to this phone's TLS certificate, so the
     *  computer can pin the certificate without anyone comparing keys. */
    fun hubPhoneProof(p: Pair, nonce: ByteArray): String =
        hex(mac(p.key, nonce, "phonecast-hub-phone".toByteArray(), certSha256Hex().toByteArray()))

    fun mac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(key, "HmacSHA256"))
        for (x in parts) m.update(x)
        return m.doFinal()
    }

    fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    fun unhex(s: String): ByteArray? =
        if (s.length % 2 != 0 || !s.matches(Regex("[0-9a-fA-F]*"))) null
        else ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun checkPin(c: Context, pin: String): Boolean {
        if (locked()) return false
        val ok = MessageDigest.isEqual(pin.toByteArray(), Prefs.pin(c).toByteArray())
        if (ok) succeeded() else failed()
        return ok
    }

    // ---- TLS ----

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun ensureKey() {
        val ks = keyStore()
        if (ks.containsAlias(ALIAS)) return
        val g = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        g.initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
            .setCertificateSubject(X500Principal("CN=PhoneCast"))
            .setCertificateSerialNumber(BigInteger.valueOf(SecureRandom().nextLong() and Long.MAX_VALUE))
            .setCertificateNotBefore(Date(System.currentTimeMillis() - 86_400_000L))
            .setCertificateNotAfter(Date(System.currentTimeMillis() + 30L * 365 * 86_400_000L))
            .build())
        g.generateKeyPair()
    }

    fun serverSocket(): SSLServerSocket {
        ensureKey()
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore(), null)
        val ctx = SSLContext.getInstance("TLSv1.3")
        ctx.init(kmf.keyManagers, null, null)
        val ss = ctx.serverSocketFactory.createServerSocket() as SSLServerSocket
        ss.enabledProtocols = arrayOf("TLSv1.3")
        return ss
    }

    /** Full SHA-256 of the link certificate, UPPERCASE hex, 64 chars (what the QR proofs are bound to). */
    fun certSha256Hex(): String = try {
        ensureKey()
        hex(MessageDigest.getInstance("SHA-256").digest(keyStore().getCertificate(ALIAS).encoded)).uppercase()
    } catch (e: Exception) { "" }

    /** SHA-256 of the certificate, as the Mac shows it ("AB12 CD34 …", first 8 groups). */
    fun fingerprint(): String = try {
        ensureKey()
        val der = keyStore().getCertificate(ALIAS).encoded
        MessageDigest.getInstance("SHA-256").digest(der).take(16)
            .joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" ")
    } catch (e: Exception) { "unavailable" }
}
