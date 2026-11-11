import Foundation

/// One chat (top-level or subagent) as the phone and the Agents page see it.
struct AgentSession {
    var id: String
    var agent: String                 // "claude" | "codex"
    var nativeId: String?
    var title: String
    var cwd: String?
    var model: String?
    var status: String                // working idle needs_input completed error unknown offline
    var stage: String?
    var updatedAt: Double
    var managed = false               // in a PhoneCast tmux pane: send / stop / approve / keys work
    var lastMessage: String?
    var live = false
    var canResume = false
    var parentId: String?
    var isSubagent = false
    var agentName: String?
    var agentRole: String?
    var task: String?
    var attached = false              // a Mac terminal shows the pane right now
    var transcript: String?           // Claude transcript / Codex rollout (never sent)

    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "agent": agent, "title": title, "status": status, "updatedAt": Int(updatedAt * 1000),
                                "managed": managed, "live": live, "canResume": canResume]
        if let nativeId { o["nativeId"] = nativeId }
        if let cwd { o["cwd"] = cwd }
        if let model { o["model"] = model }
        if let stage { o["stage"] = stage }
        if let lastMessage { o["last"] = lastMessage }
        if let parentId { o["parent"] = parentId }
        if isSubagent { o["sub"] = true }
        if let agentName { o["name"] = agentName }
        if let agentRole { o["role"] = agentRole }
        if let task { o["task"] = task }
        if attached { o["attached"] = true }
        return o
    }
}

struct AgentMessage {
    let id: String, role: String, text: String, ts: Double, tool: String?
    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "r": role, "t": text, "ts": Int(ts * 1000)]
        if let tool { o["tool"] = tool }
        return o
    }
}

/// Claude Code, read-only: `~/.claude/projects/<slug>/<sessionId>.jsonl` transcripts and the live-process
/// registry `~/.claude/sessions/<pid>.json` (status busy/idle). `*.key` files are never opened.
enum ClaudeSource {
    static let maxSessions = 60, maxAgeDays = 30.0
    static let headBytes = 64 * 1024, tailBytes = 256 * 1024, historyMax = 8 * 1024 * 1024
    static let nonTerminal = ["mcp", "sdk-ts", "sdk-py"]
    static let liveStatus = ["busy": "working", "working": "working", "running": "working", "idle": "idle",
                             "waiting": "needs_input", "waiting_for_input": "needs_input", "needs_input": "needs_input", "permission": "needs_input"]

    static var home: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var projects: URL { home.appendingPathComponent("projects") }

    struct Live { let pid: Int; let status: String?; let cwd: String?; let entrypoint: String?; let updated: Double }

