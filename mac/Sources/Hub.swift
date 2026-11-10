import AppKit
import Network
import IOKit.ps
import ServiceManagement
import Combine
import CryptoKit

/// Hub packet types (same numbers as HubProto on the phone). Both directions: [u8 type][u32 len][payload].
enum HT {
    static let hello: UInt8 = 1, helloOK: UInt8 = 2, helloBad: UInt8 = 3, ping: UInt8 = 4, pong: UInt8 = 5, status: UInt8 = 6
    static let hubNonce: UInt8 = 7   // phone->mac, 16 bytes, first packet (QR pairing proofs)
    static let notif: UInt8 = 10, notifGone: UInt8 = 11, notifAction: UInt8 = 12
    static let fileBegin: UInt8 = 20, fileData: UInt8 = 21, fileEnd: UInt8 = 22, fileCancel: UInt8 = 23
    static let clip: UInt8 = 30
    static let castReady: UInt8 = 40, castStopped: UInt8 = 41, castRequest: UInt8 = 42
    static let screenStart: UInt8 = 50, screenStop: UInt8 = 51, screenFormat: UInt8 = 52, screenConfig: UInt8 = 53
    static let screenFrame: UInt8 = 54, screenKey: UInt8 = 55, screenDenied: UInt8 = 56
    static let input: UInt8 = 60, macAction: UInt8 = 61
    static let req: UInt8 = 70, resp: UInt8 = 71, event: UInt8 = 72
}

/// One TCP connection to the phone's hub (port 27185).
final class HubLink {
    private let conn: NWConnection
    let queue = DispatchQueue(label: "phonecast.hub", qos: .userInteractive)
    private var closed = false
    var onPacket: ((UInt8, Data) -> Void)?   // called on `queue`
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?
    private(set) var videoInFlight = 0
    private let lock = NSLock()

    /// SHA-256 of the phone's TLS certificate seen on this connection.
    private(set) var certFingerprint: String?
    /// The phone accepted the PIN (HELLO_OK). Nothing but pings is acted on before that.
    private(set) var ready = false
    /// The phone's nonce (QR proofs are HMACs over it); nil from phones older than QR pairing.
    private(set) var nonce: Data?
    /// HELLO_OK check (the phone's QR proof); false closes the link.
    var verifyOK: ((Data) -> Bool)?
    private var helloSent = false
    private var makeHello: ((Data?, String?, @escaping (Data?) -> Void) -> Void)?

    /// `trust(fingerprint)` decides whether this is the paired phone (key pinned on first pairing).
    init(endpoint: NWEndpoint, trust: @escaping (String) -> Bool) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        let q = DispatchQueue(label: "phonecast.hub.tls")
        var seen: String?
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let t = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first else { complete(false); return }
            let fp = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined()
            seen = fp
            complete(trust(fp))
        }, q)
        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .responsiveData
        conn = NWConnection(to: endpoint, using: params)
        fpGetter = { seen }
    }
    private var fpGetter: () -> String? = { nil }

    /// `hello(nonce, fingerprint, answer)` builds HELLO once the phone's nonce is in (answer nil = close).
    func start(hello: @escaping (Data?, String?, @escaping (Data?) -> Void) -> Void) {
        makeHello = hello
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.certFingerprint = self.fpGetter()
                self.readHeader()
                // phones from before QR pairing don't send a nonce: say hello without one
                self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.sayHello() }
            case .failed(let e): self.finish("failed: \(e.localizedDescription)")
            case .waiting(let e): self.finish("unreachable: \(e.localizedDescription)")
            case .cancelled: self.finish("disconnected")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func close(_ why: String = "closed") { queue.async { self.finish(why) } }

    private func sayHello() {
        if helloSent || closed { return }
        helloSent = true
        makeHello?(nonce, certFingerprint) { [weak self] d in
            guard let self else { return }
            self.queue.async { if let d { self.send(HT.hello, d) } else { self.finish("pairing cancelled") } }
        }
    }

    private func finish(_ why: String) {
        if closed { return }
        closed = true
        conn.cancel()
        onClose?(why)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] d, _, done, err in
            guard let self else { return }
            guard let d, d.count == 5, err == nil else { self.finish(done ? "phone closed the link" : "read error"); return }
            let b = [UInt8](d)
            let len = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            if len == 0 { self.deliver(b[0], Data()); self.readHeader() } else { self.readBody(b[0], len) }
        }
    }

    private func readBody(_ t: UInt8, _ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] d, _, _, err in
            guard let self else { return }
            guard let d, d.count == len, err == nil else { self.finish("read error"); return }
            self.deliver(t, d); self.readHeader()
        }
    }

    private func deliver(_ t: UInt8, _ p: Data) {
        if t == HT.hubNonce { if !helloSent, p.count == 16 { nonce = p; sayHello() }; return }
        if t == HT.helloOK {
            if let v = verifyOK, !v(p) { finish("the phone couldn't prove the QR pairing"); return }
            ready = true; onReady?()
        }
        if t == HT.helloBad {
            let why = String(decoding: p, as: UTF8.self)
            finish(why == "locked" ? "locked" : why == "qr" ? "qr not known" : "wrong PIN"); return
        }
        onPacket?(t, p)
    }

    private func frame(_ t: UInt8, _ p: Data) -> Data {
        var d = Data(capacity: p.count + 5)
        let n = UInt32(p.count).bigEndian
        d.append(t); withUnsafeBytes(of: n) { d.append(contentsOf: $0) }; d.append(p)
        return d
    }

    func send(_ t: UInt8, _ p: Data = Data(), done: (() -> Void)? = nil) {
        if closed { done?(); return }
        conn.send(content: frame(t, p), completion: .contentProcessed { _ in done?() })
    }

    /// A video frame; false = dropped because the network is behind.
    func sendVideo(_ t: UInt8, _ p: Data, maxInFlight: Int = 3) -> Bool {
        lock.lock()
        if videoInFlight >= maxInFlight { lock.unlock(); return false }
        videoInFlight += 1; lock.unlock()
        send(t, p) { [weak self] in guard let self else { return }; self.lock.lock(); self.videoInFlight -= 1; self.lock.unlock() }
        return true
    }
}

