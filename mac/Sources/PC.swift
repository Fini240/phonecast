import AppKit
import Network

/// Remote control of the PC my-pc through Moonlight.
///
/// Sunshine streams only one monitor, so each OS on pc runs two Sunshines: the normal one
/// (monitor 1, port 47989) and "… Monitor 2" (port 48089). Moonlight lists them as separate PCs;
/// this menu starts the right one, or both side by side. Only one OS runs at a time (dual boot),
/// so we first check which one answers.
enum PC {
    struct Target { let os: String; let address: String; let host: String; let port: UInt16 }

    static let linux = "Linux", windows = "Windows"
    /// Tailscale addresses: work at home and away (at home Moonlight switches to the LAN by itself).
    static func targets(_ os: String) -> [Target] {
        let ip = os == linux ? "100.64.0.2" : "100.64.0.3"
        return [Target(os: os, address: ip, host: "my-pc (\(os))", port: 47989),
                Target(os: os, address: ip, host: "my-pc (\(os)) Monitor 2", port: 48089)]
    }

    static let moonlight = "/Applications/Moonlight.app/Contents/MacOS/Moonlight"

    /// Does Sunshine answer there? (≤1.5 s; pc is booted into one OS at a time.)
    static func reachable(_ t: Target, _ done: @escaping (Bool) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(t.address), port: NWEndpoint.Port(rawValue: t.port)!, using: .tcp)
        var finished = false
        let q = DispatchQueue(label: "pc.probe")
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

    /// On the home network (192.168.1.x) Moonlight's own settings apply. Away (hotspot, other Wi-Fi)
    /// the full ~34 Mbit/s at 2560×1600 overflows mobile data: measured 08.11.2026 over the phone's
    /// hotspot it gave 202 ms and 58% lost frames, while 1080p60 at 15 Mbit/s gave 41 ms and none lost.
    static func atHome() -> Bool {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return true }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if String(cString: host).hasPrefix("192.168.1.") { return true }
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
    func pcMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (n, os) in [PC.linux, PC.windows].enumerated() {
            if n > 0 { items.append(.separator()) }
            items.append(NSMenuItem(title: "\(os)", action: nil, keyEquivalent: ""))
            for (title, tag) in [("Monitor 1", 0), ("Monitor 2", 1), ("Both monitors", 2)] {
                let i = NSMenuItem(title: "   " + title, action: #selector(pcStream(_:)), keyEquivalent: "")
                i.target = self
                i.tag = n * 10 + tag
                items.append(i)
            }
        }
        items.append(.separator())
        let stop = NSMenuItem(title: "Close all pc streams", action: #selector(pcStop(_:)), keyEquivalent: "")
        stop.target = self
        items.append(stop)
        return items
    }

    @objc func pcStream(_ s: NSMenuItem) {
        let os = s.tag / 10 == 0 ? PC.linux : PC.windows
        let all = PC.targets(os)
        let picked = s.tag % 10 == 2 ? all : [all[s.tag % 10]]
        guard FileManager.default.isExecutableFile(atPath: PC.moonlight) else {
            pcAlert("Moonlight is not installed", "Install Moonlight to /Applications first.")
            return
        }
        NSLog("pc: %@ %@ asked", os, picked.map(\.host).joined(separator: " + "))
        // always knock on the main Sunshine: on Linux that connection also switches sleeping monitors
        // back on (KMS can't capture a monitor that is off), which a Monitor-2-only stream would miss
        PC.reachable(all[0]) { [weak self] ok in
            NSLog("pc: %@ reachable=%d", os, ok ? 1 : 0)
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + (picked.count == 1 && picked[0].port != all[0].port ? 2 : 0)) {
                    PC.stream(picked)
                }
                return
            }
            let other = os == PC.linux ? PC.windows : PC.linux
            PC.reachable(PC.targets(other)[0]) { otherUp in
                self?.pcAlert("pc isn't running \(os) right now",
                                  otherUp ? "It is booted into \(other). Restart it into \(os) from the dashboard, or pick \(other) here."
                                          : "It doesn't answer at all: probably off or asleep. Wake it from the dashboard first.")
            }
        }
    }

    @objc func pcStop(_ s: Any?) { PC.stopAll() }

    private func pcAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
