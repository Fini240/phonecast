import Foundation
import IOKit.pwr_mgt
import CryptoKit

/// The agents brain on the Mac: merges managed tmux panes with discovered Claude Code / Codex chats,
/// tracks status changes (completed / error / needs you), keeps the Mac awake while agents work,
/// and answers the phone (AGENT_REQ) / pushes updates to it (AGENT_EVENT) over the PhoneCast link.
/// Polling is adaptive: 1 s while something is working or the phone watches a chat, 4 s otherwise;
/// transcripts are only re-read when their mtime/size changes, panes only re-captured when tmux
/// reports activity (or while they're busy).
final class AgentHub: ObservableObject {
    static let shared = AgentHub()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var asks: [String: [String: Any]] = [:]   // session id -> open question (managed panes)
    @Published private(set) var integrationInstalled = false
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "agentsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "agentsEnabled"); if enabled { kick() } else { releaseAwake() } }
    }

    /// Where events for the phone go (set by Hub when the link is up).
    var emit: ((_ json: [String: Any]) -> Void)?
    var phoneConnected = false { didSet { let on = phoneConnected; work.async { if on { self.lastSentDigest = ""; self.poll() } else { self.watched = nil } } } }

    let tmux = AgentTmux()
    private let work = DispatchQueue(label: "phonecast.agents", qos: .utility)
    private let actions = DispatchQueue(label: "phonecast.agents.actions", qos: .userInitiated, attributes: .concurrent)
    private var locks: [String: NSLock] = [:]
    private let locksLock = NSLock()
    private var timer: DispatchSourceTimer?

    // state on `work`
    private var screens: [String: (activity: Double, at: Double, state: AgentScreen.State)] = [:]
    private var tracks: [String: Track] = [:]
    private var baselineDone = false
    private var lastSentDigest = ""
    private var watched: String?
    private var sentIds: [String] = []
    private var watchStamp: FileStamp?
    private var lastAlert: [String: Double] = [:]
    private var awake: IOPMAssertionID = 0
    private var lastAsks: [String: [String: Any]] = [:]
    private var budgetHit = Set<String>()
    /// Sleep inhibitors held on other machines while their agents work (Linux: systemd-inhibit).
    private var inhibitors: [String: Process] = [:]
    /// A browser asked for the list lately: keep polling fast like when the phone watches.
    var webSeen = Date.distantPast
    private var lastChange: [String: (sig: String, at: Double)] = [:]
    private var stuckAlerted = Set<String>()
    private var limitPlanned: [String: Date] = [:]

    /// Stuck alerts (working but nothing changes) and continue-after-usage-limit.
    private func recovery(_ list: [AgentSession], now: Double) {
        for s in list where s.managed && !s.isSubagent {
            let sig = "\(s.updatedAt)|\(s.stage ?? "")|\(s.transcript.flatMap(fileStamp)?.size ?? 0)"
            let changed = lastChange[s.id]?.sig != sig
            if changed { lastChange[s.id] = (sig, now); stuckAlerted.remove(s.id) }
            let quiet = now - (lastChange[s.id]?.at ?? now)
            if s.status == "working", quiet > Double(AgentRecovery.stuckMinutes * 60), stuckAlerted.insert(s.id).inserted {
                var x = s; x.lastMessage = "No progress for \(Int(quiet / 60)) min (\(s.stage ?? "working"))"
                alert("stuck", x, nil)
            }
            // usage limits show up in the transcript's last message or on screen
            guard s.status != "working", changed else { continue }
            let text = [s.lastMessage ?? "", screens[s.id].map { _ in (try? tmux.preview(s.id).suffix(1500)).map(String.init) ?? "" } ?? ""].joined(separator: "\n")
            guard text.range(of: "limit", options: .caseInsensitive) != nil, let at = AgentLimits.resetTime(in: text) else { continue }
            if limitPlanned[s.id] == at { continue }
            limitPlanned[s.id] = at
            let auto = AgentRecovery.autoContinue(s.id)
            var x = s
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            x.lastMessage = auto ? "Usage limit reached. Continues by itself at \(f.string(from: at))." : "Usage limit reached; resets at \(f.string(from: at))."
            alert("limit", x, nil)
            if auto {
                let sid = s.id
                work.asyncAfter(deadline: .now() + max(30, at.timeIntervalSinceNow + 60)) { [weak self] in
                    guard let self, self.limitPlanned[sid] == at else { return }
                    self.actions.async {
                        let l = self.lock(sid); l.lock(); defer { l.unlock() }
                        do { try self.tmux.send(sid, "continue") } catch { self.emit?(["e": "alert", "kind": "error", "sid": sid, "title": s.title, "body": "Couldn't continue after the limit: \(error)"]) }
                    }
                }
            }
        }
    }

    func usage(_ s: AgentSession) -> [String: Any]? {
        var u = s.agent == "claude" ? AgentUsage.claude(native: s.nativeId, path: s.transcript) : AgentUsage.codex(path: s.transcript)
        if let b = AgentBudgets.all()[s.id] { u?["budget"] = b }
        return u
    }
    private let snapLock = NSLock()
    private var _latest: [AgentSession] = []
    /// Latest list, safe from any thread.
    var latest: [AgentSession] { snapLock.lock(); defer { snapLock.unlock() }; return _latest }

    struct Track { var confirmed: String; var lastDefinite: String?; var pending: String?; var pendingSince = 0.0 }

    func start() {
        integrationInstalled = AgentShell.installed()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 1, repeating: 1)
        var tick = 0
        t.setEventHandler { [weak self] in
            guard let self, self.enabled else { return }
            tick += 1
            let fast = self.watched != nil || Date().timeIntervalSince(self.webSeen) < 10 || self.tracks.values.contains { $0.confirmed == "working" || $0.confirmed == "needs_input" }
            if fast || tick % 4 == 0 { self.poll() }
            self.drainNotifySpool()
        }
        t.resume()
        timer = t
    }

    func kick() { work.async { [weak self] in self?.poll() } }

    private func lock(_ sid: String) -> NSLock {
        locksLock.lock(); defer { locksLock.unlock() }
        if let l = locks[sid] { return l }
        let l = NSLock(); locks[sid] = l; return l
    }

    // MARK: polling

    private func poll() {
        let now = Date().timeIntervalSince1970
        let panes = tmux.panes().filter { !$0.dead }
        let live = ClaudeSource.liveRegistry()
        var discovered = ClaudeSource.discover(live: live) + CodexSource.discover()
        let tops = discovered
        discovered += ClaudeSource.children(tops, now: now) + CodexSource.children(tops, now: now)

        // managed panes: re-capture only when tmux saw output, while busy, or every 8 s
        var managed: [AgentSession] = []
        var newAsks: [String: [String: Any]] = [:]
        for p in panes {
            let prev = screens[p.id]
            let busy = prev.map { $0.state.working || $0.state.dialog != nil } ?? true
            var st: AgentScreen.State
            if let prev, prev.activity == p.activity, !busy, now - prev.at < 8 { st = prev.state }
            else if lock(p.id).try() { st = tmux.observe(p); lock(p.id).unlock(); screens[p.id] = (p.activity, now, st) }
            else { st = prev?.state ?? AgentScreen.State() }
            let native = tmux.nativeId(p)
            let meta: (title: String, model: String?, last: String?, path: String?)? = native.flatMap { n in
                if p.agent == "claude" { return ClaudeSource.lookup(n).map { ($0.title, $0.model, $0.last, $0.path) } }
                return CodexSource.lookup(n).map { ($0.title, $0.model, $0.last, $0.path) }
            }
            var s = AgentSession(id: p.id, agent: p.agent, nativeId: native, title: meta?.title ?? ((p.cwd as NSString).lastPathComponent.nilIfEmpty ?? p.agent),
                                 cwd: p.cwd, model: meta?.model, status: st.status,
                                 stage: st.working ? st.activity : st.dialog?.title, updatedAt: max(p.activity, p.created),
                                 managed: true, lastMessage: meta?.last, live: true, canResume: false, attached: p.attached, transcript: meta?.path)
            s.mode = st.mode
            s.host = p.host
            if let h = p.host { s.title = "\(((p.cwd as NSString).lastPathComponent.nilIfEmpty ?? p.agent)) · \(h.split(separator: "@").last ?? Substring(h))" }
            if let d = st.dialog {
                newAsks[p.id] = ["id": d.approvalId, "title": AgentText.clip(AgentText.redact(d.title), 300),
                                 "detail": AgentText.clip(AgentText.redact(d.detail), 4000),
                                 "choices": d.options.map { ["id": d.choiceId($0), "label": AgentText.clip(AgentText.redact($0.label), 300)] }]
                s.stage = d.title
            }
            managed.append(s)
        }
        screens = screens.filter { k, _ in panes.contains { $0.id == k } }

        // managed entries win; their discovered twin folds in (keeps transcript time/last message)
        var byNative: [String: Int] = [:]
        for (i, m) in managed.enumerated() { if let n = m.nativeId { byNative[m.agent + n] = i } }
        var out = managed
        var alias: [String: String] = [:]
        for d in discovered {
            if !d.isSubagent, let n = d.nativeId, let i = byNative[d.agent + n] {
                if out[i].status == "unknown" && ["working", "idle", "needs_input"].contains(d.status) { out[i].status = d.status }
                out[i].updatedAt = max(out[i].updatedAt, d.updatedAt)
                if out[i].lastMessage == nil { out[i].lastMessage = d.lastMessage }
                if out[i].transcript == nil { out[i].transcript = d.transcript }
                alias[d.id] = out[i].id
            } else { out.append(d) }
        }
        for i in out.indices { if let p = out[i].parentId, let a = alias[p] { out[i].parentId = a } }
        out.sort { $0.updatedAt > $1.updatedAt }
        // usage for the chats that matter now (live, managed, watched); history stays cheap
        let budgets = AgentBudgets.all()
        for i in out.indices where !out[i].isSubagent && (out[i].live || out[i].managed || out[i].id == watched || budgets[out[i].id] != nil) {
            out[i].usage = usage(out[i])
            if let b = budgets[out[i].id], let u = out[i].usage, let why = AgentBudgets.exceeded(b, u) {
                if budgetHit.insert(out[i].id).inserted {
                    var s = out[i]; s.lastMessage = why
                    alert("budget", s, nil)
                    if b["stop"] as? Bool == true, s.managed, s.status == "working" {
                        let sid = s.id
                        actions.async { let l = self.lock(sid); l.lock(); defer { l.unlock() }; try? self.tmux.stop(sid) }
                    }
                }
                out[i].overBudget = why
            } else { budgetHit.remove(out[i].id) }
        }

        // transitions -> alerts (first sight is a baseline; quiet idle after work is debounced 6 s)
        for s in out where !s.isSubagent {
            if let kind = observe(s.id, s.status, now), baselineDone { alert(kind, s, newAsks[s.id]) }
        }
        for (sid, a) in newAsks where lastAsks[sid]?["id"] as? String != a["id"] as? String && baselineDone {
            if let s = out.first(where: { $0.id == sid }) { alert("input", s, a) }
        }
        recovery(out, now: now)
        // other machines: keep them awake while their agents work (released when they're idle)
        let busyHosts = Set(out.filter { $0.status == "working" || $0.status == "needs_input" }.compactMap(\.host))
        for h in busyHosts where inhibitors[h]?.isRunning != true {
            inhibitors[h] = AgentTmux.sshBackground(h, "command -v systemd-inhibit >/dev/null && exec systemd-inhibit --what=sleep:idle --mode=block --who=PhoneCast --why='AI agent working' sleep 900")
        }
        for (h, p) in inhibitors where !busyHosts.contains(h) { if p.isRunning { p.terminate() }; inhibitors.removeValue(forKey: h) }
        tracks = tracks.filter { k, _ in out.contains { $0.id == k } }
        baselineDone = true
        lastAsks = newAsks
        snapLock.lock(); _latest = out; snapLock.unlock()

        let working = out.contains { !$0.isSubagent && $0.status == "working" }
        DispatchQueue.main.async {
            self.sessions = out
            self.asks = newAsks
            self.setAwake(working)
        }
        pushToPhone(out, newAsks)
    }

    private func observe(_ sid: String, _ status: String, _ now: Double) -> String? {
        let definite: Set<String> = ["working", "idle", "needs_input", "completed", "error"]
        guard var t = tracks[sid] else {
            tracks[sid] = Track(confirmed: status, lastDefinite: definite.contains(status) ? status : nil); return nil
        }
        defer { tracks[sid] = t }
        if status == t.confirmed { t.pending = nil; return nil }
        if (status == "idle" || status == "completed") && t.lastDefinite == "working" {
            if t.pending != status { t.pending = status; t.pendingSince = now; return nil }
            if now - t.pendingSince < 6 { return nil }
        }
        let prev = t.lastDefinite
        t.confirmed = status; t.pending = nil
        guard definite.contains(status) else { return nil }
        t.lastDefinite = status
        if status == prev { return nil }
        if (status == "idle" || status == "completed") && prev == "working" { return "completed" }
        if status == "error" { return "error" }
        if status == "needs_input" { return "input" }
        return nil
    }

    private func alert(_ kind: String, _ s: AgentSession, _ ask: [String: Any]?) {
        let key = "\(s.id)|\(kind)|\(ask?["id"] as? String ?? "")"
        let now = Date().timeIntervalSince1970
        if now - (lastAlert[key] ?? 0) < (kind == "input" ? 30 : 10) { return }
        lastAlert[key] = now
        if lastAlert.count > 300 { lastAlert = lastAlert.filter { now - $0.value < 3600 } }
        let body: String
        switch kind {
        case "budget": body = s.lastMessage ?? "Over budget"
        case "completed": body = s.lastMessage ?? "Finished"
        case "error": body = s.lastMessage ?? "The agent reported an error"
        default: body = (ask?["title"] as? String) ?? s.stage ?? "Waiting for you"
        }
        var o: [String: Any] = ["e": "alert", "kind": kind, "sid": s.id, "title": s.title, "body": AgentText.clip(body, 600), "agent": s.agent, "managed": s.managed]
        if let ask { o["ask"] = ask }
        emit?(o)
    }

    // MARK: phone

    private func pushToPhone(_ list: [AgentSession], _ asks: [String: [String: Any]]) {
        guard phoneConnected, let emit else { return }
        let rows = listRows(list, asks)
        if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
            let planSig = (try? JSONSerialization.data(withJSONObject: AgentUsage.plan(), options: [.sortedKeys])) ?? Data()
            let digest = SHA256.hash(data: d + planSig).map { String(format: "%02x", $0) }.joined()
            if digest != lastSentDigest {
                lastSentDigest = digest
                emit(["e": "sessions", "list": rows, "plan": AgentUsage.plan()])
            }
        }
        if let w = watched { pushWatched(w, list) }
    }

    /// Top-level chats + children of the listed ones; history beyond 80 stays on the Mac.
    func listRows(_ list: [AgentSession], _ asks: [String: [String: Any]]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var keep = Set<String>()
        for s in list where !s.isSubagent && (rows.count < 80 || s.live) {
            var j = s.json
            if let a = asks[s.id] { j["ask"] = a }
            rows.append(j); keep.insert(s.id)
        }
        for s in list where s.isSubagent && keep.contains(s.parentId ?? "") { rows.append(s.json) }
        return rows
    }

    private func pushWatched(_ sid: String, _ list: [AgentSession], reset: Bool = false) {
        guard let s = list.first(where: { $0.id == sid }) else { return }
        let st = s.transcript.flatMap(fileStamp)
        if !reset && st == watchStamp { return }
        watchStamp = st
        let msgs = messages(s, limit: reset ? 120 : 60)
        let fresh = reset ? msgs : msgs.filter { !sentIds.contains($0.id) }
        if reset { sentIds = [] }
        if fresh.isEmpty && !reset { return }
        sentIds += fresh.map(\.id)
        if sentIds.count > 2000 { sentIds.removeFirst(sentIds.count - 2000) }
        emit?(["e": "msgs", "sid": sid, "reset": reset, "add": fresh.map(\.json), "more": reset && msgs.count >= 120])
    }

    func messages(_ s: AgentSession, limit: Int) -> [AgentMessage] {
        if s.agent == "claude" { return ClaudeSource.messages(path: s.transcript, native: s.nativeId, limit: limit, sidechain: s.isSubagent) }
        return CodexSource.messages(path: s.transcript, native: s.nativeId, limit: limit)
    }

    /// One AGENT_REQ from the phone: {id, m, p}. `reply` gets {id, ok, data | message}.
    func handle(_ req: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let id = req["id"] ?? 0
        let m = req["m"] as? String ?? ""
        let p = req["p"] as? [String: Any] ?? [:]
        let ok: (Any) -> Void = { reply(["id": id, "ok": true, "data": $0]) }
        let fail: (String) -> Void = { reply(["id": id, "ok": false, "message": $0]) }
        let sid = p["sid"] as? String ?? ""
        let run: (@escaping () throws -> Any) -> Void = { body in
            self.actions.async {
                do { ok(try body()) } catch { fail("\(error)") }
                self.kick()
            }
        }
        switch m {
        case "hello":
            work.async { self.lastSentDigest = ""; self.poll() }
            ok(["installed": AgentShell.installed(), "enabled": enabled, "tap": AgentUsage.tapInstalled()])
        case "list":
            // browsers poll this (no push): the same rows the phone gets, plus the plan limits
            work.async {
                if !self.enabled { ok(["list": [], "plan": [:]]); return }
                ok(["list": self.listRows(self.latest, self.lastAsks), "plan": AgentUsage.plan(), "installed": AgentShell.installed(), "tap": AgentUsage.tapInstalled()])
            }
            webSeen = Date()
        case "messages":
            work.async {
                guard let s = self.latest.first(where: { $0.id == sid }) else { fail("Chat not found."); return }
                let n = min(500, max(20, p["limit"] as? Int ?? 150))
                let msgs = self.messages(s, limit: n)
                ok(["add": msgs.map(\.json), "more": msgs.count >= n])
            }
        case "watch":
            work.async {
                self.watched = sid.isEmpty ? nil : sid
                self.watchStamp = nil
                if !sid.isEmpty { self.pushWatched(sid, self.latest, reset: true) }
            }
            ok(true)
        case "older":
            work.async {
                guard let s = self.latest.first(where: { $0.id == sid }) else { fail("Chat not found."); return }
                let n = min(500, (p["have"] as? Int ?? 120) + 150)
                ok(["add": self.messages(s, limit: n).map(\.json), "more": n < 500])
            }
        case "terminal": run { try self.tmux.preview(sid) }
        case "send":
            run {
                var target = sid
                if !target.hasPrefix("t:") { target = try self.resume(sid) }
                let l = self.lock(target); l.lock(); defer { l.unlock() }
                var text = p["text"] as? String ?? ""
                let paths = try self.saveImages(p["images"] as? [String] ?? [])
                if !paths.isEmpty { text += (text.isEmpty ? "" : "\n\n") + paths.map { "Attached image: \($0)" }.joined(separator: "\n") }
                var files: [String] = []
                for f in (p["files"] as? [[String: Any]]) ?? [] {
                    guard let b = f["b64"] as? String, let d = Data(base64Encoded: b), d.count < 25 << 20 else { throw AgentTmux.Fail("A file couldn't be read.") }
                    files.append(try AgentFiles.saveUpload(name: f["name"] as? String ?? "file", data: d))
                }
                if !files.isEmpty { text += (text.isEmpty ? "" : "\n\n") + files.map { "Attached file: \($0)" }.joined(separator: "\n") }
                try self.tmux.send(target, text)
                return ["sid": target]
            }
        case "stop": run { let l = self.lock(sid); l.lock(); defer { l.unlock() }; try self.tmux.stop(sid); return true }
        case "open": run { try self.tmux.openInTerminal(sid); return true }
        case "key": run { try self.tmux.key(sid, p["key"] as? String ?? ""); return true }
        case "approve":
            run {
                let l = self.lock(sid); l.lock(); defer { l.unlock() }
                try self.tmux.approve(sid, approval: p["ask"] as? String ?? "", choice: p["choice"] as? String ?? "")
                return true
            }
        case "resume": run { ["sid": try self.resume(sid)] }
        case "start":
            run {
                let host = (p["host"] as? String)?.nilIfEmpty
                var cwd = p["cwd"] as? String ?? "~"
                if host == nil, p["worktree"] as? Bool == true { cwd = try AgentWorktree.prepare(cwd.expandingTilde) }
                let t = try self.tmux.start(agent: p["agent"] as? String ?? "claude", cwd: host == nil ? cwd.expandingTilde : cwd,
                                            model: (p["model"] as? String)?.nilIfEmpty, prompt: p["prompt"] as? String, host: host)
                return ["sid": t]
            }
        case "changes":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }), let cwd = s.cwd else { throw AgentTmux.Fail("Chat not found.") }
                return try AgentGit.changes(cwd)
            }
        case "diff":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }), let cwd = s.cwd else { throw AgentTmux.Fail("Chat not found.") }
                return try AgentGit.diff(cwd, p["path"] as? String ?? "")
            }
        case "git":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }), let cwd = s.cwd else { throw AgentTmux.Fail("Chat not found.") }
                return try AgentGit.act(cwd, p["op"] as? String ?? "", p)
            }
        case "command":
            // slash commands are typed into the TUI like a message (/compact, /model sonnet, /effort high, …)
            run {
                let cmd = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard cmd.hasPrefix("/"), !cmd.contains("\n") else { throw AgentTmux.Fail("Not a command.") }
                let l = self.lock(sid); l.lock(); defer { l.unlock() }
                try self.tmux.send(sid, cmd)
                return true
            }
        case "live": run { try self.tmux.live(sid, lines: p["lines"] as? Int ?? 120) }
        case "type": run { try self.tmux.type(sid, p["text"] as? String ?? "", enter: p["enter"] as? Bool ?? false); return true }
        case "files", "file", "find":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }), let cwd = s.cwd else { throw AgentTmux.Fail("Chat not found.") }
                switch m {
                case "files": return try AgentFiles.list(cwd, p["path"] as? String ?? "")
                case "file": return try AgentFiles.read(cwd, p["path"] as? String ?? "")
                default: return ["files": AgentFiles.find(cwd, p["q"] as? String ?? "")]
                }
            }
        case "previews":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }) else { throw AgentTmux.Fail("Chat not found.") }
                var text = self.messages(s, limit: 40).map(\.text).joined(separator: "\n")
                if s.managed, let t = try? self.tmux.preview(sid) { text += "\n" + t.suffix(6000) }
                return ["ports": AgentPreview.ports(in: text)]
            }
        case "preview": run { ["port": Int(try AgentPreview.shared.open(UInt16(p["port"] as? Int ?? 0)))] }
        case "fork":
            run {
                guard let s = self.latest.first(where: { $0.id == sid }), let n = s.nativeId, let cwd = s.cwd, !s.isSubagent else { throw AgentTmux.Fail("This chat can't be forked.") }
                return ["sid": try self.tmux.start(agent: s.agent, cwd: cwd, model: nil, prompt: nil, resume: n, fork: true)]
            }
        case "recovery":
            if let g = p["global"] as? [String: Any] { AgentRecovery.set(global: g, chat: nil, nil) }
            if let c = p["chat"] as? [String: Any] { AgentRecovery.set(global: nil, chat: sid, c) }
            ok(["global": AgentRecovery.global, "continue": AgentRecovery.autoContinue(sid), "stuckMin": AgentRecovery.stuckMinutes])
        case "hosts":
            if let set = p["set"] as? [String] {
                UserDefaults.standard.set(set.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }, forKey: "agentHosts")
            }
            run {
                ["hosts": AgentTmux.hosts.map { h -> [String: Any] in
                    let (st, out) = AgentTmux.ssh(h, "\"${SHELL:-/bin/sh}\" -lic 'for t in tmux claude codex gemini opencode; do command -v $t >/dev/null && echo $t; done' 2>/dev/null", timeout: 10)
                    return ["host": h, "up": st != 255, "tools": String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)]
                }]
            }
        case "agents":
            run { ["agents": (["claude", "codex"] + AgentTmux.otherAgents).filter { AgentTmux.binary($0) != nil }] }
        case "mode": run { try self.tmux.key(sid, "btab"); return true }
        case "usage":
            work.async {
                guard let s = self.latest.first(where: { $0.id == sid }) else { fail("Chat not found."); return }
                ok(self.usage(s) ?? [:])
            }
        case "budget":
            var b: [String: Any] = [:]
            if let v = (p["usd"] as? NSNumber)?.doubleValue, v > 0 { b["usd"] = v }
            if let v = (p["tokens"] as? NSNumber)?.intValue, v > 0 { b["tokens"] = v }
            if !b.isEmpty { b["stop"] = p["stop"] as? Bool ?? false }
            AgentBudgets.set(sid, b.isEmpty ? nil : b)
            work.async { self.budgetHit.remove(sid); self.lastSentDigest = ""; self.poll() }
            ok(true)
        case "tap":
            run {
                if p["on"] as? Bool == false { try AgentUsage.removeTap() } else { try AgentUsage.installTap() }
                return AgentUsage.tapInstalled()
            }
        case "models": run { AgentModels.list(refresh: p["refresh"] as? Bool ?? false) }
        case "folders":
            work.async {
                var seen = Set<String>(), out: [String] = []
                for s in self.latest where !s.isSubagent { if let c = s.cwd, seen.insert(c).inserted { out.append(c) } }
                ok(["folders": Array(out.prefix(25)), "home": FileManager.default.homeDirectoryForCurrentUser.path])
            }
        default: fail("Unknown request.")
        }
    }

    /// Reopen a discovered chat once inside a managed pane (refuses chats still open in another terminal).
    func resume(_ sid: String) throws -> String {
        guard let s = latest.first(where: { $0.id == sid }) else { throw AgentTmux.Fail("Chat not found.") }
        if s.managed { return s.id }
        guard !s.isSubagent, let native = s.nativeId, let cwd = s.cwd else { throw AgentTmux.Fail("This chat can't be continued from here.") }
        if s.live { throw AgentTmux.Fail("This chat is open in a terminal PhoneCast doesn't manage. Close it there (or start it with the PhoneCast shell integration) to reply from here.") }
        return try tmux.start(agent: s.agent, cwd: cwd, model: nil, prompt: nil, resume: native)
    }

    private func saveImages(_ b64: [String]) throws -> [String] {
        guard !b64.isEmpty else { return [] }
        let dir = AgentTmux.home.appendingPathComponent("uploads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // prune week-old uploads
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d.timeIntervalSinceNow < -7 * 86400 { try? FileManager.default.removeItem(at: f) }
        }
        return try b64.prefix(6).map { s in
            guard let d = Data(base64Encoded: s), d.count < 12 << 20 else { throw AgentTmux.Fail("A picture couldn't be read.") }
            let ext: String
            if d.starts(with: [0x89, 0x50, 0x4e, 0x47]) { ext = "png" } else if d.starts(with: [0xff, 0xd8, 0xff]) { ext = "jpg" }
            else if d.count > 12, d[8..<12] == Data("WEBP".utf8) { ext = "webp" } else { throw AgentTmux.Fail("Only PNG, JPEG or WebP pictures.") }
            let u = dir.appendingPathComponent("img_\(UUID().uuidString.prefix(12).lowercased()).\(ext)")
            FileManager.default.createFile(atPath: u.path, contents: d, attributes: [.posixPermissions: 0o600])
            return u.path
        }
    }

    // MARK: agent-sent notifications (`pa notify "title" "body"` from inside a session)

    private func drainNotifySpool() {
        let dir = AgentTmux.home.appendingPathComponent("notify")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { return }
        for n in names.sorted() {
            let u = dir.appendingPathComponent(n)
            defer { try? FileManager.default.removeItem(at: u) }
            guard let d = try? Data(contentsOf: u), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let tag = o["id"] as? String ?? ""
            let s = latest.first { $0.id == "t:" + tag }
            emit?(["e": "alert", "kind": "note", "sid": s?.id ?? "", "title": AgentText.clip(o["title"] as? String ?? s?.title ?? "Agent", 200),
                   "body": AgentText.clip(AgentText.redact(o["body"] as? String ?? ""), 600), "agent": s?.agent ?? "", "managed": s?.managed ?? false])
        }
    }

    // MARK: keep awake while agents work (display may sleep)

    private func setAwake(_ on: Bool) {
        if on && awake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "PhoneCast: AI agent working" as CFString, &awake)
        } else if !on { releaseAwake() }
    }
    private func releaseAwake() { if awake != 0 { IOPMAssertionRelease(awake); awake = 0 } }
}

extension String { var expandingTilde: String { (self as NSString).expandingTildeInPath } }
