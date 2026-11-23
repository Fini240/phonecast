import AppKit
import Network
import CryptoKit
import Carbon.HIToolbox

/// "Shared keyboard & mouse" between this Mac and the linked Windows PC (like Tether, built in). Push the pointer
/// over the screen edge that faces the PC and the Mac's keyboard and mouse drive the PC; push it back over the
/// PC's edge and they're the Mac's again. Works the other way round too (the PC's keyboard and mouse on the Mac).
///
/// The two computers talk directly, not through the phone: the PC dials this Mac on TCP 27196 (its addresses
/// come from the phone, which collects them from each computer's STATUS). The phone only hands both the same
/// secret ("desk.key" in its STATUS, sent to each over its TLS link): both prove they know it, and every event
/// after that is AES-GCM encrypted, so keystrokes never cross the network in the clear.
///
/// Keys travel as USB HID usages (physical key positions), so each machine's own layout decides the character.
/// ⌘ and Ctrl swap places on the way (⌘C copies on the PC, the PC's Ctrl+C copies on the Mac).
final class Desk: ObservableObject {
    static let shared = Desk()
    static let port: UInt16 = 27196

    enum State { case off, waiting, local, sending, receiving }
    private(set) var state: State = .off
    private(set) var peerName = ""
    var summary: String {
        switch state {
        case .off: return tr("Off")
        case .waiting: return tr("Waiting for the PC")
        case .local: return tr("Connected to %@", peerName)
        case .sending: return tr("Keyboard and mouse are on %@", peerName)
        case .receiving: return tr("%@'s keyboard and mouse are on this Mac", peerName)
        }
    }
    var onChange: (() -> Void)?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "deskEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "deskEnabled"); apply() }
    }
    /// Where the PC stands next to the Mac: "right" or "left".
    var pcSide: String {
        get { UserDefaults.standard.string(forKey: "deskPcSide") ?? "right" }
        set { UserDefaults.standard.set(newValue, forKey: "deskPcSide"); sendHello() }
    }
    var swapCmdCtrl: Bool {
        get { UserDefaults.standard.object(forKey: "deskSwap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "deskSwap"); sendHello() }
    }

    private let q = DispatchQueue(label: "phonecast.desk")
    private var key: SymmetricKey?
    private var listener: NWListener?
    private var conn: NWConnection?
    private var session: SymmetricKey?
    private var sendCounter: UInt64 = 0, recvCounter: UInt64 = 0

    // MARK: setup (main thread)

    /// The phone's STATUS arrived: take the secret when there is one.
    func update(phoneStatus: [String: Any]) {
        // deskTestKey (defaults): tests without the phone handing out the secret
        let k = (((phoneStatus["desk"] as? [String: Any])?["key"] as? String) ?? UserDefaults.standard.string(forKey: "deskTestKey")).flatMap { Data(base64Encoded: $0) }
        let newKey = k.map { SymmetricKey(data: $0) }
        if newKey?.withUnsafeBytes({ Data($0) }) != key?.withUnsafeBytes({ Data($0) }) { key = newKey; apply() }
    }

    private var screensObserver: Any?
    func apply() {
        if screensObserver == nil {
            refreshGeometry()
            screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshGeometry(); self?.sendLayout(); self?.objectWillChange.send()
            }
        }
        if enabled && key != nil { startListener() } else { stopAll() }
        changed()
    }

    private func changed() { DispatchQueue.main.async { self.objectWillChange.send(); self.onChange?(); Hub.shared.refreshStatusItem() } }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { s in if case .failed(let e) = s { dlog("desk: listener failed \(e)") } }
            l.start(queue: q)
            listener = l
            if state == .off { state = .waiting }
            dlog("desk: listening on \(Self.port)")
        } catch { dlog("desk: can't listen: \(error)") }
    }

    private func stopAll() {
        listener?.cancel(); listener = nil
        q.async { self.drop("off") }
        state = .off
    }

    /// The addresses the PC can dial (this Mac's LAN and Tailscale IPv4), for the Mac's STATUS to the phone.
    static func lanAddresses() -> [String] { AgentWeb.addresses() }

    // MARK: connection (desk queue)

    private func accept(_ c: NWConnection) {
        guard let key else { c.cancel(); return }
        if conn != nil { dlog("desk: a second PC tried to connect; keeping the first"); c.cancel(); return }
        c.start(queue: q)
        // PC: "PCDK", 1, nonceP(16)
        read(c, 21) { [weak self] hello in
            guard let self, let hello, hello.prefix(4) == Data("PCDK".utf8), hello[4] == 1 else { c.cancel(); return }
            let nP = hello.suffix(16)
            var nM = Data(count: 16); _ = nM.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("mac".utf8) + nP + nM, using: key))
            c.send(content: nM + proof, completion: .contentProcessed { _ in })
            self.read(c, 32 + 64) { [weak self] r in
                guard let self, let r, r.count == 96 else { c.cancel(); return }
                let want = Data(HMAC<SHA256>.authenticationCode(for: Data("pc".utf8) + nP + nM, using: key))
                guard r.prefix(32) == want else { dlog("desk: the PC didn't prove the secret"); c.cancel(); return }
                let name = String(decoding: r.suffix(64), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                self.session = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("session".utf8) + nP + nM, using: key)))
                self.sendCounter = 0; self.recvCounter = 0
                self.conn = c
                self.peerName = name.isEmpty ? "PC" : name
                c.stateUpdateHandler = { [weak self] s in
                    switch s { case .failed, .cancelled: self?.q.async { if self?.conn === c { self?.drop("closed") } } default: break }
                }
                dlog("desk: \(self.peerName) connected")
                DispatchQueue.main.async { self.refreshGeometry(); self.state = .local; self.changed(); self.startTap() }
                self.sendHello()
                self.readFrame(c)
            }
        }
    }

    private func drop(_ why: String) {
        conn?.cancel(); conn = nil; session = nil
        let was = state
        DispatchQueue.main.async {
            if was == .sending { self.unpin(); }
            self.releaseAll()
            if self.state != .off { self.state = self.listener != nil ? .waiting : .off }
            self.changed()
        }
        if was != .off { dlog("desk: disconnected (\(why))") }
    }

    private func read(_ c: NWConnection, _ n: Int, _ done: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, err in
            if let d, d.count == n, err == nil { done(d) } else { done(nil) }
        }
    }

    private func readFrame(_ c: NWConnection) {
        read(c, 2) { [weak self] h in
            guard let self, let h else { self?.drop("read"); return }
            let len = Int(h[h.startIndex]) << 8 | Int(h[h.startIndex + 1])
            self.read(c, len) { [weak self] body in
                guard let self, let body, let session = self.session else { self?.drop("read"); return }
                var nonce = Data([2, 0, 0, 0]); withUnsafeBytes(of: self.recvCounter.bigEndian) { nonce.append(contentsOf: $0) }
                self.recvCounter += 1
                guard let box = try? AES.GCM.SealedBox(combined: nonce + body), let plain = try? AES.GCM.open(box, using: session) else {
                    self.drop("bad frame"); return
                }
                DispatchQueue.main.async { self.handle(plain) }
                self.readFrame(c)
            }
        }
    }

    /// Any thread.
    private func send(_ msg: Data) {
        q.async {
            guard let c = self.conn, let session = self.session else { return }
            var nonce = Data([1, 0, 0, 0]); withUnsafeBytes(of: self.sendCounter.bigEndian) { nonce.append(contentsOf: $0) }
            self.sendCounter += 1
            guard let box = try? AES.GCM.seal(msg, using: session, nonce: AES.GCM.Nonce(data: nonce)) else { return }
            let body = box.ciphertext + box.tag
            c.send(content: Data([UInt8(body.count >> 8), UInt8(body.count & 0xff)]) + body, completion: .contentProcessed { _ in })
        }
    }

    // message types
    private enum M: UInt8 { case hello = 0, enter = 1, leave = 2, move = 3, button = 4, wheel = 5, key = 6, releaseAll = 7, layout = 8, screens = 9, setOrigin = 10 }

    /// Layout and options for the PC (u8 side of the Mac the PC is on: 0 left, 1 right; u8 swap).
    private func sendHello() { send(Data([M.hello.rawValue, pcSide == "left" ? 0 : 1, swapCmdCtrl ? 1 : 0])); sendLayout() }

    // MARK: layout: the PC's monitors and this Mac on one plane (in PC pixels), arranged in Settings

    /// PC pixels per Mac point (also how fast the Mac's mouse moves on the PC).
    static let k: CGFloat = 1.5
    /// The PC's monitors in its own pixels (from the PC; remembered for the editor while it's offline).
    @Published var pcScreens: [CGRect] = (UserDefaults.standard.array(forKey: "deskPcScreens") as? [[Double]] ?? [])
        .compactMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    /// Where the top-left of this Mac's displays sits on the PC's plane (PC pixels); nil = the default spot.
    var macOrigin: CGPoint? {
        get { let d = UserDefaults.standard; return d.object(forKey: "deskMacX") == nil ? nil : CGPoint(x: d.double(forKey: "deskMacX"), y: d.double(forKey: "deskMacY")) }
        set {
            if let v = newValue { UserDefaults.standard.set(Double(v.x), forKey: "deskMacX"); UserDefaults.standard.set(Double(v.y), forKey: "deskMacY") }
            else { UserDefaults.standard.removeObject(forKey: "deskMacX"); UserDefaults.standard.removeObject(forKey: "deskMacY") }
            refreshGeometry(); sendLayout(); objectWillChange.send()
        }
    }

    /// This Mac's displays in CoreGraphics points (top-left origin).
    static func macDisplays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    /// Next to the PC's leftmost monitor (or rightmost, for the old "PC left of the Mac"), centred on it.
    func defaultOrigin(macSize: CGSize) -> CGPoint {
        guard !pcScreens.isEmpty else { return CGPoint(x: -macSize.width, y: 0) }
        if pcSide == "left", let r = pcScreens.max(by: { $0.maxX < $1.maxX }) { return CGPoint(x: r.maxX, y: r.midY - macSize.height / 2) }
        let l = pcScreens.min(by: { $0.minX < $1.minX })!
        return CGPoint(x: l.minX - macSize.width, y: l.midY - macSize.height / 2)
    }

    // geometry the event tap reads (rebuilt on the main thread when anything changes)
    private var macUnion = CGRect.zero
    private var macRects: [CGRect] = []          // CG points
    private var macPlane: [CGRect] = []          // the same displays on the PC's plane
    private var origin = CGPoint.zero

    func refreshGeometry() {
        macRects = Self.macDisplays()
        macUnion = macRects.reduce(CGRect.null) { $0.union($1) }
        let size = CGSize(width: macUnion.width * Self.k, height: macUnion.height * Self.k)
        origin = macOrigin ?? defaultOrigin(macSize: size)
        macPlane = macRects.map { toPlane($0) }
    }

    func toPlane(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + (p.x - macUnion.minX) * Self.k, y: origin.y + (p.y - macUnion.minY) * Self.k) }
    func toPlane(_ r: CGRect) -> CGRect { CGRect(origin: toPlane(r.origin), size: CGSize(width: r.width * Self.k, height: r.height * Self.k)) }
    func fromPlane(_ q: CGPoint) -> CGPoint { CGPoint(x: macUnion.minX + (q.x - origin.x) / Self.k, y: macUnion.minY + (q.y - origin.y) / Self.k) }
    /// The Mac block dropped at [m] (plane): snapped against the nearest PC monitor edge, touching it with at
    /// least 100 px in common and overlapping no monitor. Returns the new top-left.
    func snap(_ m: CGRect) -> CGPoint {
        let minOverlap: CGFloat = 100
        var best: (CGPoint, CGFloat)?
        for sc in pcScreens {
            let y = min(max(m.minY, sc.minY - m.height + minOverlap), sc.maxY - minOverlap)
            let x = min(max(m.minX, sc.minX - m.width + minOverlap), sc.maxX - minOverlap)
            for o in [CGPoint(x: sc.minX - m.width, y: y), CGPoint(x: sc.maxX, y: y), CGPoint(x: x, y: sc.minY - m.height), CGPoint(x: x, y: sc.maxY)] {
                let cand = CGRect(origin: o, size: m.size)
                if pcScreens.contains(where: { let i = $0.intersection(cand); return !i.isNull && i.width > 1 && i.height > 1 }) { continue }
                let d = hypot(o.x - m.minX, o.y - m.minY)
                if best == nil || d < best!.1 { best = (o, d) }
            }
        }
        return best?.0 ?? m.origin
    }

    /// The Mac's displays on the plane (for the editor).
    var macPlaneRects: [CGRect] { macPlane }

    private static func clamp(_ p: CGPoint, into r: CGRect) -> CGPoint { CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1)) }

    /// A point on this Mac (CG points) nearest to [p]: inside the display that contains it, else the nearest display.
    private func onMac(_ p: CGPoint) -> CGPoint {
        if macRects.contains(where: { $0.contains(p) }) { return p }
        let r = macRects.min(by: { Self.dist($0, p) < Self.dist($1, p) }) ?? macUnion
        return Self.clamp(p, into: r)
    }
    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }

    private func sendLayout() {
        var d = Data([M.layout.rawValue, UInt8(macPlane.count)])
        for r in macPlane { for v in [r.minX, r.minY, r.width, r.height] { d += Self.i32(Int(v.rounded())) } }
        send(d)
    }

    private static func i32(_ v: Int) -> Data { withUnsafeBytes(of: Int32(clamping: v).bigEndian) { Data($0) } }
    private static func readI32(_ b: [UInt8], _ o: Int) -> Int { Int(Int32(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))) }
    private func point(_ q: CGPoint) -> Data { Self.i32(Int(q.x.rounded())) + Self.i32(Int(q.y.rounded())) }

    private static func f32(_ v: Double) -> Data { withUnsafeBytes(of: Float(v).bitPattern.bigEndian) { Data($0) } }
    private static func i16(_ v: Int) -> Data { let x = Int16(clamping: v); return withUnsafeBytes(of: x.bigEndian) { Data($0) } }
    private static func readF32(_ d: Data, _ o: Int) -> Double {
        let b = [UInt8](d); guard b.count >= o + 4 else { return 0.5 }
        return Double(Float(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])))
    }
    private static func readI16(_ d: Data, _ o: Int) -> Int { let b = [UInt8](d); return Int(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1]))) }

    // MARK: messages from the PC (main thread)

    private func handle(_ m: Data) {
        let b = [UInt8](m)
        guard let t = b.first.flatMap(M.init) else { return }
        switch t {
        case .enter where b.count >= 9:   // the PC's pointer came over (at a point on the plane): this Mac is driven by the PC now
            dlog("desk: \(peerName)'s pointer came over")
            if state == .sending { unpin() }
            state = .receiving
            pos = onMac(fromPlane(CGPoint(x: Self.readI32(b, 1), y: Self.readI32(b, 5))))
            warp(pos)
            changed()
        case .leave where b.count >= 9:   // our pointer came back from the PC
            guard state == .sending else { return }
            dlog("desk: pointer back from \(peerName)")
            state = .local
            unpin(at: onMac(fromPlane(CGPoint(x: Self.readI32(b, 1), y: Self.readI32(b, 5)))))
            changed()
        case .setOrigin where b.count >= 9:   // rearranged in the PC's editor
            macOrigin = CGPoint(x: Self.readI32(b, 1), y: Self.readI32(b, 5))
        case .screens where b.count >= 2:   // the PC's monitors
            let n = Int(b[1])
            guard b.count >= 2 + n * 16 else { return }
            pcScreens = (0..<n).map { i in
                let o = 2 + i * 16
                return CGRect(x: Self.readI32(b, o), y: Self.readI32(b, o + 4), width: Self.readI32(b, o + 8), height: Self.readI32(b, o + 12))
            }
            UserDefaults.standard.set(pcScreens.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }, forKey: "deskPcScreens")
            refreshGeometry(); sendLayout(); objectWillChange.send()
        case .move where state == .receiving && b.count >= 5:
            injectMove(dx: Double(Self.readI16(m, 1)), dy: Double(Self.readI16(m, 3)))
        case .button where state == .receiving && b.count >= 3: injectButton(Int(b[1]), down: b[2] == 1)
        case .wheel where state == .receiving && b.count >= 5: injectWheel(dx: Self.readI16(m, 1), dy: Self.readI16(m, 3))
        case .key where b.count >= 4: if state == .receiving { injectKey(hid: Int(b[1]) << 8 | Int(b[2]), down: b[3] == 1) }
        case .releaseAll: releaseAll()
        default: break
        }
    }

    // MARK: screens

    /// All displays together, in CoreGraphics coordinates (top-left origin).
    private func screenFrame() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: capture: an event tap that watches the edge and, while the pointer is on the PC, swallows everything

    private var tap: CFMachPort?
    private static let mark: Int64 = 0x5043_4453   // "PCDS" in eventSourceUserData: our own injections

    private func startTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            Banners.shared.info(tr("Shared keyboard & mouse needs Accessibility"), tr("System Settings → Privacy & Security → Accessibility → PhoneCast"))
            return
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, ev, info in
                                            guard let info else { return Unmanaged.passUnretained(ev) }
                                            return Unmanaged<Desk>.fromOpaque(info).takeUnretainedValue().tapped(type, ev)
                                        }, userInfo: me) else { dlog("desk: no event tap"); return }
        tap = t
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        thread.name = "desk-tap"; thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Runs on the tap thread; must be quick. Returns nil to swallow.
    private var tapState: State { state }
    private func tapped(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if ev.getIntegerValueField(.eventSourceUserData) == Self.mark { return Unmanaged.passUnretained(ev) }
        let st = tapState
        if st == .sending { forward(type, ev); return nil }
        if st == .local, conn != nil, type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            let dx = ev.getDoubleValueField(.mouseEventDeltaX), dy = ev.getDoubleValueField(.mouseEventDeltaY)
            let p = ev.location
            // just came back: only cross again once the pointer has been away from where it came in
            if !armed { if hypot(p.x - disarmedAt.x, p.y - disarmedAt.y) > 20 { armed = true }; return Unmanaged.passUnretained(ev) }
            // a few pixels further in the direction of the push: off every Mac display and onto a PC monitor?
            let P = toPlane(p)
            let q = CGPoint(x: P.x + (dx > 0 ? 3 : dx < 0 ? -3 : 0), y: P.y + (dy > 0 ? 3 : dy < 0 ? -3 : 0))
            if q != P, !macPlane.contains(where: { $0.contains(q) }), let screen = pcScreens.first(where: { $0.contains(q) }) {
                let entry = Self.clamp(q, into: screen)
                DispatchQueue.main.async { self.beginSending(at: entry) }
                return nil
            }
        }
        return Unmanaged.passUnretained(ev)
    }

    private func beginSending(at entry: CGPoint) {
        guard state == .local else { return }
        state = .sending
        dlog("desk: pointer -> \(peerName)")
        CGAssociateMouseAndMouseCursorPosition(0)    // hold the arrow still while the mouse drives the PC
        send(Data([M.enter.rawValue]) + point(entry))
        changed()
    }

    private var armed = true
    private var disarmedAt = CGPoint.zero
    private func disarm(_ p: CGPoint) { armed = false; disarmedAt = p }
    private func unpin(at p: CGPoint? = nil) {
        if let p { disarm(p) }
        if let p { CGWarpMouseCursorPosition(p) }
        CGAssociateMouseAndMouseCursorPosition(1)
        sendHeldKeysUp()
    }

    /// Keys held on the Mac when the pointer leaves: let go of them on the PC, so nothing sticks.
    private var held = Set<Int>()
    private func sendHeldKeysUp() { send(Data([M.releaseAll.rawValue])); held.removeAll() }

    private func forward(_ type: CGEventType, _ ev: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Int(ev.getDoubleValueField(.mouseEventDeltaX).rounded()), dy = Int(ev.getDoubleValueField(.mouseEventDeltaY).rounded())
            if dx != 0 || dy != 0 { send(Data([M.move.rawValue]) + Self.i16(dx) + Self.i16(dy)) }
        case .leftMouseDown, .leftMouseUp: send(Data([M.button.rawValue, 0, type == .leftMouseDown ? 1 : 0]))
        case .rightMouseDown, .rightMouseUp: send(Data([M.button.rawValue, 1, type == .rightMouseDown ? 1 : 0]))
        case .otherMouseDown, .otherMouseUp:
            let n = Int(ev.getIntegerValueField(.mouseEventButtonNumber))   // 2 middle, 3 back, 4 forward
            send(Data([M.button.rawValue, UInt8(min(4, max(2, n))), type == .otherMouseDown ? 1 : 0]))
        case .scrollWheel:
            // pixels (content direction) -> wheel units, 120 = one notch ≈ 40 px
            let dy = ev.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), dx = ev.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            send(Data([M.wheel.rawValue]) + Self.i16(Int(dx * 3)) + Self.i16(Int(dy * 3)))
        case .keyDown, .keyUp:
            if let hid = DeskKeys.hid(mac: Int(ev.getIntegerValueField(.keyboardEventKeycode))) {
                if type == .keyDown { held.insert(hid) } else { held.remove(hid) }
                send(Data([M.key.rawValue, UInt8(hid >> 8), UInt8(hid & 0xff), type == .keyDown ? 1 : 0]))
            }
        case .flagsChanged:
            let code = Int(ev.getIntegerValueField(.keyboardEventKeycode))
            if code == 57 {   // Caps Lock toggles: one press on the PC
                send(Data([M.key.rawValue, 0, 0x39, 1])); send(Data([M.key.rawValue, 0, 0x39, 0])); return
            }
            guard let hid = DeskKeys.hid(mac: code), let flag = DeskKeys.flag(mac: code) else { return }
            let down = ev.flags.contains(flag)
            send(Data([M.key.rawValue, UInt8(hid >> 8), UInt8(hid & 0xff), down ? 1 : 0]))
        default: break
        }
    }

    // MARK: injection (main thread): the PC drives this Mac

    private let src = CGEventSource(stateID: .hidSystemState)
    private var pos = CGPoint.zero
    private var buttons = Set<Int>()
    private var flags: CGEventFlags = []
    private var keysDown = Set<Int>()
    private var lastClick: (at: CFTimeInterval, button: Int, count: Int64) = (0, -1, 1)

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Self.mark)
        e.post(tap: .cghidEventTap)
    }

    private func warp(_ p: CGPoint) { CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(1) }

    private func injectMove(dx: Double, dy: Double) {
        // from where the cursor really is (this Mac's own trackpad may have moved it too)
        if let cur = CGEvent(source: nil)?.location { pos = cur }
        var p = CGPoint(x: pos.x + dx, y: pos.y + dy)
        if !macRects.contains(where: { $0.contains(p) }) {
            // off this Mac's displays: onto a PC monitor goes back to the PC, anywhere else stays at the edge
            let q = toPlane(p)
            if let screen = pcScreens.first(where: { $0.contains(q) }) {
                state = .local
                disarm(pos)
                releaseAll()
                send(Data([M.leave.rawValue]) + point(Self.clamp(q, into: screen)))
                changed()
                return
            }
            p = Self.clamp(p, into: macRects.first(where: { $0.contains(pos) }) ?? macUnion)
        }
        pos = p
        let type: CGEventType = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : buttons.isEmpty ? .mouseMoved : .otherMouseDragged
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.setDoubleValueField(.mouseEventDeltaX, value: dx); e?.setDoubleValueField(.mouseEventDeltaY, value: dy)
        e?.flags = flags
        post(e)
    }

    private func injectButton(_ b: Int, down: Bool) {
        if down { buttons.insert(b) } else { buttons.remove(b) }
        let type: CGEventType, btn: CGMouseButton
        switch b {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; btn = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; btn = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; btn = CGMouseButton(rawValue: UInt32(b)) ?? .center
        }
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: btn)
        if down {
            let now = CACurrentMediaTime()
            lastClick = (now, b, now - lastClick.at < NSEvent.doubleClickInterval && lastClick.button == b ? min(3, lastClick.count + 1) : 1)
        }
        e?.setIntegerValueField(.mouseEventClickState, value: lastClick.count)
        if b >= 2 { e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        e?.flags = flags
        post(e)
    }

    private func injectWheel(dx: Int, dy: Int) {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(dy / 3), wheel2: Int32(dx / 3), wheel3: 0)
        post(e)
    }

    private func injectKey(hid raw: Int, down: Bool) {
        let hid = swapCmdCtrl ? DeskKeys.swap(raw) : raw
        guard let vk = DeskKeys.mac(hid: hid) else { return }
        if down { keysDown.insert(hid) } else { keysDown.remove(hid) }
        if let flag = DeskKeys.flag(mac: vk) {
            // a modifier only counts as one when it arrives as flagsChanged with the new flags
            if down { flags.insert(flag) } else if !keysDown.contains(where: { DeskKeys.flag(mac: DeskKeys.mac(hid: $0) ?? -1) == flag }) { flags.remove(flag) }
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vk), keyDown: down)
            e?.type = .flagsChanged
            e?.flags = flags
            post(e)
            return
        }
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vk), keyDown: down)
        e?.flags = flags
        post(e)
    }

    private func releaseAll() {
        for hid in keysDown { injectKey(hid: swapCmdCtrl ? DeskKeys.swap(hid) : hid, down: false) }
        keysDown.removeAll(); flags = []
        for b in buttons { injectButton(b, down: false) }
        buttons.removeAll()
    }

    func stopOnQuit() {
        if state == .sending { CGAssociateMouseAndMouseCursorPosition(1) }
        q.sync { conn?.cancel() }
    }
}

