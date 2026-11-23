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

    func apply() {
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
                DispatchQueue.main.async { self.state = .local; self.changed(); self.startTap() }
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
    private enum M: UInt8 { case hello = 0, enter = 1, leave = 2, move = 3, button = 4, wheel = 5, key = 6, releaseAll = 7 }

    /// Layout and options for the PC (u8 side of the Mac the PC is on: 0 left, 1 right; u8 swap).
    private func sendHello() { send(Data([M.hello.rawValue, pcSide == "left" ? 0 : 1, swapCmdCtrl ? 1 : 0])) }

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
        case .enter:   // the PC's pointer came over: this Mac is driven by the PC now
            dlog("desk: \(peerName)'s pointer came over")
            if state == .sending { unpin() }
            state = .receiving
            let f = screenFrame()
            pos = CGPoint(x: pcSide == "right" ? f.maxX - 2 : f.minX + 1, y: f.minY + Self.readF32(m, 1) * (f.height - 1))
            warp(pos)
            changed()
        case .leave:   // our pointer came back from the PC
            guard state == .sending else { return }
            dlog("desk: pointer back from \(peerName)")
            state = .local
            let f = screenFrame()
            unpin(at: CGPoint(x: pcSide == "right" ? f.maxX - 3 : f.minX + 2, y: f.minY + Self.readF32(m, 1) * (f.height - 1)))
            changed()
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
        if st == .local, type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            let dx = ev.getDoubleValueField(.mouseEventDeltaX)
            let p = ev.location, f = screenFrame()
            // just came back over this edge: only cross again once the pointer has been away from it
            if !armed { if pcSide == "right" ? p.x < f.maxX - 21 : p.x > f.minX + 20 { armed = true }; return Unmanaged.passUnretained(ev) }
            let atEdge = pcSide == "right" ? (p.x >= f.maxX - 1 && dx > 0) : (p.x <= f.minX && dx < 0)
            if atEdge && conn != nil {
                DispatchQueue.main.async { self.beginSending(y: (p.y - f.minY) / max(1, f.height - 1)) }
                return nil
            }
        }
        return Unmanaged.passUnretained(ev)
    }

    private func beginSending(y: Double) {
        guard state == .local else { return }
        state = .sending
        dlog("desk: pointer -> \(peerName)")
        CGAssociateMouseAndMouseCursorPosition(0)    // hold the arrow still while the mouse drives the PC
        send(Data([M.enter.rawValue]) + Self.f32(y))
        changed()
    }

    private var armed = true
    private func unpin(at p: CGPoint? = nil) {
        armed = false
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
        let f = screenFrame()
        // from where the cursor really is (this Mac's own trackpad may have moved it too)
        if let cur = CGEvent(source: nil)?.location { pos = cur }
        var p = CGPoint(x: pos.x + dx, y: pos.y + dy)
        p.y = min(max(p.y, f.minY), f.maxY - 1)
        // over the edge that faces the PC: the pointer goes back to the PC
        if pcSide == "right" ? p.x > f.maxX - 1 : p.x < f.minX {
            state = .local
            armed = false
            releaseAll()
            send(Data([M.leave.rawValue]) + Self.f32((p.y - f.minY) / max(1, f.height - 1)))
            changed()
            return
        }
        p.x = min(max(p.x, f.minX), f.maxX - 1)
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
