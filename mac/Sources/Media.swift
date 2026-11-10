import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// Annex-B H.264 -> hardware decoder (VTDecompressionSession) -> AVSampleBufferDisplayLayer.
/// Decoding ourselves, synchronously and without temporal processing, means every frame is shown
/// the moment it is decoded - the system player would otherwise hold a few frames back.
final class VideoSink {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?
    private(set) var frames = 0
    private(set) var decodeMs = 0.0
    var onNeedKeyframe: (() -> Void)?
    private var waitingForKey = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        format = nil; sps = nil; pps = nil
        waitingForKey = true
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
    }

    func config(_ annexB: Data) {
        for nal in Self.split(annexB) { take(nal) }
        rebuildFormat()
    }

    private func take(_ nal: Data) {
        guard let first = nal.first else { return }
        switch first & 0x1f {
        case 7: sps = nal
        case 8: pps = nal
        default: break
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: fmt), session != nil { return }
        format = fmt
        makeSession()
    }

    private func makeSession() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        guard let format else { return }
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, image, _, _ in
                guard status == noErr, let image, let refCon else { return }
                Unmanaged<VideoSink>.fromOpaque(refCon).takeUnretainedValue().show(image)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cb, decompressionSessionOut: &s)
        guard st == noErr, let s else { return }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
    }

    private func show(_ image: CVImageBuffer) {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &fmt) == noErr, let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        Self.displayNow(sample)
        frames += 1
        let r = layer.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sample)
    }

    private static func displayNow(_ sample: CMSampleBuffer) {
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }

    /// Runs on the network queue: decode right here, the callback fires before this returns.
    func frame(_ payload: Data) {
        guard payload.count > 1 else { return }
        let key = payload[payload.startIndex] == 1
        if waitingForKey && !key { return }

        var avcc = Data()
        var sawParams = false
        for nal in Self.split(Data(payload.dropFirst())) {
            let t = nal[nal.startIndex] & 0x1f
            if t == 7 || t == 8 { take(nal); sawParams = true; continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        if sawParams { rebuildFormat() }
        guard let format, let session, !avcc.isEmpty else { return }
        if Recorder.shared.recording { Recorder.shared.video(avcc, key: key, format: format) }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }

        let t0 = CACurrentMediaTime()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        decodeMs = decodeMs * 0.9 + (CACurrentMediaTime() - t0) * 1000 * 0.1
        if st == noErr {
            waitingForKey = false
        } else {
            // e.g. after the Mac slept: rebuild the decoder and wait for a fresh keyframe
            makeSession()
            waitingForKey = true
            onNeedKeyframe?()
        }
    }

    /// Splits an Annex-B stream on 00 00 01 / 00 00 00 01 start codes.
    static func split(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var out: [Data] = []
        var i = 0, start = -1
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && b[end - 1] == 0 { end -= 1 }
                    if end > start { out.append(Data(b[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < b.count { out.append(Data(b[start...])) }
        return out
    }
}

/// PCM s16le 48 kHz stereo -> speakers, with a small cap on buffered audio so it stays in sync.
final class AudioSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private let lock = NSLock()
    private var queued = 0
    private var started = false
    /// Since when more audio than [high] has been waiting (0 = not too much).
    private var behindSince: CFTimeInterval = 0
    private var trimming = false
    private static let target = 48_000 * 4 / 100, high = 48_000 * 6 / 100 // 40 ms, 60 ms
    /// Audio waiting to be played, in ms (shown in the stats overlay).
    var bufferedMs: Int { lock.lock(); defer { lock.unlock() }; return queued * 1000 / 48_000 }
    var muted = false { didSet { player.volume = muted ? 0 : 1 } }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    func push(_ d: Data) {
        let frames = d.count / 4
        guard frames > 0 else { return }
        lock.lock(); let q = queued; lock.unlock()
        // Keep the delay low: audio arrives exactly as fast as it plays, so a backlog from a hiccup
        // would otherwise stay forever (sound lagging behind the picture). If more than 60 ms waits
        // for half a second, skip incoming chunks until we're back at 40 ms.
        let now = CACurrentMediaTime()
        if q > Self.high { if behindSince == 0 { behindSince = now } } else { behindSince = 0 }
        if q > 48_000 * 12 / 100 || (behindSince > 0 && now - behindSince > 0.5) { trimming = true }
        if trimming {
            if q > Self.target { return }
            trimming = false; behindSince = 0
        }

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        d.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                l[i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                r[i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        lock.lock(); queued += frames; lock.unlock()
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= frames; self.lock.unlock()
        }
        if !started {
            lock.lock(); let q2 = queued; lock.unlock()
            if q2 >= 48_000 * 4 / 100 { // 40 ms pre-roll
                try? engine.start()
                player.play()
                started = true
            }
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        started = false
        lock.lock(); queued = 0; lock.unlock()
    }
}
