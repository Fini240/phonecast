import Darwin
import Foundation

/// Cable link without USB debugging: switches the phone into Android Open Accessory mode with libusb,
/// then exposes the USB bulk pipe as a local TCP port so `Link` works unchanged.
final class UsbBridge {
    static let shared = UsbBridge()

    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    private var epIn: UInt8 = 0
    private var epOut: UInt8 = 0
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private let lock = NSLock()
    /// libusb's macOS backend crashes (null device) if one thread resets/opens a device while another
    /// is enumerating, or when it is used on a device that just vanished (USB debugging toggled,
    /// cable pulled: two crashes 08.11.2026). So every libusb call except the blocking bulk
    /// transfers runs under this lock, and devices are checked to still be attached first.
    private let usbLock = NSRecursiveLock()
    private(set) var port: UInt16 = 0
    private(set) var running = false
    /// The phone dropped off the bus: nothing left to reset.
    private var gone = false

    // Phone makers whose devices we may poke with AOA requests (never keyboards, hubs etc.)
    private let androidVendors: Set<UInt16> = [0x04E8, 0x18D1, 0x22B8, 0x2717, 0x12D1, 0x2A70, 0x0BB4, 0x1004, 0x054C, 0x0FCE, 0x2D95, 0x05C6, 0x1949, 0x0E8D]
    private let accessoryPids: ClosedRange<UInt16> = 0x2D00...0x2D05

    private init() { libusb_init(&ctx) }

    private struct Dev { let dev: OpaquePointer; let vid: UInt16; let pid: UInt16 }

    private func devices() -> ([Dev], UnsafeMutablePointer<OpaquePointer?>?) {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        var out: [Dev] = []
        if n > 0, let list {
            for i in 0..<Int(n) {
                guard let d = list[i] else { continue }
                var desc = libusb_device_descriptor()
                if libusb_get_device_descriptor(d, &desc) == 0 { out.append(Dev(dev: d, vid: desc.idVendor, pid: desc.idProduct)) }
            }
        }
        return (out, list)
    }

    /// Is an Android phone plugged in at all?
    func phonePresent() -> Bool {
        usbLock.lock(); defer { usbLock.unlock() }
        let (devs, list) = devices()
        defer { if let list { libusb_free_device_list(list, 1) } }
        return devs.contains { androidVendors.contains($0.vid) }
    }

