import Foundation
import QuartzCore

/// System plumbing for the agents feature: process table (sysctl/libproc — no `ps`/`lsof` forks),
/// bounded JSONL reading, text hygiene and a small subprocess runner.
enum Procs {
    struct Row { let pid: Int32; let ppid: Int32; let tty: Bool; let comm: String }

    private static let lock = NSLock()
    private static var cache: (at: CFTimeInterval, rows: [Row]) = (0, [])

    static func rows(maxAge: Double = 1.0) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        if CACurrentMediaTime() - cache.at < maxAge { return cache.rows }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return cache.rows }
        size += size / 8
        let n = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: n)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return cache.rows }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var out: [Row] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var p = buf[i]
            let comm = withUnsafeBytes(of: &p.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            out.append(Row(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, tty: p.kp_eproc.e_tdev != -1 && p.kp_eproc.e_tdev != 0, comm: comm))
        }
        cache = (CACurrentMediaTime(), out)
        return out
    }

    static func descendants(_ root: Int32, _ rows: [Row] = rows()) -> [Int32] {
        var kids: [Int32: [Int32]] = [:]
        for r in rows { kids[r.ppid, default: []].append(r.pid) }
        var out: [Int32] = [], stack = [root], seen = Set<Int32>()
        while let p = stack.popLast() {
            for c in kids[p] ?? [] where seen.insert(c).inserted { out.append(c); stack.append(c) }
        }
        return out
    }

    /// Full argv of a process (KERN_PROCARGS2).
    static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // exec path
        while i < size && buf[i] == 0 { i += 1 }        // padding
        var out: [String] = []
        while i < size && out.count < argc {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    static func alive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Paths of regular files a process has open.
    static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: n)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard r > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if path.hasPrefix("/") { out.append(path) }
        }
        return out
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.stride))
        guard r > 0 else { return nil }
        let p = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return p.isEmpty ? nil : p
    }
}

/// Run a program and wait (bounded). Returns exit status and stdout.
@discardableResult
func runTool(_ exe: String, _ args: [String], input: Data? = nil, env: [String: String]? = nil, timeout: Double = 10) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = input != nil ? inp : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    if let input { inp.fileHandleForWriting.write(input); try? inp.fileHandleForWriting.close() }
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    return (p.terminationStatus, data)
}

// MARK: - files

enum JSONL {
    /// First lines of a file (last, possibly cut line dropped).
    static func head(_ url: URL, _ maxBytes: Int) -> [[String: Any]] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: maxBytes)) ?? Data()
        var parts = d.split(separator: 0x0a, omittingEmptySubsequences: false)
        if d.count == maxBytes, !parts.isEmpty { parts.removeLast() }
        return parts.compactMap(obj)
    }

    /// Last lines of a file and whether the start was reached (first partial line dropped).
    static func tail(_ url: URL, _ maxBytes: Int) -> ([[String: Any]], Bool) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], true) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let d = (try? h.readToEnd()) ?? Data()
        var parts = d.split(separator: 0x0a, omittingEmptySubsequences: false)
        if start > 0, !parts.isEmpty { parts.removeFirst() }
        return (parts.compactMap(obj), start == 0)
    }

    static func obj(_ line: Data.SubSequence) -> [String: Any]? {
        guard line.count > 1 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }
}

struct FileStamp: Equatable { let mtime: Double; let size: Int }
func fileStamp(_ path: String) -> FileStamp? {
    var s = stat()
    guard stat(path, &s) == 0 else { return nil }
    return FileStamp(mtime: Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9, size: Int(s.st_size))
}

/// Memo keyed by path, valid while the file's mtime/size don't change.
final class StampCache<V> {
    private var data: [String: (FileStamp, V)] = [:]
    private let lock = NSLock()
    func get(_ path: String, _ st: FileStamp, _ make: () -> V) -> V {
        lock.lock()
        if let hit = data[path], hit.0 == st { lock.unlock(); return hit.1 }
        lock.unlock()
        let v = make()
        lock.lock()
        if data.count > 600 { data.removeAll(keepingCapacity: true) }
        data[path] = (st, v)
        lock.unlock()
        return v
    }
}

// MARK: - text

enum AgentText {
    static let maxMessage = 8000, maxTool = 1500, lastMessage = 240

    private static let redactions: [(Rx, String)] = [
        (Rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#), "[redacted private key]"),
        (Rx(#"\b(sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,})"#), "[redacted]"),
        (Rx(#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#), "[redacted]"),
        (Rx(#"\b(xox[abposr]-[A-Za-z0-9-]{10,})"#), "[redacted]"),
        (Rx(#"\bAKIA[0-9A-Z]{16}\b"#), "[redacted]"),
        (Rx(#"\bAIza[0-9A-Za-z_\-]{30,}"#), "[redacted]"),
        (Rx(#"\b(ya29\.[0-9A-Za-z_\-]{20,})"#), "[redacted]"),
        (Rx(#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#), "[redacted jwt]"),
        (Rx(#"(?i)\b(bearer)\s+[A-Za-z0-9._\-+/=]{16,}"#), "$1 [redacted]"),
        (Rx(#"(?i)\b([A-Z0-9_]*(?:api[_-]?key|secret|token|passwd|password|private[_-]?key|auth)[A-Z0-9_]*)(\s*[=:]\s*)(['"]?)[^\s'"]{8,}\3"#), "$1$2$3[redacted]$3"),
    ]

    static func redact(_ s: String) -> String {
        var s = s
        for (r, w) in redactions { s = r.replace(s, w) }
        return s
    }

    static func clip(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(max(0, n - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func clean(_ v: Any?, _ limit: Int = maxMessage) -> String {
        guard let s = v as? String else { return "" }
        return clip(redact(s.replacingOccurrences(of: "\r\n", with: "\n")).trimmingCharacters(in: .whitespacesAndNewlines), limit)
    }

    static func oneLine(_ s: String, _ n: Int) -> String {
        clip(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), n)
    }
}

enum ISO {
    private static let f: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let g: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let lock = NSLock()
    /// ISO string, epoch seconds or epoch ms → epoch seconds.
    static func parse(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is Bool) { let d = n.doubleValue; return d > 1e11 ? d / 1000 : d }
        guard let s = v as? String, !s.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return (f.date(from: s) ?? g.date(from: s))?.timeIntervalSince1970
    }
}
