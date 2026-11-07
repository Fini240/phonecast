import AppKit
import AVFoundation
import QuartzCore

struct NPoint: Codable, Equatable { var x: Double; var y: Double }
struct Bind: Codable { var x: Double; var y: Double; var label: String }

/// Key map: which key/mouse button taps where, plus WASD joystick and mouse-look area.
struct KeyMap: Codable {
    var binds: [String: Bind] = [:]
    var joy: NPoint?
    var joyR: Double = 0.11      // joystick throw, in fractions of the phone's short side
    var look: NPoint?
    var lookR: Double = 0.16     // how far a look drag may go before the finger re-centres
    var sens: Double = 1.0

    static let wasdKeys = ["k13", "k0", "k1", "k2"]

    static func load() -> KeyMap {
        guard let d = UserDefaults.standard.data(forKey: "keymap"), var m = try? JSONDecoder().decode(KeyMap.self, from: d) else { return KeyMap() }
        if m.migrateWasd() { m.save() }
        return m
    }

    /// W/A/S/D placed as separate taps around a joystick can't move a character (the finger never slides).
    /// Turn them into one WASD joystick centred between them.
    mutating func migrateWasd(aspect: Double = 2184.0 / 1968.0) -> Bool {
        let pts = Self.wasdKeys.compactMap { binds[$0] }
        guard pts.count >= 3 else { return false }
        let cx = pts.map(\.x).reduce(0, +) / Double(pts.count)
        let cy = pts.map(\.y).reduce(0, +) / Double(pts.count)
        // distance in "short side" units (x scaled by the screen's aspect)
        let ax = max(aspect, 1), ay = max(1 / aspect, 1)
        let avg = pts.map { hypot(($0.x - cx) * ax, ($0.y - cy) * ay) }.reduce(0, +) / Double(pts.count)
        joy = NPoint(x: cx, y: cy)
        joyR = min(0.2, max(0.07, avg * 1.6))
        for k in Self.wasdKeys { binds[k] = nil }
        return true
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "keymap") }
}

enum Mode { case normal, game, edit }
enum Scale: Int { case fit = 0, fill = 1, stretch = 2 }

final class PhoneView: NSView {
    let video = VideoSink()
    var link: Link?
    var videoSize = CGSize(width: 1080, height: 2340) { didSet { needsLayout = true; overlay.needsDisplay = true } }
    var controlAvailable = false
    var map = KeyMap.load()
    private(set) var mode: Mode = .normal
    var onModeChange: ((Mode) -> Void)?
    var showMarkers = true { didSet { overlay.needsDisplay = true } }
    var scale: Scale = Scale(rawValue: UserDefaults.standard.integer(forKey: "scale")) ?? .fit {
        didSet {
            UserDefaults.standard.set(scale.rawValue, forKey: "scale")
            video.layer.videoGravity = [.resizeAspect, .resizeAspectFill, .resize][scale.rawValue]
            overlay.needsDisplay = true
        }
    }

    private let overlay = Overlay()
    private let message = NSTextField(labelWithString: "")

    // normal-mode scroll finger
    private var scrolling = false
    private var scrollPos = NPoint(x: 0, y: 0)

    // game mode state
    private var held: [String: UInt8] = [:]
    private var freeIds: [UInt8] = [2, 3, 4, 5, 6, 7, 8]
    private var joyKeys = Set<UInt16>()
    private var joyDown = false
    private var lookDown = false
    private var lookPos = NPoint(x: 0, y: 0)
    private var lookIdle: Timer?
    /// Raw, unaccelerated mouse counts for aiming (falls back to NSEvent deltas without it).
    private let rawMouse = RawMouse()
    /// After the look finger goes down, hold movement back until the game has registered the
    /// touch, then send all of it at once, so no movement is lost.
    private var lookHoldUntil: CFAbsoluteTime = 0
    private var lookFlush: Timer?

    // edit mode state
    private(set) var pending: NPoint?

