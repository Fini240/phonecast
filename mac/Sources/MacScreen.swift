import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Carbon.HIToolbox

/// Shows this Mac's main display on the phone (ScreenCaptureKit -> low-latency H.264 over the hub)
/// and turns the phone's touches/keys into mouse and keyboard events.
final class MacScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var hub: Hub?
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private let q = DispatchQueue(label: "phonecast.macscreen", qos: .userInteractive)
    private var forceKey = true
    private var lastConfig: Data?
    private var width = 0, height = 0
    private var generation = 0
    private(set) var active = false

    // MARK: start / stop (main thread)

    func start(longSide: Int, mbps: Int) {
        stop()
        generation += 1
        let gen = generation
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            deny("The Mac needs permission first: on the Mac, open System Settings → Privacy & Security → " +
                 "Screen & System Audio Recording, turn on PhoneCast, then reopen PhoneCast on the Mac.")
            return
        }
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            NSLog("macscreen: no Accessibility permission yet, the phone can watch but not control")
        }
        active = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, err in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                guard let content, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    self.deny("Couldn't capture the Mac's screen: \(err?.localizedDescription ?? "no display")"); return
                }
                self.begin(display: display, longSide: longSide, mbps: mbps)
            }
        }
    }

    private func begin(display: SCDisplay, longSide: Int, mbps: Int) {
        // the display's real pixels (Retina = 2x points), scaled down to what the phone asked for
        var pw = display.width, ph = display.height
        if let mode = CGDisplayCopyDisplayMode(display.displayID) { pw = mode.pixelWidth; ph = mode.pixelHeight }
        let s = min(1, Double(max(640, longSide)) / Double(max(pw, ph)))
        width = Int(Double(pw) * s) & ~1
        height = Int(Double(ph) * s) & ~1

        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 4
        cfg.showsCursor = true
        cfg.capturesAudio = false

        guard makeEncoder(mbps: mbps) else { deny("The Mac's video encoder didn't start."); return }
        let st = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        do { try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: q) } catch { deny("Capture failed: \(error.localizedDescription)"); return }
        stream = st
        st.startCapture { [weak self] err in
            if let err { DispatchQueue.main.async { self?.deny("Capture failed: \(err.localizedDescription)") } }
        }
        var b = Data(count: 8)
        b.withUnsafeMutableBytes { p in
            p.storeBytes(of: UInt32(width).bigEndian, toByteOffset: 0, as: UInt32.self)
            p.storeBytes(of: UInt32(height).bigEndian, toByteOffset: 4, as: UInt32.self)
        }
        hub?.link?.send(HT.screenFormat, b)
        NSLog("macscreen: streaming \(width)x\(height) at \(mbps) Mbit/s")
    }

    func stop() {
        generation += 1
        active = false
        stream?.stopCapture(completionHandler: nil); stream = nil
        q.async { [s = session] in if let s { VTCompressionSessionInvalidate(s) } }
        session = nil
        lastConfig = nil
        forceKey = true
    }

    func forceKeyframe() { q.async { self.forceKey = true } }

    private func deny(_ why: String) {
        active = false
        hub?.link?.send(HT.screenDenied, Data(why.utf8))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { if self.stream === stream { self.deny("Capture stopped: \(error.localizedDescription)") } }
    }

    // MARK: encode (capture queue)

    private func makeEncoder(mbps: Int) -> Bool {
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return false }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: max(2, min(60, mbps)) * 1_000_000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 600))
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        return true
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let session, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // ScreenCaptureKit also sends "nothing changed" frames without new pixels
        if let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = att[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        let props: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, out in
            guard status == noErr, let out, let self else { return }
            self.q.async { self.sendEncoded(out) }
        }
    }

    private func sendEncoded(_ sb: CMSampleBuffer) {
        guard active, let link = hub?.link else { return }
        let notSync = ((CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let key = !notSync
        if key, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var cfg = Data()
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    cfg.append(contentsOf: [0, 0, 0, 1]); cfg.append(ptr, count: size)
                }
            }
            if cfg != lastConfig { lastConfig = cfg; link.send(HT.screenConfig, cfg) }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { return }
        var out = Data(capacity: len + 1)
        out.append(key ? 1 : 0)
        // AVCC (4-byte lengths) -> Annex B (start codes)
        let raw = UnsafeRawPointer(ptr)
        var o = 0
        while o + 4 <= len {
            let n = Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).bigEndian)
            o += 4
            guard n > 0, o + n <= len else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(raw.advanced(by: o).assumingMemoryBound(to: UInt8.self), count: n)
            o += n
        }
        // network behind: skip this frame, and restart cleanly from a keyframe
        if !link.sendVideo(HT.screenFrame, out, maxInFlight: key ? 6 : 3) { forceKey = true }
    }

    // MARK: input from the phone (hub network queue)

    private let src = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    private var lastClickAt: CFTimeInterval = 0
    private var lastClickPos = CGPoint.zero
    private var clickCount: Int64 = 1
    private var lastPos = CGPoint.zero
    private lazy var charKeys: [Character: CGKeyCode] = Self.layoutKeys()

    func input(_ d: Data) {
        let b = [UInt8](d)
        guard let kind = b.first else { return }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        func pt(_ o: Int) -> CGPoint {
            guard b.count >= o + 4 else { return lastPos }
            let x = Double(Int(b[o]) << 8 | Int(b[o + 1])) / 65535, y = Double(Int(b[o + 2]) << 8 | Int(b[o + 3])) / 65535
            return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
        }
        switch kind {
        case 0: // move
            let p = pt(1); lastPos = p
            CGEvent(mouseEventSource: src, mouseType: leftDown ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        case 1, 2: // button down / up
            guard b.count >= 6 else { return }
            let right = b[1] == 1, down = kind == 1
            let p = pt(2); lastPos = p
            if down {
                let now = CACurrentMediaTime()
                clickCount = (now - lastClickAt < 0.45 && hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 12) ? min(3, clickCount + 1) : 1
                lastClickAt = now; lastClickPos = p
            }
            let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
            if !right { leftDown = down }
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left)
            e?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            e?.post(tap: .cghidEventTap)
        case 3: // scroll
            guard b.count >= 5 else { return }
            let dx = Int32(Int16(bitPattern: UInt16(b[1]) << 8 | UInt16(b[2])))
            let dy = Int32(Int16(bitPattern: UInt16(b[3]) << 8 | UInt16(b[4])))
            CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
        case 4: // text
            guard b.count >= 2 else { return }
            let mods = b[1]
            let text = String(decoding: b[2...], as: UTF8.self)
            if mods != 0, text.count == 1, let ch = text.lowercased().first, let code = charKeys[ch] {
                key(code, mods)
            } else {
                type(text)
            }
        case 5: // key
            guard b.count >= 4 else { return }
            key(CGKeyCode(Int(b[1]) << 8 | Int(b[2])), b[3])
        case 6: // trackpad: move by dx, dy points from where the cursor is
            guard b.count >= 5 else { return }
            let dx = Double(Int16(bitPattern: UInt16(b[1]) << 8 | UInt16(b[2])))
            let dy = Double(Int16(bitPattern: UInt16(b[3]) << 8 | UInt16(b[4])))
            let cur = CGEvent(source: nil)?.location ?? lastPos
            var p = CGPoint(x: cur.x + dx, y: cur.y + dy)
            // stay on a screen (any of them)
            let all = NSScreen.screens.map { s -> CGRect in
                let f = s.frame, top = NSScreen.screens.first?.frame.maxY ?? f.maxY
                return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
            }
            if !all.contains(where: { $0.contains(p) }), let near = all.min(by: { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) }) {
                p = CGPoint(x: min(max(p.x, near.minX), near.maxX - 1), y: min(max(p.y, near.minY), near.maxY - 1))
            }
            lastPos = p
            CGEvent(mouseEventSource: src, mouseType: leftDown ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        case 7: // trackpad: button at the cursor
            guard b.count >= 3 else { return }
            let p = CGEvent(source: nil)?.location ?? lastPos
            var e4 = Data([b[2] == 1 ? 1 : 2, b[1]])
            let ux = Int((p.x - bounds.minX) / max(1, bounds.width - 1) * 65535), uy = Int((p.y - bounds.minY) / max(1, bounds.height - 1) * 65535)
            if bounds.contains(p) {
                e4.append(contentsOf: [UInt8(ux >> 8 & 0xff), UInt8(ux & 0xff), UInt8(uy >> 8 & 0xff), UInt8(uy & 0xff)])
                input(e4)   // same click logic (double clicks, drags) as a normal tap
            } else {
                let right = b[1] == 1, down = b[2] == 1
                if !right { leftDown = down }
                CGEvent(mouseEventSource: src, mouseType: right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp),
                        mouseCursorPosition: p, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
            }
        default: break
        }
    }

    private func flags(_ m: UInt8) -> CGEventFlags {
        var f: CGEventFlags = []
        if m & 1 != 0 { f.insert(.maskCommand) }
        if m & 2 != 0 { f.insert(.maskAlternate) }
        if m & 4 != 0 { f.insert(.maskControl) }
        if m & 8 != 0 { f.insert(.maskShift) }
        return f
    }

    private func key(_ code: CGKeyCode, _ mods: UInt8) {
        let f = flags(mods)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            if !f.isEmpty { e?.flags = f }
            e?.post(tap: .cghidEventTap)
        }
    }

    private func type(_ s: String) {
        let u = Array(s.utf16)
        var i = 0
        while i < u.count {
            let chunk = Array(u[i..<min(u.count, i + 16)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    /// Character -> key code for the Mac's current keyboard layout (so ⌘Z is ⌘Z on a German keyboard too).
    private static func layoutKeys() -> [Character: CGKeyCode] {
        var out: [Character: CGKeyCode] = [:]
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return out }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0; var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let r = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                       OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if r == noErr, len == 1, let c = String(utf16CodeUnits: chars, count: 1).lowercased().first, out[c] == nil {
                    out[c] = CGKeyCode(code)
                }
            }
        }
        return out
    }
}
