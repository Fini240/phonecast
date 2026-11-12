import AppKit

/// v0.8 continuity bits: where the phone is, the Mac's browser tab on the phone, and the Mac's
/// Shortcuts as buttons on the phone.
enum Continuity {

    // MARK: locate the phone

    /// Asks the phone where it is and shows it in Maps.
    static func locatePhone() {
        let hub = Hub.shared
        guard hub.connected else { Banners.shared.info("Phone not connected", "It can only be found while PhoneCast is connected."); return }
        Banners.shared.info("Locating the phone…", "This can take up to 20 seconds.")
        hub.request("phone.locate", [:], timeout: 30) { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let d):
                    guard let o = d as? [String: Any], let lat = o["lat"] as? Double, let lon = o["lon"] as? Double else { return }
                    let acc = (o["acc"] as? Double).map { " (±\(Int($0)) m)" } ?? ""
                    let t = (o["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    let ago = t.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? ""
                    let name = (Hub.shared.store.phoneName as NSString).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Phone"
                    if let u = URL(string: "maps://?ll=\(lat),\(lon)&q=\(name)") { NSWorkspace.shared.open(u) }
                    Banners.shared.info(tr("Phone found") + acc, ago.isEmpty ? tr("Shown in Maps") : tr("Position from %@", ago))
                case .failure(let e):
                    Banners.shared.info("Couldn't locate the phone",
                        e.permission ? "On the phone: PhoneCast → Settings → Allow location (Allow all the time)." : e.message)
                }
            }
        }
    }

    // MARK: browser tab → phone

    /// The front tab of the browser in front (or the most recently used one that's running).
    static func frontTab() -> String? {
        let browsers: [(String, String)] = [
            ("com.apple.Safari", "tell application \"Safari\" to return URL of front document"),
            ("com.google.Chrome", "tell application \"Google Chrome\" to return URL of active tab of front window"),
            ("company.thebrowser.Browser", "tell application \"Arc\" to return URL of active tab of front window"),
            ("com.brave.Browser", "tell application \"Brave Browser\" to return URL of active tab of front window"),
            ("com.microsoft.edgemac", "tell application \"Microsoft Edge\" to return URL of active tab of front window"),
        ]
        let running = NSWorkspace.shared.runningApplications
        // the browser that is in front first, then any running one
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let order = browsers.sorted { a, _ in a.0 == front }
        for (id, script) in order where running.contains(where: { $0.bundleIdentifier == id }) {
            var err: NSDictionary?
            if let url = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, url.hasPrefix("http") { return url }
        }
        return nil
    }

    static func sendTabToPhone() {
        let hub = Hub.shared
        guard hub.connected else { Banners.shared.info("Phone not connected", ""); return }
        guard let url = frontTab() else {
            Banners.shared.info("No browser tab found", "Open the page in Safari, Chrome, Arc, Brave or Edge. macOS may ask once to let PhoneCast read the tab.")
            return
        }
        hub.request("url.open", ["url": url]) { r in
            if case .failure(let e) = r { Banners.shared.info("Couldn't open the tab on the phone", e.message) }
        }
    }

    // MARK: phone storage in Finder

    /// Asks the phone to start its WebDAV server (WebDav.kt) and mounts it, so the phone's storage is a
    /// drive in Finder. The phone stops the server after 30 minutes without use.
    static func openInFinder() {
        let hub = Hub.shared
        guard hub.connected else { Banners.shared.info(tr("Phone not connected"), ""); return }
        NSLog("phone in Finder: asking the phone")
        hub.request("webdav.start", [:]) { r in
            NSLog("phone in Finder: phone answered \(String(describing: r).prefix(120))")
            DispatchQueue.main.async {
                switch r {
                case .failure(let e):
                    Banners.shared.info(tr("Couldn't open the phone in Finder"),
                        e.permission ? tr("On the phone: PhoneCast → Settings → Allow browsing phone files.") : e.message)
                case .success(let d):
                    guard let o = d as? [String: Any], let port = o["port"] as? Int, let user = o["user"] as? String, let pass = o["pass"] as? String else { return }
                    var host = (o["host"] as? String) ?? ""
                    if host.isEmpty { host = UserDefaults.standard.string(forKey: "lastHubHost") ?? "" }
                    if host.contains(":") { host = "[\(host)]" }   // IPv6
                    // already mounted (same address): just show it
                    if let v = mountedVolume(host: host, port: port) { NSWorkspace.shared.open(v); return }
                    DispatchQueue.global().async {
                        // osascript, not NSAppleScript: that one only works on the main thread, and mounting takes seconds.
                        // The script (with the password) goes in on stdin, so it never shows up in `ps`.
                        let script = "mount volume \"http://\(host):\(port)/\" as user name \"\(user)\" with password \"\(pass)\""
                        let p = Process(), inp = Pipe(), out = Pipe()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-"]
                        p.standardInput = inp; p.standardOutput = out; p.standardError = out
                        try? p.run()
                        inp.fileHandleForWriting.write(Data(script.utf8)); try? inp.fileHandleForWriting.close()
                        let msg = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        p.waitUntilExit()
                        NSLog("phone in Finder: mount http://\(host):\(port)/ -> \(p.terminationStatus) \(msg)")
                        DispatchQueue.main.async {
                            if let v = mountedVolume(host: host, port: port) { NSWorkspace.shared.open(v) }
                            else { Banners.shared.info(tr("Couldn't mount the phone"), msg.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }
                    }
                }
            }
        }
    }

    private static func mountedVolume(host: String, port: Int) -> URL? {
        // Finder names a WebDAV volume after the host ("/Volumes/192.168.1.20")
        let byName = URL(fileURLWithPath: "/Volumes/" + host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        if FileManager.default.fileExists(atPath: byName.path) { return byName }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            if let r = try? v.resourceValues(forKeys: Set(keys)).volumeURLForRemounting,
               r.host == host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), r.port == port { return v }
        }
        return nil
    }

    // MARK: Shortcuts for the phone

    private static var cached: [String] = []
    private static var cachedAt: Date = .distantPast

    /// The Mac's Shortcuts (Shortcuts app), refreshed every few minutes in the background.
    static var shortcuts: [String] {
        if Date().timeIntervalSince(cachedAt) > 300 {
            cachedAt = Date()
            DispatchQueue.global(qos: .utility).async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return }
                let out = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let names = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                DispatchQueue.main.async { cached = Array(names.prefix(40)) }
            }
        }
        return cached
    }

    /// From the phone: run one of the Mac's Shortcuts by name.
    static func runShortcut(_ name: String) {
        guard shortcuts.contains(name) else { NSLog("shortcut not found: \(name)"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
        p.terminationHandler = { t in
            if t.terminationStatus != 0 { DispatchQueue.main.async { Banners.shared.info("Shortcut failed", name) } }
        }
        try? p.run()
    }
}
