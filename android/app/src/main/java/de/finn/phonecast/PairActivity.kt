package de.finn.phonecast

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.widget.Toast

/**
 * Opens "phonecast:pair?…" links, so the phone's normal camera (or any QR app) can pair too.
 * A link can come from anywhere (a website, another app), so nothing is stored without the user
 * confirming the computer's name first.
 */
class PairActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.dataString ?: run { finish(); return }
        val q = Pairing.parse(text)
        if (q == null || q["id"].isNullOrEmpty() || q["k"].isNullOrEmpty()) {
            Toast.makeText(this, "That's not a PhoneCast pairing code", Toast.LENGTH_LONG).show(); finish(); return
        }
        val name = q["n"]?.takeIf { it.isNotBlank() } ?: "a computer"
        AlertDialog.Builder(this)
            .setTitle("Pair with $name?")
            .setMessage("$name will be able to show and control this phone (once you start sharing) without a PIN. Only pair computers you own.")
            .setPositiveButton("Pair") { _, _ ->
                val (ok, msg) = Pairing.pair(this, text)
                Toast.makeText(this, msg, Toast.LENGTH_LONG).show()
                if (ok) setResult(RESULT_OK)
                finish()
            }
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }
}