/// Desk's own log (NSLog shows up as <private>): ~/Library/Logs/PhoneCast-desk.log
func dlog(_ s: String) {
    NSLog("%@", s)
    let line = "\(Date()) \(s)\n"
    let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PhoneCast-desk.log")
    if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: u) }
}

/// USB HID usage <-> Mac virtual key code (from Tether), with the ISO keyboard's two swapped keys.
enum DeskKeys {
    private static let table: [Int: Int] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3, 0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37, 0x10: 46,
        0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15, 0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7, 0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23, 0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29, 0x28: 36, 0x29: 53,
        0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42, 0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43,
        0x37: 47, 0x38: 44, 0x39: 57, 0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96, 0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101,
        0x43: 109, 0x44: 103, 0x45: 111, 0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123,
        0x51: 125, 0x52: 126, 0x64: 10, 0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
    ]
    /// On ISO keyboards (German MacBooks) the key left of 1 sends kVK_ISO_Section (10) and the <> key kVK_ANSI_Grave (50).
    private static let iso = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    private static func fix(_ m: [Int: Int]) -> [Int: Int] {
        guard iso else { return m }
        var t = m; t[0x35] = 10; t[0x64] = 50; return t
    }
    private static let toMac = fix(table)
    private static let toHid = Dictionary(toMac.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })

    static func mac(hid: Int) -> Int? { toMac[hid] }
    static func hid(mac: Int) -> Int? { toHid[mac] }
    static func flag(mac: Int) -> CGEventFlags? {
        switch mac {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 57: return .maskAlphaShift
        default: return nil
        }
    }
    /// ⌘ <-> Ctrl (left and right).
    static func swap(_ hid: Int) -> Int {
        switch hid { case 0xE0: return 0xE3; case 0xE3: return 0xE0; case 0xE4: return 0xE7; case 0xE7: return 0xE4; default: return hid }
    }
}
