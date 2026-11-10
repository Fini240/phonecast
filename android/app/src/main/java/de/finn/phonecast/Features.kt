package de.finn.phonecast

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Telephony
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Base64
import android.util.Log
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Requests from the Mac (HubProto.REQ) for the phone's data: messages, calls, contacts,
 * photos, files and apps. Each answer is RESP {id, ok, data | error}.
 * Call state changes are pushed as EVENT {e: "call", ...}.
 */
class Features(private val ctx: Context, private val hub: HubService) {

    companion object { private const val TAG = "PhoneCastFeat" }

    private fun has(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** Runs on its own thread per request (queries can take a moment). */
    fun handle(req: JSONObject) {
        val id = req.optInt("id")
        val p = req.optJSONObject("p") ?: JSONObject()
        Thread({
            val out = JSONObject().put("id", id)
            try {
                out.put("data", call(req.optString("m"), p)).put("ok", true)
            } catch (e: SecurityException) {
                out.put("ok", false).put("error", "permission").put("message", "Allow this in the PhoneCast app on the phone (Features).")
            } catch (e: Exception) {
                Log.w(TAG, "request ${req.optString("m")}", e)
                out.put("ok", false).put("error", "failed").put("message", e.message ?: e.toString())
            }
            hub.sendJson(HubProto.RESP, out)
        }, "feat-$id").start()
    }

    private fun call(m: String, p: JSONObject): Any = when (m) {
        "perms" -> perms()
        "sms.threads" -> smsThreads(p.optInt("limit", 60))
        "sms.thread" -> smsThread(p.getLong("thread"), p.optInt("limit", 200))
        "sms.send" -> smsSend(p.getString("to"), p.getString("text"))
        "contacts" -> contacts()
        "calls.log" -> callLog(p.optInt("limit", 150))
        "call.dial" -> dial(p.getString("number"))
        "call.answer" -> { telecom().acceptRingingCall(); true }
        "call.end" -> { @Suppress("DEPRECATION") telecom().endCall() }
        "photos" -> photos(p.optInt("offset"), p.optInt("limit", 60))
        "photo.get" -> { hub.sendUriAsFile(Uri.parse(p.getString("uri")), p.optInt("req")); true }
        "files" -> files(p.optString("path", ""))
        "file.get" -> { hub.sendPathAsFile(p.getString("path"), p.optInt("req")); true }
        "file.delete" -> deletePath(p.getString("path"))
        "apps" -> apps()
        "app.open" -> openApp(p.getString("pkg"))
        "media.cmd" -> hub.extras.mediaCmd(p.getString("a"))
        "phone.ring" -> hub.extras.ring(p.optBoolean("on", true))
        "dnd.set" -> {
            // the notification listener may switch Do Not Disturb without any extra permission
            val nl = NotifListener.instance ?: throw SecurityException("notification access")
            nl.requestInterruptionFilter(if (p.optBoolean("on")) android.service.notification.NotificationListenerService.INTERRUPTION_FILTER_PRIORITY
                else android.service.notification.NotificationListenerService.INTERRUPTION_FILTER_ALL)
            Thread.sleep(300); hub.refreshStatus(); true
        }
        else -> throw IllegalArgumentException("unknown request $m")
    }

    // ---- which features are allowed (for the Mac's setup list) ----

    fun perms(): JSONObject = JSONObject()
        .put("sms", has(Manifest.permission.READ_SMS) && has(Manifest.permission.SEND_SMS))
        .put("contacts", has(Manifest.permission.READ_CONTACTS))
        .put("calls", has(Manifest.permission.READ_CALL_LOG) && has(Manifest.permission.READ_PHONE_STATE))
        .put("callControl", has(Manifest.permission.ANSWER_PHONE_CALLS) && has(Manifest.permission.CALL_PHONE))
        .put("photos", if (Build.VERSION.SDK_INT >= 33) has(Manifest.permission.READ_MEDIA_IMAGES) else has(Manifest.permission.READ_EXTERNAL_STORAGE))
        .put("files", Environment.isExternalStorageManager())
        .put("notifications", NotifListener.instance != null)
        .put("control", InputService.instance != null)

    // ---- messages ----

    private val names = HashMap<String, String?>()

    fun nameFor(number: String?): String? {
        if (number.isNullOrBlank() || !has(Manifest.permission.READ_CONTACTS)) return null
        synchronized(names) { if (names.containsKey(number)) return names[number] }
        val n = try {
            ctx.contentResolver.query(
                Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number)),
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (_: Exception) { null }
        synchronized(names) { names[number] = n }
        return n
    }

    private fun smsThreads(limit: Int): JSONArray {
        val seen = LinkedHashMap<Long, JSONObject>()
        val unread = HashMap<Long, Int>()
        ctx.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ),
            null, null, "${Telephony.Sms.DATE} DESC LIMIT 3000"
        )?.use { c ->
            while (c.moveToNext()) {
                val t = c.getLong(0)
                if (c.getInt(5) == 0) unread[t] = (unread[t] ?: 0) + 1
                if (seen.containsKey(t)) continue
                if (seen.size >= limit) continue
                val addr = c.getString(1) ?: ""
                seen[t] = JSONObject().put("thread", t).put("address", addr).put("name", nameFor(addr) ?: "")
                    .put("snippet", c.getString(2) ?: "").put("date", c.getLong(3)).put("mine", c.getInt(4) != Telephony.Sms.MESSAGE_TYPE_INBOX)
            }
        }
        return JSONArray().also { a -> seen.forEach { (t, o) -> a.put(o.put("unread", unread[t] ?: 0)) } }
    }

    private fun smsThread(thread: Long, limit: Int): JSONArray {
        val out = ArrayList<JSONObject>()
        ctx.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.ADDRESS),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(thread.toString()), "${Telephony.Sms.DATE} DESC LIMIT $limit"
        )?.use { c ->
            while (c.moveToNext()) out += JSONObject().put("id", c.getLong(0)).put("text", c.getString(1) ?: "")
                .put("date", c.getLong(2)).put("mine", c.getInt(3) != Telephony.Sms.MESSAGE_TYPE_INBOX).put("address", c.getString(4) ?: "")
        }
        return JSONArray(out.reversed())
    }

    private fun smsSend(to: String, text: String): Boolean {
        if (!has(Manifest.permission.SEND_SMS)) throw SecurityException("SEND_SMS")
        val sm = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()
        val parts = sm.divideMessage(text)
        sm.sendMultipartTextMessage(to, null, parts, null, null)
        return true
    }

    // ---- contacts & calls ----

    private fun contacts(): JSONArray {
        val byId = LinkedHashMap<Long, JSONObject>()
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.TYPE),
            null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE NOCASE ASC"
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val o = byId.getOrPut(id) { JSONObject().put("name", c.getString(1) ?: "").put("numbers", JSONArray()) }
                val num = c.getString(2) ?: continue
                val label = ContactsContract.CommonDataKinds.Phone.getTypeLabel(ctx.resources, c.getInt(3), "").toString()
                val nums = o.getJSONArray("numbers")
                val norm = num.filter { it.isDigit() || it == '+' }
                if ((0 until nums.length()).none { nums.getJSONObject(it).optString("n").filter { ch -> ch.isDigit() || ch == '+' } == norm })
                    nums.put(JSONObject().put("n", num).put("label", label))
            }
        }
        return JSONArray(byId.values.toList())
    }

    private fun callLog(limit: Int): JSONArray {
        val a = JSONArray()
        ctx.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            Bundle().apply {
                putStringArray(android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(CallLog.Calls.DATE))
                putInt(android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION, android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
                putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
            }, null
        )?.use { c ->
            while (c.moveToNext() && a.length() < limit) {
                val type = when (c.getInt(2)) {
                    CallLog.Calls.INCOMING_TYPE -> "in"; CallLog.Calls.OUTGOING_TYPE -> "out"
                    CallLog.Calls.MISSED_TYPE -> "missed"; CallLog.Calls.REJECTED_TYPE -> "rejected"; else -> "other"
                }
                a.put(JSONObject().put("number", c.getString(0) ?: "").put("name", c.getString(1) ?: "")
                    .put("type", type).put("date", c.getLong(3)).put("duration", c.getLong(4)))
            }
        }
        return a
    }

    private fun telecom() = ctx.getSystemService(TelecomManager::class.java)

    private fun dial(number: String): Boolean {
        if (!has(Manifest.permission.CALL_PHONE)) throw SecurityException("CALL_PHONE")
        telecom().placeCall(Uri.fromParts("tel", number, null), Bundle())
        return true
    }

    private var lastCallState: String? = null
    private val callReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val st = when (i.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
                TelephonyManager.EXTRA_STATE_OFFHOOK -> "active"
                else -> "idle"
            }
            @Suppress("DEPRECATION") val number = i.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            // the broadcast comes twice (with and without the number): only forward the useful one
            if (number == null && st == lastCallState) return
            lastCallState = st
            hub.sendJson(HubProto.EVENT, JSONObject().put("e", "call").put("state", st)
                .put("number", number ?: "").put("name", nameFor(number) ?: ""))
        }
    }

    private var watching = false
    fun startCallWatch() {
        if (watching || !has(Manifest.permission.READ_PHONE_STATE)) return
        try { ctx.registerReceiver(callReceiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)); watching = true } catch (_: Exception) {}
    }

    fun stopCallWatch() { if (watching) try { ctx.unregisterReceiver(callReceiver); watching = false } catch (_: Exception) {} }

    // ---- photos ----

    private fun photos(offset: Int, limit: Int): JSONArray {
        val a = JSONArray()
        val uri = MediaStore.Files.getContentUri("external")
        val args = Bundle().apply {
            putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,
                "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})")
            putStringArray(android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.MediaColumns.DATE_MODIFIED))
            putInt(android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION, android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
            putInt(android.content.ContentResolver.QUERY_ARG_OFFSET, offset)
        }
        ctx.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE), args, null)?.use { c ->
            while (c.moveToNext()) {
                val video = c.getInt(2) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val item = ContentUris.withAppendedId(
                    if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, c.getLong(0))
                val o = JSONObject().put("uri", item.toString()).put("name", c.getString(1) ?: "")
                    .put("video", video).put("date", c.getLong(3) * 1000).put("size", c.getLong(4))
                try {
                    val bmp = ctx.contentResolver.loadThumbnail(item, Size(240, 240), null)
                    o.put("thumb", jpeg(bmp, 70))
                } catch (_: Exception) {}
                a.put(o)
            }
        }
        return a
    }

    private fun jpeg(b: Bitmap, q: Int): String {
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.JPEG, q, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    // ---- files (needs "All files access") ----

    private val root: String get() = Environment.getExternalStorageDirectory().absolutePath

    /** Paths from the Mac are relative to the phone's storage root ("" = root). */
    fun storagePath(rel: String): String {
        val f = File(root, rel.trimStart('/')).canonicalFile
        // inside the storage root only ("/storage/emulated/0x" must not pass as "…/0")
        require(f.path == root || f.path.startsWith("$root/")) { "outside storage" }
        return f.path
    }

    /** Deletes a file or folder, but never the storage root or a top-level folder (DCIM, Download…). */
    private fun deletePath(rel: String): Boolean {
        if (!Environment.isExternalStorageManager()) throw SecurityException("files")
        val f = File(storagePath(rel))
        require(f.path != root && f.parentFile?.path != root) { "PhoneCast doesn't delete the storage or its top-level folders" }
        return f.deleteRecursively()
    }

    private fun files(rel: String): JSONObject {
        if (!Environment.isExternalStorageManager()) throw SecurityException("files")
        val dir = File(storagePath(rel))
        val list = (dir.listFiles() ?: emptyArray()).filter { !it.name.startsWith(".") }
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
        val a = JSONArray()
        for (f in list) a.put(JSONObject().put("name", f.name).put("dir", f.isDirectory)
            .put("size", if (f.isDirectory) (f.list()?.size ?: 0).toLong() else f.length()).put("date", f.lastModified()))
        return JSONObject().put("path", dir.path.removePrefix(root).trimStart('/')).put("items", a)
    }

    // ---- apps ----

    private fun apps(): JSONArray {
        val pm = ctx.packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val a = JSONArray()
        pm.queryIntentActivities(launch, 0).map { it.activityInfo.applicationInfo }.distinctBy { it.packageName }
            .filter { it.packageName != ctx.packageName }
            .sortedBy { pm.getApplicationLabel(it).toString().lowercase() }
            .forEach { ai ->
                val o = JSONObject().put("pkg", ai.packageName).put("name", pm.getApplicationLabel(ai).toString())
                try {
                    val d = pm.getApplicationIcon(ai)
                    val b = Bitmap.createBitmap(72, 72, Bitmap.Config.ARGB_8888)
                    d.setBounds(0, 0, 72, 72); d.draw(Canvas(b))
                    val out = ByteArrayOutputStream(); b.compress(Bitmap.CompressFormat.PNG, 100, out)
                    o.put("icon", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP))
                } catch (_: Exception) {}
                a.put(o)
            }
        return a
    }

    private fun openApp(pkg: String): Boolean {
        val i = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // background apps may not start activities; the accessibility service may
        val svc = InputService.instance
        if (svc != null) svc.startActivity(i) else ctx.startActivity(i)
        return true
    }
}
