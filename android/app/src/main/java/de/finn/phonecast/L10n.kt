package de.finn.phonecast

import java.util.Locale

/**
 * Translations: the app follows the phone's language (German phones get German, everything else English).
 * The UI kit (Ui.kt) and toasts call [tr] themselves, so most code just passes English text.
 * Templates use {0}, {1}: tr("Remove {0}?", name).
 */
private val german: Boolean get() = Locale.getDefault().language == "de"

fun tr(s: String, vararg args: Any?): String {
    var out = if (german) DE[s] ?: s else s
    args.forEachIndexed { i, a -> out = out.replace("{$i}", a?.toString() ?: "") }
    return out
}

private val DE = mapOf(
    // tabs & pages
    "Home" to "Start", "Mac" to "Mac", "PC" to "PC", "Cast" to "Teilen", "Settings" to "Einstellungen", "PhoneCast" to "PhoneCast",
    // home
    "Finish setting up" to "Einrichtung abschließen",
    "Starting…" to "Startet…",
    "No computer connected" to "Kein Computer verbunden",
    "Open PhoneCast on the Mac. Same Wi-Fi or Tailscale; pair once in Settings." to "Öffne PhoneCast auf dem Mac. Gleiches WLAN oder Tailscale; einmal in den Einstellungen koppeln.",
    "Connected" to "Verbunden",
    "Connected · {0} ms" to "Verbunden · {0} ms",
    "screen shared" to "Bildschirm geteilt",
    "notifications on" to "Mitteilungen an",
    "notifications off" to "Mitteilungen aus",
    "Stop casting" to "Teilen beenden",
    "Cast this phone" to "Dieses Handy teilen",
    "Shown once the Mac is connected." to "Erscheint, sobald der Mac verbunden ist.",
    "Pair a computer" to "Computer koppeln",
    "Mouse & keyboard" to "Maus & Tastatur",
    "Notifications" to "Mitteilungen",
    "Messages, calls, photos" to "Nachrichten, Anrufe, Fotos",
    "done" to "erledigt", "to do" to "offen",
    "Set up: {0}" to "Einrichten: {0}",
    "Update available" to "Update verfügbar",
    "Install update" to "Update installieren",
    "What's new" to "Was ist neu",
    "PhoneCast {0} is out (you have {1}). It installs over this app; your pairing stays." to "PhoneCast {0} ist da (du hast {1}). Es wird über diese App installiert; die Kopplung bleibt.",
    "Downloading…" to "Wird geladen…", "Downloading… {0} %" to "Wird geladen… {0} %", "Installing…" to "Wird installiert…",
    "Mac screen" to "Mac-Bildschirm",
    "Send files" to "Dateien senden",
    "Clipboard" to "Zwischenablage",
    "Devices" to "Geräte",
    "connected" to "verbunden", "offline" to "offline",
    // mac tab
    "The Mac isn't connected" to "Der Mac ist nicht verbunden",
    "Mac not connected" to "Mac nicht verbunden",
    "Open PhoneCast on the Mac." to "Öffne PhoneCast auf dem Mac.",
    "Battery" to "Akku", "CPU" to "CPU", "Memory" to "Arbeitsspeicher", "Heat" to "Wärme",
    "{0} % · on power" to "{0} % · am Strom",
    "Control the Mac" to "Mac steuern",
    "Tap = click, drag = drag, long press or two-finger tap = right click, two fingers = scroll." to
        "Tippen = Klick, Ziehen = Ziehen, lange drücken oder mit zwei Fingern tippen = Rechtsklick, zwei Finger = Scrollen.",
    "Open the Mac's screen" to "Mac-Bildschirm öffnen",
    "Trackpad & keyboard only" to "Nur Trackpad & Tastatur",
    "Trackpad mode shows no picture: it saves battery and works on a slow connection." to
        "Der Trackpad-Modus zeigt kein Bild: Er spart Akku und läuft auch bei langsamer Verbindung.",
    "Keys" to "Tasten", "Vol −" to "Leiser", "Mute" to "Stumm", "Vol +" to "Lauter",
    "Lock" to "Sperren", "Screen off" to "Bildschirm aus", "Screenshot" to "Bildschirmfoto",
    "Send to the Mac" to "An den Mac senden", "Files" to "Dateien",
    // pc tab
    "Anything unsaved on the PC may be lost." to "Nicht Gespeichertes auf dem PC kann verloren gehen.",
    "Do it" to "Ausführen", "Cancel" to "Abbrechen",
    "Waiting for the dashboard…" to "Warte auf das Dashboard…",
    "The PC is asleep or off" to "Der PC schläft oder ist aus",
    "GPU" to "Grafikkarte", "Video memory" to "Grafikspeicher", "GPU temp" to "GPU-Temperatur", "GPU power" to "GPU-Leistung",
    "CPU temp" to "CPU-Temperatur", "RAM" to "RAM", "Up for" to "Läuft seit", "Engine" to "Engine", "Loaded" to "Geladen", "nothing" to "nichts",
    "Power" to "Strom", "Wake" to "Aufwecken", "Sleep" to "Ruhezustand", "Put the PC to sleep?" to "PC in den Ruhezustand schicken?",
    "Shut down" to "Herunterfahren", "Shut the PC down?" to "PC herunterfahren?",
    "Start Linux" to "Linux starten", "Restart into Linux?" to "In Linux neu starten?",
    "Start Windows" to "Windows starten", "Restart into Windows?" to "In Windows neu starten?",
    "Monitors & lights" to "Monitore & Licht", "Monitors on" to "Monitore an", "Monitors off" to "Monitore aus", "Off" to "Aus", "On" to "An",
    "Lights follow the PC's load" to "Licht folgt der PC-Auslastung",
    "Control" to "Steuern", "Chat" to "Chat", "Builder" to "Builder", "Studio" to "Studio",
    "Windows (no switch)" to "Windows (kein Wechsel)", "Making a video" to "Erstellt ein Video", "Switching OS" to "Wechselt System",
    "Switching engines works while the PC runs Linux. Strata takes about 80 s to load." to "Die Engine lässt sich wechseln, solange der PC Linux nutzt. Strata braucht ca. 80 s zum Laden.",
    "Hermes tokens" to "Hermes-Tokens", "In" to "Rein", "Out" to "Raus", "Calls" to "Aufrufe", " · {0} cached" to " · {0} aus Cache",
    "{0} in {1} sessions" to "{0} in {1} Sitzungen", "Last session" to "Letzte Sitzung", "calls" to "Aufrufe",
    "Saving {0} to Downloads" to "Speichere {0} in Downloads",
    "AI" to "KI", "Switching engines works while the PC runs Linux." to "Die Engine lässt sich wechseln, solange der PC Linux nutzt.",
    "Use the PC" to "PC benutzen",
    "Moonlight streams the PC (Sunshine) to this phone with touch, mouse and gamepad." to
        "Moonlight streamt den PC (Sunshine) auf dieses Handy, mit Touch, Maus und Controller.",
    "Open Moonlight" to "Moonlight öffnen", "Full dashboard" to "Ganzes Dashboard",
    "The controls only work over Tailscale (the dashboard refuses everything else)." to
        "Die Steuerung klappt nur über Tailscale (das Dashboard lehnt alles andere ab).",
    "That address doesn't look like AA:BB:CC:DD:EE:FF" to "Die Adresse sieht nicht aus wie AA:BB:CC:DD:EE:FF",
    "Wake signal sent. The PC needs about 20 s to boot." to "Weck-Signal gesendet. Der PC braucht etwa 20 s zum Starten.",
    "Couldn't send (no Wi-Fi?)" to "Konnte nicht senden (kein WLAN?)",
    "Dashboard address" to "Dashboard-Adresse", "Empty = use the one set on the Mac." to "Leer = die vom Mac verwenden.", "Save" to "Speichern",
    "PC's network card address (MAC)" to "Netzwerkkarten-Adresse des PCs (MAC)",
    "For Wake-on-LAN. On Linux: ip link · on Windows: getmac" to "Für Wake-on-LAN. Unter Linux: ip link · unter Windows: getmac",
    // cast tab
    "Resolution (long side)" to "Auflösung (lange Seite)", "Native" to "Original",
    "{0} px, set by the computer" to "{0} px, vom Computer eingestellt", "{0}, set by the computer" to "{0}, vom Computer eingestellt",
    "Bitrate (Mbit/s)" to "Bitrate (Mbit/s)", "Game audio" to "Ton übertragen",
    "Takes effect next time you start sharing" to "Gilt ab dem nächsten Teilen",
    "Back to normal shape" to "Zurück zur normalen Form",
    "How to allow it" to "So erlaubst du es",
    "Once, from a computer with USB debugging on:" to "Einmalig, von einem Computer mit USB-Debugging:",
    "Not sharing" to "Nicht geteilt",
    "Faster next time: the “Cast to Mac” Quick Settings tile." to "Schneller: die Schnelleinstellung „Cast to Mac“.",
    "Shown on the Mac" to "Wird auf dem Mac gezeigt", "over the USB cable" to "über das USB-Kabel",
    "Shown on a computer" to "Wird auf einem Computer gezeigt", "Sharing" to "Wird geteilt",
    "Waiting for the Mac or PC to connect…" to "Warte, bis sich Mac oder PC verbindet…",
    "Stop sharing" to "Teilen beenden",
    "The Mac or PC can tap and type." to "Mac oder PC können tippen und schreiben.",
    "The Mac or PC can only watch." to "Mac oder PC können nur zuschauen.",
    "Accessibility settings" to "Bedienungshilfen", "Turn on mouse & keyboard" to "Maus & Tastatur einschalten",
    "The Mac can fit the phone's screen shape to its display. That needs a one-time permission." to
        "Der Mac kann die Bildschirmform des Handys an seinen Bildschirm anpassen. Dafür ist einmalig eine Erlaubnis nötig.",
    "Changed to fit the Mac ({0}×{1}). Set it back before using the phone on its own." to
        "An den Mac angepasst ({0}×{1}). Stell sie zurück, bevor du das Handy allein nutzt.",
    "Normal." to "Normal.",
    "Fit the Mac again ({0}:{1})" to "Wieder an den Mac anpassen ({0}:{1})",
    "Help" to "Hilfe",
    "Uses an Accessibility service to tap for you. If Android says \"Restricted setting\": App info → ⋮ → Allow restricted settings, then try again." to
        "Nutzt eine Bedienungshilfe, die für dich tippt. Sagt Android „Eingeschränkte Einstellung“: App-Info → ⋮ → Eingeschränkte Einstellungen zulassen, dann nochmal.",
    "Games may treat tap injection like a cheat tool. Test on a throwaway account first." to
        "Spiele könnten das wie ein Cheat-Tool behandeln. Teste es zuerst mit einem Zweitkonto.",
    "Quality" to "Qualität",
    "A connected Mac or PC sets resolution and bitrate from its own Quality menu." to
        "Ein verbundener Mac oder PC stellt Auflösung und Bitrate über sein eigenes Qualität-Menü ein.",
    "Screen shape" to "Bildschirmform",
    // settings
    "Allow notification access" to "Mitteilungszugriff erlauben",
    "Copy to the Mac automatically" to "Automatisch zum Mac kopieren",
    "Send new screenshots to the Mac" to "Neue Screenshots an den Mac senden",
    "Allow messages, calls, contacts & photos" to "Nachrichten, Anrufe, Kontakte & Fotos erlauben",
    "Allow browsing phone files" to "Durchsuchen der Handy-Dateien erlauben",
    "No network. Connect to Wi-Fi." to "Kein Netzwerk. Verbinde dich mit einem WLAN.",
    "Notifications go to the Mac" to "Mitteilungen gehen an den Mac",
    "Notifications stay on the phone" to "Mitteilungen bleiben auf dem Handy",
    "They land in Downloads/PhoneCast and on the Mac's clipboard" to "Sie landen in Downloads/PhoneCast und in der Zwischenablage des Macs",
    "Needs mouse & keyboard turned on (Cast tab)" to "Braucht Maus & Tastatur (Tab „Teilen“)",
    "Copy here, paste on the Mac" to "Hier kopieren, auf dem Mac einfügen",
    "Messages" to "Nachrichten", "Calls" to "Anrufe", "Answer & dial" to "Annehmen & wählen", "Contacts" to "Kontakte", "Photos" to "Fotos",
    "allowed" to "erlaubt", "off" to "aus",
    "Not set. With a Hermes-style dashboard, the PC tab shows your PC and its controls." to
        "Nicht gesetzt. Mit einem Dashboard im Hermes-Stil zeigt der PC-Tab deinen PC und seine Steuerung.",
    "  (from the Mac)" to "  (vom Mac)",
    "No computer paired yet." to "Noch kein Computer gekoppelt.",
    "Remove" to "Entfernen", "Remove {0}?" to "{0} entfernen?",
    "It can't connect until you scan its code again (or enter the PIN)." to "Er kann sich erst wieder verbinden, wenn du seinen Code erneut scannst (oder die PIN eingibst).",
    "Paired computers" to "Gekoppelte Computer",
    "Scan a computer's QR code" to "QR-Code eines Computers scannen",
    "On the Mac or PC: PhoneCast → Settings shows the code. No PIN needed, and both sides prove a shared key on every connection." to
        "Auf dem Mac oder PC: PhoneCast → Einstellungen zeigt den Code. Keine PIN nötig, und beide Seiten prüfen bei jeder Verbindung einen gemeinsamen Schlüssel.",
    "Pair with a PIN instead" to "Stattdessen mit PIN koppeln",
    "Enter this on the computer once:" to "Gib das einmal am Computer ein:",
    "Link key (the Mac shows the same in Settings)" to "Verbindungsschlüssel (der Mac zeigt denselben in den Einstellungen)",
    "New PIN" to "Neue PIN", "Make a new PIN?" to "Neue PIN erstellen?",
    "Computers paired with the PIN have to enter the new one. QR-paired computers stay paired." to
        "Mit PIN gekoppelte Computer müssen die neue eingeben. Per QR gekoppelte bleiben gekoppelt.",
    "New PIN made" to "Neue PIN erstellt",
    "On the Mac" to "Auf dem Mac", "Phone features on the Mac" to "Handy-Funktionen auf dem Mac",
    "Sideloaded apps may first need App info → ⋮ → Allow restricted settings." to
        "Bei selbst installierten Apps evtl. zuerst: App-Info → ⋮ → Eingeschränkte Einstellungen zulassen.",
    "PC dashboard (optional)" to "PC-Dashboard (optional)", "Set the dashboard address…" to "Dashboard-Adresse festlegen…",
    "Wi-Fi" to "WLAN", "Tailscale / VPN" to "Tailscale / VPN", "Cable" to "Kabel",
    // toasts & messages (all files)
    "Not connected to the Mac" to "Nicht mit dem Mac verbunden",
    "The clipboard is empty" to "Die Zwischenablage ist leer",
    "Screen sharing was not allowed" to "Bildschirmfreigabe wurde nicht erlaubt",
    "Needs the one-time permission (see above)" to "Braucht die einmalige Erlaubnis (siehe oben)",
    "Android refused to change the screen shape" to "Android hat das Ändern der Bildschirmform abgelehnt",
    "Copied to the Mac" to "Zum Mac kopiert", "Copied from the Mac" to "Vom Mac kopiert",
    "Picture copied to the Mac" to "Bild zum Mac kopiert", "Picture copied from the Mac" to "Bild vom Mac kopiert",
    "Found it!" to "Gefunden!", "Your Mac is ringing this phone. Tap to stop." to "Dein Mac lässt dieses Handy klingeln. Zum Beenden tippen.", "Stop" to "Stopp",
    "Update failed: {0}" to "Update fehlgeschlagen: {0}", "Update not installed: {0}" to "Update nicht installiert: {0}",
    "Connected to {0}" to "Verbunden mit {0}", "Waiting for the Mac" to "Warte auf den Mac", "PhoneCast link" to "PhoneCast-Verbindung",
    "From the Mac: {0}" to "Vom Mac: {0}", "Saved in Downloads/PhoneCast · {0}" to "Gespeichert in Downloads/PhoneCast · {0}",
    "The Mac wants to show this phone" to "Der Mac möchte dieses Handy anzeigen", "Tap to start sharing" to "Zum Teilen tippen",
    // trackpad
    "Trackpad\n\nOne finger: move   ·   tap: click\nTwo fingers: scroll   ·   two-finger tap: right click\nHold, then move: drag" to
        "Trackpad\n\nEin Finger: bewegen   ·   tippen: Klick\nZwei Finger: scrollen   ·   mit zwei tippen: Rechtsklick\nHalten, dann bewegen: ziehen",
    "Connecting to the Mac…" to "Verbinde mit dem Mac…",
    "Not connected to the Mac.\nOpen PhoneCast on the Mac first (it connects by itself)." to
        "Nicht mit dem Mac verbunden.\nÖffne zuerst PhoneCast auf dem Mac (es verbindet sich von selbst).",
)
