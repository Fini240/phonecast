import AppKit
import Network
import QuartzCore

/// A window that may go borderless and cover the whole display, including the row beside the notch.
final class PhoneWindow: NSWindow {
    var covering = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect {
        covering ? r : super.constrainFrameRect(r, to: s)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate, NSMenuItemValidation {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Phone screen shape" {
            menu.removeAllItems()
            for i in shapeMenu().items { i.menu?.removeItem(i); menu.addItem(i) }
        }
    }

    private var window: PhoneWindow!
    private let view = PhoneView(frame: NSRect(x: 0, y: 0, width: 420, height: 860))
    private let audio = AudioSink()
    private var link: Link?
    private var browser: NWBrowser?
    private var found: [String: NWEndpoint] = [:]
    /// Which Wi-Fi address (see wifiCandidates) the next attempt uses; reset after a connection works.
    private var wifiIndex = 0
    private var linkWasReady = false
    private var wantConnected = false
    private var deviceLabel = ""
    private var stateText = "Not connected"
    private var lastFrames = 0
    private var fps = 0
    private var sizedOnce = false
    private var gameItem: NSMenuItem!
    private var editItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var statsItem: NSMenuItem!
    private var showStats = UserDefaults.standard.bool(forKey: "statsOverlay")
    /// Phone health from STATS (PhoneStats.kt); nil until a phone that sends it is connected.
    private struct Health { var tempC: Double; var battery: Int; var plugged: Bool; var watts: Double; var thermal: Int; var headroom: Int; var cpuC: Double?; var gpuC: Double? }
    private var health: Health?
    private var markersItem: NSMenuItem!
    private var typingItem: NSMenuItem!
    private var scaleItems: [NSMenuItem] = []
    private var resItems: [NSMenuItem] = []
    private var rateItems: [NSMenuItem] = []
    private var rttMs = 0.0
    private var resyncs = 0
    private var lastFrameAt = 0.0
    private var stutters: [CFTimeInterval] = []
    private let stutterLock = NSLock()
    private func stuttersLast10s() -> Int {
        stutterLock.lock(); defer { stutterLock.unlock() }
        let now = CACurrentMediaTime()
        stutters.removeAll { now - $0 > 10 }
        return stutters.count
    }
    /// Wi-Fi video over UDP (nil on the cable, or until the phone offers it).
    private var udp: UdpVideoIn?
    private var udpActive = false
    private var udpOnAt: CFTimeInterval = 0
    private let lagLog = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/PhoneCast-lag.log")
    // 0 = match this Mac's screen (full phone resolution on any Retina Mac)
    private let resolutions: [(String, Int)] = [("Match this Mac (sharpest)", 0), ("1440p", 1440), ("1080p", 1080), ("720p (fastest)", 720)]
    private let bitrates = [8, 16, 24, 40]

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        window = PhoneWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false   // closing hides the mirror; the hub keeps running
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .black
        let tb = NSToolbar(identifier: "main")
        tb.delegate = self
        tb.displayMode = .iconOnly
        window.toolbar = tb
        window.toolbarStyle = .unifiedCompact
        // macOS full screen stops below the notch, so the green button and ⌘F use our own mode instead
        window.collectionBehavior = [.fullScreenNone]
        window.setFrameAutosaveName("PhoneCastWindow")
        if !window.setFrameUsingName("PhoneCastWindow") { window.center() }
        window.title = "Phone"
        window.makeFirstResponder(view)   // shown when mirroring starts

        view.video.onNeedKeyframe = { [weak self] in self?.link?.send(CT.keyframe) }
        view.onModeChange = { [weak self] _ in self?.refreshMenu(); self?.updateTitle() }
        view.setMessage("Not connected\n⌘K to connect")

        startBrowsing()
        Hub.shared.onCastReady = { [weak self] in self?.castReady() }
        Hub.shared.onOpenWindow = { [weak self] in self?.showWindow() }
        Hub.shared.onOpenMain = { MainWindowController.shared.show() }
        Hub.shared.start()
        view.onDropFiles = { urls in Hub.shared.sendFiles(urls) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickFps() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.ping() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.watchCable() }

