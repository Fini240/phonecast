import Foundation
import Network
import CryptoKit

enum PT {
    static let format: UInt8 = 0, config: UInt8 = 1, frame: UInt8 = 2, audio: UInt8 = 3
    static let helloOK: UInt8 = 4, helloBad: UInt8 = 5, control: UInt8 = 6, pong: UInt8 = 7, resResult: UInt8 = 8, stats: UInt8 = 14, stopped: UInt8 = 19
    static let udpToken: UInt8 = 20, udpOn: UInt8 = 21, udpOff: UInt8 = 22, nonce: UInt8 = 23
}

enum CT {
    static let hello: UInt8 = 9, touch: UInt8 = 10, global: UInt8 = 11, text: UInt8 = 12, key: UInt8 = 13, keyframe: UInt8 = 15, ping: UInt8 = 16, settings: UInt8 = 17, resolution: UInt8 = 18
}

enum Touch { static let down: UInt8 = 0, move: UInt8 = 1, up: UInt8 = 2, cancelAll: UInt8 = 3 }
enum Global { static let back: UInt8 = 1, home: UInt8 = 2, recents: UInt8 = 3, notifications: UInt8 = 4 }

/// One TCP connection to the phone. Packets in: [u8 type][u32 len][payload]. Packets out: [u8 type][u16 len][payload].
final class Link {
    enum State { case connecting, ready, badPin, closed(String) }

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "phonecast.link", qos: .userInteractive)
    private var closed = false

    var onPacket: ((UInt8, Data) -> Void)?
    var onState: ((State) -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        conn = NWConnection(to: endpoint, using: params)
    }

    func start(pin: String) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                // The phone sends a nonce first. With the mirror key (handed over the encrypted link)
                // the Mac answers HMAC(key, nonce), so the PIN never crosses the network in the clear.
                self.pin = pin
                self.readHeader()
                self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sendHello(nonce: nil) } // older phone app
            case .failed(let e):
                self.finish("failed: \(e.localizedDescription)")
            case .waiting(let e):
                self.finish("unreachable: \(e.localizedDescription)")
            case .cancelled:
                self.finish("disconnected")
            default: break
            }
        }
        onState?(.connecting)
        conn.start(queue: queue)
    }

    private func finish(_ why: String) {
        if closed { return }
        closed = true
        conn.cancel()
        onState?(.closed(why))
    }

    func close(_ why: String = "disconnected") { finish(why) }

    /// Run on the link's queue (where all packets are handled), e.g. for frames that came over UDP.
    func async(_ work: @escaping () -> Void) { queue.async(execute: work) }

    /// The phone's address as this connection resolved it (for the UDP video socket).
    var remoteHost: String? {
        guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, done, err in
            guard let self else { return }
            guard let data, data.count == 5, err == nil else { self.finish(done ? "phone closed the connection" : "read error"); return }
            let b = [UInt8](data)
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            if len == 0 { self.deliver(b[0], Data()); self.readHeader() } else { self.readBody(b[0], len) }
        }
    }

    private func readBody(_ type: UInt8, _ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, done, err in
            guard let self else { return }
            guard let data, data.count == len, err == nil else { self.finish("read error"); return }
            self.deliver(type, data)
            self.readHeader()
        }
    }

    private var pin = ""
    private var helloSent = false
    private var q1Nonce: Data?

    private func sendHello(nonce: Data?) {
        if helloSent || closed { return }
        helloSent = true
        if let nonce, let key = UserDefaults.standard.string(forKey: "mirrorKey"), !key.isEmpty {
            var mac = HMAC<SHA256>(key: SymmetricKey(data: Data(key.utf8)))
            mac.update(data: nonce); mac.update(data: Data("phonecast-mirror".utf8))
            let hex = Data(mac.finalize()).map { String(format: "%02x", $0) }.joined()
            send(CT.hello, Data("T1:\(hex)".utf8))
        } else if let nonce, UserDefaults.standard.bool(forKey: "qrPaired") {
            // QR pairing: prove the Mac's key; the phone proves its own in HELLO_OK (checked below)
            q1Nonce = nonce
            send(CT.hello, Data("Q1:\(Pairing.id):\(Pairing.hex(Pairing.proof(nonce, "phonecast-mirror")))".utf8))
        } else {
            send(CT.hello, Data(pin.utf8))
        }
    }

    private func deliver(_ type: UInt8, _ payload: Data) {
        switch type {
        case PT.nonce: sendHello(nonce: payload)
        case PT.helloOK:
            if let n = q1Nonce, payload.count < 33 || payload.subdata(in: 1..<33) != Pairing.proof(n, "phonecast-phone") {
                finish("the phone couldn't prove the QR pairing"); return
            }
            onState?(.ready); onPacket?(type, payload)
        case PT.helloBad: onState?(.badPin); finish("wrong PIN")
        case PT.stopped:
            finish(payload.first == 1
                ? "the phone locked, and Android ends screen sharing then. Unlock it and allow sharing again"
                : "sharing was stopped on the phone")
        default: onPacket?(type, payload)
        }
    }

    func send(_ type: UInt8, _ payload: Data = Data()) {
        if closed { return }
        var d = Data([type, UInt8((payload.count >> 8) & 0xff), UInt8(payload.count & 0xff)])
        d.append(payload)
        conn.send(content: d, completion: .idempotent)
    }

    func touch(_ action: UInt8, _ id: UInt8, _ x: Double, _ y: Double) {
        let ux = UInt16(max(0, min(1, x)) * 65535), uy = UInt16(max(0, min(1, y)) * 65535)
        send(CT.touch, Data([action, id, UInt8(ux >> 8), UInt8(ux & 0xff), UInt8(uy >> 8), UInt8(uy & 0xff)]))
    }
}
