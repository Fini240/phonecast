import AppKit

/// The mirror window's content: the phone picture with a bar of phone controls underneath.
final class MirrorContainer: NSView {
    let phone: NSView
    let bar = MirrorBar()
    static let barHeight: CGFloat = 40
    var barHidden = false { didSet { bar.isHidden = barHidden; needsLayout = true } }
    var barSpace: CGFloat { barHidden ? 0 : Self.barHeight }

    init(phone: NSView) {
        self.phone = phone
        super.init(frame: .zero)
        addSubview(phone)
        addSubview(bar)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = barSpace
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: b)
        phone.frame = NSRect(x: 0, y: b, width: bounds.width, height: bounds.height - b)
    }
}

/// Phone buttons: navigation, volume, lock, flashlight, apps, files, clipboard, typing, game mode…
/// When the window is too narrow, less important buttons drop out; "⋯" always has everything.
final class MirrorBar: NSVisualEffectView {
    struct Item { let id: String; let symbol: String; let tip: String; let priority: Float }
    var onAction: ((String, NSView) -> Void)?
    private var buttons: [String: NSButton] = [:]

    static let items: [Item] = [
        Item(id: "back", symbol: "chevron.backward", tip: "Back (Esc / right-click)", priority: 1000),
        Item(id: "home", symbol: "circle", tip: "Home (middle-click)", priority: 1000),
        Item(id: "recents", symbol: "square.on.square", tip: "Recent apps", priority: 1000),
        Item(id: "|", symbol: "", tip: "", priority: 600),
        Item(id: "notifications", symbol: "bell", tip: "Pull down notifications", priority: 700),
        Item(id: "quick", symbol: "switch.2", tip: "Quick settings", priority: 650),
        Item(id: "|", symbol: "", tip: "", priority: 600),
        Item(id: "voldown", symbol: "speaker.wave.1", tip: "Volume down", priority: 900),
        Item(id: "volup", symbol: "speaker.wave.3", tip: "Volume up", priority: 900),
        Item(id: "mute", symbol: "speaker.slash", tip: "Mute / unmute", priority: 500),
        Item(id: "|", symbol: "", tip: "", priority: 600),
        Item(id: "lock", symbol: "lock", tip: "Lock the phone (ends sharing)", priority: 450),
        Item(id: "torch", symbol: "flashlight.off.fill", tip: "Flashlight", priority: 300),
        Item(id: "apps", symbol: "square.grid.2x2", tip: "Open an app on the phone", priority: 800),
        Item(id: "files", symbol: "square.and.arrow.up", tip: "Send files to the phone (or drop them on it)", priority: 550),
        Item(id: "clip", symbol: "doc.on.clipboard", tip: "Send the Mac's clipboard to the phone", priority: 400),
        Item(id: "|", symbol: "", tip: "", priority: 600),
        Item(id: "typing", symbol: "keyboard", tip: "Typing mode: keys type text instead of game keys (⌘T)", priority: 750),
        Item(id: "game", symbol: "gamecontroller", tip: "Mouse aiming (⌘G)", priority: 850),
        Item(id: "keymap", symbol: "keyboard.badge.ellipsis", tip: "Edit key map (⌘E)", priority: 500),
        Item(id: "stats", symbol: "speedometer", tip: "Stats: FPS, delay, heat (⌘O)", priority: 350),
        Item(id: "shot", symbol: "camera", tip: "Screenshot to the Desktop", priority: 420),
        Item(id: "record", symbol: "record.circle", tip: "Record the mirror to a video (⇧⌘R)", priority: 430),
        Item(id: "full", symbol: "arrow.up.left.and.arrow.down.right", tip: "Full screen (⌘F)", priority: 950),
    ]

    private var views: [(Item, NSView)] = []
    private var more: NSButton!

    init() {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        for it in Self.items {
            let v: NSView
            if it.id == "|" {
                let sep = NSBox(); sep.boxType = .separator
                v = sep
            } else {
                let b = NSButton(image: NSImage(systemSymbolName: it.symbol, accessibilityDescription: it.tip) ?? NSImage(), target: self, action: #selector(tap(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(it.id)
                b.isBordered = false
                b.imageScaling = .scaleProportionallyDown
                b.toolTip = it.tip
                b.refusesFirstResponder = true   // keys keep going to the phone
                buttons[it.id] = b
                v = b
            }
            addSubview(v)
            views.append((it, v))
        }
        more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More") ?? NSImage(), target: self, action: #selector(showMore(_:)))
        more.isBordered = false
        more.toolTip = "All phone controls"
        more.refusesFirstResponder = true
        addSubview(more)
    }

    /// Show as many buttons as fit, most important first, in their usual order; the rest are in "⋯".
    override func layout() {
        super.layout()
        let slot: CGFloat = 32, sepW: CGFloat = 9, h = bounds.height
        let avail = bounds.width - 16 - slot     // margins + "⋯"
        let ranked = views.filter { $0.0.id != "|" }.sorted { $0.0.priority > $1.0.priority }
        var shown = Set<String>()
        var used: CGFloat = 0
        for (it, _) in ranked where used + slot <= avail * 0.86 { shown.insert(it.id); used += slot }
        var x: CGFloat = 8
        var lastWasSep = true
        for (i, (it, v)) in views.enumerated() {
            if it.id == "|" {
                // a divider only between two visible groups
                let nextVisible = views[(i + 1)...].first { $0.0.id != "|" && shown.contains($0.0.id) } != nil
                let show = !lastWasSep && nextVisible
                v.isHidden = !show
                if show { v.frame = NSRect(x: x + 4, y: (h - 18) / 2, width: 1, height: 18); x += sepW; lastWasSep = true }
                continue
            }
            v.isHidden = !shown.contains(it.id)
            if !v.isHidden { v.frame = NSRect(x: x, y: (h - 28) / 2, width: slot - 2, height: 28); x += slot; lastWasSep = false }
        }
        more.frame = NSRect(x: bounds.width - 8 - slot, y: (h - 28) / 2, width: slot - 2, height: 28)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ b: NSButton) { onAction?(b.identifier?.rawValue ?? "", b) }

    /// Highlight toggles (game mode, typing, stats, flashlight).
    func setOn(_ id: String, _ on: Bool) {
        guard let b = buttons[id] else { return }
        b.contentTintColor = on ? (id == "record" ? .systemRed : .controlAccentColor) : nil
        if id == "record" { b.image = NSImage(systemSymbolName: on ? "stop.circle.fill" : "record.circle", accessibilityDescription: on ? "Stop recording" : "Record") }
        if id == "torch" { b.image = NSImage(systemSymbolName: on ? "flashlight.on.fill" : "flashlight.off.fill", accessibilityDescription: "Flashlight") }
    }

    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        func add(_ title: String, _ id: String, _ symbol: String? = nil) {
            let i = NSMenuItem(title: title, action: #selector(menuPick(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = id
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(i)
        }
        for it in Self.items {
            if it.id == "|" { m.addItem(.separator()) } else { add(it.tip, it.id, it.symbol) }
        }
        m.addItem(.separator())
        add("Power menu", "power", "power")
        add("Split screen", "split", "rectangle.split.2x1")
        add("Screenshot on the phone", "phoneshot", "camera.viewfinder")
        add("Phone screen shape…", "shape", "aspectratio")
        add("Quality…", "quality", "dial.medium")
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuPick(_ i: NSMenuItem) { onAction?(i.representedObject as? String ?? "", self) }
}