    /// Switches the phone to accessory mode (if needed), opens the pipe and returns a local port. Blocking (~1–3 s).
    func start() -> UInt16? {
        usbLock.lock(); defer { usbLock.unlock() }
        stop()
        // 1. If the phone is still in accessory mode from an earlier run, reset it so both sides start clean.
        if let acc = findAccessory() {
            var h: OpaquePointer?
            if attached(acc), libusb_open(acc, &h) == 0, let h { if attached(acc) { libusb_reset_device(h) }; libusb_close(h) }
            libusb_unref_device(acc)
            Thread.sleep(forTimeInterval: 1.5)
        }
        // 2. Ask the phone to become our accessory.
        if findAccessory() == nil {
            guard switchToAccessory() else { return nil }
        }
        // 3. Wait for it to come back as an accessory and open the bulk endpoints.
        var acc: OpaquePointer?
        for _ in 0..<24 {
            acc = findAccessory()
            if acc != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let acc else { return nil }
        defer { libusb_unref_device(acc) }
        gone = false
        guard openAccessory(acc) else { return nil }
        guard listen() else { stop(); return nil }
        running = true
        Thread { self.acceptLoop() }.start()
        return port
    }

    /// Is this device still on the bus? (libusb keeps detached devices alive but unusable.)
    private func attached(_ dev: OpaquePointer) -> Bool {
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        defer { if let list { libusb_free_device_list(list, 1) } }
        guard n > 0, let list else { return false }
        return (0..<Int(n)).contains { list[$0] == dev }
    }

    private func findAccessory() -> OpaquePointer? {
        let (devs, list) = devices()
        defer { if let list { libusb_free_device_list(list, 1) } }
        guard let d = devs.first(where: { $0.vid == 0x18D1 && accessoryPids.contains($0.pid) }) else { return nil }
        return libusb_ref_device(d.dev)
    }

    private func switchToAccessory() -> Bool {
        let (devs, list) = devices()
        defer { if let list { libusb_free_device_list(list, 1) } }
        for d in devs where androidVendors.contains(d.vid) && !(d.vid == 0x18D1 && accessoryPids.contains(d.pid)) {
            var h: OpaquePointer?
            guard libusb_open(d.dev, &h) == 0, let h else { continue }
            defer { libusb_close(h) }
            var ver: [UInt8] = [0, 0]
            let r = libusb_control_transfer(h, 0xC0, 51, 0, 0, &ver, 2, 1000)
            guard r == 2, (Int(ver[0]) | Int(ver[1]) << 8) >= 1 else { continue }
            let strings = ["Finn", "PhoneCast", "PhoneCast Mac viewer", "1.0", "https://github.com/Fini240", "phonecast"]
            for (i, s) in strings.enumerated() {
                var bytes = Array(s.utf8) + [0]
                _ = libusb_control_transfer(h, 0x40, 52, 0, UInt16(i), &bytes, UInt16(bytes.count), 1000)
            }
            _ = libusb_control_transfer(h, 0x40, 53, 0, 0, nil, 0, 1000)
            return true
        }
        return false
    }

    private func openAccessory(_ dev: OpaquePointer) -> Bool {
        var h: OpaquePointer?
        guard libusb_open(dev, &h) == 0, let h else { return false }
        var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
        guard attached(dev) else { libusb_close(h); return false }
        guard libusb_get_active_config_descriptor(dev, &cfg) == 0, let cfg else { libusb_close(h); return false }
        defer { libusb_free_config_descriptor(cfg) }
        // interface 0 is the accessory interface (1 may be adb)
        let alt = cfg.pointee.interface[0].altsetting[0]
        epIn = 0; epOut = 0
        for i in 0..<Int(alt.bNumEndpoints) {
            let ep = alt.endpoint[i]
            guard ep.bmAttributes & 0x03 == 2 else { continue } // bulk
            if ep.bEndpointAddress & 0x80 != 0 { epIn = ep.bEndpointAddress } else { epOut = ep.bEndpointAddress }
        }
        libusb_set_auto_detach_kernel_driver(h, 1)
        guard epIn != 0, epOut != 0, libusb_claim_interface(h, Int32(alt.bInterfaceNumber)) == 0 else { libusb_close(h); return false }
        handle = h
        return true
    }

    private func listen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } } == 0
        guard ok, Darwin.listen(fd, 1) == 0 else { close(fd); return false }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        listenFd = fd
        return true
    }

    private func acceptLoop() {
        // One viewer connection per USB session: the phone side has no way to re-sync mid-stream.
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { stop(); return }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        clientFd = fd
        Thread { self.usbToSocket() }.start()
        socketToUsb()
    }

    private func socketToUsb() {
        var buf = [UInt8](repeating: 0, count: 16384)
        while running {
            let n = read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            // A transfer that is an exact multiple of 512 bytes has no short packet at the end, so the
            // phone would keep waiting for more. Split those so every transfer ends short.
            var chunks: [(Int, Int)] = [(0, n)]
            if n % 512 == 0 { chunks = n > 1 ? [(0, n - 1), (n - 1, 1)] : [(0, n)] }
            for (start, len) in chunks {
                var off = 0
                while off < len {
                    var sent: Int32 = 0
                    let r = buf.withUnsafeMutableBufferPointer { p in
                        libusb_bulk_transfer(handle, epOut, p.baseAddress! + start + off, Int32(len - off), &sent, 0)
                    }
                    if r != 0 { if r == LIBUSB_ERROR_NO_DEVICE.rawValue { gone = true }; stop(); return }
                    off += Int(sent)
                }
            }
        }
        stop()
    }

    private func usbToSocket() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while running {
            // No timeout: on macOS a timed-out bulk read can drop bytes it had already received,
            // which desyncs the stream. stop() resets the device, which ends this read.
            var got: Int32 = 0
            let r = libusb_bulk_transfer(handle, epIn, &buf, Int32(buf.count), &got, 0)
            if r != 0 { if r == LIBUSB_ERROR_NO_DEVICE.rawValue { gone = true }; break }
            var off = 0
            while off < Int(got) {
                let w = buf.withUnsafeBufferPointer { write(clientFd, $0.baseAddress! + off, Int(got) - off) }
                if w <= 0 { stop(); return }
                off += w
            }
        }
        stop()
    }

    /// Closes everything and resets the phone out of accessory mode so the next start is clean.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        let wasRunning = running
        running = false
        if clientFd >= 0 { close(clientFd); clientFd = -1 }
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        if let h = handle {
            handle = nil
            if wasRunning {
                let skipReset = gone
                DispatchQueue.global().async { [self] in
                    usbLock.lock(); defer { usbLock.unlock() }
                    let dev = libusb_get_device(h)
                    if !skipReset, let dev, attached(dev) {
                        libusb_release_interface(h, 0)
                        libusb_reset_device(h)
                    }
                    libusb_close(h)
                }
            } else {
                libusb_close(h)
            }
        }
    }
}