    private let joyId: UInt8 = 1, lookId: UInt8 = 9, mouseId: UInt8 = 0, scrollId: UInt8 = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(video.layer)
        overlay.owner = self
        addSubview(overlay)
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.alignment = .center
        message.maximumNumberOfLines = 0
        addSubview(message)
        video.layer.videoGravity = [.resizeAspect, .resizeAspectFill, .resize][scale.rawValue]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.layer.frame = bounds
        CATransaction.commit()
        overlay.frame = bounds
        message.frame = NSRect(x: 20, y: bounds.midY - 40, width: bounds.width - 40, height: 80)
    }

    func setMessage(_ s: String?) {
        message.stringValue = s ?? ""
        message.isHidden = s == nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: geometry

    /// Where the phone picture actually sits in the view (may extend past the edges in Fill mode).
    var videoRect: CGRect {
        switch scale {
        case .fit: return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        case .stretch: return bounds
        case .fill:
            let k = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let w = videoSize.width * k, h = videoSize.height * k
            return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        }
    }

    func norm(_ e: NSEvent) -> NPoint {
        let p = convert(e.locationInWindow, from: nil)
        let r = videoRect
        return NPoint(x: max(0, min(1, (p.x - r.minX) / r.width)), y: max(0, min(1, 1 - (p.y - r.minY) / r.height)))
    }

    func viewPoint(_ n: NPoint) -> CGPoint {
        let r = videoRect
        return CGPoint(x: r.minX + n.x * r.width, y: r.maxY - n.y * r.height)
    }

    /// Converts a distance in "short side" units into normalized x/y offsets.
    private func offset(_ dx: Double, _ dy: Double) -> (Double, Double) {
        let s = min(videoSize.width, videoSize.height)
        return (dx * s / videoSize.width, dy * s / videoSize.height)
    }

    private func send(_ a: UInt8, _ id: UInt8, _ p: NPoint) { link?.touch(a, id, p.x, p.y) }

    // MARK: modes

    func setMode(_ m: Mode) {
        if mode == m { return }
        if mode == .game { releaseAll() }
        mode = m
        pending = nil
        if m == .game {
            rawMouse.onMove = { [weak self] x, y in
                guard let self, self.mode == .game, self.window?.isKeyWindow == true else { return }
                self.look(Double(x), Double(y))
            }
            rawMouse.start()
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        overlay.needsDisplay = true
        onModeChange?(m)
    }

    func releaseAll() {
        link?.touch(Touch.cancelAll, 0, 0, 0)
        held.removeAll(); freeIds = [2, 3, 4, 5, 6, 7, 8]
        joyKeys.removeAll(); joyDown = false
        lookDown = false; lookIdle?.invalidate(); lookFlush?.invalidate(); lookFlush = nil
        scrolling = false
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        switch mode {
        case .normal: send(Touch.down, mouseId, norm(e))
        case .game: press("m0")
        case .edit: editClick(e, button: 0)
        }
    }
    override func mouseDragged(with e: NSEvent) {
        switch mode {
        case .normal: send(Touch.move, mouseId, norm(e))
        case .game: look(e)
        case .edit: break
        }
    }
    override func mouseUp(with e: NSEvent) {
        switch mode {
        case .normal: send(Touch.up, mouseId, norm(e))
        case .game: release("m0")
        case .edit: break
        }
    }
    override func rightMouseDown(with e: NSEvent) {
        switch mode {
        case .normal: link?.send(CT.global, Data([Global.back]))
        case .game: press("m1")
        case .edit: editClick(e, button: 1)
        }
    }
    override func rightMouseUp(with e: NSEvent) { if mode == .game { release("m1") } }
    override func rightMouseDragged(with e: NSEvent) { if mode == .game { look(e) } }
    override func otherMouseDown(with e: NSEvent) {
        switch mode {
        case .normal: link?.send(CT.global, Data([Global.home]))
        case .game: press("m2")
        case .edit: editClick(e, button: 2)
        }
    }
    override func otherMouseUp(with e: NSEvent) { if mode == .game { release("m2") } }
    override func otherMouseDragged(with e: NSEvent) { if mode == .game { look(e) } }
    override func mouseMoved(with e: NSEvent) {
        if mode == .game { look(e) }
        if mode == .edit { overlay.hover = norm(e); overlay.needsDisplay = true }
    }

    override func scrollWheel(with e: NSEvent) {
        if mode == .edit {
            map.joyR = max(0.04, min(0.3, map.joyR + Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.0008 : 0.01)))
            map.save(); overlay.needsDisplay = true
            return
        }
        guard mode == .normal else { return }
        // Trackpad: a real finger drag that follows the two-finger scroll; the phone does its own fling.
        let r = videoRect
        let k = e.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let dx = Double(e.scrollingDeltaX) * k / r.width, dy = Double(e.scrollingDeltaY) * k / r.height
        if e.momentumPhase != [] { return }
        if !scrolling {
            scrolling = true
            scrollPos = norm(e)
            send(Touch.down, scrollId, scrollPos)
        }
        scrollPos = NPoint(x: max(0, min(1, scrollPos.x + dx)), y: max(0, min(1, scrollPos.y + dy)))
        send(Touch.move, scrollId, scrollPos)
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) || e.phase == [] {
            if e.phase == [] {
                // mouse wheel: one short swipe per notch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, self.scrolling else { return }
                    self.send(Touch.up, self.scrollId, self.scrollPos); self.scrolling = false
                }
            } else {
                send(Touch.up, scrollId, scrollPos); scrolling = false
            }
        }
    }

    // MARK: keyboard

    /// ⌘T: keys type text instead of pressing mapped buttons.
    var typing = false { didSet { if typing { releaseAll() } } }

    private func isMapped(_ code: UInt16) -> Bool {
        map.binds["k\(code)"] != nil || (map.joy != nil && Self.wasd[code] != nil)
    }

    override func keyDown(with e: NSEvent) {
        switch mode {
        case .normal:
            // mapped keys press their buttons in every mode, no game mode needed
            if !typing && isMapped(e.keyCode) {
                if !e.isARepeat { keyPress(e.keyCode) }
                return
            }
            switch e.keyCode {
            case 53: link?.send(CT.global, Data([Global.back]))
            case 51: link?.send(CT.key, Data([1]))
            case 36, 76: link?.send(CT.key, Data([2]))
            default:
                if let s = e.characters, !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) {
                    link?.send(CT.text, Data(s.utf8))
                }
            }
        case .game:
            if e.keyCode == 53 { setMode(.normal); return }
            if e.isARepeat { return }
            keyPress(e.keyCode)
        case .edit:
            editKey(e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if mode == .game || (mode == .normal && !typing) { keyRelease(e.keyCode) }
    }

    private static let modifierFlag: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift, 59: .control, 62: .control, 58: .option, 61: .option, 57: .capsLock,
    ]

    private var lastFlags: NSEvent.ModifierFlags = []
    /// left/right versions of a modifier act as the same key (left one's code)
    private static let modifierCode: [(NSEvent.ModifierFlags, UInt16)] = [(.shift, 56), (.control, 59), (.option, 58), (.capsLock, 57)]
    private static let canonical: [UInt16: UInt16] = [60: 56, 62: 59, 61: 58]

    override func flagsChanged(with e: NSEvent) {
        let now = e.modifierFlags.intersection([.shift, .control, .option, .capsLock])
        defer { lastFlags = now }
        for (flag, code) in Self.modifierCode where now.contains(flag) != lastFlags.contains(flag) {
            let down = now.contains(flag)
            switch mode {
            case .game, .normal:
                if mode == .normal && typing { continue }
                if code == 57 {
                    // Caps Lock reports on/off, not press/release: every change is one tap
                    keyPress(57)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.keyRelease(57) }
                } else {
                    down ? keyPress(code) : keyRelease(code)
                }
            case .edit:
                if down, pending != nil { bind("k\(code)", label: Self.keyName(code, nil)) }
            }
        }
    }

    // MARK: game mode

    private static let wasd: [UInt16: (Double, Double)] = [13: (0, -1), 0: (-1, 0), 1: (0, 1), 2: (1, 0)]

    private func keyPress(_ code: UInt16) {
        let code = Self.canonical[code] ?? code
        let name = "k\(code)"
        if map.joy != nil, Self.wasd[code] != nil { joyKeys.insert(code); updateJoy(); return }
        if map.binds[name] != nil { press(name) }
    }

    private func keyRelease(_ code: UInt16) {
        let code = Self.canonical[code] ?? code
        let name = "k\(code)"
        if joyKeys.remove(code) != nil { updateJoy(); return }
        if held[name] != nil { release(name) }
    }

    private var pressedAt: [String: CFTimeInterval] = [:]
    private static let minPress: CFTimeInterval = 0.06  // games running at 30 fps miss shorter taps

    private func press(_ name: String) {
        guard let b = map.binds[name], held[name] == nil, !freeIds.isEmpty else { return }
        let id = freeIds.removeFirst()
        held[name] = id
        pressedAt[name] = CACurrentMediaTime()
        send(Touch.down, id, NPoint(x: b.x, y: b.y))
    }

    private func release(_ name: String) {
        guard let id = held[name], let b = map.binds[name] else { return }
        let elapsed = CACurrentMediaTime() - (pressedAt[name] ?? 0)
        if elapsed < Self.minPress {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.minPress - elapsed) { [weak self] in self?.release(name) }
            return
        }
        held[name] = nil
        send(Touch.up, id, NPoint(x: b.x, y: b.y))
        freeIds.append(id)
    }

    private func updateJoy() {
        guard let c = map.joy else { return }
        var dx = 0.0, dy = 0.0
        for k in joyKeys { if let v = Self.wasd[k] { dx += v.0; dy += v.1 } }
        let len = (dx * dx + dy * dy).squareRoot()
        if len == 0 {
            if joyDown { send(Touch.up, joyId, c); joyDown = false }
            return
        }
        let (ox, oy) = offset(dx / len * map.joyR, dy / len * map.joyR)
        let target = NPoint(x: c.x + ox, y: c.y + oy)
        if !joyDown {
            // put the thumb down, let the game register it, then slide
            send(Touch.down, joyId, c)
            joyDown = true
            joyTarget = target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.joyDown, let t = self.joyTarget else { return }
                self.send(Touch.move, self.joyId, t)
            }
            return
        }
        joyTarget = target
        send(Touch.move, joyId, target)
    }
    private var joyTarget: NPoint?

    private func look(_ e: NSEvent) {
        if rawMouse.live { return } // raw counts already drive aiming
        look(Double(e.deltaX), Double(e.deltaY))
    }

    private func look(_ dx: Double, _ dy: Double) {
        guard let a = map.look else { return }
        if dx == 0 && dy == 0 { return }
        if !lookDown {
            lookPos = a
            send(Touch.down, lookId, a)
            lookDown = true
            lookHoldUntil = CFAbsoluteTimeGetCurrent() + 0.025
        }
        let (ox, oy) = offset(dx * map.sens * 0.0004, dy * map.sens * 0.0004)
        lookPos.x += ox; lookPos.y += oy
        let s = min(videoSize.width, videoSize.height)
        let dist = hypot((lookPos.x - a.x) * videoSize.width / s, (lookPos.y - a.y) * videoSize.height / s)
        if dist > map.lookR || lookPos.x <= 0.01 || lookPos.x >= 0.99 || lookPos.y <= 0.01 || lookPos.y >= 0.99 {
            // ran out of room: lift the finger (with all movement so far) and put it back at the centre
            lookFlush?.invalidate(); lookFlush = nil
            send(Touch.up, lookId, lookPos)
            lookPos = a
            send(Touch.down, lookId, a)
            lookHoldUntil = CFAbsoluteTimeGetCurrent() + 0.025
            return
        }
        let wait = lookHoldUntil - CFAbsoluteTimeGetCurrent()
        if wait > 0 {
            // the game hasn't registered the new touch yet: send the collected movement afterwards
            if lookFlush == nil {
                lookFlush = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.lookFlush = nil
                    if self.lookDown { self.send(Touch.move, self.lookId, self.lookPos) }
                }
            }
            return
        }
        send(Touch.move, lookId, lookPos)
        // The look finger stays down while aiming: every new touch costs the game a moment to pick
        // up, which ate the start of each movement. It is lifted when leaving mouse aiming.
    }

    // MARK: edit mode

    private func editClick(_ e: NSEvent, button: Int) {
        let p = norm(e)
        if e.modifierFlags.contains(.option) { map.joy = p; map.save(); pending = nil }
        else if e.modifierFlags.contains(.control) { map.look = p; map.save(); pending = nil }
        else if pending != nil { bind("m\(button)", label: ["LMB", "RMB", "MMB"][min(button, 2)]) }
        else if button == 0 { pending = p }
        overlay.needsDisplay = true
    }

    private func editKey(_ e: NSEvent) {
        switch e.keyCode {
        case 53:
            if pending != nil { pending = nil } else { setMode(.normal) }
        case 51, 117:
            deleteNearest(pending ?? overlay.hover)
            pending = nil
        default:
            guard let p = pending, !e.isARepeat else { break }
            if Self.wasd[e.keyCode] != nil {
                // W/A/S/D = the movement joystick: this spot becomes its centre
                map.joy = p
                for k in KeyMap.wasdKeys { map.binds[k] = nil }
                map.save()
                pending = nil
            } else {
                bind("k\(e.keyCode)", label: Self.keyName(e.keyCode, e.charactersIgnoringModifiers))
            }
        }
        overlay.needsDisplay = true
    }

    private func bind(_ name: String, label: String) {
        guard let p = pending else { return }
        map.binds[name] = Bind(x: p.x, y: p.y, label: label)
        map.save()
        pending = nil
        overlay.needsDisplay = true
    }

    private func deleteNearest(_ p: NPoint?) {
        guard let p else { return }
        func d(_ x: Double, _ y: Double) -> Double { hypot(x - p.x, (y - p.y) * videoSize.height / videoSize.width) }
        var best: (String, Double)?
        for (k, b) in map.binds { let dist = d(b.x, b.y); if dist < (best?.1 ?? 0.06) { best = (k, dist) } }
        if let j = map.joy, d(j.x, j.y) < (best?.1 ?? 0.06) { best = ("joy", d(j.x, j.y)) }
        if let l = map.look, d(l.x, l.y) < (best?.1 ?? 0.06) { best = ("look", d(l.x, l.y)) }
        guard let (k, _) = best else { return }
        if k == "joy" { map.joy = nil } else if k == "look" { map.look = nil } else { map.binds[k] = nil }
        map.save()
    }

    static func keyName(_ code: UInt16, _ chars: String?) -> String {
        let named: [UInt16: String] = [
            49: "Space", 48: "Tab", 36: "Ret", 56: "Shift", 60: "Shift", 59: "Ctrl", 62: "Ctrl", 58: "Opt", 61: "Opt",
            57: "Caps", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
        ]
        if let n = named[code] { return n }
        return (chars ?? "?").uppercased()
    }

    // MARK: overlay

    final class Overlay: NSView {
        weak var owner: PhoneView?
        var hover: NPoint?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let o = owner, o.mode != .normal, o.mode == .edit || o.showMarkers else { return }
            let editing = o.mode == .edit
            let alpha: CGFloat = editing ? 0.9 : 0.35
            let r = o.videoRect

            if editing {
                NSColor.black.withAlphaComponent(0.25).setFill()
                r.fill()
            }

            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            func marker(_ n: NPoint, _ label: String, _ color: NSColor, radius: CGFloat = 16) {
                let c = o.viewPoint(n)
                let circle = NSBezierPath(ovalIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                color.withAlphaComponent(alpha * 0.55).setFill(); circle.fill()
                NSColor.white.withAlphaComponent(alpha).setStroke(); circle.lineWidth = 1.5; circle.stroke()
                let s = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
                let sz = s.size()
                s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
            }

            for b in o.map.binds.values { marker(NPoint(x: b.x, y: b.y), b.label, .systemBlue) }
            if let j = o.map.joy {
                let c = o.viewPoint(j)
                let rad = CGFloat(o.map.joyR) * min(r.width, r.height)
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                NSColor.white.withAlphaComponent(alpha * 0.8).setStroke(); ring.lineWidth = 1.5; ring.stroke()
                marker(j, "WASD", .systemGreen, radius: 22)
            }
            if let l = o.map.look {
                let c = o.viewPoint(l)
                let rad = CGFloat(o.map.lookR) * min(r.width, r.height)
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                ring.setLineDash([5, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(alpha * 0.8).setStroke(); ring.lineWidth = 1.5; ring.stroke()
                marker(l, "LOOK", .systemOrange, radius: 22)
            }
            if let p = o.pending {
                let c = o.viewPoint(p)
                NSColor.systemYellow.setStroke()
                let cross = NSBezierPath()
                cross.move(to: CGPoint(x: c.x - 14, y: c.y)); cross.line(to: CGPoint(x: c.x + 14, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 14)); cross.line(to: CGPoint(x: c.x, y: c.y + 14))
                cross.lineWidth = 2; cross.stroke()
            }

            if editing {
                let help = o.pending == nil
                    ? "KEY MAP — click a button on the phone screen, then press the key or mouse button for it.\nMovement: click the middle of the joystick, then press W (scroll to resize)  ·  ⌃-click: mouse-look area  ·  ⌫ over a marker: delete  ·  Esc: done"
                    : "Now press a key, or click left/right mouse button, to bind this spot.  Esc: cancel"
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let s = NSAttributedString(string: help, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: para,
                ])
                let box = CGRect(x: bounds.minX + 12, y: bounds.maxY - 58, width: bounds.width - 24, height: 46)
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                s.draw(in: box.insetBy(dx: 8, dy: 6))
            }
        }
    }
}
