import CryptoKit
import Darwin
import Foundation
import Network
import QuartzCore

/// Internet relay: reaches the phone from any network (school Wi-Fi, mobile data, a Wi-Fi that keeps
/// devices apart) without Tailscale. Phone and Mac both dial out to a small Cloudflare Worker
/// (relay/ in the repo), which pipes the bytes between them. Like the USB cable, the relay shows up
/// as a local port, so `Link` and `HubLink` work unchanged.
///
/// Security: every tunnel is encrypted end to end with AES-256-GCM (key from the mirror key, fresh per
/// connection), on top of the link's own TLS with the pinned phone key and the mirror's key proof. So the
/// relay sees neither the picture nor the link, and can't log in. Each phone has its own room, derived from
/// the mirror key, so it needs one pairing at home first.
///
/// Before the relay, the Mac tries the phone's public IPv6 addresses directly (the phone reports them to
/// the relay): faster, and it doesn't go through Cloudflare at all. Many mobile networks block that, then
/// the relay takes over.
///
/// Flow control: the receiving side acknowledges ("a:<bytes>") what it delivered locally, and the sender
/// stops at 2 MB in flight, so a slow network drops mirror frames on the phone (as on slow Wi-Fi) instead
/// of piling them up in the relay.
final class Relay {
    static let shared = Relay()

