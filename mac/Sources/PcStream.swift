import AppKit
import Network

/// Remote control of a dual-boot PC (Linux and Windows) through Moonlight, set up in the Mac's
/// defaults (nothing is built in):
///
///     defaults write de.finn.phonecast.mac pcName "my-pc"            # Sunshine name without " (Linux)"
///     defaults write de.finn.phonecast.mac pcLinuxAddress 100.64.0.20
///     defaults write de.finn.phonecast.mac pcWindowsAddress 100.64.0.21
///     defaults write de.finn.phonecast.mac homeNetworkPrefix "192.168.1."   # optional, see atHome()
///
/// Sunshine streams only one monitor, so each OS runs two Sunshines: the normal one
/// (monitor 1, port 47989, named "<pcName> (<OS>)") and "<pcName> (<OS>) Monitor 2" (port 48089).
/// Moonlight lists them as separate PCs; this menu starts the right one, or both side by side.
/// Only one OS runs at a time (dual boot), so we first check which one answers.
enum PcStream {
    struct Target { let os: String; let address: String; let host: String; let port: UInt16 }

    static let linux = "Linux", windows = "Windows"
    private static var d: UserDefaults { .standard }

    /// The PC's Sunshine name; nil = not set up (the menu and stream buttons stay hidden).
    static var name: String? { d.string(forKey: "pcName").flatMap { $0.isEmpty ? nil : $0 } }

    static func address(_ os: String) -> String? {
        d.string(forKey: os == linux ? "pcLinuxAddress" : "pcWindowsAddress").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The OSes that have an address.
    static var systems: [String] { name == nil ? [] : [linux, windows].filter { address($0) != nil } }

    /// Use Tailscale addresses: they work at home and away (at home Moonlight switches to the LAN by itself).
    static func targets(_ os: String) -> [Target] {
        guard let n = name, let ip = address(os) else { return [] }
        return [Target(os: os, address: ip, host: "\(n) (\(os))", port: 47989),
                Target(os: os, address: ip, host: "\(n) (\(os)) Monitor 2", port: 48089)]
    }

    static let moonlight = "/Applications/Moonlight.app/Contents/MacOS/Moonlight"

    /// Does Sunshine answer there? (≤1.5 s; the PC is booted into one OS at a time.)
    static func reachable(_ t: Target, _ done: @escaping (Bool) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(t.address), port: NWEndpoint.Port(rawValue: t.port)!, using: .tcp)
        var finished = false
        let q = DispatchQueue(label: "pcstream.probe")
        func finish(_ ok: Bool) {
            if finished { return }
            finished = true; c.cancel()
            DispatchQueue.main.async { done(ok) }
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: finish(true)
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + 1.5) { finish(false) }
    }

    /// On the home network (an address starting with `homeNetworkPrefix`) Moonlight's own settings apply. Away (hotspot, other Wi-Fi)
    /// the full ~34 Mbit/s at 2560×1600 overflows mobile data: measured 08.11.2026 over the phone's
    /// hotspot it gave 202 ms and 58% lost frames, while 1080p60 at 15 Mbit/s gave 41 ms and none lost.
    static func atHome() -> Bool {
        guard let prefix = d.string(forKey: "homeNetworkPrefix"), !prefix.isEmpty else { return true } // not set: never throttle
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return true }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if String(cString: host).hasPrefix(prefix) { return true }
            }
            p = i.pointee.ifa_next
        }
        return false
    }
    static let awayArgs = ["--bitrate", "15000", "--resolution", "1920x1080", "--fps", "60"]

    /// Starts one Moonlight per target. Several at once open in windows so they fit side by side.
    static func stream(_ ts: [Target]) {
        for (i, t) in ts.enumerated() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: moonlight)
            // by name, not address: both Sunshines share the IP and Moonlight ignores the port when matching
            p.arguments = ["stream", t.host, "Desktop"] + (ts.count > 1 ? ["--display-mode", "windowed"] : [])
                + (atHome() ? [] : awayArgs)
            // let the first one connect before the second asks (both talk to the same PC)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.5) { try? p.run() }
        }
    }

    static func stopAll() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "Moonlight.app/Contents/MacOS/Moonlight stream"]
        try? p.run()
    }
}

extension AppDelegate {
    /// The PC menu (empty when no PC is set up).
    func pcMenuItems() -> [NSMenuItem] {
        guard let pc = PcStream.name, !PcStream.systems.isEmpty else { return [] }
        var items: [NSMenuItem] = []
        for (n, os) in [PcStream.linux, PcStream.windows].enumerated() where PcStream.address(os) != nil {
            if !items.isEmpty { items.append(.separator()) }
            items.append(NSMenuItem(title: "\(os)", action: nil, keyEquivalent: ""))
            for (title, tag) in [("Monitor 1", 0), ("Monitor 2", 1), ("Both monitors", 2)] {
                let i = NSMenuItem(title: "   " + title, action: #selector(pcStream(_:)), keyEquivalent: "")
                i.target = self
                i.tag = n * 10 + tag
                items.append(i)
            }
        }
        items.append(.separator())
        let stop = NSMenuItem(title: "Close all \(pc) streams", action: #selector(pcStop(_:)), keyEquivalent: "")
        stop.target = self
        items.append(stop)
        return items
    }

    @objc func pcStream(_ s: NSMenuItem) {
        let os = s.tag / 10 == 0 ? PcStream.linux : PcStream.windows
        let all = PcStream.targets(os)
        guard !all.isEmpty else { return }
        let picked = s.tag % 10 == 2 ? all : [all[s.tag % 10]]
        guard FileManager.default.isExecutableFile(atPath: PcStream.moonlight) else {
            pcAlert("Moonlight is not installed", "Install Moonlight to /Applications first.")
            return
        }
        NSLog("pc: %@ %@ asked", os, picked.map(\.host).joined(separator: " + "))
        // always knock on the main Sunshine: on Linux that connection also switches sleeping monitors
        // back on (KMS can't capture a monitor that is off), which a Monitor-2-only stream would miss
        PcStream.reachable(all[0]) { [weak self] ok in
            NSLog("pc: %@ reachable=%d", os, ok ? 1 : 0)
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + (picked.count == 1 && picked[0].port != all[0].port ? 2 : 0)) {
                    PcStream.stream(picked)
                }
                return
            }
            let other = os == PcStream.linux ? PcStream.windows : PcStream.linux
            guard let probe = PcStream.targets(other).first else {
                self?.pcAlert("\(PcStream.name ?? "The PC") doesn't answer on \(os)", "Probably off, asleep or booted into the other system.")
                return
            }
            PcStream.reachable(probe) { otherUp in
                self?.pcAlert("\(PcStream.name ?? "The PC") isn't running \(os) right now",
                                  otherUp ? "It is booted into \(other). Restart it into \(os) from the dashboard, or pick \(other) here."
                                          : "It doesn't answer at all: probably off or asleep. Wake it from the dashboard first.")
            }
        }
    }

    @objc func pcStop(_ s: Any?) { PcStream.stopAll() }

    private func pcAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = tr(title)
        a.informativeText = tr(text)
        a.runModal()
    }
}
