package de.finn.phonecast

import android.util.Log
import java.io.BufferedInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * "Phone in Finder": a small WebDAV server over the phone's storage, which macOS mounts as a network
 * drive (Finder → Go → Connect to Server works too). It only runs while a computer asked for it
 * (Features "webdav.start"), stops after 30 minutes without requests, and needs a fresh random password
 * each time. Needs "All files access". Plain HTTP with Basic auth: use it on your own Wi-Fi or Tailscale.
 *
 * Supports what Finder uses: OPTIONS, PROPFIND (depth 0/1), GET/HEAD (with Range), PUT, DELETE, MKCOL,
 * MOVE, COPY, PROPPATCH (ignored) and LOCK/UNLOCK (fake locks: macOS mounts read-only without class 2).
 */
object WebDav {
    private const val TAG = "PhoneCastDav"
    const val PORT = 27186
    private const val IDLE_MS = 30 * 60_000L

    @Volatile private var server: ServerSocket? = null
    @Volatile private var lastUse = 0L
    @Volatile var password: String = ""
        private set
    const val USER = "phonecast"
    private lateinit var root: File

    val running get() = server != null

    /** Starts (or keeps) the server; returns the password for this session. */
    @Synchronized fun start(storageRoot: String): String {
        root = File(storageRoot).canonicalFile
        lastUse = System.currentTimeMillis()
        if (server != null) return password
        val b = ByteArray(12).also { SecureRandom().nextBytes(it) }
        password = b.joinToString("") { "%02x".format(it) }
        val ss = ServerSocket(PORT, 32)
        server = ss
        Thread({
            try {
                while (true) {
                    val s = ss.accept()
                    Thread({ serve(s) }, "dav-client").start()
                }
            } catch (_: Exception) {}
        }, "dav-accept").start()
        Thread({
            while (server === ss) {
                Thread.sleep(60_000)
                if (System.currentTimeMillis() - lastUse > IDLE_MS) { Log.i(TAG, "idle, stopping"); stop() }
            }
        }, "dav-idle").start()
        Log.i(TAG, "started on $PORT")
        return password
    }

    @Synchronized fun stop() {
        try { server?.close() } catch (_: Exception) {}
        server = null
    }

    // ---- HTTP ----

    private class Req(val method: String, val path: String, val headers: Map<String, String>, val input: InputStream) {
        fun h(name: String) = headers[name.lowercase()]
        val length get() = h("content-length")?.toLongOrNull() ?: 0L
    }

    private fun serve(s: Socket) {
        try {
            s.soTimeout = 60_000
            s.tcpNoDelay = true
            val input = BufferedInputStream(s.getInputStream(), 64 * 1024)
            val out = s.getOutputStream().buffered(64 * 1024)
            while (true) {                      // keep-alive: Finder sends many requests per connection
                val req = readRequest(input) ?: break
                lastUse = System.currentTimeMillis()
                val keep = handle(req, out)
                out.flush()
                if (!keep || req.h("connection").equals("close", true)) break
            }
        } catch (_: Exception) {
        } finally { try { s.close() } catch (_: Exception) {} }
    }

