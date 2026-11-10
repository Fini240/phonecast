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
 *  - Wrong PINs: 5 tries, then 5 minutes locked (for both connections).
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

    /** HELLO from the mirror: "T1:<hmac hex>" (mirror key) or the plain PIN. */
    fun checkMirrorHello(c: Context, hello: String, nonce: ByteArray): Boolean {
        if (locked()) return false
        val ok = if (hello.startsWith("T1:")) MessageDigest.isEqual(hello.substring(3).toByteArray(), hmacHex(Prefs.token(c), nonce).toByteArray())
                 else MessageDigest.isEqual(hello.toByteArray(), Prefs.pin(c).toByteArray())
        if (ok) succeeded() else failed()
        return ok
    }

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

    /** SHA-256 of the certificate, as the Mac shows it ("AB12 CD34 …", first 8 groups). */
    fun fingerprint(): String = try {
        ensureKey()
        val der = keyStore().getCertificate(ALIAS).encoded
        MessageDigest.getInstance("SHA-256").digest(der).take(16)
            .joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" ")
    } catch (e: Exception) { "unavailable" }
}
