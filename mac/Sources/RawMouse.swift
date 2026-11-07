import Foundation
import IOKit.hid

/// Reads mouse movement straight from the HID device: raw counts, no macOS pointer acceleration.
/// NSEvent deltas are accelerated, so a fast flick and a slow move back cover different distances
/// and aim never lands where it started. Needs the "Input Monitoring" permission; without it (or
/// with a trackpad, which reports no relative X/Y) the view falls back to NSEvent deltas.
final class RawMouse {
    /// Called on the main thread with the counts collected since the last call.
    var onMove: ((Int, Int) -> Void)?
    private var manager: IOHIDManager?
    private var dx = 0, dy = 0
    private var pending = false
    private(set) var lastEvent: CFAbsoluteTime = 0

    /// True while raw events are actually arriving (so NSEvent deltas should be ignored).
    var live: Bool { CFAbsoluteTimeGetCurrent() - lastEvent < 0.5 }

    func start() {
        if manager != nil { return }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) // shows the permission prompt once
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<RawMouse>.fromOpaque(ctx).takeUnretainedValue()
            let el = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(el) == UInt32(kHIDPage_GenericDesktop),
                  IOHIDElementIsRelative(el) else { return }
            let v = IOHIDValueGetIntegerValue(value)
            if v == 0 { return }
            switch IOHIDElementGetUsage(el) {
            case UInt32(kHIDUsage_GD_X): me.add(v, 0)
            case UInt32(kHIDUsage_GD_Y): me.add(0, v)
            default: break
            }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func add(_ x: Int, _ y: Int) {
        dx += x; dy += y
        lastEvent = CFAbsoluteTimeGetCurrent()
        // X and Y of one report arrive as separate values: deliver them together
        if pending { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            let x = self.dx, y = self.dy
            self.dx = 0; self.dy = 0
            self.onMove?(x, y)
        }
    }
}