        // The main window (notifications, messages, files…) opens first; the mirror window opens when the
        // phone starts sharing (hub CAST_READY) or from "Mirror phone".
        MainWindowController.shared.show(UserDefaults.standard.string(forKey: "pin") == nil ? .settings : nil)
        if Self.noUSB == false, UsbBridge.shared.phonePresent(), UserDefaults.standard.string(forKey: "pin") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.connectSaved() }  // cable: mirror right away
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // The menu-bar link (notifications, files, monitor) keeps running without the mirror window.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindowController.shared.show() }
        return true
    }
    func windowWillClose(_ n: Notification) {
        // stop the phone's video while nobody watches (saves its battery); the hub stays connected
        if (n.object as? NSWindow) === window { disconnect(nil) }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The phone started sharing (tapped Cast / the tile): connect the mirror right away.
    private func castReady() {
        showWindow()
        if stateText == "Connected" || stateText == "Connecting…" { return }
        wantConnected = true
        retryDelay = 2
        wifiIndex = 0
        connectSaved()
    }
    func windowDidResignKey(_ n: Notification) {
        if view.mode == .game { view.setMode(.normal) } else { view.releaseAll() }
    }

    // Full screen: cover the whole display, past the notch. That area is 16:10-ish like the phone
    // picture, so Fill only trims a fraction of a percent. Menu bar and Dock slide in at the screen edges.
    private var scaleBeforeCover: Scale?
    private var frameBeforeCover = NSRect.zero
    private var styleBeforeCover: NSWindow.StyleMask = []
    private var toolbarBeforeCover: NSToolbar?

    func windowShouldZoom(_ w: NSWindow, toFrame f: NSRect) -> Bool {
        fullScreen(nil)
        return false
    }

    private func enterCover() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        scaleBeforeCover = view.scale
        frameBeforeCover = window.frame
        styleBeforeCover = window.styleMask
        toolbarBeforeCover = window.toolbar
        window.setFrameAutosaveName("") // don't remember the cover frame as the normal window size
        window.covering = true
        window.toolbar = nil
        window.styleMask = [.borderless]
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.setFrame(screen.frame, display: true)
        view.scale = .fill
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        refreshMenu()
    }

    private func exitCover() {
        window.covering = false
        NSApp.presentationOptions = []
        window.styleMask = styleBeforeCover
        window.toolbar = toolbarBeforeCover
        toolbarBeforeCover = nil
        view.scale = scaleBeforeCover ?? .fit
        scaleBeforeCover = nil
        window.contentAspectRatio = view.videoSize
        window.setFrame(frameBeforeCover, display: true)
        window.setFrameAutosaveName("PhoneCastWindow")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        refreshMenu()
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let i = NSMenuItem(); i.submenu = m; main.addItem(i)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = self; return i
        }
        let quit = NSMenuItem(title: "Quit PhoneCast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        sub("PhoneCast", [quit])
        sub("Device", [
            item("Connect…", #selector(showConnect(_:)), "k"),
            // ⇧⌘D, not ⌘D: D is "strafe right" in games, and ⌘ still held after ⌘G disconnected mid-match
            item("Disconnect", #selector(disconnect(_:)), "d", [.command, .shift]),
            .separator(),
            item("Back", #selector(back(_:)), "b"),
            item("Home", #selector(home(_:)), "h"),
            item("Recent apps", #selector(recents(_:)), "r"),
            item("Notifications", #selector(notifications(_:)), "n"),
        ])
        gameItem = item("Mouse aiming (game mode)", #selector(toggleGame(_:)), "g")
        typingItem = item("Keys type text (instead of buttons)", #selector(toggleTyping(_:)), "t")
        editItem = item("Edit key map", #selector(toggleEdit(_:)), "e")
        markersItem = item("Show key markers in game mode", #selector(toggleMarkers(_:)), "j")
        sub("Game", [
            editItem, gameItem, typingItem, markersItem,
            .separator(),
            item("Mouse-look faster", #selector(sensUp(_:)), "+"),
            item("Mouse-look slower", #selector(sensDown(_:)), "-"),
            .separator(),
            item("Clear key map", #selector(clearMap(_:)), ""),
        ])
        muteItem = item("Mute phone audio", #selector(toggleMute(_:)), "m")
        statsItem = item("Show stats overlay (FPS, delay, phone heat)", #selector(toggleStats(_:)), "o")
        scaleItems = [
            item("Fit — whole picture, black bars", #selector(setScale(_:)), "1"),
            item("Fill — no bars, crops the edges", #selector(setScale(_:)), "2"),
            item("Stretch — no bars, distorts", #selector(setScale(_:)), "3"),
        ]
        for (i, it) in scaleItems.enumerated() { it.tag = i }
        sub("View", [
            item("Full screen", #selector(fullScreen(_:)), "f"),
            item("Fit window to phone", #selector(fitWindow(_:)), "0"),
            .separator(),
        ] + scaleItems + [.separator(), muteItem, statsItem])
        resItems = resolutions.enumerated().map { i, r in let it = item(r.0, #selector(setResolution(_:)), ""); it.tag = i; return it }
        rateItems = bitrates.enumerated().map { i, b in let it = item("\(b) Mbit/s" + (b == 24 ? " (default)" : ""), #selector(setBitrate(_:)), ""); it.tag = i; return it }
        sub("Quality", [NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")] + resItems
            + [.separator(), NSMenuItem(title: "Bitrate", action: nil, keyEquivalent: "")] + rateItems)
        let shape = NSMenuItem(title: "Phone screen shape", action: nil, keyEquivalent: "")
        shape.submenu = NSMenu(title: "Phone screen shape")
        shape.submenu?.delegate = self
        main.items.last?.submenu?.addItem(.separator())
        main.items.last?.submenu?.addItem(shape)
        sub("PC", pcMenuItems())
        sub("Help", [item("Keyboard shortcuts", #selector(showShortcuts(_:)), "i")])
        NSApp.mainMenu = main
        refreshMenu()
    }

    private func refreshMenu() {
        gameItem?.state = view.mode == .game ? .on : .off
        editItem?.state = view.mode == .edit ? .on : .off
        markersItem?.state = view.showMarkers ? .on : .off
        typingItem?.state = view.typing ? .on : .off
        muteItem?.state = audio.muted ? .on : .off
        statsItem?.state = showStats ? .on : .off
        for it in scaleItems { it.state = it.tag == view.scale.rawValue ? .on : .off }
        let res = UserDefaults.standard.integer(forKey: "resolution")
        for it in resItems { it.state = resolutions[it.tag].1 == res ? .on : .off }
        for it in rateItems { it.state = bitrates[it.tag] == bitrate ? .on : .off }
    }

    private var bitrate: Int { let b = UserDefaults.standard.integer(forKey: "bitrate"); return b == 0 ? 24 : b }

    @objc func setScale(_ s: NSMenuItem) { view.scale = Scale(rawValue: s.tag) ?? .fit; refreshMenu() }
    @objc func setResolution(_ s: NSMenuItem) { UserDefaults.standard.set(resolutions[s.tag].1, forKey: "resolution"); refreshMenu(); sendSettings() }
    @objc func setBitrate(_ s: NSMenuItem) { UserDefaults.standard.set(bitrates[s.tag], forKey: "bitrate"); refreshMenu(); sendSettings() }

    /// Tells the phone how big to encode. "Match this Mac" = the long side of this screen in real pixels,
    /// which on a Retina Mac is more than the phone has, so the phone sends its full native resolution.
    private func sendSettings() {
        var maxSize = UserDefaults.standard.integer(forKey: "resolution")
        if maxSize == 0, let sc = window?.screen ?? NSScreen.main {
            maxSize = Int(max(sc.frame.width, sc.frame.height) * sc.backingScaleFactor)
        }
        maxSize = min(maxSize, 65535)
        link?.send(CT.settings, Data([UInt8(maxSize >> 8), UInt8(maxSize & 0xff), UInt8(bitrate)]))
    }

    private var lastPong: CFTimeInterval = 0

    private func ping() {
        guard stateText == "Connected" else { return }
        // A phone that stopped answering (e.g. sharing ended while the cable stays plugged in, so
        // the connection never closes) would otherwise leave a black window forever.
        let now = CACurrentMediaTime()
        if lastPong == 0 { lastPong = now }
        if now - lastPong > 6 { lastPong = 0; link?.close("the phone stopped answering"); return }
        // UDP video on, but nothing arrives (firewall?): stop the hellos, the phone goes back to TCP
        if udpActive, let u = udp, now - max(udpOnAt, u.lastPacketAt) > 2 {
            NSLog("udp: no video datagrams for 2 s, back to TCP")
            u.stop(); udp = nil
        }
        // too lossy for the repair (frames keep failing): TCP's resends work better there
        if udpActive, let u = udp, u.recentLossCount() >= 8 {
            NSLog("udp: 8+ frames lost in 5 s, back to TCP")
            u.stop(); udp = nil
        }
        var t = CACurrentMediaTime().bitPattern.bigEndian
        link?.send(CT.ping, Data(bytes: &t, count: 8))
    }

    @objc func back(_ s: Any?) { link?.send(CT.global, Data([Global.back])) }
    @objc func home(_ s: Any?) { link?.send(CT.global, Data([Global.home])) }
    @objc func recents(_ s: Any?) { link?.send(CT.global, Data([Global.recents])) }
    @objc func notifications(_ s: Any?) { link?.send(CT.global, Data([Global.notifications])) }
    @objc func toggleGame(_ s: Any?) {
        if view.mode != .game && view.map.look == nil {
            // No aiming area yet: use an empty spot in the upper right, where dragging turns the camera
            view.map.look = NPoint(x: 0.62, y: 0.28)
            view.map.save()
            view.setMessage("Mouse aiming on — the mouse now turns the camera.\nEsc to stop. To move the aiming area: ⌘E, then ⌃-click.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.view.setMessage(nil) }
        }
        view.setMode(view.mode == .game ? .normal : .game)
    }
    @objc func toggleTyping(_ s: Any?) { view.typing.toggle(); refreshMenu(); updateTitle() }
    @objc func toggleEdit(_ s: Any?) { view.setMode(view.mode == .edit ? .normal : .edit) }
    @objc func toggleMarkers(_ s: Any?) { view.showMarkers.toggle(); refreshMenu() }
    @objc func toggleMute(_ s: Any?) { audio.muted.toggle(); refreshMenu() }
    @objc func toggleStats(_ s: Any?) {
        showStats.toggle()
        UserDefaults.standard.set(showStats, forKey: "statsOverlay")
        refreshMenu(); updateStats()
    }

    private static let thermalNames = ["cool", "light", "moderate", "hot — slowing down", "very hot — slowing down", "emergency", "shutting down"]

    private func updateStats() {
        guard showStats, stateText == "Connected" else { view.setStats(nil); return }
        let white = NSColor.white, warn = NSColor.systemOrange, bad = NSColor.systemRed
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor = white) { out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])) }
        add("\(fps) fps", fps < 20 ? warn : white)
        add(" · \(transport) \(Int(rttMs)) ms", rttMs > 40 ? warn : white)
        add(" · decode \(String(format: "%.1f", view.video.decodeMs)) ms · skipped \(resyncs)")
        if !audio.muted { add(" · audio \(audio.bufferedMs) ms", audio.bufferedMs > 70 ? warn : white) }
        let st = stuttersLast10s()
        add(" · stutters \(st)/10 s", st > 2 ? warn : white)
        if udpActive, let u = udp { add(" · repaired \(u.repaired) · resent \(u.resentFrames) · lost \(u.lost)", u.lost > 0 ? warn : white) }
        if let h = health {
            add("\nBattery ")
            add(String(format: "%.1f °C", h.tempC), h.tempC >= 45 ? bad : h.tempC >= 40 ? warn : white)
            add(" · \(h.battery)%")
            if abs(h.watts) >= 0.1 { add(String(format: h.watts > 0 ? " · charging %.1f W" : " · using %.1f W", abs(h.watts))) }
            else if h.plugged { add(" · plugged in") }
            if h.cpuC != nil || h.gpuC != nil {
                add("\n")
                func chip(_ name: String, _ v: Double) { add(String(format: "%@ %.0f °C", name, v), v >= 85 ? bad : v >= 70 ? warn : white) }
                if let c = h.cpuC { chip("CPU", c) }
                if let g = h.gpuC { if h.cpuC != nil { add(" · ") }; chip("GPU", g) }
            }
            add("\nHeat ")
            add(Self.thermalNames[min(max(h.thermal, 0), 6)], h.thermal >= 3 ? bad : h.thermal >= 2 ? warn : white)
            if h.headroom != 255 {
                add(" · \(h.headroom)% to throttling", h.headroom >= 100 ? bad : h.headroom >= 85 ? warn : white)
            }
        }
        view.setStats(out)
    }
    /// Each phone screen layout (size) has its own key map, because the game's buttons move with it.
    private func switchKeyLayout(_ w: Int, _ h: Int) {
        let layout = "\(w)x\(h)"
        if layout == KeyMap.layout { return }
        let first = KeyMap.layout.isEmpty
        if view.mode == .game { view.setMode(.normal) } // fingers held for the old layout would land wrong
        KeyMap.layout = layout
        let (m, copied) = KeyMap.load(layout: layout)
        view.map = m
        view.needsDisplay = true
        guard w > h, copied || !first, !(m.binds.isEmpty && m.joy == nil && m.look == nil) else { return }
        view.setMessage(copied
            ? "New screen layout (\(w)×\(h)): the game's buttons moved.\nYour last key map was copied — check it with ⌘E and drag the markers into place."
            : "Key map for \(w)×\(h) loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + (copied ? 6 : 2.5)) { [weak self] in
            guard let self, self.stateText == "Connected" else { return }
            self.view.setMessage(nil)
        }
    }

    @objc func sensUp(_ s: Any?) { view.map.sens = min(5, view.map.sens * 1.12); view.map.save(); updateTitle() }
    @objc func sensDown(_ s: Any?) { view.map.sens = max(0.1, view.map.sens / 1.12); view.map.save(); updateTitle() }
    @objc func clearMap(_ s: Any?) { view.map = KeyMap(); view.map.save(); view.needsDisplay = true; view.setMode(.normal) }
    @objc func fullScreen(_ s: Any?) { window.covering ? exitCover() : enterCover() }

    @objc func showShortcuts(_ s: Any?) {
        if view.mode == .game { view.setMode(.normal) }
        let a = NSAlert()
        a.messageText = "PhoneCast shortcuts"
        a.informativeText = """
        ⌘F   Full screen on / off
        ⌘1   Fit (whole picture)      ⌘2   Fill (no bars)      ⌘3   Stretch
        ⌘0   Window size = phone

        ⌘B   Back          ⌘H   Home          ⌘R   Recent apps
        ⌘N   Notifications ⌘M   Mute sound    ⌘O   Stats overlay

        ⌘E   Edit key map  (Esc when done; drag markers to move them)
        ⌘G   Mouse aiming  (Esc to leave; needs a LOOK area)
        ⌘T   Keys type text instead of pressing buttons
        ⌘+ / ⌘-   Mouse aiming faster / slower
        ⌘J   Show/hide key markers

        ⌘K   Connect       ⇧⌘D  Disconnect     ⌘I   This list

        Mouse: click = tap · drag = swipe · two-finger scroll = scroll
        Right-click or Esc = Back · middle-click = Home
        """
        a.runModal()
    }

    @objc func fitWindow(_ s: Any?) {
        if window.covering { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let vs = view.videoSize
        let maxH = screen.visibleFrame.height * 0.9, maxW = screen.visibleFrame.width * 0.9
        let scale = min(maxH / vs.height, maxW / vs.width)
        let size = NSSize(width: (vs.width * scale).rounded(), height: (vs.height * scale).rounded())
        var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        f.origin = CGPoint(x: window.frame.midX - f.width / 2, y: window.frame.maxY - f.height)
        f.origin.y = max(screen.visibleFrame.minY, f.origin.y)
        f.origin.x = max(screen.visibleFrame.minX, min(f.origin.x, screen.visibleFrame.maxX - f.width))
        window.setFrame(f, display: true, animate: true)
    }

    // MARK: toolbar

    private let tbItems: [(String, String, String, Selector)] = [
        ("back", "chevron.backward", "Back (⌘B)", #selector(back(_:))),
        ("home", "circle", "Home (⌘H)", #selector(home(_:))),
        ("recents", "square.on.square", "Recent apps (⌘R)", #selector(recents(_:))),
        ("full", "arrow.up.left.and.arrow.down.right", "Full screen (⌘F)", #selector(fullScreen(_:))),
        ("scale", "rectangle.expand.vertical", "Whole picture / crop to fill (⌘1 ⌘2)", #selector(cycleScale(_:))),
        ("shape", "aspectratio", "Phone screen shape", #selector(showShapeMenu(_:))),
        ("keys", "keyboard", "Edit key map (⌘E)", #selector(toggleEdit(_:))),
        ("game", "gamecontroller", "Mouse aiming (⌘G)", #selector(toggleGame(_:))),
        ("help", "questionmark.circle", "Shortcuts (⌘I)", #selector(showShortcuts(_:))),
    ]

    // MARK: phone screen shape

    private func shapeMenu() -> NSMenu {
        let m = NSMenu(title: "Phone screen shape")
        func add(_ title: String, _ w: Int, _ h: Int) {
            let i = NSMenuItem(title: title, action: #selector(setShape(_:)), keyEquivalent: "")
            i.target = self; i.tag = w << 16 | h
            m.addItem(i)
        }
        if let sc = window.screen ?? NSScreen.main {
            let w = Int(sc.frame.width), h = Int(sc.frame.height), top = Int(sc.safeAreaInsets.top)
            add("Fit this Mac — whole display", w, h)
            if top > 0 { add("Fit this Mac — below the notch", w, h - top) }
        }
        add("16:9", 16, 9)
        m.addItem(.separator())
        add("Phone's normal shape", 0, 0)
        m.addItem(.separator())
        let head = NSMenuItem(title: "Sharpness (for the shapes above)", action: nil, keyEquivalent: "")
        m.addItem(head)
        for (title, long) in [("Phone's own pixels (coolest)", 0), ("Sharp — 2560 px wide", 2560), ("Sharpest — 3200 px wide (hotter)", 3200)] {
            let i = NSMenuItem(title: title, action: #selector(setSharpness(_:)), keyEquivalent: "")
            i.target = self; i.tag = long
            i.state = UserDefaults.standard.integer(forKey: "shapeLong") == long ? .on : .off
            i.indentationLevel = 1
            m.addItem(i)
        }
        return m
    }

    /** Render the phone at more pixels than its panel has, so the Mac's Retina screen looks sharp. */
    @objc func setSharpness(_ s: NSMenuItem) {
        UserDefaults.standard.set(s.tag, forKey: "shapeLong")
        // re-send the last shape with the new sharpness
        let last = UserDefaults.standard.integer(forKey: "lastShapeTag")
        if last != 0 { sendShape(last >> 16, last & 0xffff) }
    }

    @objc func showShapeMenu(_ s: Any?) {
        shapeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func setShape(_ s: NSMenuItem) {
        UserDefaults.standard.set(s.tag, forKey: "lastShapeTag")
        sendShape(s.tag >> 16, s.tag & 0xffff)
    }

    private func sendShape(_ w: Int, _ h: Int) {
        let l = w == 0 ? 0 : UserDefaults.standard.integer(forKey: "shapeLong")
        link?.send(CT.resolution, Data([UInt8(w >> 8), UInt8(w & 0xff), UInt8(h >> 8), UInt8(h & 0xff), UInt8(l >> 8), UInt8(l & 0xff)]))
    }

    private func resolutionResult(_ r: UInt8) {
        if r == 0 { return }
        let a = NSAlert()
        if r == 1 {
            a.messageText = "The phone needs one permission first"
            a.informativeText = "Turn on USB debugging once and run:\n\nadb shell pm grant de.finn.phonecast android.permission.WRITE_SECURE_SETTINGS\n\nIt stays granted after you turn USB debugging off again."
        } else {
            a.messageText = "The phone couldn't change its screen shape"
            a.informativeText = "Android refused the change. You can still set it with adb: adb shell wm size"
        }
        a.runModal()
    }

    @objc func cycleScale(_ s: Any?) { view.scale = view.scale == .fit ? .fill : .fit; refreshMenu() }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        let ids = tbItems.map { NSToolbarItem.Identifier($0.0) }
        return Array(ids[0..<3]) + [.flexibleSpace] + Array(ids[3...])
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        guard let d = tbItems.first(where: { $0.0 == id.rawValue }) else { return nil }
        let it = NSToolbarItem(itemIdentifier: id)
        it.image = NSImage(systemSymbolName: d.1, accessibilityDescription: d.2)
        it.label = d.2; it.toolTip = d.2
        it.target = self; it.action = d.3
        it.isBordered = true
        return it
    }

    // MARK: discovery

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: "_phonecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                var f: [String: NWEndpoint] = [:]
                for r in results { if case let .service(name, _, _, _) = r.endpoint { f[name] = r.endpoint } }
                self?.found = f
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Wi-Fi addresses to try, best first. The phone's IP changes with every network (home, school…),
    /// so one saved IP stops working elsewhere: first the phone Bonjour finds on this network, then the
    /// saved name/IP, then the phone's Tailscale address (works where the Wi-Fi keeps devices apart, or
    /// when the phone is on mobile data). Each failed attempt moves on to the next one.
    private func wifiCandidates() -> [(NWEndpoint, String)] {
        if let h = ProcessInfo.processInfo.environment["PHONECAST_TEST_HOST"] {
            return [(.hostPort(host: NWEndpoint.Host(h), port: 27183), "test phone")]
        }
        let d = UserDefaults.standard
        var out: [(NWEndpoint, String)] = []
        var seen = Set<String>()
        func add(_ ep: NWEndpoint, _ label: String) { if seen.insert("\(ep)").inserted { out.append((ep, label)) } }
        let saved = d.string(forKey: "service")
        if let saved, let ep = found[saved] { add(ep, saved) }
        for name in found.keys.sorted() { add(found[name]!, name) }
        if let saved { add(.service(name: saved, type: "_phonecast._tcp", domain: "local.", interface: nil), saved) }
        if let host = d.string(forKey: "host"), !host.isEmpty { add(.hostPort(host: NWEndpoint.Host(host), port: 27183), host) }
        if let ts = d.string(forKey: "tailnetHost"), !ts.isEmpty {
            add(.hostPort(host: NWEndpoint.Host(ts), port: 27183), "\(ts) (Tailscale)")
        }
        return out
    }

    @objc func showConnect(_ s: Any?) {
        if view.mode == .game { view.setMode(.normal) }
        let d = UserDefaults.standard
        let a = NSAlert()
        a.messageText = "Connect to your phone"
        a.informativeText = "Open PhoneCast on the phone and tap Start sharing. Phones on this Wi-Fi show up automatically."
        a.addButton(withTitle: "Connect"); a.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let names = found.keys.sorted()
        names.forEach { popup.addItem(withTitle: $0) }
        popup.addItem(withTitle: "IP address below")
        if let saved = d.string(forKey: "service"), names.contains(saved) { popup.selectItem(withTitle: saved) }
        else if names.isEmpty || d.string(forKey: "host") != nil { popup.selectItem(withTitle: "IP address below") }

        let host = NSTextField(string: d.string(forKey: "host") ?? "")
        host.placeholderString = "e.g. 192.168.1.57 (shown in the phone app)"
        let pin = NSTextField(string: d.string(forKey: "pin") ?? "")
        pin.placeholderString = "6-digit PIN from the phone app"
        let ts = NSTextField(string: d.string(forKey: "tailnetHost") ?? "")
        ts.placeholderString = "optional, e.g. 100.64.0.10 — used when Wi-Fi can't reach it"
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Phone:"), popup,
            NSTextField(labelWithString: "IP address:"), host,
            NSTextField(labelWithString: "PIN:"), pin,
            NSTextField(labelWithString: "Tailscale address of the phone:"), ts,
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 210)
        [popup, host, pin, ts].forEach { $0.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        a.accessoryView = stack
        a.window.initialFirstResponder = pin.stringValue.isEmpty ? pin : host

        guard a.runModal() == .alertFirstButtonReturn else { return }
        let p = pin.stringValue.trimmingCharacters(in: .whitespaces)
        d.set(p, forKey: "pin")
        d.set(ts.stringValue.trimmingCharacters(in: .whitespaces), forKey: "tailnetHost")
        wifiIndex = 0
        if let t = popup.titleOfSelectedItem, t != "IP address below" {
            d.set(t, forKey: "service"); d.removeObject(forKey: "host")
        } else {
            d.set(host.stringValue.trimmingCharacters(in: .whitespaces), forKey: "host"); d.removeObject(forKey: "service")
        }
        Hub.shared.reconnect()
        connectSaved()
    }

    private var viaUSB = false
    private var retryDelay: Double = 2   // grows while the phone isn't answering, so we don't hammer the cable
    private var usbBusy = false
    /// USB failed while plugged in: don't try again before this time (and never block Wi-Fi meanwhile).
    /// (Was "until re-plugged", but a quick unplug/replug was easily missed -> never switched back.)
    private var usbRetryAt: CFTimeInterval = 0
    private var usbGaveUp: Bool { CACurrentMediaTime() < usbRetryAt }

    /// Cable first (if a phone is plugged in), Wi-Fi otherwise.
    private func connectSaved() {
        guard let pin = UserDefaults.standard.string(forKey: "pin") else { showConnect(nil); return }
        wantConnected = true
        if !usbBusy && !usbGaveUp && !Self.noUSB && UsbBridge.shared.phonePresent() {
            usbBusy = true
            // Already playing over Wi-Fi (cable plugged back in): keep Wi-Fi running while the cable
            // gets ready in the background, then swap in one step (game mode stays on).
            let switching = stateText == "Connected" && link != nil
            NSLog("cable: trying USB (switching from Wi-Fi: \(switching))")
            if !switching {
                link?.onState = nil; link?.close(); link = nil
                stateText = "Connecting…"
                view.setMessage("Connecting over the USB cable…\n(If the phone asks to open PhoneCast for this USB device, tap OK / Always.)")
                updateTitle()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let port = UsbBridge.shared.start()
                DispatchQueue.main.async {
                    self.usbBusy = false
                    NSLog("cable: USB start -> \(port.map { "port \($0)" } ?? "failed")")
                    if let port {
                        self.viaUSB = true
                        self.connect(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), label: "USB cable", pin: pin)
                    } else {
                        self.usbRetryAt = CACurrentMediaTime() + (UsbBridge.shared.heldByOtherApp ? 30 : 10)
                        if !(switching && self.stateText == "Connected") { self.connectWifi(pin) } // else: stay on Wi-Fi
                        if UsbBridge.shared.heldByOtherApp {
                            self.deviceLabel += " (cable busy: another Mac app is using the phone's USB connection)"
                            self.updateTitle()
                        }
                    }
                }
            }
            return
        }
        connectWifi(pin)
    }

    private func connectWifi(_ pin: String) {
        let c = wifiCandidates()
        guard !c.isEmpty else { showConnect(nil); return }
        if wifiIndex >= c.count { wifiIndex = 0 }
        let (ep, label) = c[wifiIndex]
        NSLog("wifi: trying \(label) (\(wifiIndex + 1) of \(c.count))")
        viaUSB = false
        connect(ep, label: label, pin: pin)
    }

    /// Every few seconds: switch to the cable when it gets plugged in.
    static let noUSB = ProcessInfo.processInfo.environment["PHONECAST_NO_USB"] != nil

    private var lastPresent = false

    private func watchCable() {
        if Self.noUSB { return }
        let present = UsbBridge.shared.phonePresent()
        if present != lastPresent {
            NSLog("cable: phone \(present ? "plugged in" : "unplugged") (viaUSB=\(viaUSB) busy=\(usbBusy) gaveUp=\(usbGaveUp) want=\(wantConnected) state=\(stateText))")
            lastPresent = present
        }
        if !present { usbRetryAt = 0 }
        // (also in game mode: the switch keeps Wi-Fi running until the cable is ready)
        if wantConnected && present && !viaUSB && !usbBusy && !usbGaveUp {
            connectSaved()
        }
    }

    func applicationWillTerminate(_ n: Notification) { link?.close(); UsbBridge.shared.stop() }

    private func connect(_ ep: NWEndpoint, label: String, pin: String) {
        link?.onState = nil; link?.onPacket = nil
        link?.close()
        udp?.stop(); udp = nil; udpActive = false
        view.releaseAll()
        deviceLabel = label
        linkWasReady = false
        let l = Link(endpoint: ep)
        link = l
        view.link = l
        view.video.reset()
        sizedOnce = false

        l.onState = { [weak self, weak l] st in
            DispatchQueue.main.async {
                guard let self, let l, self.link === l else { return }
                switch st {
                case .connecting:
                    self.stateText = "Connecting…"
                    self.view.setMessage(self.viaUSB
                        ? "Cable connected — waiting for the phone.\nOpen PhoneCast on the phone and tap Start sharing."
                        : "Connecting to \(label)…")
                case .ready:
                    self.retryDelay = 2
                    self.wifiIndex = 0
                    self.linkWasReady = true
                    self.lastPong = 0
                    self.stateText = "Connected"; self.view.setMessage(nil)
                    self.sendSettings()
                case .badPin:
                    self.wantConnected = false
                    self.stateText = "Wrong PIN"
                    self.view.setMessage("Wrong PIN — check the PIN in the phone app")
                    self.showConnect(nil)
                case .closed(let why):
                    self.udp?.stop(); self.udp = nil; self.udpActive = false
                    if self.viaUSB { UsbBridge.shared.stop(); self.viaUSB = false }
                    self.audio.stop()
                    self.view.setMode(.normal)
                    self.stateText = "Disconnected"
                    // Never got through on this Wi-Fi address: try the next one right away; only back off
                    // once every address has failed.
                    let wasWifi = label != "USB cable", neverReady = !self.linkWasReady
                    if self.wantConnected, wasWifi, neverReady, self.wifiIndex + 1 < self.wifiCandidates().count {
                        self.wifiIndex += 1
                        self.view.setMessage("\(label) didn't answer (\(why)) — trying the next address…")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            guard let self, self.wantConnected, self.link === l else { return }
                            self.connectSaved()
                        }
                    } else if self.wantConnected {
                        if wasWifi && neverReady { self.wifiIndex = 0 }
                        let wait = self.retryDelay
                        self.retryDelay = min(15, self.retryDelay * 2)
                        self.view.setMessage("Lost connection (\(why))\nRetrying in \(Int(wait)) s — is sharing on in the phone app?")
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            guard let self, self.wantConnected, self.link === l else { return }
                            self.connectSaved()
                        }
                    } else {
                        self.view.setMessage("Not connected\n⌘K to connect")
                    }
                }
                self.updateTitle()
            }
        }
        l.onPacket = { [weak self] type, payload in self?.packet(type, payload) }
        l.start(pin: pin)
    }

    /// While mouse aiming, ⌘ plus a game key (R reload, H, D strafe…) must not reach the phone or
    /// the connection: ⌘R/⌘H would send the game to the background, ⌘D disconnected mid-match.
    /// Only harmless shortcuts stay active in game mode.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard view.mode == .game, let a = item.action else { return true }
        let allowed: [Selector] = [#selector(toggleGame(_:)), #selector(toggleStats(_:)), #selector(toggleMute(_:)),
                                   #selector(fullScreen(_:)), #selector(sensUp(_:)), #selector(sensDown(_:)),
                                   #selector(NSApplication.terminate(_:))]
        return allowed.contains(a)
    }

    @objc func disconnect(_ s: Any?) {
        wantConnected = false
        link?.close()
        UsbBridge.shared.stop()
    }

    // runs on the link queue
    private func packet(_ type: UInt8, _ p: Data) {
        switch type {
        case PT.frame:
            let now = CACurrentMediaTime()
            if lastFrameAt > 0, now - lastFrameAt > 0.15 { logLag(gapMs: (now - lastFrameAt) * 1000) }
            // stutter: a gap of 2+ missing frames while the picture is moving (fps high) — a static
            // menu legitimately sends few frames, so only count it when the last second was busy
            if lastFrameAt > 0, now - lastFrameAt > 0.07, fps >= 20 {
                stutterLock.lock(); stutters.append(now); stutterLock.unlock()
            }
            lastFrameAt = now
            view.video.frame(p)
        case PT.audio: audio.push(p)
        case PT.udpToken:
            guard p.count >= 6, let l = link, let host = l.remoteHost else { return }
            let b = [UInt8](p)
            let token = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            let port = UInt16(b[4]) << 8 | UInt16(b[5])
            udp?.stop()
            guard let u = UdpVideoIn(host: host, port: port, token: token) else { NSLog("udp: no socket for \(host)"); return }
            u.onFrame = { [weak self, weak l] payload in l?.async { self?.packet(PT.frame, payload) } }
            u.onNeedKeyframe = { [weak l] in l?.send(CT.keyframe) }
            udp = u
            u.start()
        case PT.udpOn: DispatchQueue.main.async { self.udpActive = true; self.udpOnAt = CACurrentMediaTime(); self.updateTitle() }
        case PT.udpOff: DispatchQueue.main.async { self.udpActive = false; self.updateTitle() }
        case PT.config: view.video.config(p)
        case PT.format:
            guard p.count >= 8 else { return }
            let b = [UInt8](p)
            let w = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            let h = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
            view.video.reset()
            DispatchQueue.main.async {
                // refit on rotation and on a new screen shape
                let old = self.view.videoSize
                let rotated = self.sizedOnce && old.height > 0 && abs(CGFloat(w) / CGFloat(h) - old.width / old.height) > 0.01
                self.view.videoSize = CGSize(width: w, height: h)
                self.switchKeyLayout(w, h)
                self.window.contentAspectRatio = NSSize(width: w, height: h)
                if !self.sizedOnce || rotated { self.fitWindow(nil); self.sizedOnce = true }
                self.updateTitle()
            }
        case PT.pong:
            guard p.count == 8 else { return }
            let sent = Double(bitPattern: p.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian)
            let rtt = (CACurrentMediaTime() - sent) * 1000
            DispatchQueue.main.async { self.lastPong = CACurrentMediaTime(); self.rttMs = self.rttMs == 0 ? rtt : self.rttMs * 0.7 + rtt * 0.3 }
        case PT.stats:
            guard p.count >= 4 else { break }
            let b = [UInt8](p)
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            var h: Health?
            if b.count >= 12 {
                let t = Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5]))
                let w = Int16(bitPattern: UInt16(b[8]) << 8 | UInt16(b[9]))
                h = Health(tempC: Double(t) / 10, battery: Int(b[6]), plugged: b[7] != 0, watts: Double(w) / 10, thermal: Int(b[10]), headroom: Int(b[11]), cpuC: nil, gpuC: nil)
                if b.count >= 16 {
                    let c = Int16(bitPattern: UInt16(b[12]) << 8 | UInt16(b[13]))
                    let g = Int16(bitPattern: UInt16(b[14]) << 8 | UInt16(b[15]))
                    if c != Int16.min { h?.cpuC = Double(c) / 10 }
                    if g != Int16.min { h?.gpuC = Double(g) / 10 }
                }
            }
            DispatchQueue.main.async { self.resyncs = n; if h != nil { self.health = h } }
        case PT.resResult:
            let r = p.first ?? 2
            DispatchQueue.main.async { self.resolutionResult(r) }
        case PT.helloOK, PT.control:
            let on = p.first == 1
            DispatchQueue.main.async { self.view.controlAvailable = on; self.updateTitle() }
        default: break
        }
    }

    /// A gap in arriving video (runs on the link queue). A static screen also pauses frames, so this
    /// only means something while the game is moving.
    private func logLag(gapMs: Double) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) gap=\(Int(gapMs))ms rtt=\(Int(rttMs))ms decode=\(String(format: "%.1f", view.video.decodeMs))ms resyncs=\(resyncs)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: lagLog) { h.seekToEndOfFile(); h.write(d); h.closeFile() }
        else { FileManager.default.createFile(atPath: lagLog, contents: d) }
    }

    private func tickFps() {
        let f = view.video.frames
        fps = f - lastFrames
        lastFrames = f
        updateTitle()
        updateStats()
    }

    private var transport: String { viaUSB ? "USB" : udpActive ? "Wi-Fi UDP" : "Wi-Fi" }

    private func updateTitle() {
        var parts = ["PhoneCast"]
        if !deviceLabel.isEmpty { parts.append(deviceLabel) }
        if stateText == "Connected" {
            parts.append("\(Int(view.videoSize.width))×\(Int(view.videoSize.height)) · \(fps) fps · \(transport) \(Int(rttMs)) ms · decode \(String(format: "%.1f", view.video.decodeMs)) ms · skipped \(resyncs)")
            if !view.controlAvailable { parts.append("view only — turn on mouse & keyboard in the phone app") }
        } else {
            parts.append(stateText)
        }
        switch view.mode {
        case .game: parts.append("MOUSE AIMING (Esc to exit) · speed \(String(format: "%.1f", view.map.sens))×")
        case .edit: parts.append("EDITING KEY MAP")
        case .normal: if view.typing { parts.append("TYPING (⌘T for buttons)") }
        }
        window?.title = parts.joined(separator: " — ")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
