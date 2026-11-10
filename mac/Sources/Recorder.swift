import AppKit
import AVFoundation
import CoreMedia

/// Records the mirror to an .mp4 in ~/Movies/PhoneCast. The phone's H.264 frames are written as they
/// arrive (no re-encoding, so recording costs no CPU and adds no lag); the phone's sound is encoded to AAC.
/// Starts on the next key frame. Stops by itself if the phone's picture changes size (e.g. rotation).
final class Recorder {
    static let shared = Recorder()
    private(set) var recording = false
    /// Main thread: recording started (true) or a file was finished (false).
    var onState: ((Bool) -> Void)?

    private let q = DispatchQueue(label: "phonecast.recorder")
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?
    private var aIn: AVAssetWriterInput?
    private var format: CMFormatDescription?
    private var t0: CFTimeInterval = 0
    private var lastVideo = CMTime.invalid
    private var audioStart: Double?
    private var audioFrames: Int64 = 0
    private var lastAudioArrival: CFTimeInterval = 0
    private var url: URL?
    private var audioFormat: CMAudioFormatDescription?

    static var folder: URL {
        let u = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneCast")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func start() {
        q.async {
            guard !self.recording else { return }
            self.recording = true
            DispatchQueue.main.async { self.onState?(true) }
        }
    }

    func stop(reason: String? = nil) {
        q.async { self.finish(reason: reason) }
    }

    // MARK: input (network queue)

    func video(_ avcc: Data, key: Bool, format fmt: CMFormatDescription) {
        guard recording else { return }
        let now = CACurrentMediaTime()
        q.async {
            guard self.recording else { return }
            if self.writer == nil {
                guard key else { return }                  // a file must start on a key frame
                self.open(fmt, at: now)
            } else if let f = self.format, !CMFormatDescriptionEqual(f, otherFormatDescription: fmt) {
                self.finish(reason: "The phone's picture changed size, so the recording was saved.")
                return
            }
            guard let vIn = self.vIn, vIn.isReadyForMoreMediaData else { return }
            var pts = CMTime(seconds: now - self.t0, preferredTimescale: 90_000)
            // frames that arrive in a network burst still get distinct times (at least 2 ms apart)
            let gap = CMTime(value: 180, timescale: 90_000)
            if self.lastVideo.isValid && pts < self.lastVideo + gap { pts = self.lastVideo + gap }
            self.lastVideo = pts
            guard let s = Self.sample(avcc, fmt, pts: pts, key: key) else { return }
            vIn.append(s)
        }
    }

    /// PCM s16le 48 kHz stereo, straight from the phone.
    func audio(_ pcm: Data) {
        guard recording else { return }
        let now = CACurrentMediaTime()
        q.async {
            self.lastAudioArrival = now
            guard self.recording, self.writer != nil, let aIn = self.aIn, aIn.isReadyForMoreMediaData else { return }
            let frames = pcm.count / 4
            guard frames > 0 else { return }
            // audio time = first arrival + samples so far: no gaps or overlaps from network jitter
            if self.audioStart == nil { self.audioStart = max(0, now - self.t0 - Double(frames) / 48_000) }
            let pts = CMTime(value: Int64(self.audioStart! * 48_000) + self.audioFrames, timescale: 48_000)
            self.audioFrames += Int64(frames)
            if let s = self.audioSample(pcm, frames: frames, pts: pts) { aIn.append(s) }
        }
    }

    // MARK: file

    private func open(_ fmt: CMFormatDescription, at now: CFTimeInterval) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let u = Self.folder.appendingPathComponent("PhoneCast \(f.string(from: Date())).mp4")
        guard let w = try? AVAssetWriter(outputURL: u, fileType: .mp4) else { finish(reason: "Couldn't create the video file."); return }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        v.expectsMediaDataInRealTime = true
        v.mediaTimeScale = 90_000
        w.add(v)
        // only add a sound track if the phone is sending sound (an empty track breaks the file)
        if now - lastAudioArrival < 1 {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); aIn = a }
        }
        guard w.startWriting() else { finish(reason: "Couldn't start recording: \(w.error?.localizedDescription ?? "")"); return }
        w.startSession(atSourceTime: .zero)
        writer = w; vIn = v; format = fmt; url = u
        t0 = now; lastVideo = .invalid; audioStart = nil; audioFrames = 0
        NSLog("recorder: writing \(u.path)")
    }

    private func finish(reason: String?) {
        guard recording else { return }
        recording = false
        guard let w = writer else {
            reset(); DispatchQueue.main.async { self.onState?(false) }
            return
        }
        vIn?.markAsFinished(); aIn?.markAsFinished()
        let u = url
        w.finishWriting { [weak self] in
            DispatchQueue.main.async {
                self?.onState?(false)
                if w.status == .completed, let u {
                    Banners.shared.file(u, from: reason == nil ? "the mirror recording" : "the mirror recording · " + reason!)
                } else {
                    Banners.shared.info("Recording failed", w.error?.localizedDescription ?? reason ?? "")
                }
            }
        }
        reset()
    }

    private func reset() { writer = nil; vIn = nil; aIn = nil; format = nil; url = nil }

    // MARK: sample buffers

    private static func sample(_ avcc: Data, _ fmt: CMFormatDescription, pts: CMTime, key: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: pts)
        var size = avcc.count
        var s: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &s) == noErr, let s else { return nil }
        if !key, let arr = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return s
    }

    private func audioSample(_ pcm: Data, frames: Int, pts: CMTime) -> CMSampleBuffer? {
        if audioFormat == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                                   mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        }
        guard let audioFormat else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        var s: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
                                                                   sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
                                                                   sampleBufferOut: &s) == noErr else { return nil }
        return s
    }
}
