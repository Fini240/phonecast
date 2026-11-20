import CryptoKit
import QuartzCore
import Foundation
import Network

/// Internet relay: reaches the phone from any network (school Wi-Fi, mobile data, a Wi-Fi that keeps
/// devices apart) without Tailscale. Phone and Mac both dial out to a small Cloudflare Worker
/// (relay/ in the repo), which pipes the bytes between them. Like the USB cable, the relay shows up
/// as a local port, so `Link` and `HubLink` work unchanged, and their security stays end-to-end:
/// the link is TLS 1.3 with the phone's pinned key, the mirror proves the shared key.
///
/// Each phone has its own room, derived from the mirror key the phone hands over on pairing, so it
/// needs one pairing at home first. Flow control: the receiving side acknowledges ("a:<bytes>") what
/// it has delivered locally and the sender stops at 2 MB in flight, so a slow network drops mirror
/// frames on the phone (as on slow Wi-Fi) instead of piling them up in the relay.
final class Relay {
    static let shared = Relay()

    static var base: String { UserDefaults.standard.string(forKey: "relayURL") ?? "wss://phonecast-relay.fini240.workers.dev" }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "relayOn") as? Bool ?? true }

    /// The paired phone's room: only the phone and its paired computers know the mirror key.
    static var room: String? {
        guard let k = UserDefaults.standard.string(forKey: "mirrorKey"), !k.isEmpty else { return nil }
        return SHA256.hash(data: Data(("phonecast-relay:" + k).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let label = "internet relay"

    /// When the relay last said the phone isn't there: skip it for 30 s, so a phone that's off or
    /// asleep isn't asked again on every retry round.
    static var offlineSince: CFTimeInterval = 0

    private let q = DispatchQueue(label: "phonecast.relay")
    private var listeners: [UInt16: NWListener] = [:]
    private var localPorts: [UInt16: UInt16] = [:]
    private let session = URLSession(configuration: .ephemeral)

    /// A local address that tunnels to the phone's `port` (27183 mirror, 27185 link) through the relay.
    /// nil when the relay is off or the phone was never paired.
    func endpoint(_ port: UInt16) -> NWEndpoint? {
        guard Self.enabled, Self.room != nil, CACurrentMediaTime() - Self.offlineSince > 30, let lp = localPort(port), let p = NWEndpoint.Port(rawValue: lp) else { return nil }
        return .hostPort(host: "127.0.0.1", port: p)
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

/// One TCP connection tunnelled through the relay.
private final class RelayPipe {
    static let window = 2 << 20, ackEvery = 256 << 10
    // (no owner: the pending receive callbacks keep a pipe alive until both sides are cancelled)

    private let local: NWConnection
    private let ws: URLSessionWebSocketTask
    private let q = DispatchQueue(label: "phonecast.relay.pipe")
    private var unacked = 0, consumed = 0
    private var blocked: (() -> Void)?
    private var closed = false, heard = false
    private let port: UInt16

    init(local: NWConnection, port: UInt16, session: URLSession) {
        self.local = local
        self.port = port
        let url = URL(string: "\(Relay.base)/v1/\(Relay.room ?? "")/mac?port=\(port)")!
        ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = 8 << 20
    }

    func start() {
        local.start(queue: q)
        ws.resume()
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
                    self.ws.send(.data(data)) { e in
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
                        NSLog("relay: port \(self.port): \(e.localizedDescription)")
                        // the relay refuses the upgrade (HTTP 404) while the phone isn't connected to it
                        if (self.ws.response as? HTTPURLResponse)?.statusCode == 404 { Relay.offlineSince = CACurrentMediaTime() }
                    }
                    self.close()
                case .success(.data(let d)):
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
