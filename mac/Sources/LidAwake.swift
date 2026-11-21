import AppKit
import IOKit.ps

/// "Stay awake with lid closed": a MacBook always sleeps when its lid shuts (without an external display),
/// whatever sleep assertion an app holds. Only `pmset -a disablesleep 1` (root) stops that, so PhoneCast
/// installs a one-line sudoers rule once that allows exactly `pmset -a disablesleep 0|1`, nothing else.
///
/// Safety, because a fanless Air in a closed bag gets hot:
///  - turns itself off on battery below `minBattery` %, after the chosen time, and when the Mac gets too hot
///  - a small watchdog process turns it off if PhoneCast quits or crashes
///  - the menu bar shows ☕︎ while it's on
final class LidAwake: ObservableObject {
    static let shared = LidAwake()

    static let rulePath = "/etc/sudoers.d/phonecast-lidawake"
    private static let pmset = "/usr/bin/pmset"

    /// Sleep is really disabled right now (read back from `pmset -g`).
    @Published private(set) var on = false
    /// When it switches itself off; nil = until turned off.
    @Published private(set) var until: Date?
    @Published private(set) var ready = FileManager.default.fileExists(atPath: LidAwake.rulePath)
    @Published var lastNote = ""
    @Published var minBattery: Int = UserDefaults.standard.object(forKey: "lidAwakeMinBattery") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(minBattery, forKey: "lidAwakeMinBattery"); check() }
    }

    private var watchdog: Process?
    private var timer: Timer?
    private var hotSince: Date?

    private init() {}

    /// At launch: if an earlier PhoneCast run left sleep disabled (crash before the watchdog fired, or a forced quit
    /// of both), switch it back on — a new session starts with normal sleep.
    func start() {
        let d = UserDefaults.standard
        if d.bool(forKey: "lidAwakeOwned"), Self.readSleepDisabled() { setPmset(false) }
        d.set(false, forKey: "lidAwakeOwned")
        on = Self.readSleepDisabled()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: turning it on and off

    /// minutes: 0 = until turned off.
    func enable(minutes: Int, from: String = "Mac") {
        guard ready || ruleWorks() else {
            // first time: macOS asks for the password (off the main thread, so the phone link keeps running)
            installRule { [weak self] ok in if ok { self?.enable(minutes: minutes, from: from) } }
            return
        }
        if let b = Self.battery(), !b.charging, b.percent <= minBattery {
            note(tr("Not turned on: the battery is at %d %% (limit %d %%).", b.percent, minBattery)); return
        }
        until = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        guard setPmset(true) else { until = nil; return }
        UserDefaults.standard.set(true, forKey: "lidAwakeOwned")
        startWatchdog()
        hotSince = nil
        note(minutes > 0 ? tr("On until %@.", Self.time(until!)) : tr("On until you turn it off."))
        NSLog("lid awake on (\(minutes) min, from \(from))")
        changed()
    }

    func disable(reason: String? = nil) {
        stopWatchdog()
        let was = on
        setPmset(false)
        UserDefaults.standard.set(false, forKey: "lidAwakeOwned")
        until = nil
        if let reason {
            note(reason)
            if was { Banners.shared.info(tr("The Mac sleeps normally again"), reason) }
        } else { note("") }
        changed()
    }

    /// The phone's Mac tab: "lidawake:off", "lidawake:<minutes>" (0 = until off).
    func action(_ arg: String) {
        if arg == "off" { disable(); return }
        enable(minutes: Int(arg) ?? 0, from: "phone")
    }

    /// Text for menus and the phone.
    var summary: String {
        guard on else { return tr("Off: the Mac sleeps when the lid closes") }
        if let until { return tr("On until %@", Self.time(until)) }
        return tr("On until you turn it off")
    }

    var statusForPhone: [String: Any] {
        var o: [String: Any] = ["on": on, "ready": ready, "min": minBattery]
        if let until { o["until"] = Int(until.timeIntervalSince1970) }
        if !lastNote.isEmpty { o["note"] = lastNote }
        return o
    }

    // MARK: safety checks (every 15 s)

    func check() {
        let really = Self.readSleepDisabled()
        if really != on { on = really; changed() }
        guard on else { hotSince = nil; return }
        // someone else (Terminal) turned it on: we don't own it, leave it alone apart from showing it
        guard UserDefaults.standard.bool(forKey: "lidAwakeOwned") else { return }
        if let until, Date() >= until { disable(reason: tr("The time you set is up.")); return }
        if let b = Self.battery(), !b.charging, b.percent <= minBattery {
            disable(reason: tr("The battery is down to %d %%.", b.percent)); return
        }
        switch ProcessInfo.processInfo.thermalState {
        case .critical: disable(reason: tr("The Mac got too hot.")); return
        case .serious:
            if hotSince == nil { hotSince = Date() }
            if let h = hotSince, Date().timeIntervalSince(h) > 300 { disable(reason: tr("The Mac stayed too hot for 5 minutes.")); return }
        default: hotSince = nil
        }
    }

    /// App quits normally.
    func stopOnQuit() {
        guard UserDefaults.standard.bool(forKey: "lidAwakeOwned") else { return }
        stopWatchdog(); setPmset(false); UserDefaults.standard.set(false, forKey: "lidAwakeOwned")
    }

    // MARK: the sudoers rule

    private var installing = false

    private func ruleWorks() -> Bool {
        ready = FileManager.default.fileExists(atPath: Self.rulePath) && sudoOK()
        return ready
    }

    /// Installs the rule once (macOS asks for the password), then calls done on the main thread.
    func installRule(done: @escaping (Bool) -> Void = { _ in }) {
        guard !installing else { return }
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            note(tr("Can't set it up for this user name.")); done(false); return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1\n"
        let tmp = NSTemporaryDirectory() + "phonecast-lidawake.\(getpid())"
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { note(error.localizedDescription); done(false); return }
        let sh = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' '\(Self.rulePath)'"
        installing = true
        NSApp.activate(ignoringOtherApps: true)
        admin(sh, prompt: "PhoneCast wants to keep the Mac awake with the lid closed. This allows it to switch sleep off and on (pmset disablesleep), nothing else.") { [weak self] cancelled in
            try? FileManager.default.removeItem(atPath: tmp)
            guard let self else { return }
            self.installing = false
            let ok = self.ruleWorks()
            if !ok { self.note(cancelled ? tr("Setup was cancelled.") : tr("Setup failed.")) }
            self.changed()
            done(ok)
        }
    }

    /// Runs a shell command as root through osascript's password prompt, on a background thread.
    private func admin(_ sh: String, prompt: String, done: @escaping (_ cancelled: Bool) -> Void) {
        DispatchQueue.global().async {
            let script = "do shell script \"\(sh)\" with prompt \"\(prompt)\" with administrator privileges"
            let r = Self.run("/usr/bin/osascript", ["-e", script])
            DispatchQueue.main.async { done(r.out.contains("-128")) }   // -128 = user cancelled
        }
    }

    func removeRule() {
        disable()
        admin("/bin/rm -f '\(Self.rulePath)'", prompt: "PhoneCast removes its keep-awake permission.") { [weak self] _ in
            self?.ready = FileManager.default.fileExists(atPath: LidAwake.rulePath)
            self?.changed()
        }
    }

    private func sudoOK() -> Bool {
        Self.run("/usr/bin/sudo", ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"]).status == 0
    }

    // MARK: helpers

    @discardableResult
    private func setPmset(_ disabled: Bool) -> Bool {
        let r = Self.run("/usr/bin/sudo", ["-n", Self.pmset, "-a", "disablesleep", disabled ? "1" : "0"])
        on = Self.readSleepDisabled()
        if r.status != 0 { note(tr("pmset failed: %@", r.out.trimmingCharacters(in: .whitespacesAndNewlines))); return false }
        return on == disabled
    }

    /// A detached shell that turns sleep back on once PhoneCast's process is gone (crash, force quit, update).
    private func startWatchdog() {
        stopWatchdog()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 5; done; /usr/bin/sudo -n \(Self.pmset) -a disablesleep 0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        watchdog = p
    }

    private func stopWatchdog() {
        if let w = watchdog, w.isRunning { w.terminate() }
        watchdog = nil
    }

    private func note(_ s: String) { lastNote = s }

    private func changed() {
        DispatchQueue.main.async {
            Hub.shared.refreshStatusItem()
            Hub.shared.pushStatus()
        }
    }

    static func readSleepDisabled() -> Bool {
        let out = run(pmset, ["-g"]).out
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    static func battery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }

    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