/// The always-on link to the phone: notifications, messages, calls, files, clipboard, monitor.
/// UI state lives in `Store`; this class talks to the phone.
final class Hub: NSObject, NSMenuDelegate {
    static let shared = Hub()
    let store = Store.shared

    private(set) var link: HubLink?
    private var found: [String: NWEndpoint] = [:]
    private var browser: NWBrowser?
    private var candidateIndex = 0
    private var lastPong: CFTimeInterval = 0
    private var retryWork: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    let stats = MacStats()
    let probes = DeviceProbes()
    let screen = MacScreen()
    private var clipCount = NSPasteboard.general.changeCount
    private var clipFromPhone = -1
    private var nextReq = 1
    private var pending: [Int: (Result<Any, HubError>) -> Void] = [:]
    /// Files the Mac asked for (request id -> what to do once it's here).
    private var wanted: [Int: (URL) -> Void] = [:]
    private var bag: Set<AnyCancellable> = []

    struct HubError: Error { let message: String; let permission: Bool }

    var connected: Bool { store.connected }
    var onCastReady: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onOpenMain: (() -> Void)?

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuGlyph(lit: false)
        statusItem.button?.imagePosition = .imageLeading
        let m = NSMenu(); m.delegate = self; statusItem.menu = m
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatusItem() }
        }.store(in: &bag)
        refreshStatusItem()

        let b = NWBrowser(for: .bonjour(type: "_phonecasthub._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var f: [String: NWEndpoint] = [:]
                for r in results { if case let .service(name, _, _, _) = r.endpoint { f[name] = r.endpoint } }
                self.found = f
                if !self.connected && self.link == nil { self.connect() }
            }
        }
        b.start(queue: .main)
        browser = b

        screen.hub = self
        probes.onUpdate = { [weak self] r in self?.store.devices = r }
        probes.start()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sendStatus() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watchClipboard() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.connect() }
    }

    // MARK: connection

    private func candidates() -> [(NWEndpoint, String)] {
        let d = UserDefaults.standard
        if let h = ProcessInfo.processInfo.environment["PHONECAST_TEST_HOST"] {
            return [(.hostPort(host: NWEndpoint.Host(h), port: 27185), "test phone")]
        }
        var out: [(NWEndpoint, String)] = []
        for name in found.keys.sorted() { out.append((found[name]!, name)) }
        if let h = d.string(forKey: "host"), !h.isEmpty { out.append((.hostPort(host: NWEndpoint.Host(h), port: 27185), h)) }
        if let h = d.string(forKey: "lastHubHost"), !h.isEmpty, h != d.string(forKey: "host"), h != d.string(forKey: "tailnetHost") {
            out.append((.hostPort(host: NWEndpoint.Host(h), port: 27185), h))
        }
        if let ts = d.string(forKey: "tailnetHost"), !ts.isEmpty { out.append((.hostPort(host: NWEndpoint.Host(ts), port: 27185), "\(ts) (Tailscale)")) }
        return out
    }

    func connect() {
        retryWork?.cancel(); retryWork = nil
        guard link == nil else { return }
        let pin = UserDefaults.standard.string(forKey: "pin") ?? ""
        let c = candidates()
        guard !c.isEmpty else { store.linkState = "Looking for the phone…"; scheduleRetry(); return }
        if candidateIndex >= c.count { candidateIndex = 0 }
        let (ep, label) = c[candidateIndex]
        let l = HubLink(endpoint: ep) { fp in
            // first pairing: remember the phone's key; afterwards only that phone is accepted
            guard let pinned = UserDefaults.standard.string(forKey: "phoneKey") else { return true }
            return pinned == fp
        }
        link = l
        if !store.connected { store.linkState = "Connecting to \(label)…" }
        var usedQR = false
        let hello: (Data?, String?, @escaping (Data?) -> Void) -> Void = { [weak self] nonce, fp, answer in
            DispatchQueue.main.async {
                guard let self else { answer(nil); return }
                let pinned = UserDefaults.standard.string(forKey: "phoneKey")
                var o: [String: Any] = ["name": Pairing.name]
                // QR proof, bound to the certificate this Mac sees (a relay through another phone fails)
                if let nonce, let fp {
                    o["qr"] = Pairing.id
                    o["proof"] = Pairing.hex(Pairing.proof(nonce, "phonecast-hub", fp))
                    usedQR = true
                }
                if pinned != nil {
                    if !pin.isEmpty { o["pin"] = pin }          // known phone (TLS key pinned): PIN is safe to send
                    answer(try? JSONSerialization.data(withJSONObject: o))
                } else if usedQR && (pin.isEmpty || !self.qrRejected) {
                    // (without a PIN there's nothing else to try: keep offering the QR proof until the phone scans)
                    answer(try? JSONSerialization.data(withJSONObject: o))   // first contact: QR only, no PIN
                } else if !pin.isEmpty, let fp {
                    // the phone hasn't scanned this Mac: compare keys before the PIN goes out
                    self.confirmPairing(fp) { ok in
                        if ok { o["pin"] = pin; usedQR = false; o.removeValue(forKey: "proof"); o.removeValue(forKey: "qr") }
                        answer(ok ? try? JSONSerialization.data(withJSONObject: o) : nil)
                    }
                } else {
                    self.store.linkState = "Not paired yet: scan the QR code in Settings with PhoneCast on the phone"
                    answer(nil)
                }
            }
        }
        l.verifyOK = { [weak l] p in
            // with QR, the phone must prove it knows the key too (otherwise it's an impostor)
            guard usedQR else { return true }
            guard let l, let nonce = l.nonce, let fp = l.certFingerprint,
                  let o = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any],
                  let proof = o["proof"] as? String else { return UserDefaults.standard.string(forKey: "phoneKey") != nil }
            let ok = proof == Pairing.hex(Pairing.proof(nonce, "phonecast-hub-phone", fp))
            if ok { DispatchQueue.main.async { UserDefaults.standard.set(fp, forKey: "phoneKey"); UserDefaults.standard.set(true, forKey: "qrPaired") } }
            return ok
        }
        l.onReady = { [weak self, weak l] in
            DispatchQueue.main.async {
                guard let self, let l, self.link === l else { return }
                NSLog("hub: connected via \(label)")
                if case .hostPort(let h, _) = ep, label != "test phone" { UserDefaults.standard.set("\(h)", forKey: "lastHubHost") }
                if UserDefaults.standard.string(forKey: "phoneKey") == nil, let fp = l.certFingerprint {
                    UserDefaults.standard.set(fp, forKey: "phoneKey")   // pinned now that the PIN was right
                }
                self.store.connected = true; self.store.linkState = "Connected via \(label)"
                self.candidateIndex = 0; self.lastPong = CACurrentMediaTime()
                self.sendStatus()
                self.store.refreshAll()
                if let t = ProcessInfo.processInfo.environment["PHONECAST_TEST_SEND"] { self.sendFiles([URL(fileURLWithPath: t)]) }
            }
        }
        l.onPacket = { [weak self, weak l] t, p in
            guard let self, let l else { return }
            self.packet(l, t, p)
        }
        // an address that never answers (e.g. a stale Bonjour entry after the phone app restarted) can
        // leave the connection "preparing" forever without an error: give up after 8 s, try the next one
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak l] in
            guard let self, let l, self.link === l, !l.ready, !self.asking else { return }
            l.close("no answer")
        }
        l.onClose = { [weak self, weak l] why in
            DispatchQueue.main.async {
                guard let self, let l, self.link === l else { return }
                NSLog("hub: \(label) closed (\(why))")
                let wasConnected = self.store.connected
                self.link = nil
                self.store.connected = false; self.store.phoneCasting = false
                let keyChanged = why.contains("certificate") || why.contains("-98") || why.contains("handshake")
                if why == "pairing cancelled" {
                    // not paired (no QR scan, no PIN) or the key check was declined: keep the message, try now and then
                    if !self.store.linkState.hasPrefix("Not paired") { self.store.linkState = "Pairing cancelled — scan the QR code in Settings" }
                    self.scheduleRetry(6); return
                }
                if why == "the phone couldn't prove the QR pairing" {
                    self.store.linkState = "Something answered as your phone but couldn't prove the QR pairing — not connected"
                    self.scheduleRetry(10); return
                }
                self.store.linkState = why == "wrong PIN" ? "Wrong PIN (or too many tries: wait 5 minutes) — check Settings"
                    : keyChanged && UserDefaults.standard.string(forKey: "phoneKey") != nil
                        ? "The phone's key doesn't match the paired one. Reinstalled PhoneCast on the phone? Settings → Forget phone key"
                        : "Looking for the phone…"
                self.screen.stop()
                self.incoming.values.forEach { $0.abort() }; self.incoming.removeAll()
                self.incomingReq.values.forEach { self.store.failTransfer($0.1) }; self.incomingReq.removeAll()
                let p = self.pending; self.pending.removeAll()
                p.values.forEach { $0(.failure(HubError(message: "The phone disconnected.", permission: false))) }
                Banners.shared.endCall()
                if why == "qr not known" {
                    // the phone hasn't scanned this Mac's QR code: next try uses the PIN (with key check)
                    self.qrRejected = true
                    // the phone may scan the code any moment: forget the refusal after 30 s
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.qrRejected = false }
                    if pin.isEmpty { self.store.linkState = "Not paired yet: scan the QR code in Settings with PhoneCast on the phone"; self.scheduleRetry(4) }
                    else { self.scheduleRetry(0.5) }
                    return
                }
                if why == "wrong PIN" { return }
                if why == "locked" {
                    self.store.linkState = "The phone is locked for a few minutes after wrong PINs — trying again…"
                    self.scheduleRetry(30); return
                }
                if !wasConnected { self.candidateIndex += 1 }
                self.scheduleRetry(wasConnected ? 1 : (self.candidateIndex < self.candidates().count ? 0.3 : 4))
            }
        }
        l.start(hello: hello)
    }

    private var rejectedKeys = Set<String>()
    /// This session the phone said it doesn't know our QR id: use the PIN path.
    private var qrRejected = false
    /// Settings: the QR was just scanned / PIN changed — try QR again.
    func pairingChanged() { qrRejected = false; rejectedKeys.removeAll(); reconnect() }
    private var asking = false

    /// First pairing: the phone app shows its link key in Settings; only send the PIN if they match.
    private func confirmPairing(_ fp: String, _ answer: @escaping (Bool) -> Void) {
        if rejectedKeys.contains(fp) || asking { answer(false); return }
        if let pinned = UserDefaults.standard.string(forKey: "phoneKey") { answer(pinned == fp); return }
        asking = true
        let short = stride(from: 0, to: 32, by: 4).map { i -> String in
            let a = fp.index(fp.startIndex, offsetBy: i); return String(fp[a..<fp.index(a, offsetBy: 4)])
        }.joined(separator: " ")
        let a = NSAlert()
        a.messageText = "Pair with this phone?"
        a.informativeText = "Open PhoneCast on the phone → Settings. Its link key must be exactly:\n\n\(short)\n\nIf it's different, something else on this network is pretending to be your phone: don't pair."
        a.addButton(withTitle: "Same key, pair"); a.addButton(withTitle: "Different / cancel")
        NSApp.activate(ignoringOtherApps: true)
        let ok = a.runModal() == .alertFirstButtonReturn
        asking = false
        if ok { UserDefaults.standard.set(fp, forKey: "phoneKey") } else { rejectedKeys.insert(fp) }
        answer(ok)
    }

    private func scheduleRetry(_ after: Double = 4) {
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    /// The PIN or addresses changed.
    func reconnect() {
        link?.onClose = nil; link?.close("reconnecting"); link = nil
        store.connected = false; candidateIndex = 0; connect()
    }

    private func tick() {
        guard let l = link, connected else { return }
        if CACurrentMediaTime() - lastPong > 5 { l.close("the phone stopped answering"); return }
        var t = CACurrentMediaTime().bitPattern.bigEndian
        l.send(HT.ping, Data(bytes: &t, count: 8))
    }

    // MARK: requests to the phone

    /// Ask the phone for data (see Features.kt). `done` runs on the main thread.
    func request(_ m: String, _ p: [String: Any] = [:], timeout: Double = 30, done: @escaping (Result<Any, HubError>) -> Void) {
        guard let l = link, connected else { done(.failure(HubError(message: "The phone isn't connected.", permission: false))); return }
        let id = nextReq; nextReq += 1
        pending[id] = done
        guard let d = try? JSONSerialization.data(withJSONObject: ["id": id, "m": m, "p": p]) else { return }
        l.send(HT.req, d)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.pending.removeValue(forKey: id)?(.failure(HubError(message: "The phone didn't answer.", permission: false)))
        }
    }

    /// Ask for a file (photo, file browser item); `then` runs with the downloaded file.
    func fetchFile(_ m: String, _ p: [String: Any], keep: Bool, then: @escaping (URL) -> Void) {
        let req = nextReq; nextReq += 1
        wanted[req] = then
        if !keep { tempReqs.insert(req) }
        var q = p; q["req"] = req
        request(m, q) { r in if case .failure(let e) = r { Banners.shared.info("Couldn't get it from the phone", e.message) } }
    }
    private var tempReqs = Set<Int>()

    // MARK: packets (on the link queue)

    private func packet(_ l: HubLink, _ t: UInt8, _ p: Data) {
        // nothing from a link that hasn't been accepted with the PIN may click, type or write files
        guard l.ready || t == HT.helloOK || t == HT.ping else { return }
        switch t {
        case HT.ping: l.send(HT.pong, p)
        case HT.input: screen.input(p)       // straight from the network queue: lowest delay
        case HT.macAction: let a = String(decoding: p, as: UTF8.self); DispatchQueue.main.async { MacActions.run(a) }
        case HT.screenKey: screen.forceKeyframe()
        case HT.fileData:
            guard p.count >= 4 else { return }
            let id = Int(p.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            let body = p.dropFirst(4)
            DispatchQueue.main.async { self.incoming[id]?.write(body) }
        default:
            DispatchQueue.main.async { self.mainPacket(l, t, p) }
        }
    }

    private func fileId(_ p: Data) -> Int? {
        guard p.count >= 4 else { return nil }
        return Int(p.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
    }

    private func mainPacket(_ l: HubLink, _ t: UInt8, _ p: Data) {
        guard link === l else { return }
        switch t {
        case HT.pong:
            lastPong = CACurrentMediaTime()
            if p.count == 8 {
                let sent = Double(bitPattern: p.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian })
                let ms = (CACurrentMediaTime() - sent) * 1000
                store.rttMs = store.rttMs < 0 ? ms : store.rttMs * 0.7 + ms * 0.3
            }
        case HT.helloOK:
            if let o = json(p) {
                if let n = o["name"] as? String { store.phoneName = n }
                if let k = o["mirrorKey"] as? String { UserDefaults.standard.set(k, forKey: "mirrorKey") }
            }
        case HT.status:
            if let o = json(p) { store.applyStatus(o) }
        case HT.notif: if let o = json(p) { store.addNotification(o) }
        case HT.notifGone: store.removeNotification(String(decoding: p, as: UTF8.self))
        case HT.clip: receiveClip(String(decoding: p, as: UTF8.self))
        case HT.castReady: store.phoneCasting = true; onCastReady?()
        case HT.castStopped: store.phoneCasting = false
        case HT.resp:
            guard let o = json(p), let id = o["id"] as? Int, let done = pending.removeValue(forKey: id) else { return }
            if o["ok"] as? Bool == true { done(.success(o["data"] ?? NSNull())) }
            else { done(.failure(HubError(message: o["message"] as? String ?? "Failed", permission: o["error"] as? String == "permission"))) }
        case HT.event:
            guard let o = json(p) else { return }
            if o["e"] as? String == "call" { store.callEvent(o) }
        case HT.fileBegin:
            if let o = json(p), let id = o["id"] as? Int {
                let name = o["name"] as? String ?? "file"
                let size = (o["size"] as? NSNumber)?.int64Value ?? -1
                let req = o["req"] as? Int ?? 0
                let tid = store.beginTransfer(name: name, outgoing: false, size: size)
                incoming[id] = IncomingFile(name: name, size: size, temp: tempReqs.contains(req)) { [weak self] f in
                    self?.store.progress(tid, f)
                }
                incomingReq[id] = (req, tid)
            }
        case HT.fileEnd:
            guard let id = fileId(p) else { return }
            let (req, tid) = incomingReq.removeValue(forKey: id) ?? (0, 0)
            if let f = incoming.removeValue(forKey: id), let url = f.finish() {
                NSLog("hub: received file \(url.path)")
                store.finishTransfer(tid, url: url)
                tempReqs.remove(req)
                if let then = wanted.removeValue(forKey: req) { then(url) }
                else { Banners.shared.file(url, from: store.phoneName) }
            }
        case HT.fileCancel:
            guard let id = fileId(p) else { return }
            incoming.removeValue(forKey: id)?.abort()
            if let (_, tid) = incomingReq.removeValue(forKey: id) { store.failTransfer(tid) }
        case HT.screenStart:
            let b = [UInt8](p)
            let long = b.count >= 2 ? Int(b[0]) << 8 | Int(b[1]) : 1920
            let mbps = b.count >= 3 ? Int(b[2]) : 16
            screen.start(longSide: long, mbps: mbps)
            store.phoneControlsMac = true
        case HT.screenStop: screen.stop(); store.phoneControlsMac = false
        default: break
        }
    }

    private func json(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    func notifAction(_ key: String, _ action: String, _ text: String = "") {
        guard let d = try? JSONSerialization.data(withJSONObject: ["key": key, "action": action, "text": text]) else { return }
        link?.send(HT.notifAction, d)
    }

    // MARK: clipboard

    private func receiveClip(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(text, forType: .string)
        clipFromPhone = pb.changeCount; clipCount = pb.changeCount
        NSLog("hub: clipboard from phone (\(text.utf8.count) bytes)")
        Banners.shared.clipboard(text, from: store.phoneName)
    }

    private func watchClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != clipCount else { return }
        clipCount = pb.changeCount
        guard store.autoClipboard, connected, pb.changeCount != clipFromPhone else { return }
        // skip what password managers mark as secret
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        if let s = pb.string(forType: .string), !s.isEmpty, s.utf8.count < 1_000_000 { link?.send(HT.clip, Data(s.utf8)) }
    }

    @objc func sendClipboard(_ s: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else { return }
        guard connected else { Banners.shared.info("Phone not connected", ""); return }
        link?.send(HT.clip, Data(str.utf8))
        Banners.shared.info("Sent to \(store.phoneName)'s clipboard", String(str.prefix(120)))
    }

    // MARK: files

    private var incoming: [Int: IncomingFile] = [:]
    private var incomingReq: [Int: (Int, Int)] = [:]
    private var nextFileId: UInt32 = 1
    private let sendQueue = DispatchQueue(label: "phonecast.hub.files")

    @objc func chooseFiles(_ s: Any?) { choose(dir: nil) }

    /// Pick files or folders and send them (to Downloads/PhoneCast, or to `dir` on the phone).
    func choose(dir: String?, done: (() -> Void)? = nil) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = true
        p.message = "Send to \(store.phoneName) — folders are sent as .zip"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { sendFiles(p.urls, dir: dir, done: done) }
    }

    func sendFiles(_ urls: [URL], dir: String? = nil, done: (() -> Void)? = nil) {
        guard let l = link, connected else {
            Banners.shared.info("Phone not connected", "Open PhoneCast on the phone; it connects by itself."); return
        }
        sendQueue.async {
            for original in urls {
                var u = original
                var tempZip: URL?
                if u.hasDirectoryPath {
                    // folders go as one zip (like Finder's "Compress")
                    let z = FileManager.default.temporaryDirectory.appendingPathComponent(u.lastPathComponent + ".zip")
                    try? FileManager.default.removeItem(at: z)
                    let pr = Process()
                    pr.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    pr.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", u.path, z.path]
                    try? pr.run(); pr.waitUntilExit()
                    guard pr.terminationStatus == 0 else { continue }
                    u = z; tempZip = z
                }
                guard let fh = try? FileHandle(forReadingFrom: u) else { continue }
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let (id, tid) = DispatchQueue.main.sync { () -> (UInt32, Int) in
                    self.nextFileId += 1
                    return (self.nextFileId, self.store.beginTransfer(name: u.lastPathComponent, outgoing: true, size: Int64(size)))
                }
                var idBE = id.bigEndian
                let idData = Data(bytes: &idBE, count: 4)
                var begin: [String: Any] = ["id": Int(id), "name": u.lastPathComponent, "size": size]
                if let dir { begin["dir"] = dir }
                l.send(HT.fileBegin, try! JSONSerialization.data(withJSONObject: begin))
                let window = DispatchSemaphore(value: 4)   // at most 4 chunks (1 MB) queued
                var sent = 0, lastPct = -1, ok = true
                while true {
                    guard let chunk = try? fh.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                    window.wait()
                    if self.link !== l { ok = false; break }
                    l.send(HT.fileData, idData + chunk) { window.signal() }
                    sent += chunk.count
                    let pct = size > 0 ? sent * 100 / size : -1
                    if pct != lastPct { lastPct = pct
                        let f = size > 0 ? Double(sent) / Double(size) : 0
                        DispatchQueue.main.async { self.store.progress(tid, f) } }
                }
                try? fh.close()
                if ok { l.send(HT.fileEnd, idData) } else { l.send(HT.fileCancel, idData) }
                DispatchQueue.main.async { ok ? self.store.finishTransfer(tid, url: original) : self.store.failTransfer(tid) }
                if let tempZip { DispatchQueue.global().asyncAfter(deadline: .now() + 5) { try? FileManager.default.removeItem(at: tempZip) } }
            }
            DispatchQueue.main.async { done?() }
        }
    }

    // MARK: status to the phone

    private func sendStatus() {
        var o = stats.sample()
        store.macStats = o
        guard let l = link, connected else { return }
        o["name"] = Host.current().localizedName ?? "Mac"
        if store.rttMs >= 0 { o["rtt"] = Int(store.rttMs.rounded()) }
        o["devices"] = store.devices.map { r -> [String: Any] in
            var d: [String: Any] = ["name": r.name]
            if let ms = r.ms { d["ms"] = Int(ms.rounded()) }
            return d
        }
        if !PcDashboard.shared.base.isEmpty { o["dashboard"] = PcDashboard.shared.base }   // the phone's PC tab uses it too
        if let t = store.transfers.first(where: { $0.state == .running }) { o["transfer"] = "\(t.outgoing ? "Sending" : "Receiving") \(t.name) \(Int(t.progress * 100)) %" }
        if let d = try? JSONSerialization.data(withJSONObject: o) { l.send(HT.status, d) }
    }

    // MARK: menu bar

    func refreshStatusItem() {
        guard let b = statusItem?.button else { return }
        if connected, let bat = store.phoneStatus["battery"] as? Int {
            b.title = " \(bat)%" + ((store.phoneStatus["charging"] as? Bool ?? false) ? "⚡" : "")
            b.appearsDisabled = false
        } else {
            b.title = ""
            b.appearsDisabled = true
        }
        b.toolTip = connected ? "\(store.phoneName) connected" : "Phone not connected"
        // Dock + menu bar icon: the phone's screen is lit while it's connected, dark when not
        if dockShowsConnected != connected {
            dockShowsConnected = connected
            if let img = Bundle.main.image(forResource: connected ? "DockOn" : "DockOff") { NSApp.applicationIconImage = img }
            b.image = Self.menuGlyph(lit: connected)
        }
    }
    private var dockShowsConnected: Bool?

    static func menuGlyph(lit: Bool) -> NSImage? {
        let img = Bundle.main.image(forResource: lit ? "MenuGlyphOn" : "MenuGlyphOff")
        img?.isTemplate = true                       // follows the menu bar's light/dark colour
        return img ?? NSImage(systemSymbolName: "smartphone", accessibilityDescription: "PhoneCast")
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
        func act(_ s: String, _ sel: Selector, _ target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: ""); i.target = target ?? self; m.addItem(i); return i
        }
        if connected {
            info("\(store.phoneName)  ●  \(store.rttMs >= 0 ? "\(Int(store.rttMs.rounded())) ms" : "")  ·  \(store.phoneSummary)")
        } else {
            info(store.linkState)
        }
        if let t = store.transfers.first(where: { $0.state == .running }) { info("\(t.outgoing ? "Sending" : "Receiving") \(t.name) \(Int(t.progress * 100)) %") }
        m.addItem(.separator())
        _ = act("Open PhoneCast", #selector(openMain(_:)))
        _ = act(store.phoneCasting ? "Show phone screen" : "Mirror phone", #selector(castPhone(_:)))
        _ = act("Send files to phone…", #selector(chooseFiles(_:)))
        _ = act("Send clipboard to phone", #selector(sendClipboard(_:)))
        act("Mute notifications", #selector(toggleMute(_:))).state = store.muteAll ? .on : .off
        m.addItem(.separator())
        for r in store.devices { info(r.name + "   " + (r.ms.map { "● \(Int($0.rounded())) ms" } ?? "○ offline")) }
        m.addItem(.separator())
        _ = act("Quit PhoneCast", #selector(NSApplication.terminate(_:)), NSApp)
    }

    @objc func openMain(_ s: Any?) { onOpenMain?() }
    @objc func toggleMute(_ s: Any?) { store.muteAll.toggle() }
    @objc func castPhone(_ s: Any?) { mirror() }

    /// Show the phone's screen: connect if it's already sharing, otherwise ask it to start.
    func mirror() {
        onOpenWindow?()
        if !store.phoneCasting { link?.send(HT.castRequest) }
        onCastReady?()
    }

    static var loginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("login item: \(error)") }
        }
    }
}

/// A file arriving from the phone: ~/Downloads/PhoneCast, or a temp folder when the Mac asked
/// for it only to look at it (Quick Look / open).
final class IncomingFile {
    private var fh: FileHandle?
    private let url: URL
    private let size: Int64
    private var got: Int64 = 0
    private var lastPct = -1
    private let progress: (Double) -> Void

    init(name: String, size: Int64, temp: Bool, progress: @escaping (Double) -> Void) {
        self.size = size; self.progress = progress
        let dir = temp
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PhoneCast-\(UUID().uuidString.prefix(8))")
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneCast")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var u = dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        url = u
        FileManager.default.createFile(atPath: u.path, contents: nil)
        fh = try? FileHandle(forWritingTo: u)
    }

    func write(_ d: Data) {
        try? fh?.write(contentsOf: d)
        got += Int64(d.count)
        let pct = size > 0 ? Int(got * 100 / size) : -1
        if pct != lastPct { lastPct = pct; progress(size > 0 ? Double(got) / Double(size) : 0) }
    }

    func finish() -> URL? { try? fh?.close(); fh = nil; return url }
    func abort() { try? fh?.close(); fh = nil; try? FileManager.default.removeItem(at: url) }
}

/// This Mac's health: battery, CPU, memory, thermal state.
final class MacStats {
    private var lastTicks: [UInt32]?

    func sample() -> [String: Any] {
        var o: [String: Any] = [:]
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    o["battery"] = cur * 100 / max
                    o["charging"] = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                }
            }
        }
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if r == KERN_SUCCESS {
            let t = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3] // user, system, idle, nice
            if let p = lastTicks {
                let d = zip(t, p).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                if total > 0 { o["cpu"] = Int(((total - d[2]) / total * 100).rounded()) }
            }
            lastTicks = t
        }
        var vm = vm_statistics64()
        var vc = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vc)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vc) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * page
            o["mem"] = Int((used / Double(ProcessInfo.processInfo.physicalMemory) * 100).rounded())
        }
        o["thermal"] = ["cool", "warm", "hot", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        return o
    }
}

