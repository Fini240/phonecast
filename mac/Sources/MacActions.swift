import AppKit

/// Keys the phone's Mac tab can press: volume, media, lock, display sleep, screenshot.
enum MacActions {
    // NX_KEYTYPE_* media keys (IOKit/hidsystem/ev_keymap.h)
    private static let keys: [String: Int32] = ["volup": 0, "voldown": 1, "mute": 7, "play": 16, "next": 17, "prev": 18]

    static func run(_ a: String) {
        if let k = keys[a] { mediaKey(k); return }
        switch a {
        case "lock":
            // ⌃⌘Q locks the screen (needs the Accessibility permission PhoneCast already has)
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down)
                e?.flags = [.maskCommand, .maskControl]
                e?.post(tap: .cghidEventTap)
            }
        case "displaysleep": run("/usr/bin/pmset", ["displaysleepnow"])
        case "screenshot":
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/Screenshot \(f.string(from: Date())).png")
            run("/usr/sbin/screencapture", ["-x", path]) {
                // send it straight to the phone too
                Hub.shared.sendFiles([URL(fileURLWithPath: path)])
            }
        default: NSLog("mac action: unknown \(a)")
        }
    }

    private static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func run(_ exe: String, _ args: [String], then: (() -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.terminationHandler = { _ in if let then { DispatchQueue.main.async(execute: then) } }
        try? p.run()
    }
}
