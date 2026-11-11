import Foundation
import SQLite3
import QuartzCore

/// Codex CLI, read-only: `~/.codex/state_N.sqlite` (threads, thread_spawn_edges), rollout JSONL files,
/// open files of terminal Codex processes, and thread status from the local app-server daemon.
/// `auth.json` is never opened.
enum CodexSource {
    static let maxSessions = 60, maxAgeDays = 30.0
    static let tailBytes = 512 * 1024, historyMax = 16 * 1024 * 1024
    static let originators = ["codex-tui"], sources = ["cli"]
    static let rolloutRe = Rx(#"rollout-[^/]*?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"#)
    static let uuidRe = Rx(#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
    static let injected = ["# AGENTS.md instructions", "<environment_context>", "<user_instructions>", "<permissions",
                           "<turn_aborted>", "<user_shell_command>", "<collaboration_mode", "<skill>", "<subagent_notification"]

    static var home: URL {
        if let d = ProcessInfo.processInfo.environment["CODEX_HOME"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    // MARK: sqlite (read only)

    static func stateDB() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let best = names.compactMap { n -> (Int, String)? in
            guard n.hasPrefix("state_"), n.hasSuffix(".sqlite"), let v = Int(n.dropFirst(6).dropLast(7)) else { return nil }
            return (v, n)
        }.max { $0.0 < $1.0 }
        return best.map { home.appendingPathComponent($0.1).path }
    }

    static func query(_ sql: String, _ args: [Any]) -> [[String: Any]] {
        guard let path = stateDB() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            if let s = a as? String { sqlite3_bind_text(st, Int32(i + 1), s, -1, transient) }
            else if let n = a as? Int { sqlite3_bind_int64(st, Int32(i + 1), Int64(n)) }
        }
        var rows: [[String: Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, c))
                switch sqlite3_column_type(st, c) {
                case SQLITE_INTEGER: r[name] = Int(sqlite3_column_int64(st, c))
                case SQLITE_FLOAT: r[name] = sqlite3_column_double(st, c)
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(st, c))
                default: break
                }
            }
            rows.append(r)
        }
        return rows
    }

    private static var colCache: (String, Set<String>)?
    static func columns(_ table: String = "threads") -> Set<String> {
        if table == "threads", let c = colCache, c.0 == stateDB() { return c.1 }
        let cols = Set(query("PRAGMA table_info(\(table))", []).compactMap { $0["name"] as? String })
        if table == "threads" { colCache = (stateDB() ?? "", cols) }
        return cols
    }

    static let wanted = ["id", "rollout_path", "created_at", "updated_at", "created_at_ms", "updated_at_ms", "source", "cwd", "title", "name",
                         "preview", "first_user_message", "model", "archived", "originator", "agent_nickname", "agent_role", "agent_path"]

    static func threads(limit: Int = maxSessions, ids: [String]? = nil) -> [[String: Any]] {
        let cols = columns()
        guard cols.contains("id") else { return [] }
        let want = wanted.filter(cols.contains)
        var whereSQL: [String] = [], args: [Any] = []
        if cols.contains("archived") { whereSQL.append("archived = 0") }
        if let ids, !ids.isEmpty {
            whereSQL.append("id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"); args += ids
        } else {
            var terms: [String] = []
            if cols.contains("source") { terms.append("source IN (\(sources.map { _ in "?" }.joined(separator: ",")))"); args += sources }
            if cols.contains("originator") { terms.append("originator IN (\(originators.map { _ in "?" }.joined(separator: ",")))"); args += originators }
            if !terms.isEmpty { whereSQL.append("(" + terms.joined(separator: " OR ") + ")") }
            if cols.contains("thread_source") { whereSQL.append("COALESCE(thread_source, '') != 'subagent'") }
            if cols.contains("source") { whereSQL.append("source NOT LIKE '{%'") }
            if cols.contains("updated_at") { whereSQL.append("updated_at >= ?"); args.append(Int(Date().timeIntervalSince1970 - maxAgeDays * 86400)) }
        }
        let order = cols.contains("updated_at_ms") ? "COALESCE(updated_at_ms, updated_at * 1000)" : "updated_at"
        var sql = "SELECT \(want.joined(separator: ", ")) FROM threads"
        if !whereSQL.isEmpty { sql += " WHERE " + whereSQL.joined(separator: " AND ") }
        sql += " ORDER BY \(order) DESC LIMIT ?"
        args.append(limit)
        return query(sql, args)
    }

    // MARK: live terminal processes

    private static var liveCache: (at: CFTimeInterval, byThread: [String: Int32], unmapped: [String])?

    static func isTUI(_ args: [String]) -> Bool {
        let cmd = args.joined(separator: " ")
        if ["app-server", "exec-server", "code-mode-host", "mcp-server"].contains(where: cmd.contains) { return false }
        guard let exe = args.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        var rest = Array(args.dropFirst())
        if exe == "node" || exe == "bun" {
            guard let s = rest.first, s.hasSuffix("/codex") || s.hasSuffix("/codex.js") else { return false }
            rest = Array(rest.dropFirst())
        } else if exe != "codex" { return false }
        let sub = rest.first ?? ""
        return sub.isEmpty || sub == "resume" || sub == "fork" || sub.hasPrefix("-") || !sub.allSatisfy(\.isLetter)
    }

    /// threadId -> pid of terminal Codex processes, plus cwds of those whose thread is unknown.
    static func liveProcesses(maxAge: Double = 10) -> ([String: Int32], [String]) {
        if let c = liveCache, CACurrentMediaTime() - c.at < maxAge { return (c.byThread, c.unmapped) }
        let rows = Procs.rows()
        let names: Set<String> = ["codex", "node", "bun"]
        var tui: [Procs.Row] = []
        for r in rows where r.tty && names.contains(r.comm) && isTUI(Procs.args(r.pid)) { tui.append(r) }
        let tuiPids = Set(tui.map { $0.pid })
        var by: [String: Int32] = [:], unmapped: [String] = []
        for r in tui where !tuiPids.contains(r.ppid) {
            var found: String?
            for pid in [r.pid] + rows.filter({ $0.ppid == r.pid }).map(\.pid) {
                found = threadFromFiles(pid)
                if found == nil {
                    let a = Procs.args(pid)
                    if let i = a.firstIndex(of: "resume"), i + 1 < a.count, uuidRe.match(a[i + 1]) != nil { found = a[i + 1] }
                }
                if found != nil { break }
            }
            if let found { by[found] = r.pid } else if let c = Procs.cwd(r.pid) { unmapped.append(c) }
        }
        liveCache = (CACurrentMediaTime(), by, unmapped)
        return (by, unmapped)
    }

    static func threadFromFiles(_ pid: Int32) -> String? {
        for f in Procs.openFiles(pid) { if let m = rolloutRe.search(f) { return m.g(1) } }
        return nil
    }

    static func thread(forPids pids: [Int32]) -> String? {
        for p in pids { if let t = threadFromFiles(p) { return t } }
        return nil
    }

    // MARK: rollouts

    struct Activity { var turnOpen: Bool?; var lastTs: Double?; var last: String?; var model: String?; var state: String?; var error: String?; var doing: String?; var mtime: Double = 0 }
    private static let actCache = StampCache<Activity>()

    static func activity(_ path: String) -> Activity {
        guard let st = fileStamp(path) else { return Activity() }
        return actCache.get(path, st) {
            var a = Activity(mtime: st.mtime)
            var last: String?
            for e in JSONL.tail(URL(fileURLWithPath: path), 128 * 1024).0 {
                let pl = e["payload"] as? [String: Any] ?? [:]
                if let ts = ISO.parse(e["timestamp"]) { a.lastTs = ts }
                if e["type"] as? String == "turn_context", let m = pl["model"] as? String { a.model = m }
                guard e["type"] as? String == "event_msg" else { continue }
                switch pl["type"] as? String {
                case "task_started": a.turnOpen = true; a.state = "open"; a.error = nil
                case "task_complete":
                    a.turnOpen = false; a.state = "complete"
                    if let m = pl["last_agent_message"] as? String { last = m }
                case "turn_aborted": a.turnOpen = false; a.state = "aborted"
                case "error": a.state = "error"; a.error = pl["message"] as? String
                case "agent_message": if let m = pl["message"] as? String { last = m }
                case "item_completed":
                    let it = pl["item"] as? [String: Any] ?? [:]
                    if it["type"] as? String == "CommandExecution" {
                        let c = it["command"]
                        a.doing = "$ " + ((c as? [String])?.last ?? (c as? String) ?? "")
                    } else if it["type"] as? String == "FileChange" { a.doing = "Editing files" }
                default: break
                }
            }
            a.last = last.map { AgentText.oneLine(AgentText.clean($0), AgentText.lastMessage) }
            a.doing = a.doing.map { AgentText.oneLine(AgentText.clean($0), AgentText.lastMessage) }
            a.error = a.error.map { AgentText.oneLine(AgentText.clean($0), 200) }
            return a
        }
    }

    static func safeRollout(_ p: Any?) -> String? {
        guard let s = p as? String, s.hasSuffix(".jsonl"), s.hasPrefix(home.path), FileManager.default.fileExists(atPath: s) else { return nil }
        return s
    }

    static func title(_ r: [String: Any]) -> String {
        for k in ["name", "title", "preview", "first_user_message"] {
            if let v = r[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty, !isInjected(v) { return AgentText.oneLine(v, 80) }
        }
        let base = ((r["cwd"] as? String) as NSString?)?.lastPathComponent ?? ""
        return base.isEmpty ? "Codex chat" : base
    }

    static func isInjected(_ s: String) -> Bool { let t = s.drop(while: { $0.isWhitespace }); return injected.contains { t.hasPrefix($0) } }

    static func daemonStatus(_ l: CodexDaemon.Thread) -> (String, String?) {
        switch l.status {
        case "active":
            if l.flags.contains("waitingOnApproval") { return ("needs_input", "Waiting for approval") }
            if l.flags.contains("waitingOnUserInput") { return ("needs_input", "Waiting for input") }
            return ("working", nil)
        case "idle": return ("idle", nil)
        case "systemError": return ("error", "Codex reported a system error")
        default: return ("unknown", "Loaded in Codex")
        }
    }

    static func updated(_ r: [String: Any]) -> Double? {
        if let ms = r["updated_at_ms"] as? Int { return Double(ms) / 1000 }
        if let s = r["updated_at"] as? Int { return Double(s) }
        return nil
    }

    static func discover() -> [AgentSession] {
        var rows = threads()
        let daemon = CodexDaemon.loaded()
        let (live, unmapped) = liveProcesses()
        let known = Set(rows.compactMap { $0["id"] as? String })
        let missing = live.keys.filter { !known.contains($0) }
        if !missing.isEmpty { rows += threads(limit: missing.count, ids: Array(missing)) }
        var out: [AgentSession] = []
        for r in rows {
            guard let tid = r["id"] as? String else { continue }
            let rollout = safeRollout(r["rollout_path"])
            let act = rollout.map(activity) ?? Activity()
            let loaded = daemon?[tid]
            let isLive = live[tid] != nil || loaded != nil
            let cwd = r["cwd"] as? String
            let possibly = daemon == nil && !isLive && unmapped.contains(where: { $0 == cwd })
            var status: String, stage: String?
            if let loaded { (status, stage) = daemonStatus(loaded) }
            else if isLive { status = act.turnOpen == true ? "working" : act.turnOpen == false ? "idle" : "unknown"; stage = act.turnOpen == nil ? "Running in a terminal" : nil }
            else if possibly { status = "unknown"; stage = "A Codex terminal is open in this folder" }
            else { status = "offline"; stage = "Not running · history only" }
            out.append(AgentSession(id: "codex:\(tid)", agent: "codex", nativeId: tid, title: title(r), cwd: cwd,
                                    model: (r["model"] as? String) ?? act.model, status: status, stage: stage,
                                    updatedAt: updated(r) ?? act.lastTs ?? 0, lastMessage: act.last,
                                    live: isLive, canResume: !isLive && !possibly, transcript: rollout))
        }
        let have = Set(out.compactMap(\.nativeId))
        for (tid, l) in daemon ?? [:] where !have.contains(tid) && originators.contains(l.originator ?? "") {
            let (status, stage) = daemonStatus(l)
            out.append(AgentSession(id: "codex:\(tid)", agent: "codex", nativeId: tid, title: "New Codex chat", cwd: l.cwd, model: nil,
                                    status: status, stage: stage, updatedAt: l.updated ?? Date().timeIntervalSince1970, live: true, canResume: false))
        }
        return out
    }

    static func lookup(_ native: String) -> (title: String, model: String?, cwd: String?, last: String?, path: String?)? {
        guard let r = threads(limit: 1, ids: [native]).first else { return nil }
        let p = safeRollout(r["rollout_path"])
        let a = p.map(activity)
        return (title(r), (r["model"] as? String) ?? a?.model, r["cwd"] as? String, a?.last, p)
    }

    static func messages(path: String?, native: String?, limit: Int) -> [AgentMessage] {
        guard let p = safeRollout(path) ?? native.flatMap({ lookup($0)?.path }) else { return [] }
        let limit = max(1, min(limit, 500))
        var budget = tailBytes
        while true {
            let (lines, atStart) = JSONL.tail(URL(fileURLWithPath: p), budget)
            let msgs = parse(lines)
            if msgs.count >= limit || atStart || budget >= historyMax { return Array(msgs.suffix(limit)) }
            budget *= 4
        }
    }

    static func contentText(_ c: Any?) -> String {
        if let s = c as? String { return s }
        guard let a = c as? [[String: Any]] else { return "" }
        return a.filter { ["text", "input_text", "output_text"].contains(($0["type"] as? String ?? "").lowercased()) }
            .compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func parse(_ entries: [[String: Any]]) -> [AgentMessage] {
        let hasItems = entries.contains { e in
            e["type"] as? String == "event_msg" && ["item_completed", "user_message", "agent_message"].contains((e["payload"] as? [String: Any])?["type"] as? String ?? "")
        }
        var out: [AgentMessage] = []
        var recent: [String] = []
        func emit(_ id: String, _ role: String, _ text: String, _ ts: Double, _ tool: String? = nil) {
            guard !text.isEmpty else { return }
            let key = role + "\u{1f}" + text
            if recent.contains(key) { return }
            recent.append(key); if recent.count > 12 { recent.removeFirst() }
            out.append(AgentMessage(id: id, role: role, text: text, ts: ts, tool: tool))
        }
        // forked children start with the parent's copied context: skip up to the child's own first task_started
        var ownStart = 0
        let metas = entries.indices.filter { entries[$0]["type"] as? String == "session_meta" }
        if let first = metas.first, first == 0 {
            let own = (entries[0]["payload"] as? [String: Any])?["id"] as? String
            let foreign = metas.filter { let i = (entries[$0]["payload"] as? [String: Any])?["id"] as? String; return i != nil && i != own }
            if let f = foreign.last {
                ownStart = (f..<entries.count).first { (entries[$0]["payload"] as? [String: Any])?["type"] as? String == "task_started" && entries[$0]["type"] as? String == "event_msg" } ?? 0
            }
        }
        for (n, e) in entries.enumerated() where n >= ownStart {
            let pl = e["payload"] as? [String: Any] ?? [:]
            let ts = ISO.parse(e["timestamp"]) ?? 0
            let typ = e["type"] as? String, pt = pl["type"] as? String
            if typ == "event_msg" {
                switch pt {
                case "item_completed":
                    guard let it = pl["item"] as? [String: Any] else { break }
                    let iid = (it["id"] as? String) ?? "\(n)"
                    switch it["type"] as? String {
                    case "UserMessage": let t = contentText(it["content"]); if !isInjected(t) { emit(iid, "user", AgentText.clean(t), ts) }
                    case "AgentMessage": emit(iid, "assistant", AgentText.clean(contentText(it["content"])), ts)
                    case "CommandExecution":
                        let c = it["command"]
                        let cmd = (c as? [String])?.joined(separator: " ") ?? (c as? String) ?? ""
                        let code = it["exit_code"] as? Int
                        emit(iid, "tool", AgentText.clean("$ \(cmd)" + (code != nil && code != 0 ? " (exit \(code!))" : ""), AgentText.maxTool), ts, "shell")
                    case "FileChange":
                        let names = ((it["changes"] as? [String: Any])?.keys.map { ($0 as NSString).lastPathComponent } ?? []).sorted()
                        emit(iid, "tool", AgentText.clean("Edited " + names.prefix(8).joined(separator: ", ") + (names.count > 8 ? " …" : ""), AgentText.maxTool), ts, "apply_patch")
                    case "McpToolCall":
                        let name = "\(it["server"] ?? "").\(it["tool"] ?? "")"
                        emit(iid, "tool", name, ts, name)
                    case "SubAgentActivity":
                        emit(iid, "tool", "Subagent \((it["agent_path"] ?? it["agent_thread_id"]) ?? "subagent")", ts, "subagent")
                    case "ContextCompaction": emit(iid, "system", "Context compacted", ts)
                    default: break
                    }
                case "user_message": if let m = pl["message"] as? String, !isInjected(m) { emit("um\(n)", "user", AgentText.clean(m), ts) }
                case "agent_message": if let m = pl["message"] as? String { emit("am\(n)", "assistant", AgentText.clean(m), ts) }
                case "turn_aborted": emit("ab\(n)", "system", "Turn interrupted", ts)
                case "error": emit("er\(n)", "system", "Error: " + AgentText.clean("\(pl["message"] ?? "unknown error")", AgentText.maxTool), ts)
                case "task_complete": if let m = pl["last_agent_message"] as? String { emit("tc\(n)", "assistant", AgentText.clean(m), ts) }
                default: break
                }
            } else if typ == "response_item" && pt == "message" && pl["role"] as? String == "user" && hasItems {
                let t = contentText(pl["content"])
                if !isInjected(t) { emit((pl["id"] as? String) ?? "ri\(n)", "user", AgentText.clean(t), ts) }
            } else if typ == "response_item" && !hasItems {
                if pt == "message", let role = pl["role"] as? String, role == "user" || role == "assistant" {
                    let t = contentText(pl["content"])
                    if role == "user" && isInjected(t) { continue }
                    emit((pl["id"] as? String) ?? "ri\(n)", role, AgentText.clean(t), ts)
                } else if pt == "function_call" || pt == "custom_tool_call" {
                    let name = pl["name"] as? String ?? "tool"
                    let arg = pt == "function_call" ? pl["arguments"] : pl["input"]
                    emit((pl["call_id"] as? String) ?? "\(n)", "tool", AgentText.clean("\(name): \(arg ?? "")", AgentText.maxTool), ts, name)
                }
            }
        }
        return out
    }

    // MARK: subagents (thread_spawn_edges, BFS up to depth 4)

    static func children(_ parents: [AgentSession], now: Double) -> [AgentSession] {
        let byNative = Dictionary(parents.filter { $0.agent == "codex" }.compactMap { p in p.nativeId.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        guard !byNative.isEmpty, !columns("thread_spawn_edges").isEmpty else { return [] }
        let cols = columns()
        let want = wanted.filter(cols.contains).map { "t.\($0)" }.joined(separator: ", ")
        var ids = byNative.mapValues(\.id)
        var liveRoots = Set(byNative.filter { $0.value.live }.keys)
        var frontier = Array(byNative.keys), seen = Set(frontier), depth = 1
        var rows: [[String: Any]] = []
        while !frontier.isEmpty && depth <= 4 && rows.count < 200 {
            let sql = "SELECT e.parent_thread_id AS _parent, \(want) FROM thread_spawn_edges e JOIN threads t ON t.id = e.child_thread_id WHERE e.parent_thread_id IN (\(frontier.map { _ in "?" }.joined(separator: ","))) ORDER BY COALESCE(t.updated_at_ms, t.updated_at * 1000) DESC LIMIT ?"
            var next: [String] = []
            var perParent: [String: Int] = [:]
            for var r in query(sql, frontier + [200 - rows.count]) {
                guard let id = r["id"] as? String, !seen.contains(id), let par = r["_parent"] as? String, perParent[par, default: 0] < 40 else { continue }
                perParent[par, default: 0] += 1
                seen.insert(id); r["_depth"] = depth; rows.append(r); next.append(id)
            }
            frontier = next; depth += 1
        }
        guard !rows.isEmpty else { return [] }
        let daemon = CodexDaemon.loaded() ?? [:]
        var out: [AgentSession] = []
        for r in rows {
            let tid = r["id"] as! String, par = r["_parent"] as! String
            ids[tid] = "codex:\(tid)"
            let parentLive = liveRoots.contains(par)
            if parentLive { liveRoots.insert(tid) }
            let rollout = safeRollout(r["rollout_path"])
            let info = rollout.map(activity)
            var status: String, stage: String?
            if let l = daemon[tid] { (status, stage) = daemonStatus(l); stage = stage ?? info?.doing }
            else if let info {
                switch info.state {
                case "complete": status = "completed"
                case "error": status = "error"; stage = info.error
                case "aborted": status = "idle"; stage = "Interrupted"
                default:
                    if now - info.mtime <= 90 { status = "working"; stage = info.doing }
                    else if !parentLive { status = "offline"; stage = "Stopped without a final report" }
                    else { status = "unknown"; stage = "No recent activity" }
                }
            } else { status = "unknown"; stage = "No rollout recorded" }
            let nick = r["agent_nickname"] as? String
            let task = (r["first_user_message"] as? String).map { AgentText.clip(AgentText.clean($0), 600) }
            out.append(AgentSession(id: "codex:\(tid)", agent: "codex", nativeId: tid, title: AgentText.oneLine(nick ?? title(r), 80),
                                    cwd: (r["cwd"] as? String) ?? byNative[par]?.cwd, model: (r["model"] as? String) ?? info?.model,
                                    status: status, stage: stage, updatedAt: max(updated(r) ?? 0, info?.lastTs ?? 0),
                                    lastMessage: info?.last ?? info?.doing, live: status == "working", canResume: false,
                                    parentId: ids[par], isSubagent: true, agentName: nick, agentRole: r["agent_role"] as? String,
                                    task: task, transcript: rollout))
        }
        return out
    }
}

/// Read-only status queries to the Codex app-server daemon (JSON-RPC over a WebSocket on a unix socket):
/// `initialize`, `thread/loaded/list`, `thread/read` (no turns). Never starts a turn or uses quota.
enum CodexDaemon {
    struct Thread { let status: String?; let flags: [String]; let originator: String?; let cwd: String?; let updated: Double? }
    private static var cache: (at: CFTimeInterval, value: [String: Thread]?) = (0, nil)
    private static let lock = NSLock()

    static func loaded(maxAge: Double = 4) -> [String: Thread]? {
        lock.lock(); defer { lock.unlock() }
        if let v = cache.value, CACurrentMediaTime() - cache.at < maxAge { return v }
        let path = CodexSource.home.appendingPathComponent("app-server-control/app-server-control.sock").resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: path), let ws = UnixWS(path: path) else { return nil }
        defer { ws.close() }
        var out: [String: Thread] = [:]
        do {
            _ = try ws.call(1, "initialize", ["clientInfo": ["name": "phonecast-status", "title": "PhoneCast", "version": "1"],
                                               "capabilities": ["optOutNotificationMethods": [String]()]])
            ws.send(["method": "initialized"])
            var ids: [String] = []
            var cursor: String?
            for page in 0..<5 {
                var p: [String: Any] = ["limit": 200]
                if let cursor { p["cursor"] = cursor }
                let r = try ws.call(2 + page, "thread/loaded/list", p)
                ids += (r["data"] as? [String]) ?? []
                cursor = r["nextCursor"] as? String
                if cursor == nil { break }
            }
            for (n, tid) in ids.prefix(40).enumerated() {
                let r = try ws.call(100 + n, "thread/read", ["threadId": tid, "includeTurns": false])
                let th = r["thread"] as? [String: Any] ?? [:]
                let st = th["status"] as? [String: Any]
                out[tid] = Thread(status: st?["type"] as? String, flags: st?["activeFlags"] as? [String] ?? [],
                                  originator: th["originator"] as? String, cwd: th["cwd"] as? String, updated: ISO.parse(th["updatedAt"]))
            }
        } catch {
            if out.isEmpty { return nil }
        }
        cache = (CACurrentMediaTime(), out)
        return out
    }
}

/// Minimal blocking WebSocket client over a unix domain socket (text frames, client masking).
final class UnixWS {
    private let fd: Int32
    private var buf = [UInt8]()
    struct Err: Error { let s: String }

    init?(path: String, timeout: Int = 6) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() { p[i] = b } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { Darwin.close(fd); return nil }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        writeAll(Array("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        var head = [UInt8]()
        while true {
            guard fill() else { Darwin.close(fd); return nil }
            if let r = find(buf, [13, 10, 13, 10]) { head = Array(buf[..<r]); buf.removeFirst(r + 4); break }
            if buf.count > 16384 { Darwin.close(fd); return nil }
        }
        guard String(decoding: head, as: UTF8.self).split(separator: "\r\n").first?.contains(" 101 ") == true else { Darwin.close(fd); return nil }
    }

    private func find(_ a: [UInt8], _ n: [UInt8]) -> Int? {
        guard a.count >= n.count else { return nil }
        for i in 0...(a.count - n.count) where Array(a[i..<i + n.count]) == n { return i }
        return nil
    }

    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 { return false }
        buf += tmp[..<n]
        return true
    }

    private func take(_ n: Int) throws -> [UInt8] {
        while buf.count < n { guard fill() else { throw Err(s: "closed") } }
        let out = Array(buf[..<n]); buf.removeFirst(n); return out
    }

    private func writeAll(_ b: [UInt8]) {
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            off += n
        }
    }

    private func frame(_ op: UInt8, _ payload: [UInt8]) {
        var h: [UInt8] = [0x80 | op]
        let n = payload.count
        if n < 126 { h.append(0x80 | UInt8(n)) }
        else if n < 65536 { h += [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xff)] }
        else { h.append(0x80 | 127); for s in stride(from: 56, through: 0, by: -8) { h.append(UInt8((n >> s) & 0xff)) } }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        writeAll(h + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    func send(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        frame(0x1, Array(d))
    }

    func recv() throws -> [String: Any]? {
        var message = [UInt8]()
        while true {
            let h = try take(2)
            let fin = h[0] & 0x80 != 0, op = h[0] & 0x0f
            var n = Int(h[1] & 0x7f)
            if n == 126 { let b = try take(2); n = Int(b[0]) << 8 | Int(b[1]) }
            else if n == 127 { n = try take(8).reduce(0) { $0 << 8 | Int($1) } }
            if n > 64 << 20 { throw Err(s: "frame too large") }
            let mask = h[1] & 0x80 != 0 ? try take(4) : nil
            var p = try take(n)
            if let mask { p = p.enumerated().map { $0.element ^ mask[$0.offset % 4] } }
            switch op {
            case 0x8: return nil
            case 0x9: frame(0xA, p); continue
            case 0x0, 0x1, 0x2:
                message += p
                if fin {
                    if let o = (try? JSONSerialization.jsonObject(with: Data(message))) as? [String: Any] { return o }
                    message = []
                }
            default: continue
            }
        }
    }

    func call(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            guard let m = try recv() else { throw Err(s: "closed") }
            if m["id"] as? Int == id && m["method"] == nil {
                if let e = m["error"] { throw Err(s: "\(e)") }
                return m["result"] as? [String: Any] ?? [:]
            }
            if m["method"] != nil, let rid = m["id"] { send(["id": rid, "error": ["code": -32601, "message": "unsupported"]]) }
        }
        throw Err(s: "timeout")
    }

    func close() { frame(0x8, []); Darwin.close(fd) }
}

/// Live model lists from the installed, logged-in CLIs. Claude: one SDK `initialize` control request to
/// `claude -p --input-format stream-json` (no message, no inference). Codex: `app-server` `model/list`.
/// The last good result is cached on disk and used (marked "cache") when live discovery fails.
enum AgentModels {
    static var cacheURL: URL { AgentTmux.home.appendingPathComponent("models.json") }
    private static var memory: (at: Double, value: [String: Any])?
    private static let lock = NSLock()

    static func list(refresh: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if !refresh, let m = memory, Date().timeIntervalSince1970 - m.at < 600 { return m.value }
        var results: [String: [String: Any]] = [:]
        let g = DispatchGroup(), rl = NSLock()
        for a in ["claude", "codex"] {
            DispatchQueue.global().async(group: g) {
                let r = discover(a)
                rl.lock(); results[a] = r; rl.unlock()
            }
        }
        _ = g.wait(timeout: .now() + 60)
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var agents: [[String: Any]] = []
        for a in ["claude", "codex"] {
            var e = results[a] ?? ["id": a, "available": false, "models": [], "error": "discovery did not finish"]
            if let ms = e["models"] as? [[String: Any]], !ms.isEmpty, e["source"] as? String == "live" { cache[a] = ms }
            else if let ms = cache[a] as? [[String: Any]] { e["models"] = ms; e["source"] = "cache" }
            agents.append(e)
        }
        if let d = try? JSONSerialization.data(withJSONObject: cache) { try? d.write(to: cacheURL, options: .atomic) }
        let v: [String: Any] = ["agents": agents]
        memory = (Date().timeIntervalSince1970, v)
        return v
    }

    private static func discover(_ agent: String) -> [String: Any] {
        var e: [String: Any] = ["id": agent, "available": false, "models": [[String: Any]]()]
        guard let bin = AgentTmux.binary(agent) else { e["error"] = "\(agent) CLI not found"; return e }
        e["available"] = true
        do {
            e["models"] = try agent == "claude" ? claude(bin) : codex(bin)
            e["source"] = "live"
        } catch { e["error"] = "live discovery failed: \(error)" }
        return e
    }

    /// Talks newline-delimited JSON to a subprocess until `until` returns a value.
    private static func converse(_ bin: String, _ args: [String], first: [[String: Any]], until: (_ msg: [String: Any], _ send: ([String: Any]) -> Void) throws -> [[String: Any]]?) throws -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phonecast-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        p.currentDirectoryURL = dir
        var env = AgentTmux.loginEnv()
        for k in ["TMUX", "TMUX_PANE", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "PHONECAST_AGENT_ID", "AGENTDECK_SESSION_ID"] { env.removeValue(forKey: k) }
        p.environment = env
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        defer {
            try? inp.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        }
        let send: ([String: Any]) -> Void = { o in
            if let d = try? JSONSerialization.data(withJSONObject: o) { inp.fileHandleForWriting.write(d + Data([10])) }
        }
        first.forEach(send)
        let deadline = Date().addingTimeInterval(45)
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        defer { killer.cancel() }
        var pending = Data()
        let h = out.fileHandleForReading
        while Date() < deadline {
            let chunk = h.availableData
            if chunk.isEmpty { throw UnixWS.Err(s: "\(agent(bin)) exited early") }
            pending += chunk
            while let nl = pending.firstIndex(of: 10) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if let r = try until(o, send) { return r }
            }
        }
        throw UnixWS.Err(s: "timed out")
    }

    private static func agent(_ bin: String) -> String { (bin as NSString).lastPathComponent }

    static func claude(_ bin: String) throws -> [[String: Any]] {
        let raw = try converse(bin, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                     "--setting-sources", "local", "--strict-mcp-config", "--no-session-persistence"],
                               first: [["type": "control_request", "request_id": "pc-init", "request": ["subtype": "initialize"]]]) { m, _ in
            guard m["type"] as? String == "control_response", let r = m["response"] as? [String: Any] else { return nil }
            if r["subtype"] as? String == "error" { throw UnixWS.Err(s: "\(r["error"] ?? "initialize failed")") }
            guard let ms = (r["response"] as? [String: Any])?["models"] as? [[String: Any]] else { throw UnixWS.Err(s: "no model list") }
            return ms
        }
        return raw.compactMap { m in
            guard let v = m["value"] as? String else { return nil }
            var desc = m["description"] as? String
            if let r = m["resolvedModel"] as? String, r != v { desc = desc.map { "\($0) · \(r)" } ?? r }
            return ["id": v, "label": (m["displayName"] as? String) ?? v, "desc": desc ?? "", "default": v == "default"]
        }
    }

    static func codex(_ bin: String) throws -> [[String: Any]] {
        var models: [[String: Any]] = []
        var page = 0
        _ = try converse(bin, ["app-server"], first: [["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "phonecast", "title": "PhoneCast", "version": "1"]]]]) { m, send in
            if m["method"] != nil, let id = m["id"] { send(["id": id, "error": ["code": -32601, "message": "unsupported"]]); return nil }
            guard let id = m["id"] as? Int else { return nil }
            if let e = m["error"] { throw UnixWS.Err(s: "\(e)") }
            let res = m["result"] as? [String: Any] ?? [:]
            if id == 1 {
                send(["method": "initialized"])
                send(["id": 2, "method": "model/list", "params": [String: Any]()])
                return nil
            }
            models += (res["data"] as? [[String: Any]]) ?? []
            page += 1
            if let c = res["nextCursor"] as? String, page < 20 { send(["id": 2 + page, "method": "model/list", "params": ["cursor": c]]); return nil }
            return models
        }
        return models.compactMap { m in
            guard let id = (m["model"] ?? m["id"]) as? String, m["hidden"] as? Bool != true else { return nil }
            return ["id": id, "label": (m["displayName"] as? String) ?? id, "desc": (m["description"] as? String) ?? "", "default": m["isDefault"] as? Bool ?? false]
        }
    }
}
