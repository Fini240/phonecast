import Foundation

/// v0.5 agent features on the Mac: git changes (status, diff, commit, push, PR), slash commands and the
/// permission mode, token/cost usage with plan limits, and per-chat budgets.
enum AgentGit {
    static let git = "/usr/bin/git"
    static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Fail: Error, CustomStringConvertible { let description: String }

    @discardableResult
    static func run(_ cwd: String, _ args: [String], timeout: Double = 30) throws -> String {
        var env = AgentTmux.loginEnv()
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_PAGER"] = "cat"; env["LC_ALL"] = "C"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", cwd, "-c", "core.quotepath=off", "-c", "color.ui=false"] + args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        if p.terminationStatus != 0 {
            let msg = String(decoding: e.isEmpty ? o : e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Fail(description: AgentText.clip(msg.isEmpty ? "git \(args.first ?? "") failed" : msg, 400))
        }
        return String(decoding: o, as: UTF8.self)
    }

    /// Branch, upstream state and changed files with +/- counts (untracked files count as all-added).
    static func changes(_ cwd: String) throws -> [String: Any] {
        guard (try? run(cwd, ["rev-parse", "--is-inside-work-tree"]))?.hasPrefix("true") == true else {
            return ["repo": false]
        }
        let status = try run(cwd, ["status", "--porcelain=v1", "-b", "-uall"])
        var branch = "", ahead = 0, behind = 0, upstream = false
        var files: [[String: Any]] = []
        var counts: [String: (Int, Int)] = [:]
        let hasHead = (try? run(cwd, ["rev-parse", "--verify", "HEAD"])) != nil
        if hasHead {
            for l in try run(cwd, ["diff", "HEAD", "--numstat"]).split(separator: "\n") {
                let p = l.split(separator: "\t", maxSplits: 2)
                if p.count == 3 { counts[String(p[2])] = (Int(p[0]) ?? 0, Int(p[1]) ?? 0) }
            }
        }
        for line in status.split(separator: "\n").map(String.init) {
            if line.hasPrefix("## ") {
                let h = String(line.dropFirst(3))
                branch = String(h.split(separator: ".").first ?? Substring(h)).components(separatedBy: " ").first ?? h
                if h.contains("...") { upstream = true }
                if let m = Rx(#"ahead (\d+)"#).search(h) { ahead = Int(m.g(1) ?? "") ?? 0 }
                if let m = Rx(#"behind (\d+)"#).search(h) { behind = Int(m.g(1) ?? "") ?? 0 }
                if h.hasPrefix("No commits yet on ") { branch = String(h.dropFirst("No commits yet on ".count)) }
                continue
            }
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }
            var add = counts[path]?.0 ?? 0, del = counts[path]?.1 ?? 0
            if code == "??" {
                let full = (cwd as NSString).appendingPathComponent(path)
                if let s = fileStamp(full), s.size < 2_000_000, let t = try? String(contentsOfFile: full, encoding: .utf8) { add = t.split(separator: "\n", omittingEmptySubsequences: false).count; del = 0 }
            }
            let kind: String
            switch true {
            case code == "??": kind = "new"
            case code.contains("D"): kind = "deleted"
            case code.contains("R"): kind = "renamed"
            case code.contains("A"): kind = "added"
            default: kind = "modified"
            }
            files.append(["path": path, "kind": kind, "add": add, "del": del])
        }
        let remote = (try? run(cwd, ["remote"]))?.split(separator: "\n").first.map(String.init)
        return ["repo": true, "branch": branch, "ahead": ahead, "behind": behind, "upstream": upstream, "remote": remote ?? "",
                "files": Array(files.prefix(300)), "more": max(0, files.count - 300), "gh": gh != nil]
    }

    static func diff(_ cwd: String, _ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Fail(description: "Bad path.") }
        let full = (cwd as NSString).appendingPathComponent(path)
        let tracked = (try? run(cwd, ["ls-files", "--error-unmatch", "--", path])) != nil
        var out: String
        if tracked { out = try (try? run(cwd, ["diff", "HEAD", "--", path])) ?? run(cwd, ["diff", "--", path]) }
        else {
            // untracked: show the whole file as added (git diff --no-index exits 1 on differences)
            guard let s = fileStamp(full), s.size < 2_000_000, let t = try? String(contentsOfFile: full, encoding: .utf8) else { return "(binary or large file)" }
            out = "+++ " + path + "\n" + t.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        return String(AgentText.redact(out).prefix(200_000))
    }

    static func act(_ cwd: String, _ op: String, _ p: [String: Any]) throws -> String {
        switch op {
        case "commit":
            let msg = (p["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { throw Fail(description: "The commit message is empty.") }
            try run(cwd, ["add", "-A"])
            try run(cwd, ["commit", "-m", msg])
            return try run(cwd, ["log", "-1", "--format=%h %s"]).trimmingCharacters(in: .whitespacesAndNewlines)
        case "push":
            let branch = try run(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUp = (try? run(cwd, ["rev-parse", "--abbrev-ref", "@{u}"])) != nil
            try run(cwd, hasUp ? ["push"] : ["push", "-u", "origin", branch], timeout: 120)
            return "Pushed \(branch)"
        case "pr":
            guard let gh else { throw Fail(description: "GitHub CLI (gh) isn't installed on the Mac.") }
            var env = AgentTmux.loginEnv(); env["GH_PROMPT_DISABLED"] = "1"
            var args = ["pr", "create", "--fill"]
            if let t = p["title"] as? String, !t.isEmpty { args = ["pr", "create", "--title", t, "--body", p["body"] as? String ?? ""] }
            if p["draft"] as? Bool == true { args.append("--draft") }
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: gh); pr.arguments = args; pr.environment = env
            pr.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let o = Pipe(), e = Pipe(); pr.standardOutput = o; pr.standardError = e; pr.standardInput = FileHandle.nullDevice
            try pr.run()
            let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
            pr.waitUntilExit()
            let out = String(decoding: od, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if pr.terminationStatus != 0 { throw Fail(description: AgentText.clip(String(decoding: ed, as: UTF8.self), 400)) }
            return out.split(separator: "\n").last.map(String.init) ?? out
        case "pull":
            try run(cwd, ["pull", "--ff-only"], timeout: 120)
            return "Up to date"
        default: throw Fail(description: "Unknown git action.")
        }
    }
}

/// Token, cost and plan-limit usage of a chat.
enum AgentUsage {
    static var statusDir: URL { AgentTmux.home.appendingPathComponent("status") }
    /// Running totals per transcript; only bytes appended since the last look are parsed.
    private final class Inc { var offset: UInt64 = 0; var stamp: FileStamp?; var seen = Set<String>(); var inTok = 0, outTok = 0, cached = 0, ctx = 0; var model = ""; var rest = Data()
        var dict: [String: Any] { ["in": inTok, "out": outTok, "cached": cached, "ctxTokens": ctx, "model": model] } }
    private static var incs: [String: Inc] = [:]
    private static let incLock = NSLock()

    private static func incremental(_ path: String, _ st: FileStamp) -> [String: Any] {
        incLock.lock(); defer { incLock.unlock() }
        let c = incs[path] ?? Inc()
        if incs[path] == nil { if incs.count > 200 { incs.removeAll() }; incs[path] = c }
        if c.stamp != st {
            if UInt64(st.size) < c.offset { incs[path] = Inc(); return incremental2(path, st, incs[path]!) }
            return incremental2(path, st, c)
        }
        return c.dict
    }

    private static func incremental2(_ path: String, _ st: FileStamp, _ c: Inc) -> [String: Any] {
        guard let h = FileHandle(forReadingAtPath: path) else { return c.dict }
        defer { try? h.close() }
        try? h.seek(toOffset: c.offset)
        let d = (try? h.readToEnd()) ?? Data()
        c.offset += UInt64(d.count); c.stamp = st
        var buf = c.rest + d
        if let last = buf.lastIndex(of: 10) { c.rest = Data(buf[buf.index(after: last)...]); buf = Data(buf[..<last]) } else { c.rest = buf; return c.dict }
        for line in buf.split(separator: 10) where line.count > 20 {
            // cheap prefilter before JSON parsing: only assistant lines carry usage
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], e["type"] as? String == "assistant",
                  let m = e["message"] as? [String: Any], let usage = m["usage"] as? [String: Any] else { continue }
            if let id = m["id"] as? String, !c.seen.insert(id).inserted { continue }
            let i = usage["input_tokens"] as? Int ?? 0, c1 = usage["cache_creation_input_tokens"] as? Int ?? 0, c2 = usage["cache_read_input_tokens"] as? Int ?? 0
            c.inTok += i + c1; c.cached += c2; c.outTok += usage["output_tokens"] as? Int ?? 0
            if e["isSidechain"] as? Bool != true { c.ctx = i + c1 + c2 }
            if let mo = m["model"] as? String, mo != "<synthetic>" { c.model = mo }
        }
        return c.dict
    }
    private static let codexCache = StampCache<[String: Any]>()

    /// Claude: tokens summed from the transcript (each API message counted once); cost, context % and
    /// plan limits from the statusline tap when present (Claude Code hands its statusline that JSON).
    static func claude(native: String?, path: String?) -> [String: Any]? {
        guard let path, let st = fileStamp(path) else { return nil }
        var u = incremental(path, st)
        if let native, let d = try? Data(contentsOf: statusDir.appendingPathComponent("\(native).json")),
           let s = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if let c = (s["cost"] as? [String: Any])?["total_cost_usd"] as? Double { u["cost"] = c }
            if let w = s["context_window"] as? [String: Any] { u["ctxPct"] = w["used_percentage"]; u["ctxSize"] = w["context_window_size"] ?? w["size"] }
            if let r = s["rate_limits"] as? [String: Any] {
                var lim: [[String: Any]] = []
                for (k, label) in [("five_hour", "5 h"), ("seven_day", "7 days")] {
                    if let x = r[k] as? [String: Any], let pct = x["used_percentage"] as? Double {
                        var o: [String: Any] = ["label": label, "pct": pct]
                        if let at = x["resets_at"] { o["resets"] = at }
                        lim.append(o)
                    }
                }
                if !lim.isEmpty { u["limits"] = lim }
            }
        }
        return u
    }

    /// Codex: the rollout's own token_count events (total usage, context window, plan limit %).
    static func codex(path: String?) -> [String: Any]? {
        guard let path, let st = fileStamp(path) else { return nil }
        return codexCache.get(path, st) {
            var out: [String: Any] = [:]
            for e in JSONL.tail(URL(fileURLWithPath: path), 512 * 1024).0.reversed() {
                guard e["type"] as? String == "event_msg", let pl = e["payload"] as? [String: Any], pl["type"] as? String == "token_count" else { continue }
                if let info = pl["info"] as? [String: Any] {
                    let t = info["total_token_usage"] as? [String: Any] ?? [:]
                    let last = info["last_token_usage"] as? [String: Any] ?? [:]
                    out["in"] = t["input_tokens"] ?? 0; out["out"] = t["output_tokens"] ?? 0; out["cached"] = t["cached_input_tokens"] ?? 0
                    if let w = info["model_context_window"] as? Int, w > 0, let lt = last["total_tokens"] as? Int {
                        out["ctxPct"] = min(100, Double(lt) / Double(w) * 100); out["ctxSize"] = w; out["ctxTokens"] = lt
                    }
                }
                if let r = pl["rate_limits"] as? [String: Any] {
                    var lim: [[String: Any]] = []
                    for k in ["primary", "secondary"] {
                        if let x = r[k] as? [String: Any], let pct = x["used_percent"] as? Double {
                            let mins = x["window_minutes"] as? Int ?? 0
                            lim.append(["label": mins >= 10080 ? "\(mins / 1440) days" : mins >= 60 ? "\(mins / 60) h" : "\(mins) min", "pct": pct, "resets": x["resets_at"] ?? 0])
                        }
                    }
                    if !lim.isEmpty { out["limits"] = lim }
                }
                break
            }
            return out
        }
    }

    // MARK: account-wide plan limits (what's left)

    private static var planCache: (at: Double, value: [String: Any])?

    /// The newest plan-limit report of each agent: Claude from the statusline tap (any chat; limits are per
    /// account), Codex from its newest rollout. Each window: {label, pct used, resets (epoch s), at (report time)}.
    static func plan() -> [String: Any] {
        let now = Date().timeIntervalSince1970
        if let c = planCache, now - c.at < 10 { return c.value }
        var out: [String: Any] = [:]
        let fm = FileManager.default
        // Claude: plan limits belong to an account, and Claude doesn't say which account a chat uses.
        // Chats of one account share its weekly reset time, so reports are grouped by it (one group per
        // account; the 5-hour reset moves every window), newest report per group wins.
        if let files = try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]) {
            struct Acc { var key: String; var limits: [[String: Any]]; var at: Double; var newestStart: Double; var sessions: [String] }
            var accs: [String: Acc] = [:]
            for u in files where u.pathExtension == "json" {
                guard let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]),
                      let mod = rv.contentModificationDate?.timeIntervalSince1970, now - mod < 7 * 86400,
                      let data = try? Data(contentsOf: u), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let r = o["rate_limits"] as? [String: Any] else { continue }
                var lim: [[String: Any]] = []
                var weekly: Double?
                for (k, label) in [("five_hour", "5 h"), ("seven_day", "7 days")] {
                    if let x = r[k] as? [String: Any], let pct = (x["used_percentage"] as? NSNumber)?.doubleValue {
                        let resets = (x["resets_at"] as? NSNumber)?.doubleValue ?? 0
                        lim.append(["label": label, "pct": pct, "resets": resets, "at": mod])
                        if k == "seven_day" { weekly = resets }
                    }
                }
                guard !lim.isEmpty, let wk = weekly else { continue }
                let k = String(Int(wk))
                let sid = o["session_id"] as? String ?? u.deletingPathExtension().lastPathComponent
                // when the chat started: its transcript's first timestamp (the account it runs on was the login then)
                var started = rv.creationDate?.timeIntervalSince1970 ?? mod
                if let tp = o["transcript_path"] as? String, let t = JSONL.head(URL(fileURLWithPath: tp), 16 * 1024).lazy.compactMap({ ISO.parse($0["timestamp"]) }).first { started = t }
                var a = accs[k] ?? Acc(key: k, limits: lim, at: mod, newestStart: started, sessions: [])
                // newest report wins, but keep a 5-hour window an older report still has (weekly-only reports)
                if mod >= a.at {
                    if lim.count == 1, let five = a.limits.first(where: { $0["label"] as? String == "5 h" }) { lim.insert(five, at: 0) }
                    a.limits = lim; a.at = mod
                }
                a.newestStart = max(a.newestStart, started)
                a.sessions.append(sid)
                accs[k] = a
            }
            // windows that already reset are kept only if nothing newer exists for that account
            let list = accs.values.sorted { $0.at > $1.at }
            if !list.isEmpty {
                out["claude"] = list.first!.limits          // newest overall (widget, older phones)
                // Which account is logged in right now can't be told reliably: a running chat switches account
                // after /login, so start times don't say it. Accounts are labelled by their chats instead.
                let current: String? = nil
                out["claudeAccounts"] = list.prefix(4).map { a -> [String: Any] in
                    ["limits": a.limits, "chats": a.sessions.count, "sessions": Array(a.sessions.prefix(50)), "current": a.key == current]
                }
            }
        }
        // Codex: newest rollout that reported limits (sessions/YYYY/MM/DD/*.jsonl)
        let root = CodexSource.home.appendingPathComponent("sessions")
        var newestRollout: (Date, URL)?
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in e where u.pathExtension == "jsonl" {
                if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > (newestRollout?.0 ?? .distantPast) { newestRollout = (d, u) }
            }
        }
        if let (d, u) = newestRollout, var lim = codex(path: u.path)?["limits"] as? [[String: Any]] {
            for i in lim.indices { lim[i]["at"] = d.timeIntervalSince1970; if let r = lim[i]["resets"] as? NSNumber { lim[i]["resets"] = r.doubleValue } }
            out["codex"] = lim
        }
        planCache = (now, out)
        return out
    }

    /// E-mail of the Claude account that's logged in now (new chats use it).
    static func currentLogin() -> String? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let s = fileStamp(u.path), s.size < 50 << 20, let d = try? Data(contentsOf: u),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (o["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    // MARK: statusline tap (Claude hands its statusline a JSON with cost, context and plan limits)

    static var tapScript: URL { AgentTmux.home.appendingPathComponent("statusline.sh") }
    static var origFile: URL { AgentTmux.home.appendingPathComponent("statusline.orig") }
    static var settingsURL: URL { ClaudeSource.home.appendingPathComponent("settings.json") }
    static let tapSource = #"""
    #!/bin/sh
    # PhoneCast: keeps a copy of what Claude Code hands its statusline (cost, context, plan limits) for the
    # phone, then runs your own statusline command unchanged (saved in statusline.orig).
    in=$(cat)
    d="$HOME/.phonecast/agents/status"
    mkdir -p "$d" 2>/dev/null
    sid=$(printf '%s' "$in" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$sid" ] && printf '%s' "$in" > "$d/$sid.json.tmp" && mv "$d/$sid.json.tmp" "$d/$sid.json"
    orig="$HOME/.phonecast/agents/statusline.orig"
    [ -s "$orig" ] && printf '%s' "$in" | sh -c "$(cat "$orig")"
    exit 0
    """#

    static func tapInstalled() -> Bool {
        guard let d = try? Data(contentsOf: settingsURL), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let sl = o["statusLine"] as? [String: Any], let c = sl["command"] as? String else { return false }
        return c.contains(".phonecast/agents/statusline.sh")
    }

    /// Wraps the user's statusline (kept exactly as it was in statusline.orig). Backup of settings.json first.
    static func installTap() throws {
        try? FileManager.default.createDirectory(at: AgentTmux.home, withIntermediateDirectories: true)
        try tapSource.write(to: tapScript, atomically: true, encoding: .utf8)
        chmod(tapScript.path, 0o755)
        if tapInstalled() { return }
        let data = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        guard var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AgentGit.Fail(description: "~/.claude/settings.json isn't valid JSON; not touching it.") }
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.pre-phonecast")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup) }
        let orig = (o["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        try orig.write(to: origFile, atomically: true, encoding: .utf8)
        var sl = o["statusLine"] as? [String: Any] ?? ["type": "command"]
        sl["type"] = "command"
        sl["command"] = "sh \"$HOME/.phonecast/agents/statusline.sh\""
        o["statusLine"] = sl
        let out = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    static func removeTap() throws {
        guard tapInstalled(), let d = try? Data(contentsOf: settingsURL), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let orig = (try? String(contentsOf: origFile, encoding: .utf8)) ?? ""
        if orig.isEmpty { o.removeValue(forKey: "statusLine") } else { o["statusLine"] = ["type": "command", "command": orig] }
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: settingsURL, options: .atomic)
    }
}

/// Per-chat budgets: {sid: {usd?, tokens?, stop}}; checked on every poll.
enum AgentBudgets {
    static var file: URL { AgentTmux.home.appendingPathComponent("budgets.json") }
    private static let lock = NSLock()
    private static var cache: [String: [String: Any]]?

    static func all() -> [String: [String: Any]] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let v = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        cache = v; return v
    }

    static func set(_ sid: String, _ b: [String: Any]?) {
        var a = all()
        lock.lock(); defer { lock.unlock() }
        if let b, !b.isEmpty { a[sid] = b } else { a.removeValue(forKey: sid) }
        cache = a
        if let d = try? JSONSerialization.data(withJSONObject: a) { try? d.write(to: file, options: .atomic) }
    }

    /// nil = within budget; otherwise a short reason.
    static func exceeded(_ b: [String: Any], _ u: [String: Any]) -> String? {
        if let usd = (b["usd"] as? NSNumber)?.doubleValue, usd > 0, let c = u["cost"] as? Double, c >= usd {
            return String(format: "Spent $%.2f of $%.2f", c, usd)
        }
        if let tk = (b["tokens"] as? NSNumber)?.intValue, tk > 0 {
            let used = (u["in"] as? Int ?? 0) + (u["out"] as? Int ?? 0)
            if used >= tk { return "Used \(used / 1000)k of \(tk / 1000)k tokens" }
        }
        return nil
    }
}