    static let defaultBase = "wss://phonecast-relay.fini240.workers.dev"
    static var base: String { UserDefaults.standard.string(forKey: "relayURL") ?? defaultBase }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "relayOn") as? Bool ?? true }
    /// PHONECAST_FORCE_RELAY=1: use only the relay (tests at home).
    static let forced = ProcessInfo.processInfo.environment["PHONECAST_FORCE_RELAY"] != nil

    static var mirrorKey: String? {
        guard let k = UserDefaults.standard.string(forKey: "mirrorKey"), !k.isEmpty else { return nil }
        return k
    }

    /// The paired phone's room: only the phone and its paired computers know the mirror key.
    static var room: String? {
        guard let k = mirrorKey else { return nil }
        return SHA256.hash(data: Data(("phonecast-relay:" + k).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let label = "internet relay"
    static let directLabel = "internet (direct IPv6)"
    /// Not on the same network: the mirror uses a lighter quality there.
    static func isRemote(_ label: String) -> Bool { label == Self.label || label.hasPrefix(directLabel) }

    /// What the relay said last (shown in Settings).
    private(set) var status = "Not checked yet"
    /// The relay said the phone isn't there (skip it for 30 s) or refused this phone (skip it for 10 min).
    var offlineUntil: CFTimeInterval = 0
    private(set) var phoneAddrs: [String] = []
    /// The ones that answered a quick test connection (mobile networks usually block incoming ones),
    /// so a blocked address doesn't cost a 5 s timeout before the relay.
    private(set) var reachable: [String] = []
    /// The relay says the phone is online and none of its Wi-Fi addresses is on this Mac's network: it's away,
    /// so the internet ways go first instead of after ~20 s of home addresses that can't answer.
    private(set) var phoneAway = false
    /// Called when phoneAway turns on, so a connection attempt to a home address can stop at once.
    var onAway: (() -> Void)?
    private var lastCheck: CFTimeInterval = 0

    private let q = DispatchQueue(label: "phonecast.relay")
    private var listeners: [UInt16: NWListener] = [:]
    private var localPorts: [UInt16: UInt16] = [:]
    let session = URLSession(configuration: .ephemeral)

    /// A local address that tunnels to the phone's `port` (27183 mirror, 27185 link) through the relay.
    /// nil when the relay is off, the phone was never paired, or the relay just said it's not there.
    func endpoint(_ port: UInt16) -> NWEndpoint? {
        guard Self.enabled, Self.room != nil else { return nil }
        check()
        guard CACurrentMediaTime() > offlineUntil, let lp = localPort(port), let p = NWEndpoint.Port(rawValue: lp) else { return nil }
        return .hostPort(host: "127.0.0.1", port: p)
    }

    /// The phone's public IPv6 addresses, when this Mac has public IPv6 too.
    func directEndpoints(_ port: UInt16) -> [(NWEndpoint, String)] {
        guard Self.enabled, Self.room != nil, !Self.forced, Self.hasPublicIPv6() else { return [] }
        check()
        return reachable.compactMap { a in
            guard let v6 = IPv6Address(a), let p = NWEndpoint.Port(rawValue: port) else { return nil }
            return (.hostPort(host: .ipv6(v6), port: p), "\(Self.directLabel) \(a)")
        }
    }

    /// Asks the relay whether the phone is online and for its addresses (at most every 20 s, in the background).
    /// `force`: a link just dropped or a home address failed, so ask now (at most every 2 s).
    func check(force: Bool = false) {
        guard let room = Self.room, CACurrentMediaTime() - lastCheck > (force ? 2 : 20) else { return }
        lastCheck = CACurrentMediaTime()
        let http = Self.base.replacingOccurrences(of: "wss://", with: "https://").replacingOccurrences(of: "ws://", with: "http://")
        guard let url = URL(string: "\(http)/v1/\(room)/addrs") else { return }
        session.dataTask(with: url) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 403 {
                    self.status = "The relay refused this phone. Run relay/allow.sh (after a new PIN, the phone has a new room)."
                    self.offlineUntil = CACurrentMediaTime() + 600; self.phoneAddrs = []
                } else if code == 200, let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let online = o["online"] as? Bool ?? false
                    self.phoneAddrs = (o["addrs"] as? [String]) ?? []
                    self.reachable = self.reachable.filter { self.phoneAddrs.contains($0) }   // gone = not worth a try
                    let lan = (o["lan"] as? [String]) ?? []
                    let wasAway = self.phoneAway
                    self.phoneAway = online && o["lan"] != nil && !lan.contains { Self.onMyNetwork($0) }
                    if self.phoneAway && !wasAway { NSLog("relay: the phone is away from this network"); self.onAway?() }
                    self.probe(self.phoneAddrs)
                    self.status = online ? "The phone is online at the relay" + (self.phoneAddrs.isEmpty ? "" : " (public IPv6 too)")
                                         : "The phone isn't connected to the relay (off, no internet, or relay turned off on it)"
                    if !online { self.phoneAway = false }
                    if !online { self.offlineUntil = max(self.offlineUntil, CACurrentMediaTime() + 20) }
                    else if self.offlineUntil < CACurrentMediaTime() + 600 { self.offlineUntil = 0 }
                } else {
                    self.status = "Relay not reachable (\(err?.localizedDescription ?? "HTTP \(code)"))"
                }
            }
        }.resume()
    }

    private func probe(_ addrs: [String]) {
        guard Self.hasPublicIPv6(), !addrs.isEmpty else { reachable = []; return }
        var ok: [String] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for a in addrs {
            guard let v6 = IPv6Address(a) else { continue }
            group.enter()
            let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 2
            let c = NWConnection(to: .hostPort(host: .ipv6(v6), port: 27185), using: NWParameters(tls: nil, tcp: tcp))
            var done = false
            let finish: (Bool) -> Void = { good in
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                if good { ok.append(a) }
                c.cancel(); group.leave()
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
        group.notify(queue: .main) { [weak self] in
            self?.reachable = addrs.filter { ok.contains($0) }
            if !ok.isEmpty { NSLog("relay: the phone answers directly on \(ok.joined(separator: ", "))") }
        }
    }

    /// Is this IPv4 address in one of this Mac's own subnets?
    static func onMyNetwork(_ ip: String) -> Bool {
        var target = in_addr()
        guard inet_pton(AF_INET, ip, &target) == 1 else { return false }
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return false }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = i.pointee.ifa_netmask else { continue }
            let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if m != 0, a & m == target.s_addr & m, a != UInt32(0x0100007f) { return true }
        }
        return false
    }

    /// A routable (2000::/3) IPv6 address on this Mac, not a Tailscale one.
    static func hasPublicIPv6() -> Bool {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return false }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: i.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("lo") { continue }
            let b = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
            if b[0] & 0xE0 == 0x20 { return true }
        }
        return false
    }

    private func localPort(_ port: UInt16) -> UInt16? {
        if let p = q.sync(execute: { localPorts[port] }) { return p }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // loopback only
        guard let l = try? NWListener(using: params) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            switch st {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { c.cancel(); return }
            RelayPipe(local: c, port: port, session: self.session).start()
        }
        l.start(queue: q)
        _ = ready.wait(timeout: .now() + 2)
        guard let lp = l.port?.rawValue, lp != 0 else { l.cancel(); return nil }
        q.sync { listeners[port] = l; localPorts[port] = lp }
        NSLog("relay: phone port \(port) via 127.0.0.1:\(lp)")
        return lp
    }
}

/// End-to-end encryption of one tunnel (the same on the phone and Windows):
/// base = HMAC-SHA256(mirrorKey, "phonecast-relay-e2e"); the Mac picks a 16-byte salt and sends "s:<hex>"
/// first; up = HMAC(base, salt‖"up") for Mac→phone, down = HMAC(base, salt‖"down") for phone→Mac.
/// Each binary message is AES-256-GCM ciphertext‖tag, nonce = 4 zero bytes ‖ 64-bit message counter.
struct RelayCrypto {
    let up: SymmetricKey, down: SymmetricKey
    private var sent: UInt64 = 0, received: UInt64 = 0

