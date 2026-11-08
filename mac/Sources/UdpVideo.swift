import Darwin
import Foundation
import QuartzCore

/// Receives Wi-Fi video over UDP (see UdpVideo.kt on the phone).
///
/// Frames are reassembled from datagrams and delivered strictly in order (each frame builds on the
/// one before). A missing piece is first rebuilt from the XOR repair datagrams; if that isn't
/// possible, only the missing pieces are requested again ("PCR1"), which costs one Wi-Fi round
/// trip (~5–10 ms) instead of stalling everything like TCP does. Only if that fails too (120 ms) is
/// the frame given up and a keyframe requested.
final class UdpVideoIn {
    /// A complete frame payload (same as a TCP FRAME packet: u8 keyframe, then Annex B).
    var onFrame: ((Data) -> Void)?
    var onNeedKeyframe: (() -> Void)?
    private(set) var lost = 0
    private(set) var repaired = 0
    private(set) var resentFrames = 0
    /// Datagrams arrive (so UDP gets through this network).
    private(set) var lastPacketAt: CFTimeInterval = 0

    private static let shard = 1200, header = 16
    /// Test only: PHONECAST_UDP_DROP=0.05 throws away 5% of the datagrams to exercise the repair.
    private static let testDrop = Double(ProcessInfo.processInfo.environment["PHONECAST_UDP_DROP"] ?? "") ?? 0
    private var fd: Int32 = -1
    private var running = false
    private let token: UInt32
    private var helloTimer: DispatchSourceTimer?

    private final class Frame {
        let n: Int, p: Int, len: Int
        var data: [Data?], repair: [Data?]
        var haveData = 0
        var lastAt = CACurrentMediaTime()
        init(n: Int, p: Int, len: Int) {
            self.n = n; self.p = p; self.len = len
            data = Array(repeating: nil, count: n); repair = Array(repeating: nil, count: p)
        }
    }
    /// Frames still missing pieces.
    private var frames: [UInt32: Frame] = [:]
    /// Complete frames waiting for an older one.
    private var ready: [UInt32: Data] = [:]
    /// Next frame to hand to the decoder; nil while waiting for a keyframe.
    private var next: UInt32?
    private var maxSeen: UInt32 = 0
    /// Chasing the frame we are stuck on: since when, last request, number of requests.
    private var stuckSince: CFTimeInterval = 0, lastAsk: CFTimeInterval = 0, asks = 0
    private var lastKeyRequest: CFTimeInterval = 0

    private var recentLosses: [CFTimeInterval] = []
    private let lossLock = NSLock()
    /// Frames lost in the last 5 s (safe from any thread).
    func recentLossCount() -> Int {
        lossLock.lock(); defer { lossLock.unlock() }
        let now = CACurrentMediaTime()
        return recentLosses.filter { now - $0 < 5 }.count
    }

    /// [host] is the phone's address as the TCP link resolved it (may be IPv6 with %scope).
    init?(host: String, port: UInt16, token: UInt32) {
        self.token = token
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        fd = socket(ai.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var big: Int32 = 7 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 5_000) // wake up every 5 ms to chase missing pieces
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // connect: only the phone's datagrams get in, and our requests go there
        guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { close(fd); return nil }
    }

