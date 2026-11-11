import Foundation
import Network

/// v0.6 agent features on the Mac: live terminal (colours + typing), recovery (continue after a usage
/// limit, stuck alerts), project files (browse, read, @ suggestions, uploads), dev-server previews.

enum AgentLimits {
    /// "You've hit your limit · resets 3pm (Europe/Berlin)", "5-hour limit reached ∙ resets 4:30am",
    /// Codex "You've hit your usage limit … try again at 3:15 PM". Returns the next matching clock time.
    static let re = Rx(#"(?i)(?:limit|usage)[^\n]{0,80}?(?:resets?(?: at)?|try again at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#)

    static func resetTime(in text: String, now: Date = Date()) -> Date? {
        guard let m = re.all(text).last, let h0 = Int(m.g(1) ?? "") else { return nil }
        var h = h0
        let mi = Int(m.g(2) ?? "") ?? 0
        if let ap = m.g(3)?.lowercased() { if ap == "pm" && h < 12 { h += 12 }; if ap == "am" && h == 12 { h = 0 } }
        guard h < 24, mi < 60 else { return nil }
        let cal = Calendar.current
        var d = cal.date(bySettingHour: h, minute: mi, second: 0, of: now) ?? now
        if d <= now.addingTimeInterval(-60) { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }
}

/// Recovery settings and state: {global: {continue: Bool, stuckMin: Int}, chats: {sid: {continue: Bool}}}.
enum AgentRecovery {
    static var file: URL { AgentTmux.home.appendingPathComponent("recovery.json") }
    private static let lock = NSLock()
    private static var cache: [String: Any]?

    static func load() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let v = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cache = v; return v
    }
    static func save(_ v: [String: Any]) {
        lock.lock(); cache = v; lock.unlock()
        if let d = try? JSONSerialization.data(withJSONObject: v) { try? d.write(to: file, options: .atomic) }
    }
    static var global: [String: Any] { load()["global"] as? [String: Any] ?? [:] }
    static func autoContinue(_ sid: String) -> Bool {
        if let c = (load()["chats"] as? [String: Any])?[sid] as? [String: Any], let v = c["continue"] as? Bool { return v }
        return global["continue"] as? Bool ?? false
    }
    static var stuckMinutes: Int { global["stuckMin"] as? Int ?? 10 }
    static func set(global g: [String: Any]?, chat sid: String?, _ c: [String: Any]?) {
        var v = load()
        if let g { var cur = v["global"] as? [String: Any] ?? [:]; cur.merge(g) { $1 }; v["global"] = cur }
        if let sid { var chats = v["chats"] as? [String: Any] ?? [:]; chats[sid] = c; v["chats"] = chats }
        save(v)
    }
}

enum AgentFiles {
    struct Fail: Error, CustomStringConvertible { let description: String }

    /// Resolves `rel` inside `root`; refuses anything that leaves it (.., symlinks out).
    static func resolve(_ root: String, _ rel: String) throws -> URL {
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let u = (rel.isEmpty ? base : base.appendingPathComponent(rel)).standardizedFileURL.resolvingSymlinksInPath()
        guard u.path == base.path || u.path.hasPrefix(base.path + "/") else { throw Fail(description: "Outside the project folder.") }
        return u
    }

    static let hidden: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", ".gradle", "__pycache__", ".venv", ".DS_Store", ".idea"]

    static func list(_ root: String, _ rel: String) throws -> [String: Any] {
        let u = try resolve(root, rel)
        let fm = FileManager.default
        var items: [[String: Any]] = []
        for name in try fm.contentsOfDirectory(atPath: u.path) where name != ".DS_Store" {
            var isDir: ObjCBool = false
            let p = u.appendingPathComponent(name)
            fm.fileExists(atPath: p.path, isDirectory: &isDir)
            items.append(["name": name, "dir": isDir.boolValue, "size": (fileStamp(p.path)?.size ?? 0), "dim": hidden.contains(name)])
        }
        items.sort { a, b in
            let da = a["dir"] as! Bool, db = b["dir"] as! Bool
            return da != db ? da : (a["name"] as! String).localizedStandardCompare(b["name"] as! String) == .orderedAscending
        }
        return ["path": rel, "items": Array(items.prefix(500))]
    }

    static func read(_ root: String, _ rel: String) throws -> [String: Any] {
        let u = try resolve(root, rel)
        guard let st = fileStamp(u.path) else { throw Fail(description: "File not found.") }
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        let d = try h.read(upToCount: 400_000) ?? Data()
        if d.prefix(8000).contains(0) { return ["binary": true, "size": st.size] }
        return ["text": AgentText.redact(String(decoding: d, as: UTF8.self)), "size": st.size, "cut": st.size > d.count]
    }

    private static var indexCache: [String: (Double, [String])] = [:]
    private static let lock = NSLock()