    init(mirrorKey: String, salt: Data) {
        let base = Data(HMAC<SHA256>.authenticationCode(for: Data("phonecast-relay-e2e".utf8), using: SymmetricKey(data: Data(mirrorKey.utf8))))
        let bk = SymmetricKey(data: base)
        up = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: salt + Data("up".utf8), using: bk)))
        down = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: salt + Data("down".utf8), using: bk)))
    }

    private static func nonce(_ n: UInt64) -> AES.GCM.Nonce {
        var b = Data(count: 4); withUnsafeBytes(of: n.bigEndian) { b.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: b)
    }

    mutating func seal(_ d: Data) -> Data {
        let box = try! AES.GCM.seal(d, using: up, nonce: Self.nonce(sent)); sent += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ d: Data) -> Data? {
        guard d.count >= 16 else { return nil }
        guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(received), ciphertext: d.prefix(d.count - 16), tag: d.suffix(16)),
              let plain = try? AES.GCM.open(box, using: down) else { return nil }
        received += 1
        return plain
    }
}

/// One TCP connection tunnelled through the relay.
private final class RelayPipe {
    static let window = 2 << 20, ackEvery = 256 << 10
    // (no owner: the pending receive callbacks keep a pipe alive until both sides are cancelled)

    private let local: NWConnection
    private let ws: URLSessionWebSocketTask
    private let q = DispatchQueue(label: "phonecast.relay.pipe")
    private var crypto: RelayCrypto
    private let salt: Data
    private var unacked = 0, consumed = 0
    private var blocked: (() -> Void)?
    private var closed = false, heard = false
    private let port: UInt16

    init(local: NWConnection, port: UInt16, session: URLSession) {
        self.local = local
        self.port = port
        var s = Data(count: 16)
        _ = s.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        salt = s
        crypto = RelayCrypto(mirrorKey: Relay.mirrorKey ?? "", salt: s)
        let url = URL(string: "\(Relay.base)/v1/\(Relay.room ?? "")/mac?port=\(port)")!
        ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 8 << 20
    }

    func start() {
        local.start(queue: q)
        ws.resume()
        ws.send(.string("s:" + salt.map { String(format: "%02x", $0) }.joined())) { _ in }
        readLocal()
        readRelay()
        // both protocols answer within moments once the phone picked up; nothing means it's offline
        q.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.heard else { return }
            NSLog("relay: port \(self.port): the phone didn't answer")
            self.close()
        }
    }

    private func close() {
        q.async { [self] in
            if closed { return }
            closed = true
            local.cancel()
            ws.cancel(with: .normalClosure, reason: nil)
            blocked = nil
        }
    }

    // Mac -> phone
    private func readLocal() {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, err in
            self.q.async {
                if self.closed { return }
                if let data, !data.isEmpty {
                    self.unacked += data.count
                    self.ws.send(.data(self.crypto.seal(data))) { e in
                        self.q.async {
                            if e != nil || done { self.close(); return }   // closed after the last chunk went out
                            if self.unacked > Self.window { self.blocked = { self.readLocal() } } else { self.readLocal() }
                        }
                    }
                } else if done || err != nil {
                    self.close()
                } else {
                    self.readLocal()
                }
            }
        }
    }

    // phone -> Mac
    private func readRelay() {
        ws.receive { result in
            self.q.async {
                if self.closed { return }
                switch result {
                case .failure(let e):
                    if !self.heard {
                        let code = (self.ws.response as? HTTPURLResponse)?.statusCode ?? 0
                        NSLog("relay: port \(self.port): \(code > 0 ? "HTTP \(code)" : e.localizedDescription)")
                        // the relay refuses the upgrade: 404 = the phone isn't connected to it, 403 = not allowed
                        if code == 404 || code == 403 {
                            DispatchQueue.main.async {
                                Relay.shared.offlineUntil = CACurrentMediaTime() + (code == 403 ? 600 : 30)
                                Relay.shared.check(force: true)
                            }
                        }
                    }
                    self.close()
                case .success(.data(let sealed)):
                    guard let d = self.crypto.open(sealed) else {
                        NSLog("relay: port \(self.port): a message failed the end-to-end check, closing")
                        self.close(); return
                    }
                    self.heard = true
                    self.local.send(content: d, completion: .contentProcessed { e in
                        self.q.async {
                            if e != nil { self.close(); return }
                            self.consumed += d.count
                            if self.consumed >= Self.ackEvery {
                                self.ws.send(.string("a:\(self.consumed)")) { _ in }
                                self.consumed = 0
                            }
                            self.readRelay()
                        }
                    })
                case .success(.string(let s)):
                    if s.hasPrefix("a:"), let n = Int(s.dropFirst(2)) {
                        self.unacked -= n
                        if self.unacked <= Self.window, let b = self.blocked { self.blocked = nil; b() }
                    }
                    self.readRelay()
                @unknown default:
                    self.readRelay()
                }
            }
        }
    }
}