    static func liveRegistry() -> [String: Live] {
        let dir = home.appendingPathComponent("sessions")
        var out: [String: Live] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard name.hasSuffix(".json"), Int(name.dropLast(5)) != nil else { continue }
            guard let o = readSmallJSON(dir.appendingPathComponent(name)), let sid = o["sessionId"] as? String,
                  let pid = (o["pid"] as? NSNumber)?.intValue, Procs.alive(pid) else { continue }
            let upd = ISO.parse(o["statusUpdatedAt"] ?? o["updatedAt"]) ?? 0
            if let prev = out[sid], prev.updated > upd { continue }
            out[sid] = Live(pid: pid, status: o["status"] as? String, cwd: o["cwd"] as? String, entrypoint: o["entrypoint"] as? String, updated: upd)
        }
        return out
    }

    static func readSmallJSON(_ u: URL) -> [String: Any]? {
        guard let s = fileStamp(u.path), s.size < 64 * 1024, let d = try? Data(contentsOf: u) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Registry entry of one Claude process (managed panes).
    static func session(forPid pid: Int32) -> [String: Any]? {
        guard let o = readSmallJSON(home.appendingPathComponent("sessions/\(pid).json")), (o["pid"] as? NSNumber)?.int32Value == pid else { return nil }
        return o
    }

    private static var pathIndex: [String: URL] = [:]
    private static let indexLock = NSLock()

    static func transcript(_ native: String) -> URL? {
        guard !native.isEmpty, !native.contains("/"), !native.hasPrefix(".") else { return nil }
        indexLock.lock(); let hit = pathIndex[native]; indexLock.unlock()
        if let hit, FileManager.default.fileExists(atPath: hit.path) { return hit }
        for p in (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let c = p.appendingPathComponent("\(native).jsonl")
            if FileManager.default.fileExists(atPath: c.path) {
                indexLock.lock(); pathIndex[native] = c; indexLock.unlock()
                return c
            }
        }
        return nil
    }

    static func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let a = content as? [[String: Any]] {
            return a.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    static func noise(_ t: String) -> Bool {
        let s = t.drop(while: { $0.isWhitespace })
        return ["<local-command-", "<command-", "<system-reminder>", "Caveat: ", "<bash-", "<task-notification"].contains { s.hasPrefix($0) }
    }

    struct Meta {
        var cwd: String?, firstPrompt: String?, model: String?, customTitle: String?, aiTitle: String?, agentName: String?
        var entrypoint: String?, lastTs: Double?, lastMessage: String?, sidechainOnly = true
    }
    private static let metaCache = StampCache<Meta>()

    static func meta(_ u: URL) -> Meta? {
        guard let st = fileStamp(u.path) else { return nil }
        return metaCache.get(u.path, st) {
            var m = Meta()
            for e in JSONL.head(u, headBytes) {
                if m.cwd == nil, let c = e["cwd"] as? String { m.cwd = c }
                if m.entrypoint == nil, let ep = e["entrypoint"] as? String { m.entrypoint = ep }
                let t = e["type"] as? String
                let side = e["isSidechain"] as? Bool == true
                if (t == "user" || t == "assistant") && !side { m.sidechainOnly = false }
                if m.firstPrompt == nil, t == "user", e["isMeta"] as? Bool != true, !side {
                    let txt = textOf((e["message"] as? [String: Any])?["content"])
                    if !txt.isEmpty && !noise(txt) { m.firstPrompt = AgentText.oneLine(txt, 80) }
                }
            }
            for e in JSONL.tail(u, tailBytes).0 {
                let t = e["type"] as? String
                if let c = e["cwd"] as? String { m.cwd = c }
                switch t {
                case "custom-title": if let s = e["customTitle"] as? String { m.customTitle = s }
                case "ai-title": if let s = e["aiTitle"] as? String { m.aiTitle = s }
                case "agent-name": if let s = e["agentName"] as? String { m.agentName = s }
                default: break
                }
                guard t == "user" || t == "assistant", e["isSidechain"] as? Bool != true else { continue }
                m.sidechainOnly = false
                if let ts = ISO.parse(e["timestamp"]) { m.lastTs = max(m.lastTs ?? 0, ts) }
                let msg = e["message"] as? [String: Any] ?? [:]
                if t == "assistant", let mo = msg["model"] as? String, mo != "<synthetic>" { m.model = mo }
                let txt = textOf(msg["content"])
                if !txt.isEmpty && !(t == "user" && (noise(txt) || e["isMeta"] as? Bool == true)) {
                    m.lastMessage = AgentText.oneLine(AgentText.clean(txt), AgentText.lastMessage)
                }
            }
            return m
        }
    }

    static func title(_ m: Meta, _ cwd: String?) -> String {
        for v in [m.customTitle, m.aiTitle, m.firstPrompt] { if let v, !v.isEmpty { return AgentText.oneLine(v, 80) } }
        if let n = m.agentName, n != "Chat session" { return AgentText.clip(n, 80) }
        let base = (cwd as NSString?)?.lastPathComponent ?? ""
        return base.isEmpty ? "Claude Code chat" : base
    }

    static func discover(live: [String: Live]) -> [AgentSession] {
        let fm = FileManager.default
        let cutoff = Date().timeIntervalSince1970 - maxAgeDays * 86400
        var files: [(Double, URL)] = []
        var index: [String: URL] = [:]
        for proj in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: proj.path)) ?? [] where name.hasSuffix(".jsonl") {
                let u = proj.appendingPathComponent(name)
                guard let st = fileStamp(u.path) else { continue }
                index[String(name.dropLast(6))] = u
                if st.mtime >= cutoff || live[String(name.dropLast(6))] != nil { files.append((st.mtime, u)) }
            }
        }
        indexLock.lock(); pathIndex = index; indexLock.unlock()
        files.sort { a, b in
            let la = live[a.1.deletingPathExtension().lastPathComponent] != nil, lb = live[b.1.deletingPathExtension().lastPathComponent] != nil
            return la != lb ? la : a.0 > b.0
        }
        var out: [AgentSession] = []
        var history = 0
        for (mtime, f) in files {
            let native = f.deletingPathExtension().lastPathComponent
            let le = live[native]
            if le == nil && history >= maxSessions { continue }
            guard let m = meta(f), !m.sidechainOnly else { continue }
            let ep = m.entrypoint ?? ""
            if nonTerminal.contains(where: { ep.hasPrefix($0) }) && le?.entrypoint != "cli" { continue }
            if le == nil { history += 1 }
            let cwd = m.cwd ?? le?.cwd
            var status = "offline", stage: String? = "Not running · history only"
            if let le {
                let raw = le.status ?? ""
                status = liveStatus[raw] ?? "unknown"
                stage = status == "unknown" ? (raw.isEmpty ? "Running" : "Running · \(raw)") : nil
            }
            out.append(AgentSession(id: "claude:\(native)", agent: "claude", nativeId: native, title: title(m, cwd), cwd: cwd, model: m.model,
                                    status: status, stage: stage, updatedAt: m.lastTs ?? mtime, lastMessage: m.lastMessage,
                                    live: le != nil, canResume: le == nil, transcript: f.path))
        }
        let listed = Set(out.compactMap(\.nativeId))
        for (sid, e) in live where !listed.contains(sid) && !nonTerminal.contains(where: { (e.entrypoint ?? "").hasPrefix($0) }) {
            out.append(AgentSession(id: "claude:\(sid)", agent: "claude", nativeId: sid, title: "New Claude Code chat", cwd: e.cwd, model: nil,
                                    status: liveStatus[e.status ?? ""] ?? "unknown", stage: nil, updatedAt: e.updated > 0 ? e.updated : Date().timeIntervalSince1970,
                                    live: true, canResume: false))
        }
        return out
    }

    static func lookup(_ native: String) -> (title: String, model: String?, cwd: String?, last: String?, path: String)? {
        guard let p = transcript(native), let m = meta(p) else { return nil }
        return (title(m, m.cwd), m.model, m.cwd, m.lastMessage, p.path)
    }

    static func toolSummary(_ name: String, _ input: Any?) -> String {
        if let d = input as? [String: Any] {
            for k in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
                if let v = d[k] as? String, !v.isEmpty { return "\(name): \(AgentText.oneLine(v, 300))" }
            }
        }
        return name
    }

    static func messages(path: String?, native: String?, limit: Int, sidechain: Bool = false) -> [AgentMessage] {
        var u: URL?
        if let path, path.hasSuffix(".jsonl"), path.hasPrefix(projects.path) { u = URL(fileURLWithPath: path) }
        else if let native { u = transcript(native) }
        guard let u else { return [] }
        let limit = max(1, min(limit, 500))
        var budget = tailBytes * 4
        while true {
            let (lines, atStart) = JSONL.tail(u, budget)
            let msgs = parse(lines, sidechain: sidechain)
            if msgs.count >= limit || atStart || budget >= historyMax { return Array(msgs.suffix(limit)) }
            budget *= 4
        }
    }

    static func parse(_ entries: [[String: Any]], sidechain: Bool = false) -> [AgentMessage] {
        var out: [AgentMessage] = []
        var toolNames: [String: String] = [:]
        func role(_ t: String) -> String { t.hasPrefix("[Request interrupted by user") ? "system" : "user" }
        for e in entries {
            guard let t = e["type"] as? String, t == "user" || t == "assistant" else { continue }
            if e["isSidechain"] as? Bool == true && !sidechain { continue }
            let msg = e["message"] as? [String: Any] ?? [:]
            let ts = ISO.parse(e["timestamp"]) ?? 0
            let base = (e["uuid"] as? String) ?? String(out.count)
            let content = msg["content"]
            if t == "user" {
                if e["isMeta"] as? Bool == true { continue }
                if let s = content as? String {
                    if noise(s) { continue }
                    let txt = AgentText.clean(s)
                    if !txt.isEmpty { out.append(AgentMessage(id: base, role: role(txt), text: txt, ts: ts, tool: nil)) }
                    continue
                }
                for (i, b) in ((content as? [[String: Any]]) ?? []).enumerated() {
                    switch b["type"] as? String {
                    case "text":
                        let raw = b["text"] as? String ?? ""
                        if noise(raw) { continue }
                        let txt = AgentText.clean(raw)
                        if !txt.isEmpty { out.append(AgentMessage(id: "\(base):\(i)", role: role(txt), text: txt, ts: ts, tool: nil)) }
                    case "tool_result":
                        let res = b["content"]
                        let txt = (res as? String) ?? textOf(res)
                        let name = toolNames[b["tool_use_id"] as? String ?? ""]
                        let prefix = b["is_error"] as? Bool == true ? "Error: " : ""
                        out.append(AgentMessage(id: "\(base):\(i)", role: "tool", text: prefix + AgentText.clean(txt, AgentText.maxTool), ts: ts, tool: name))
                    case "image":
                        out.append(AgentMessage(id: "\(base):\(i)", role: "user", text: "[Image]", ts: ts, tool: nil))
                    default: break
                    }
                }
            } else {
                for (i, b) in ((content as? [[String: Any]]) ?? []).enumerated() {
                    switch b["type"] as? String {
                    case "text":
                        let txt = AgentText.clean(b["text"])
                        if !txt.isEmpty { out.append(AgentMessage(id: "\(base):\(i)", role: "assistant", text: txt, ts: ts, tool: nil)) }
                    case "tool_use":
                        let name = b["name"] as? String ?? "tool"
                        toolNames[b["id"] as? String ?? ""] = name
                        out.append(AgentMessage(id: "\(base):\(i)", role: "tool", text: AgentText.clean(toolSummary(name, b["input"]), AgentText.maxTool), ts: ts, tool: name))
                    default: break
                    }
                }
            }
        }
        return out
    }

    // MARK: subagents — projects/<slug>/<parent>/subagents/agent-<id>.jsonl (+ .meta.json)

    struct Child { var task: String?; var cwd: String?; var model: String?; var lastTs: Double?; var last: String?; var final = false; var pending: String?; var mtime: Double }
    private static let childCache = StampCache<Child>()
    private static let notifyCache = StampCache<[String: (String, Double?, String?)]>()
    private static let notifyRe = Rx(#"<task-id>([A-Za-z0-9_-]+)</task-id>.*?<status>([a-z_]+)</status>(?:.*?<summary>(.*?)</summary>)?"#, [.dotMatchesLineSeparators])

    private static func notifications(_ parent: URL) -> [String: (String, Double?, String?)] {
        guard let st = fileStamp(parent.path) else { return [:] }
        return notifyCache.get(parent.path, st) {
            var found: [String: (String, Double?, String?)] = [:]
            for rec in JSONL.tail(parent, 4 * 1024 * 1024).0 {
                guard let d = try? JSONSerialization.data(withJSONObject: rec), var s = String(data: d, encoding: .utf8),
                      s.contains("<task-notification>") else { continue }
                s = s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\/", with: "/")
                let ts = ISO.parse(rec["timestamp"])
                for m in notifyRe.all(s) {
                    guard let aid = m.g(1), let status = m.g(2) else { continue }
                    if let prev = found[aid], (prev.1 ?? 0) > (ts ?? 0) { continue }
                    let sum = m.g(3).map { AgentText.oneLine($0.replacingOccurrences(of: "\\\"", with: "\""), 200) }
                    found[aid] = (status, ts, (sum?.isEmpty ?? true) ? nil : sum)
                }
            }
            return found
        }
    }

    private static func scanChild(_ u: URL, _ st: FileStamp) -> Child {
        childCache.get(u.path, st) {
            var c = Child(mtime: st.mtime)
            for e in JSONL.head(u, headBytes) {
                if c.cwd == nil, let w = e["cwd"] as? String { c.cwd = w }
                if c.task == nil, e["type"] as? String == "user" {
                    let t = textOf((e["message"] as? [String: Any])?["content"])
                    if !t.isEmpty { c.task = AgentText.clip(AgentText.clean(t), 600) }
                }
                if c.task != nil && c.cwd != nil { break }
            }
            var pending: [(String, String)] = []
            for e in JSONL.tail(u, tailBytes).0 {
                let t = e["type"] as? String
                guard t == "user" || t == "assistant" else { continue }
                if let ts = ISO.parse(e["timestamp"]) { c.lastTs = max(c.lastTs ?? 0, ts) }
                if let w = e["cwd"] as? String { c.cwd = w }
                let msg = e["message"] as? [String: Any] ?? [:]
                let blocks = msg["content"] as? [[String: Any]] ?? []
                if t == "assistant" {
                    if let mo = msg["model"] as? String, mo != "<synthetic>" { c.model = mo }
                    c.final = msg["stop_reason"] as? String == "end_turn"
                    for b in blocks {
                        if b["type"] as? String == "text", let tx = b["text"] as? String, !tx.trimmingCharacters(in: .whitespaces).isEmpty {
                            c.last = AgentText.oneLine(AgentText.clean(tx), AgentText.lastMessage)
                        } else if b["type"] as? String == "tool_use" {
                            pending.append((b["id"] as? String ?? "", AgentText.oneLine(AgentText.clean(toolSummary(b["name"] as? String ?? "tool", b["input"])), AgentText.lastMessage)))
                        }
                    }
                } else {
                    c.final = false
                    for b in blocks where b["type"] as? String == "tool_result" {
                        let id = b["tool_use_id"] as? String ?? ""
                        pending.removeAll { $0.0 == id }
                    }
                }
            }
            c.pending = pending.last?.1
            return c
        }
    }

    static func children(_ parents: [AgentSession], now: Double) -> [AgentSession] {
        var out: [AgentSession] = []
        let fm = FileManager.default
        for p in parents where p.agent == "claude" {
            guard let tp = p.transcript, tp.hasSuffix(".jsonl") else { continue }
            let parentURL = URL(fileURLWithPath: tp)
            let sub = parentURL.deletingPathExtension().appendingPathComponent("subagents")
            guard let names = try? fm.contentsOfDirectory(atPath: sub.path) else { continue }
            var files: [(URL, FileStamp)] = names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }.compactMap {
                let u = sub.appendingPathComponent($0)
                return fileStamp(u.path).map { (u, $0) }
            }
            if files.isEmpty { continue }
            files.sort { $0.1.mtime > $1.1.mtime }
            files = Array(files.prefix(40))
            let notifs = notifications(parentURL)
            for (f, st) in files {
                let aid = String(f.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
                let info = scanChild(f, st)
                let meta = readSmallJSON(f.deletingPathExtension().appendingPathExtension("meta.json")) ?? [:]
                let last = info.lastTs ?? info.mtime
                var status: String, stage: String?
                if let n = notifs[aid], (n.1 ?? 0) >= last - 2 {
                    switch n.0 {
                    case "completed": status = "completed"
                    case "failed": status = "error"; stage = n.2
                    case "killed", "stopped": status = "idle"; stage = "Stopped"
                    default: status = "unknown"; stage = "Reported \(n.0)"
                    }
                } else if now - info.mtime <= 90 && !info.final { status = "working"; stage = info.pending }
                else if info.final && info.pending == nil { status = "completed" }
                else if !p.live { status = "offline"; stage = "Stopped without a final report" }
                else { status = "unknown"; stage = "No recent activity" }
                let desc = meta["description"] as? String
                out.append(AgentSession(id: "claude-sub:\(aid)", agent: "claude", nativeId: aid,
                                        title: AgentText.oneLine(desc ?? info.task ?? "Subagent", 80), cwd: info.cwd ?? p.cwd, model: info.model,
                                        status: status, stage: stage, updatedAt: last, lastMessage: info.last ?? info.pending,
                                        live: status == "working", canResume: false, parentId: p.id, isSubagent: true,
                                        agentName: desc.map { AgentText.clip($0, 80) }, agentRole: meta["agentType"] as? String, task: info.task,
                                        transcript: f.path))
            }
        }
        return out
    }
}