    /// Fuzzy file search for @ suggestions: git ls-files when it's a repo, else a bounded walk.
    static func find(_ root: String, _ q: String) -> [String] {
        lock.lock()
        var files = indexCache[root].flatMap { Date().timeIntervalSince1970 - $0.0 < 60 ? $0.1 : nil }
        lock.unlock()
        if files == nil {
            if let out = try? AgentGit.run(root, ["ls-files", "-co", "--exclude-standard"], timeout: 8) {
                files = out.split(separator: "\n").map(String.init)
            } else {
                var acc: [String] = []
                let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                while let u = e?.nextObject() as? URL, acc.count < 20000 {
                    if hidden.contains(u.lastPathComponent) { e?.skipDescendants(); continue }
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { acc.append(String(u.path.dropFirst(root.count + 1))) }
                }
                files = acc
            }
            lock.lock(); indexCache[root] = (Date().timeIntervalSince1970, files!); lock.unlock()
        }
        let ql = q.lowercased()
        if ql.isEmpty { return Array(files!.prefix(30)) }
        func score(_ f: String) -> Int? {
            let fl = f.lowercased(), name = (fl as NSString).lastPathComponent
            if name.hasPrefix(ql) { return 0 }
            if name.contains(ql) { return 1 }
            if fl.contains(ql) { return 2 }
            var i = fl.startIndex
            for c in ql { guard let r = fl[i...].firstIndex(of: c) else { return nil }; i = fl.index(after: r) }
            return 3
        }
        var scored: [(Int, String)] = []
        for f in files! { if let sc = score(f) { scored.append((sc, f)) } }
        scored.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1.count < b.1.count }
        return scored.prefix(30).map { $0.1 }
    }

    /// Saves an uploaded file (any type) under uploads/ with its own name; returns the path.
    static func saveUpload(name: String, data: Data) throws -> String {
        let dir = AgentTmux.home.appendingPathComponent("uploads/" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var clean = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        if clean.isEmpty || clean.hasPrefix(".") { clean = "file" + clean }
        let u = dir.appendingPathComponent(clean)
        guard FileManager.default.createFile(atPath: u.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Fail(description: "Couldn't save the file.") }
        return u.path
    }
}

/// Dev-server previews: forwards a port on the Mac's network address to 127.0.0.1:<port>, accepting only
/// the phone's address, so a server the agent started on localhost opens on the phone. Closes after 1 h idle.
final class AgentPreview {
    static let shared = AgentPreview()
    private var listeners: [UInt16: (NWListener, Date)] = [:]
    private let q = DispatchQueue(label: "phonecast.preview")
    var phoneHost: String?

    static let urlRe = Rx(#"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::(\d{2,5}))?(/[^\s)\]"'`>]*)?"#)

    /// Ports of local URLs mentioned recently (newest first).
    static func ports(in text: String) -> [[String: Any]] {
        var seen = Set<Int>(), out: [[String: Any]] = []
        for m in urlRe.all(text).reversed() {
            let port = Int(m.g(1) ?? "") ?? 80
            if seen.insert(port).inserted { out.append(["port": port, "path": m.g(2) ?? "/", "url": m.g(0) ?? ""]) }
        }
        return Array(out.prefix(5))
    }

    /// Starts (or reuses) a forwarder; returns the public port.
    func open(_ port: UInt16) throws -> UInt16 {
        try q.sync {
            if let l = listeners[port] { listeners[port] = (l.0, Date()); return l.0.port?.rawValue ?? 0 }
            let params = NWParameters.tcp
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port &+ 20000) ?? .any)
            l.newConnectionHandler = { [weak self] c in self?.accept(c, port) }
            let sem = DispatchSemaphore(value: 0)
            var failed: Error?
            l.stateUpdateHandler = { st in
                switch st { case .ready: sem.signal(); case .failed(let e): failed = e; sem.signal(); default: break }
            }
            l.start(queue: q)
            q.async {}   // let the handler run
            _ = sem.wait(timeout: .now() + 3)
            if let failed { throw failed }
            listeners[port] = (l, Date())
            q.asyncAfter(deadline: .now() + 3600) { [weak self] in self?.reap() }
            return l.port?.rawValue ?? 0
        }
    }

    private func reap() {
        for (p, v) in listeners where Date().timeIntervalSince(v.1) > 3500 { v.0.cancel(); listeners.removeValue(forKey: p) }
    }

    private func accept(_ c: NWConnection, _ port: UInt16) {
        // only the phone may use the preview port
        if case .hostPort(let h, _) = c.endpoint {
            let ip = ("\(h)".split(separator: "%").first.map(String.init) ?? "").replacingOccurrences(of: "::ffff:", with: "")
            if let phone = phoneHost?.replacingOccurrences(of: "::ffff:", with: "") {
                if ip != phone { c.cancel(); return }
            } else if !(ip.hasPrefix("100.") || ip.hasPrefix("192.168.") || ip.hasPrefix("10.")) { c.cancel(); return }
        }
        listeners[port]?.1 = Date()
        let up = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        func pipe(_ a: NWConnection, _ b: NWConnection) {
            a.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, err in
                if let d, !d.isEmpty { b.send(content: d, completion: .contentProcessed { _ in pipe(a, b) }) }
                else if done || err != nil { b.send(content: nil, isComplete: true, completion: .contentProcessed { _ in }); a.cancel() }
                else { pipe(a, b) }
            }
        }
        up.stateUpdateHandler = { st in if case .ready = st { pipe(c, up); pipe(up, c) } else if case .failed = st { c.cancel() } }
        c.start(queue: q); up.start(queue: q)
    }
}