    func start() {
        running = true
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.hello() }
        t.resume()
        helloTimer = t
        Thread { [weak self] in self?.receiveLoop() }.start()
    }

    func stop() {
        running = false
        helloTimer?.cancel(); helloTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func hello() {
        guard fd >= 0 else { return }
        var b: [UInt8] = Array("PCU1".utf8)
        withUnsafeBytes(of: token.bigEndian) { b.append(contentsOf: $0) }
        _ = send(fd, b, b.count, 0)
    }

    /// Ask the phone to send these data pieces of frame [id] again ([(start, count)]).
    private func askResend(_ id: UInt32, _ ranges: [(Int, Int)]) {
        guard fd >= 0 else { return }
        var b: [UInt8] = Array("PCR1".utf8)
        withUnsafeBytes(of: token.bigEndian) { b.append(contentsOf: $0) }
        withUnsafeBytes(of: id.bigEndian) { b.append(contentsOf: $0) }
        for (s, c) in ranges.prefix(300) {
            withUnsafeBytes(of: UInt16(s).bigEndian) { b.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(min(c, 0xFFFF)).bigEndian) { b.append(contentsOf: $0) }
        }
        _ = send(fd, b, b.count, 0)
    }

    private func receiveLoop() {
        Thread.current.qualityOfService = .userInteractive
        var buf = [UInt8](repeating: 0, count: 2048)
        while running {
            let n = recv(fd, &buf, buf.count, 0)
            if n >= Self.header, buf[0] == 0xC5 {
                lastPacketAt = CACurrentMediaTime()
                if Self.testDrop == 0 || Double.random(in: 0..<1) >= Self.testDrop { handle(buf, n) }
            } else if n < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                if !running { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            pump()
            chase()
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    /// a is newer than b (frame ids wrap around)
    private static func newer(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

    private func handle(_ b: [UInt8], _ count: Int) {
        let isRepair = b[1] & 1 != 0
        let id = Self.u32(b, 2), index = Self.u16(b, 6), n = Self.u16(b, 8), p = Self.u16(b, 10)
        let len = Int(Self.u32(b, 12))
        guard n > 0, p > 0, len > 0, len <= n * Self.shard else { return }
        if let next, Self.newer(next, id) { return }  // already delivered or given up
        if ready[id] != nil { return }                 // complete already (late duplicate)
        if maxSeen == 0 || Self.newer(id, maxSeen) { maxSeen = id }
        let f: Frame
        if let e = frames[id] { f = e } else { f = Frame(n: n, p: p, len: len); frames[id] = f }
        guard f.n == n, f.p == p else { return }
        f.lastAt = CACurrentMediaTime()
        let body = Data(b[Self.header..<count])
        if isRepair {
            if index < p, f.repair[index] == nil { f.repair[index] = body }
        } else if index < n, f.data[index] == nil {
            f.data[index] = body; f.haveData += 1
        }
        if f.haveData == f.n { complete(id, f) }
        else if f.haveData + f.repair.lazy.filter({ $0 != nil }).count >= f.n, rebuild(f) { repaired += 1; complete(id, f) }
    }

    private func complete(_ id: UInt32, _ f: Frame) {
        frames[id] = nil
        var payload = Data(capacity: f.len)
        for d in f.data { if let d { payload.append(d) } }
        if payload.count == f.len { ready[id] = payload }
    }

    /// Fills missing data pieces from the repair pieces (one missing piece per repair group).
    private func rebuild(_ f: Frame) -> Bool {
        let missing = (0..<f.n).filter { f.data[$0] == nil }
        if missing.isEmpty { return true }
        var groups: [Int: Int] = [:]
        for i in missing { groups[i % f.p, default: 0] += 1 }
        guard groups.allSatisfy({ $0.value == 1 && f.repair[$0.key] != nil }) else { return false }
        for i in missing {
            let g = i % f.p
            var x = [UInt8](f.repair[g]!)
            if x.count < Self.shard { x += [UInt8](repeating: 0, count: Self.shard - x.count) }
            var j = g
            while j < f.n {
                if j != i, let d = f.data[j] {
                    d.withUnsafeBytes { raw in
                        let s = raw.bindMemory(to: UInt8.self)
                        for k in 0..<s.count { x[k] ^= s[k] }
                    }
                }
                j += f.p
            }
            let size = i == f.n - 1 ? f.len - i * Self.shard : Self.shard
            f.data[i] = Data(x[0..<max(0, size)])
            f.haveData += 1
        }
        return true
    }

    /// Hands every frame that is next in line to the decoder.
    private func pump() {
        if next == nil {
            // waiting for a keyframe: start at the oldest complete one
            guard let k = ready.filter({ $0.value.first == 1 }).keys.min(by: { Self.newer($1, $0) }) else {
                if !ready.isEmpty || !frames.isEmpty { askKey() }
                if ready.count > 200 { ready.removeAll() }
                if frames.count > 200 { frames.removeAll() }
                return
            }
            ready = ready.filter { !Self.newer(k, $0.key) }
            frames = frames.filter { Self.newer($0.key, k) }
            next = k
        }
        while let id = next, let payload = ready.removeValue(forKey: id) {
            onFrame?(payload)
            next = id &+ 1
            stuckSince = 0; asks = 0
        }
    }

    /// The next frame is incomplete while newer ones arrive (or it went quiet): get the missing
    /// pieces again, and give up after 120 ms.
    private func chase() {
        guard let id = next, ready[id] == nil else { return }
        let now = CACurrentMediaTime()
        let f = frames[id]
        let newerArrived = Self.newer(maxSeen, id)
        guard newerArrived || (f.map { now - $0.lastAt > 0.02 } ?? false) else { return }
        if stuckSince == 0 { stuckSince = now }
        if now - stuckSince > 0.12 { giveUp(id); return }
        // ask again every 30 ms (the request or the resend itself can get lost too)
        guard asks == 0 || now - lastAsk > 0.03 else { return }
        if asks == 0 { resentFrames += 1 }
        asks += 1; lastAsk = now
        if let f {
            var ranges: [(Int, Int)] = []
            var i = 0
            while i < f.n {
                if f.data[i] == nil {
                    let s = i
                    while i < f.n, f.data[i] == nil { i += 1 }
                    ranges.append((s, i - s))
                } else { i += 1 }
            }
            askResend(id, ranges)
        } else {
            askResend(id, [(0, 0xFFFF)]) // nothing of it arrived at all: the whole frame
        }
    }

    private func giveUp(_ id: UInt32) {
        frames[id] = nil
        next = nil // wait for a keyframe (everything after this frame depends on it)
        stuckSince = 0; asks = 0
        lost += 1
        let now = CACurrentMediaTime()
        lossLock.lock(); recentLosses = recentLosses.filter { now - $0 < 5 } + [now]; lossLock.unlock()
        askKey()
    }

    private func askKey() {
        let now = CACurrentMediaTime()
        // keyframes are big (up to ~1 MB): asking too often floods the Wi-Fi with them
        if now - lastKeyRequest > 0.5 { lastKeyRequest = now; onNeedKeyframe?() }
    }
}