    private fun readLine(i: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = i.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
            if (sb.length > 16_384) throw IllegalStateException("line too long")
        }
    }

    private fun readRequest(i: InputStream): Req? {
        val first = readLine(i) ?: return null
        if (first.isBlank()) return readRequest(i)
        val parts = first.split(' ')
        if (parts.size < 2) return null
        val headers = HashMap<String, String>()
        while (true) {
            val l = readLine(i) ?: break
            if (l.isEmpty()) break
            val c = l.indexOf(':')
            if (c > 0) headers[l.substring(0, c).trim().lowercase()] = l.substring(c + 1).trim()
        }
        val raw = parts[1].substringBefore('?')
        val path = URLDecoder.decode(raw.replace("+", "%2B"), "UTF-8")
        return Req(parts[0].uppercase(), path, headers, i)
    }

    private fun authorized(r: Req): Boolean {
        val a = r.h("authorization") ?: return false
        if (!a.startsWith("Basic ", true)) return false
        val dec = try { String(android.util.Base64.decode(a.substring(6).trim(), android.util.Base64.DEFAULT)) } catch (_: Exception) { return false }
        return password.isNotEmpty() && java.security.MessageDigest.isEqual(dec.toByteArray(), "$USER:$password".toByteArray())
    }

    /** The file for a request path, never outside the storage root. */
    private fun fileFor(path: String): File? {
        val f = File(root, path.trimStart('/')).canonicalFile
        return if (f.path == root.path || f.path.startsWith(root.path + "/")) f else null
    }

    // ---- Finder's ._ (AppleDouble) and .DS_Store files: kept in memory, never written to the phone ----

    private val junk = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()
    private fun isJunk(path: String) = path.substringAfterLast('/').let { it.startsWith("._") || it == ".DS_Store" }
    private fun junkKey(f: File) = f.path

    private fun handleJunk(r: Req, f: File, out: OutputStream) {
        val k = junkKey(f)
        when (r.method) {
            "PUT" -> { val b = java.io.ByteArrayOutputStream(); copyN(r.input, b, minOf(r.length, 1L shl 20)); drain(r, r.length - minOf(r.length, 1L shl 20))
                       val had = junk.put(k, b.toByteArray()) != null; respond(out, if (had) 204 else 201, "") }
            "GET", "HEAD" -> { drain(r); val b = junk[k]; if (b == null) respond(out, 404, "") else {
                out.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ${b.size}\r\n\r\n".toByteArray())
                if (r.method == "GET") out.write(b) } }
            "PROPFIND" -> { drain(r); val b = junk[k]; if (b == null) respond(out, 404, "") else
                respond(out, 207, """<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">${junkEntry(r.path, b.size)}</D:multistatus>""", "application/xml; charset=utf-8") }
            "DELETE" -> { drain(r); respond(out, if (junk.remove(k) != null) 204 else 404, "") }
            "MOVE", "COPY" -> { drain(r)
                val dest = r.h("destination")?.let { d -> fileFor(URLDecoder.decode((try { java.net.URI(d).rawPath } catch (_: Exception) { d }).replace("+", "%2B"), "UTF-8")) }
                val b = junk[k]
                if (dest == null || b == null) respond(out, 404, "") else { junk[junkKey(dest)] = b; if (r.method == "MOVE") junk.remove(k); respond(out, 201, "") } }
            "LOCK" -> { drain(r); respond(out, 200, """<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery/></D:prop>""", "application/xml; charset=utf-8") }
            else -> { drain(r); respond(out, 204, "") }
        }
    }

    private fun junkEntry(path: String, size: Int) =
        "<D:response><D:href>${href(path, false)}</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>$size</D:getcontentlength>" +
        "<D:getcontenttype>application/octet-stream</D:getcontenttype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"

    private fun handle(r: Req, out: OutputStream): Boolean {
        if (!authorized(r)) {
            drain(r)
            respond(out, 401, "Unauthorized", extra = mapOf("WWW-Authenticate" to "Basic realm=\"PhoneCast\""))
            return true
        }
        val f = fileFor(r.path) ?: run { drain(r); respond(out, 403, "Forbidden"); return true }
        if (isJunk(r.path)) { handleJunk(r, f, out); return true }
        when (r.method) {
            "OPTIONS" -> respond(out, 200, "", extra = mapOf("DAV" to "1, 2", "MS-Author-Via" to "DAV",
                "Allow" to "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, COPY, LOCK, UNLOCK"))
            "PROPFIND" -> { drain(r); propfind(r, f, out) }
            "PROPPATCH" -> { drain(r); multistatusOk(r.path, out) }
            "GET", "HEAD" -> get(r, f, out)
            "PUT" -> {
                f.parentFile?.mkdirs()
                val existed = f.exists()
                f.outputStream().buffered(256 * 1024).use { o -> copyN(r.input, o, r.length) }
                scan(f)
                respond(out, if (existed) 204 else 201, "")
            }
            "DELETE" -> {
                drain(r)
                // never the storage root or its top-level folders (DCIM, Download…), like the Mac's file browser
                if (f.path == root.path || f.parentFile?.canonicalPath == root.path && f.isDirectory) respond(out, 403, "Forbidden")
                else { f.deleteRecursively(); respond(out, 204, "") }
            }
            "MKCOL" -> { drain(r); respond(out, if (f.exists()) 405 else if (f.mkdirs()) 201 else 409, "") }
            "MOVE", "COPY" -> {
                drain(r)
                val dest = r.h("destination")?.let { d ->
                    val p = try { java.net.URI(d).rawPath } catch (_: Exception) { d }
                    fileFor(URLDecoder.decode(p.replace("+", "%2B"), "UTF-8"))
                }
                if (dest == null || !f.exists()) { respond(out, if (dest == null) 400 else 404, ""); return true }
                val overwrite = r.h("overwrite") != "F"
                if (dest.exists() && !overwrite) { respond(out, 412, ""); return true }
                val existed = dest.exists()
                if (existed) dest.deleteRecursively()
                dest.parentFile?.mkdirs()
                val ok = if (r.method == "MOVE") f.renameTo(dest) || (f.copyRecursively(dest) && f.deleteRecursively())
                         else f.copyRecursively(dest)
                if (ok && f.isDirectory.not() && r.method == "MOVE") {
                    junk.remove(f.parent + "/._" + f.name)?.let { junk[dest.parent + "/._" + dest.name] = it }
                }
                scan(dest)
                respond(out, if (!ok) 500 else if (existed) 204 else 201, "")
            }
            "LOCK" -> {
                drain(r)
                val token = "opaquelocktoken:" + java.util.UUID.randomUUID()
                val body = """<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>""" +
                    """<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>""" +
                    """<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>$token</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>"""
                respond(out, 200, body, "application/xml; charset=utf-8", mapOf("Lock-Token" to "<$token>"))
            }
            "UNLOCK" -> { drain(r); respond(out, 204, "") }
            else -> { drain(r); respond(out, 405, "") }
        }
        return true
    }

    private val httpDate = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }
    private val isoDate = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }

    private fun href(path: String, dir: Boolean): String {
        val enc = path.split('/').joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
        return if (dir && !enc.endsWith("/")) "$enc/" else enc
    }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    private fun entry(path: String, f: File): String {
        val dir = f.isDirectory
        val sb = StringBuilder("<D:response><D:href>").append(href(path, dir)).append("</D:href><D:propstat><D:prop>")
        sb.append("<D:displayname>").append(esc(if (f.path == root.path) "Phone" else f.name)).append("</D:displayname>")
        synchronized(httpDate) {
            sb.append("<D:getlastmodified>").append(httpDate.format(Date(f.lastModified()))).append("</D:getlastmodified>")
            sb.append("<D:creationdate>").append(isoDate.format(Date(f.lastModified()))).append("</D:creationdate>")
        }
        if (dir) sb.append("<D:resourcetype><D:collection/></D:resourcetype>")
        else {
            sb.append("<D:resourcetype/><D:getcontentlength>").append(f.length()).append("</D:getcontentlength>")
            sb.append("<D:getcontenttype>").append(mime(f.name)).append("</D:getcontenttype>")
            sb.append("<D:getetag>\"").append(f.length()).append('-').append(f.lastModified()).append("\"</D:getetag>")
        }
        sb.append("<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>")
        sb.append("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
        return sb.toString()
    }

    private fun propfind(r: Req, f: File, out: OutputStream) {
        if (!f.exists()) { respond(out, 404, ""); return }
        val sb = StringBuilder("""<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">""")
        val base = if (r.path.isEmpty()) "/" else r.path
        sb.append(entry(base, f))
        if (f.isDirectory && r.h("depth") != "0") {
            // hidden ._ files Finder writes are kept like any other file; Android's own dot-folders are listed too
            f.listFiles()?.filter { !isJunk(it.name) }?.sortedBy { it.name.lowercase() }?.forEach { c ->
                sb.append(entry(base.trimEnd('/') + "/" + c.name, c))
            }
            val prefix = f.path + "/"
            for ((k, b) in junk) if (k.startsWith(prefix) && '/' !in k.substring(prefix.length))
                sb.append(junkEntry(base.trimEnd('/') + "/" + k.substring(prefix.length), b.size))
        }
        sb.append("</D:multistatus>")
        respond(out, 207, sb.toString(), "application/xml; charset=utf-8")
    }

    private fun multistatusOk(path: String, out: OutputStream) {
        respond(out, 207, """<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>${href(path, false)}</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>""",
            "application/xml; charset=utf-8")
    }

    private fun get(r: Req, f: File, out: OutputStream) {
        if (!f.exists()) { respond(out, 404, ""); return }
        if (f.isDirectory) { respond(out, 200, "PhoneCast: mount this address in Finder (Go → Connect to Server).", "text/plain"); return }
        val len = f.length()
        var start = 0L; var end = len - 1; var partial = false
        r.h("range")?.removePrefix("bytes=")?.split('-')?.let { p ->
            if (p.size == 2) {
                if (p[0].isEmpty()) { start = maxOf(0, len - (p[1].toLongOrNull() ?: 0)) }
                else { start = p[0].toLongOrNull() ?: 0; end = p[1].toLongOrNull()?.coerceAtMost(len - 1) ?: (len - 1) }
                partial = true
            }
        }
        if (start > end && len > 0) { respond(out, 416, "", extra = mapOf("Content-Range" to "bytes */$len")); return }
        val n = if (len == 0L) 0 else end - start + 1
        val h = StringBuilder("HTTP/1.1 ${if (partial) "206 Partial Content" else "200 OK"}\r\n")
        h.append("Content-Type: ${mime(f.name)}\r\nContent-Length: $n\r\nAccept-Ranges: bytes\r\n")
        synchronized(httpDate) { h.append("Last-Modified: ${httpDate.format(Date(f.lastModified()))}\r\n") }
        h.append("ETag: \"${f.length()}-${f.lastModified()}\"\r\n")
        if (partial) h.append("Content-Range: bytes $start-$end/$len\r\n")
        h.append("\r\n")
        out.write(h.toString().toByteArray())
        if (r.method == "GET" && n > 0) f.inputStream().use { i -> i.skip(start); copyN(i, out, n) }
    }

    private fun respond(out: OutputStream, code: Int, body: String, type: String = "text/plain; charset=utf-8", extra: Map<String, String> = emptyMap()) {
        val b = body.toByteArray()
        val reason = mapOf(200 to "OK", 201 to "Created", 204 to "No Content", 207 to "Multi-Status", 400 to "Bad Request", 401 to "Unauthorized",
            403 to "Forbidden", 404 to "Not Found", 405 to "Method Not Allowed", 409 to "Conflict", 412 to "Precondition Failed",
            416 to "Range Not Satisfiable", 500 to "Internal Server Error")[code] ?: "OK"
        val h = StringBuilder("HTTP/1.1 $code $reason\r\nServer: PhoneCast\r\nContent-Length: ${b.size}\r\n")
        if (b.isNotEmpty()) h.append("Content-Type: $type\r\n")
        extra.forEach { (k, v) -> h.append("$k: $v\r\n") }
        h.append("\r\n")
        out.write(h.toString().toByteArray()); out.write(b)
    }

    private fun drain(r: Req, n: Long = r.length) { if (n > 0) copyN(r.input, null, n) }

    private fun copyN(i: InputStream, o: OutputStream?, n: Long) {
        val buf = ByteArray(256 * 1024); var left = n
        while (left > 0) {
            val k = i.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (k < 0) break
            o?.write(buf, 0, k); left -= k
        }
    }

    private fun mime(name: String) =
        android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

    private var scanCtx: android.content.Context? = null
    fun bind(c: android.content.Context) { scanCtx = c.applicationContext }
    private fun scan(f: File) {
        val c = scanCtx ?: return
        if (f.isFile) android.media.MediaScannerConnection.scanFile(c, arrayOf(f.path), null, null)
    }

    /** The phone's address on the network [peer] reached it from (Wi-Fi or Tailscale). */
    fun localAddressFor(peer: Socket?): String? {
        val local = peer?.localAddress ?: return null
        // Bonjour links often run over IPv6 link-local (fe80::…%wlan0), which Finder can't mount: use the IPv4
        // address of the same network interface instead (Wi-Fi or Tailscale)
        if (local is java.net.Inet6Address) {
            val v4 = try { java.net.NetworkInterface.getByInetAddress(local)?.inetAddresses?.toList()?.firstOrNull { it is java.net.Inet4Address } } catch (_: Exception) { null }
            if (v4 != null) return v4.hostAddress
            val mapped = local.hostAddress?.substringAfterLast("::ffff:", "")
            if (!mapped.isNullOrEmpty() && mapped.count { it == '.' } == 3) return mapped
        }
        return local.hostAddress?.substringBefore('%')
    }
}
