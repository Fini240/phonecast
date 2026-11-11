import Foundation
import Network

/// Agents in a browser: the Mac serves the Agents UI (AgentWebUI.swift) on port 27190 for an iPad, a
/// school laptop or any browser at home (Wi-Fi) or on Tailscale, without installing anything. The Mac's
/// own Agents page shows the same UI in a web view. Sign-in: the 6-digit code shown on the Mac, then a
/// cookie. Only loopback, private-network and Tailscale addresses are served.
final class AgentWeb {
    static let shared = AgentWeb()
    static let port: UInt16 = 27190

    private let q = DispatchQueue(label: "phonecast.web", attributes: .concurrent)
    private var listener: NWListener?
    /// The sign-in code shown on the Mac (new each launch).
    private(set) var code = String(format: "%06d", Int.random(in: 0...999_999))
    /// One-time token for the Mac's own web view.
    let localToken = UUID().uuidString
    private var fails = 0
    private var lockedUntil = Date.distantPast
    private let lock = NSLock()

    private var tokens: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: "webTokens") as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "webTokens") }
    }

    func start() {
        guard listener == nil else { return }
        saveCode()
        do {
            let p = NWParameters.tcp
            p.allowLocalEndpointReuse = true
            let l = try NWListener(using: p, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("agents web: \(e)") } }
            l.start(queue: q)
            listener = l
        } catch { NSLog("agents web: \(error)") }
    }

    func newCode() { code = String(format: "%06d", Int.random(in: 0...999_999)); saveCode() }
    /// The code is also kept in ~/.phonecast/agents/web-code (owner-only) for `cat` in a terminal.
    private func saveCode() {
        let u = AgentTmux.home.appendingPathComponent("web-code")
        FileManager.default.createFile(atPath: u.path, contents: Data((code + "\n").utf8), attributes: [.posixPermissions: 0o600])
    }
    func signOutAll() { tokens = [:] }
    var devices: Int { tokens.count }

    /// Addresses people would type: LAN and Tailscale IPv4 of this Mac.
    static func addresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            if allowedIP(ip) && !out.contains(ip) { out.append(ip) }
        }
        return out.sorted { a, _ in !a.hasPrefix("100.") }
    }

    static func allowedIP(_ raw: String) -> Bool {
        let ip = raw.replacingOccurrences(of: "::ffff:", with: "").split(separator: "%").first.map(String.init) ?? raw
        if ip == "::1" || ip.hasPrefix("127.") || ip.hasPrefix("10.") || ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("172."), let b = Int(ip.split(separator: ".")[1]), (16...31).contains(b) { return true }
        if ip.hasPrefix("100."), let b = Int(ip.split(separator: ".")[1]), (64...127).contains(b) { return true }   // Tailscale CGNAT
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0") { return true }                                              // Tailscale IPv6
        if ip.lowercased().hasPrefix("fe80") || ip.lowercased().hasPrefix("fc") || ip.lowercased().hasPrefix("fd") { return true }
        return false
    }

    // MARK: HTTP (one request per connection, Connection: close)

    private func accept(_ c: NWConnection) {
        var remote = ""
        if case .hostPort(let h, _) = c.endpoint { remote = "\(h)" }
        guard Self.allowedIP(remote) else { c.cancel(); return }
        c.start(queue: q)
        read(c, Data(), remote: remote)
    }

    private func read(_ c: NWConnection, _ buf: Data, remote: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self else { return }
            var b = buf
            if let d { b += d }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ").map(String.init) ?? []
                var headers: [String: String] = [:]
                for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let len = Int(headers["content-length"] ?? "0") ?? 0
                if len > 40 << 20 { self.respond(c, 413, "text/plain", Data("too large".utf8)); return }
                let body = b[end.upperBound...]
                if body.count >= len {
                    self.route(c, method: parts.first ?? "", target: parts.count > 1 ? parts[1] : "/", headers: headers, body: Data(body.prefix(len)), remote: remote)
                    return
                }
            }
            if done || err != nil || b.count > 41 << 20 { c.cancel(); return }
            self.read(c, b, remote: remote)
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, headers: [String: String] = [:]) {
        let reason = [200: "OK", 302: "Found", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Too Large", 429: "Too Many"][status] ?? "OK"
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        c.send(content: Data((h + "\r\n").utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func json(_ c: NWConnection, _ o: Any, status: Int = 200, headers: [String: String] = [:]) {
        respond(c, status, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8), headers: headers)
    }

    private func cookieToken(_ headers: [String: String]) -> String? {
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("pc=") { return String(kv.dropFirst(3)) }
        }
        return nil
    }

    private func signedIn(_ headers: [String: String]) -> Bool {
        guard let t = cookieToken(headers), !t.isEmpty else { return false }
        return tokens[t] != nil
    }

    private func issue(_ name: String) -> String {
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        var all = tokens
        all[t] = ["name": AgentText.clip(name, 80), "at": Date().timeIntervalSince1970]
        tokens = all
        return "pc=\(t); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict"
    }

    private func route(_ c: NWConnection, method: String, target: String, headers: [String: String], body: Data, remote: String) {
        let path = String(target.split(separator: "?").first ?? "/")
        let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        // cross-site requests can't use the API (SameSite cookie + Origin check)
        if method == "POST", let origin = headers["origin"], let host = headers["host"], !origin.hasSuffix("//" + host) {
            respond(c, 403, "text/plain", Data("bad origin".utf8)); return
        }
        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(c, 200, "text/html; charset=utf-8", Data(AgentWebUI.html.utf8),
                    headers: ["Content-Security-Policy": "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'self'"])
        case ("GET", "/local"):
            let loop = remote == "::1" || remote.hasPrefix("127.") || remote == "::ffff:127.0.0.1"
            guard loop, query == "t=" + localToken else { respond(c, 403, "text/plain", Data("no".utf8)); return }
            respond(c, 302, "text/plain", Data(), headers: ["Location": "/", "Set-Cookie": issue("This Mac")])
        case ("POST", "/login"):
            lock.lock()
            if Date() < lockedUntil { lock.unlock(); json(c, ["ok": false, "message": "Too many wrong codes. Wait a few minutes."], status: 429); return }
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let given = (o["code"] as? String ?? "").filter(\.isNumber)
            if given == code {
                fails = 0; lock.unlock()
                json(c, ["ok": true], headers: ["Set-Cookie": issue(o["name"] as? String ?? headers["user-agent"] ?? "Browser")])
            } else {
                fails += 1
                if fails >= 5 { lockedUntil = Date().addingTimeInterval(300); fails = 0 }
                lock.unlock()
                json(c, ["ok": false, "message": "Wrong code."], status: 401)
            }
        case ("POST", "/logout"):
            if let t = cookieToken(headers) { var all = tokens; all.removeValue(forKey: t); tokens = all }
            json(c, ["ok": true], headers: ["Set-Cookie": "pc=; Path=/; Max-Age=0"])
        case ("POST", "/api"):
            guard signedIn(headers) else { json(c, ["ok": false, "message": "signin"], status: 401); return }
            guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { json(c, ["ok": false, "message": "bad request"]); return }
            let ip = remote.replacingOccurrences(of: "::ffff:", with: "").split(separator: "%").first.map(String.init) ?? remote
            if o["m"] as? String == "preview" { AgentPreview.shared.allow(ip) }
            AgentHub.shared.handle(o) { [weak self] r in self?.json(c, r) }
        default:
            respond(c, 404, "text/plain", Data("not found".utf8))
        }
    }
}
