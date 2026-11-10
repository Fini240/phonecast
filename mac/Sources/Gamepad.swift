import Foundation
import GameController

/// Game controllers (Xbox, PlayStation, Switch Pro, MFi) on the Mac play phone games through the key map:
///  - left stick  = the movement joystick (analog: half a push = half the throw)
///  - right stick = mouse-look (the look area)
///  - buttons/triggers/d-pad = mapped buttons, bound in the key map editor like keys ("gA", "gRT", …)
/// Works while PhoneCast is the front app, in normal and mouse-aiming mode.
final class Gamepad {
    static let shared = Gamepad()
    weak var view: PhoneView?
    private(set) var name: String?
    var onChange: (() -> Void)?

    fileprivate var timer: Timer?
    fileprivate var left = (x: 0.0, y: 0.0), right = (x: 0.0, y: 0.0)
    private var pressed = Set<String>()

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.releaseAll()
            self.name = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.vendorName
            if self.name == nil { self.timer?.invalidate(); self.timer = nil }
            self.onChange?()
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        name = c.vendorName ?? "Controller"
        let buttons: [(GCControllerButtonInput?, String, String)] = [
            (pad.buttonA, "gA", "A"), (pad.buttonB, "gB", "B"), (pad.buttonX, "gX", "X"), (pad.buttonY, "gY", "Y"),
            (pad.leftShoulder, "gLB", "LB"), (pad.rightShoulder, "gRB", "RB"),
            (pad.leftTrigger, "gLT", "LT"), (pad.rightTrigger, "gRT", "RT"),
            (pad.leftThumbstickButton, "gL3", "L3"), (pad.rightThumbstickButton, "gR3", "R3"),
            (pad.buttonMenu, "gMenu", "☰"), (pad.buttonOptions, "gView", "⧉"),
            (pad.dpad.up, "gUp", "D↑"), (pad.dpad.down, "gDown", "D↓"), (pad.dpad.left, "gLeft", "D←"), (pad.dpad.right, "gRight", "D→"),
        ]
        for (b, key, label) in buttons {
            b?.pressedChangedHandler = { [weak self] _, _, down in
                DispatchQueue.main.async { self?.button(key, label, down) }
            }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in DispatchQueue.main.async { self?.left = (Double(x), Double(y)) } }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in DispatchQueue.main.async { self?.right = (Double(x), Double(y)) } }
        if timer == nil {
            // sticks are sampled at 120 Hz: smooth for the game, and a held stick keeps turning
            timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
        onChange?()
    }

    fileprivate func button(_ key: String, _ label: String, _ down: Bool) {
        guard let v = view else { return }
        if down { pressed.insert(key) } else { pressed.remove(key) }
        v.gamepadButton(key, label: label, down: down)
    }

    fileprivate func tick() {
        guard let v = view else { return }
        v.gamepadSticks(left: left, right: right)
    }

    func releaseAll() {
        for k in pressed { view?.gamepadButton(k, label: "", down: false) }
        pressed.removeAll()
        left = (0, 0); right = (0, 0)
        view?.gamepadSticks(left: left, right: right)
    }
}

extension Gamepad {
    /// UI test (PHONECAST_TEST_PAD=1): a scripted controller session, so the touch output can be checked
    /// against a fake phone without a real controller. Binds "gA" in memory only (not saved).
    func runTestScript() {
        guard let v = view else { return }
        v.map.binds["gA"] = Bind(x: 0.8, y: 0.7, label: "A")
        let steps: [(Double, () -> Void)] = [
            (0.0, { self.left = (0.6, 0) }),        // half push right -> joystick slides part way
            (0.3, { self.left = (1, 1) }),          // full push up-right
            (0.6, { self.left = (0, 0) }),          // let go -> finger up
            (0.9, { self.right = (1, 0) }),         // look right
            (1.2, { self.right = (0, 0) }),         // let go -> look finger lifts after ~150 ms
            (1.6, { self.button("gA", "A", true) }),
            (1.75, { self.button("gA", "A", false) }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        if timer == nil {
            timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
}