/// Measures how fast other machines answer (TCP connect time), every 5 s.
final class DeviceProbes {
    struct Result: Identifiable { var id: String { name }; let name: String; let ms: Double? }
    private(set) var results: [Result] = []
    var onUpdate: (([Result]) -> Void)?
    private let q = DispatchQueue(label: "phonecast.probes")

    static let defaultConfig = ""   // set in Settings → Devices to watch

    var config: String {
        get { UserDefaults.standard.string(forKey: "monitorDevices") ?? Self.defaultConfig }
        set { UserDefaults.standard.set(newValue, forKey: "monitorDevices"); probe() }
    }

    private var targets: [(String, String, UInt16)] {
        config.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let last = parts.last, parts.count >= 2 else { return nil }
            let hp = last.split(separator: ":")
            guard hp.count == 2, let port = UInt16(hp[1]) else { return nil }
            return (parts.dropLast().joined(separator: " "), String(hp[0]), port)
        }
    }

    func start() {
        results = targets.map { Result(name: $0.0, ms: nil) }
        onUpdate?(results)
        probe()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.probe() }
    }

    func probe() {
        let t = targets
        var out = [Result?](repeating: nil, count: t.count)
        let group = DispatchGroup()
        for (i, (name, host, port)) in t.enumerated() {
            group.enter()
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let start = CACurrentMediaTime()
            var done = false
            func finish(_ ms: Double?) {
                if done { return }; done = true
                out[i] = Result(name: name, ms: ms); c.cancel(); group.leave()
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish((CACurrentMediaTime() - start) * 1000)
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
        group.notify(queue: .main) { self.results = out.compactMap { $0 }; self.onUpdate?(self.results) }
    }
}
