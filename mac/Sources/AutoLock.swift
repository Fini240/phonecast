import AppKit
import Combine

/// Opt-in: lock this Mac when the phone leaves. Fires only when the phone link has been gone for
/// [Store.autoLockMinutes] after having been connected, AND nobody has used the Mac's keyboard or mouse
/// for that long either, so it never locks while you are sitting at the Mac (a Wi-Fi blip is harmless).
final class AutoLock {
    static let shared = AutoLock()
    private var bag = Set<AnyCancellable>()
    private var lostAt: Date?
    private var timer: Timer?
    private var wasConnected = false

    func start() {
        let s = Store.shared
        s.$connected.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] c in
            guard let self else { return }
            if c { self.wasConnected = true; self.lostAt = nil; self.timer?.invalidate(); self.timer = nil }
            else if self.wasConnected && self.lostAt == nil { self.lostAt = Date(); self.arm() }
        }.store(in: &bag)
    }

    private func arm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let s = Store.shared
        guard s.autoLock, let lost = lostAt, !s.connected else { if s.connected { timer?.invalidate(); timer = nil }; return }
        let wait = Double(max(1, s.autoLockMinutes)) * 60
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard Date().timeIntervalSince(lost) >= wait, idle >= wait else { return }
        timer?.invalidate(); timer = nil
        lostAt = nil; wasConnected = false      // once per departure
        if Self.screenLocked { return }
        NSLog("autolock: phone gone \(Int(Date().timeIntervalSince(lost))) s, Mac idle \(Int(idle)) s -> locking")
        MacActions.run("lock")
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
