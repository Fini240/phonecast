import AppKit

/// "Advanced (USB debugging)": what Android only allows the shell user, done by starting scrcpy
/// (`brew install scrcpy`) against the phone over adb, USB or wireless debugging. This is the same
/// thing LinkMyMac's "Advanced Mirroring" needs debugging for:
///  - phone apps in their own Mac windows (each on its own virtual display)
///  - the phone's camera in a window (Zoom/Meet screen share, OBS window capture)
///  - the phone's microphone played on the Mac
///  - the phone's screen really off while PhoneCast mirrors it (the panel goes dark, the picture keeps coming)
/// Nothing here is needed for the normal features.
enum Advanced {
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                                      NSHomeDirectory() + "/Library/Android/sdk/platform-tools"]
    static func tool(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var adb: String? { tool("adb") }
    static var scrcpy: String? { tool("scrcpy") }

    /// Running helpers by job ("app:<pkg>", "camera", "mic", "screenoff").
    private static var jobs: [String: Process] = [:]
    static func running(_ job: String) -> Bool { jobs[job]?.isRunning == true }

    // MARK: device

    struct Device { let serial: String; let model: String; let wireless: Bool }

    /// Phones adb can talk to right now ("device" state only: unauthorized/offline ones can't be used).
    static func devices() -> [Device] {
        guard let adb, let out = run(adb, ["devices", "-l"], timeout: 8) else { return [] }
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? parts[0]
            return Device(serial: parts[0], model: model, wireless: parts[0].contains(":") || parts[0].contains("._adb-tls-connect"))
        }
    }

    /// The phone to use: the one picked in Settings, else the only/first one.
    static func device() -> Device? {
        let all = devices()
        let want = UserDefaults.standard.string(forKey: "advancedSerial")
        return all.first { $0.serial == want } ?? all.first
    }

    /// One line for Settings and the menu.
    static func status() -> String {
        if scrcpy == nil { return tr("scrcpy isn't installed. In Terminal: brew install scrcpy") }
        if adb == nil { return tr("adb isn't installed. In Terminal: brew install android-platform-tools") }
        guard let d = device() else {
            return tr("No phone with USB debugging found. Turn on USB debugging (or Wireless debugging) and allow this Mac on the phone.")
        }
        return tr("Ready: %@ (%@)", d.model, d.wireless ? tr("wireless debugging") : tr("USB"))
    }

    // MARK: jobs

    /// Size of the virtual display an app window gets ("tall", "wide" or "phone").
    static var appShape: String {
        get { UserDefaults.standard.string(forKey: "appWindowShape") ?? "tall" }
        set { UserDefaults.standard.set(newValue, forKey: "appWindowShape") }
    }

    /// Opens one phone app in its own Mac window. Closing the window moves the app back to the phone's screen.
    static func openAppWindow(pkg: String, name: String) {
        let size: String
        switch appShape {
        case "wide": size = "--new-display=2000x1200/320"
        case "phone": size = "--new-display"
        default: size = "--new-display=1080x2160/400"
        }
        start("app:\(pkg)", [size, "--start-app=\(pkg)", "--no-vd-destroy-content", "--no-vd-system-decorations", "--no-audio",
                             "--window-title=\(name)", "--display-ime-policy=local"], what: name)
    }

    /// The phone's camera in a window. Share that window in a call, or capture it in OBS.
    static func camera(facing: String) {
        stop("camera")
        start("camera", ["--video-source=camera", "--camera-facing=\(facing)", "--max-size=1920", "--no-audio", "--no-control",
                         "--window-title=\(tr("Phone camera"))"], what: tr("Phone camera"))
    }

    /// The phone's microphone, played on the Mac (no window). For a Mac app to record it as an input,
    /// route the Mac's output through a loopback device such as BlackHole.
    static func microphone(_ on: Bool) {
        if !on { stop("mic"); return }
        start("mic", ["--no-video", "--no-window", "--no-control", "--audio-source=mic"], what: tr("Phone microphone"))
    }

    /// Turns the phone's panel off while it keeps drawing, so PhoneCast's mirror keeps working with a dark phone.
    static func screenOff(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "advancedScreenOff")
        if !on { stop("screenoff"); return }
        // A tiny 1 fps stream nobody looks at keeps scrcpy's connection (and its "screen off") alive.
        start("screenoff", ["--no-window", "--no-audio", "--turn-screen-off", "--max-size=320", "--max-fps=1",
                            "--video-bit-rate=200K", "--no-power-on"], what: tr("Screen off"))
    }

    static func stop(_ job: String) {
        if let p = jobs.removeValue(forKey: job), p.isRunning { p.terminate() }
    }

    static func stopAll() { for k in Array(jobs.keys) { stop(k) } }

    private static func start(_ job: String, _ args: [String], what: String) {
        guard let scrcpy else { Banners.shared.info(tr("scrcpy isn't installed"), tr("In Terminal: brew install scrcpy")); return }
        guard let d = device() else {
            Banners.shared.info(tr("No phone with USB debugging"), tr("Turn on USB debugging (or Wireless debugging) and allow this Mac on the phone."))
            return
        }
        stop(job)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scrcpy)
        p.arguments = ["-s", d.serial] + args
        var env = ProcessInfo.processInfo.environment
        if let adb { env["ADB"] = adb }
        env["PATH"] = (searchPaths + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        p.environment = env
        let err = Pipe()
        p.standardError = err; p.standardOutput = err
        let started = Date()
        p.terminationHandler = { proc in
            let out = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                if jobs[job] === proc { jobs[job] = nil }
                // a quick exit with an error: tell why (old Android, app not found, debugging revoked…)
                if proc.terminationStatus != 0 && Date().timeIntervalSince(started) < 8 {
                    let line = out.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? out.split(separator: "\n").last.map(String.init) ?? ""
                    Banners.shared.info(tr("%@ didn't start", what), line.replacingOccurrences(of: "ERROR: ", with: ""))
                    NSLog("scrcpy \(job) failed:\n\(out)")
                }
            }
        }
        do { try p.run(); jobs[job] = p } catch { Banners.shared.info(tr("%@ didn't start", what), error.localizedDescription) }
    }

    // MARK: wireless debugging (no cable)

    /// `adb pair` with the code from Developer options → Wireless debugging → Pair device with pairing code.
    static func pair(_ hostPort: String, code: String, done: @escaping (String) -> Void) {
        guard let adb else { done(tr("adb isn't installed")); return }
        DispatchQueue.global().async {
            let out = run(adb, ["pair", hostPort.trimmingCharacters(in: .whitespaces), code.trimmingCharacters(in: .whitespaces)], timeout: 20) ?? ""
            DispatchQueue.main.async { done(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// `adb connect` to the address shown under Wireless debugging (it changes when Wi-Fi changes).
    static func connect(_ hostPort: String, done: @escaping (String) -> Void) {
        guard let adb else { done(tr("adb isn't installed")); return }
        DispatchQueue.global().async {
            let out = run(adb, ["connect", hostPort.trimmingCharacters(in: .whitespaces)], timeout: 15) ?? ""
            DispatchQueue.main.async { done(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // MARK: helpers

    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: Double) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return String(decoding: d, as: UTF8.self)
    }
}
