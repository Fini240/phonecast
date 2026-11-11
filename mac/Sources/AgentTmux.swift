import Foundation

/// Managed agent terminals: every `claude`/`codex` started from a terminal (via the shell integration) or
/// from the phone runs in its own session on a private tmux server. The Mac terminal shows the same pane,
/// so phone input lands in the same live TUI. tmux itself is the registry: each session carries
/// `@pc_id`, `@pc_agent`, `@pc_native` (Claude session id chosen at start). Panes from the old
/// Agent Deck server (`@agentdeck_id`) are adopted and controlled the same way until they end.
///
/// Input rules (unchanged from Agent Deck, all learned live): only type when the prompt is visible and no
/// dialog/spinner shows; interrupt = one Escape and only while working or a dialog blocks (never Ctrl-C,
/// which quits idle Claude); text goes in as a bracketed paste and is submitted with one Enter.
final class AgentTmux {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".phonecast/agents")
    static let socket = home.appendingPathComponent("tmux.sock").path
    static let conf = home.appendingPathComponent("tmux.conf").path
    static let legacySocket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-deck/terminal/tmux.sock").path
    static let legacyConf = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-deck/terminal/tmux.conf").path

    static let tmuxConf = """
    # PhoneCast private tmux server (only managed Claude Code / Codex sessions)
    set -g status off
    set -s escape-time 10
    set -g history-limit 20000
    set -g focus-events on
    set -g window-size latest
    set -g aggressive-resize on
    set -g remain-on-exit off
    set -g destroy-unattached off
    set -g exit-empty on
    set -g set-titles on
    set -g set-titles-string "#{session_name}"
    set -g mouse on

    """

    static let tmuxBin: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Pane {
        let tag: String              // pc id or legacy agent-deck id
        let socket: String
        let paneId: String
        let session: String
        let dead: Bool
        let pid: Int32
        let attached: Bool
        let activity: Double         // window_activity (s)
        let agent: String
        let nativeHint: String?
        let cwd: String
        let created: Double
        var id: String { "t:" + tag }
    }

    struct Fail: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    init() {
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? String(contentsOfFile: Self.conf, encoding: .utf8)) != Self.tmuxConf {
            FileManager.default.createFile(atPath: Self.conf, contents: Data(Self.tmuxConf.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: plumbing

    private static let envDeny: Set<String> = ["TMUX", "TMUX_PANE", "PHONECAST_AGENT_ID", "AGENTDECK_SESSION_ID", "CLAUDECODE",
                                               "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "__CFBundleIdentifier"]

    @discardableResult
    func tmux(_ socket: String, _ args: [String], input: Data? = nil, check: Bool = true) throws -> String {
        guard let bin = Self.tmuxBin else { throw Fail("tmux is not installed (brew install tmux)") }
        let conf = socket == Self.legacySocket ? Self.legacyConf : Self.conf
        var env = ProcessInfo.processInfo.environment
        for k in Self.envDeny { env.removeValue(forKey: k) }
        let (st, out) = runTool(bin, ["-S", socket, "-f", conf] + args, input: input, env: env, timeout: 10)
        if check && st != 0 { throw Fail("tmux \(args.first ?? "") failed") }
        return String(decoding: out, as: UTF8.self)
    }

    var sockets: [String] { [Self.socket, Self.legacySocket].filter { FileManager.default.fileExists(atPath: $0) } }

    /// All tagged panes on both servers (one `list-panes` per server).
    func panes() -> [Pane] {
        let fmt = ["#{@pc_id}", "#{@agentdeck_id}", "#{pane_id}", "#{session_name}", "#{pane_dead}", "#{pane_pid}", "#{session_attached}",
                   "#{window_activity}", "#{@pc_agent}", "#{@pc_native}", "#{pane_current_path}", "#{session_created}", "#{pane_start_command}"].joined(separator: "\t")
        var out: [Pane] = []
        for s in sockets {
            guard let text = try? tmux(s, ["list-panes", "-a", "-F", fmt], check: false) else { continue }
            for line in text.split(separator: "\n") {
                let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard p.count >= 13 else { continue }
                let tag = !p[0].isEmpty ? p[0] : p[1]
                guard !tag.isEmpty else { continue }
                let agent = !p[8].isEmpty ? p[8] : (p[12].contains("codex") ? "codex" : "claude")
                out.append(Pane(tag: tag, socket: s, paneId: p[2], session: p[3], dead: p[4] == "1", pid: Int32(p[5]) ?? 0,
                                attached: !(p[6].isEmpty || p[6] == "0"), activity: Double(p[7]) ?? 0, agent: agent,
                                nativeHint: p[9].isEmpty ? nil : p[9], cwd: p[10], created: Double(p[11]) ?? 0))
            }
        }
        return out
    }

    func pane(_ id: String) throws -> Pane {
        guard let p = panes().first(where: { $0.id == id }) else { throw Fail("This terminal has ended.") }
        if p.dead { throw Fail("The agent in this terminal has exited.") }
        return p
    }

    func capture(_ p: Pane, history: Int = 0) -> String {
        var a = ["capture-pane", "-p", "-e", "-J", "-t", p.paneId]
        if history > 0 { a += ["-S", "-\(history)"] }
        return (try? tmux(p.socket, a)) ?? ""
    }

    func observe(_ p: Pane) -> AgentScreen.State {
        var st = AgentScreen.parse(agent: p.agent, styled: capture(p))
        if p.agent == "claude" && !st.working && st.dialog == nil, registry(p)?["status"] as? String == "busy" {
            // Claude draws no spinner while streaming text; its own process registry says "busy"
            st.working = true
            st.activity = st.activity ?? "Responding"
        }
        return st
    }

    private var regPid: [String: Int32] = [:]

    /// `~/.claude/sessions/<pid>.json` of the Claude process in this pane.
    func registry(_ p: Pane) -> [String: Any]? {
        let key = p.socket + p.paneId
        if let pid = regPid[key], let e = ClaudeSource.session(forPid: pid) { return e }
        for pid in [p.pid] + Procs.descendants(p.pid) {
            if let e = ClaudeSource.session(forPid: pid) { regPid[key] = pid; return e }
        }
        return nil
    }

    private var codexAssoc: [String: (Double, String?)] = [:]

    /// The native chat id this pane is showing right now (follows /clear, /new and resume pickers).
    func nativeId(_ p: Pane) -> String? {
        if p.agent == "claude" { return (registry(p)?["sessionId"] as? String) ?? p.nativeHint }
        if let c = codexAssoc[p.id], Date().timeIntervalSince1970 - c.0 < 20, c.1 != nil { return c.1 }
        let t = CodexSource.thread(forPids: [p.pid] + Procs.descendants(p.pid))
        codexAssoc[p.id] = (Date().timeIntervalSince1970, t ?? codexAssoc[p.id]?.1)
        return t ?? codexAssoc[p.id]?.1
    }

    private func keys(_ p: Pane, _ k: String...) throws { for x in k { try tmux(p.socket, ["send-keys", "-t", p.paneId, x]) } }

    private func wait(_ p: Pane, _ timeout: Double, _ interval: Double = 0.2, _ ok: (AgentScreen.State) -> Bool) throws -> AgentScreen.State {
        let end = Date().addingTimeInterval(timeout)
        var st = observe(p)
        while !ok(st) {
            if Date() > end { throw Fail("The terminal didn't reach the expected state in time.") }
            Thread.sleep(forTimeInterval: interval)
            st = observe(try pane(p.id))
        }
        return st
    }

    // MARK: actions (call off the main thread; one at a time per pane via AgentHub's locks)

    func send(_ id: String, _ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Fail("The message is empty.") }
        if text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 0x7f }) { throw Fail("The message contains control characters.") }
        let p = try pane(id)
        var st = observe(p)
        var interrupted = false
        if st.dialog != nil {
            try keys(p, "Escape"); interrupted = true
            st = try wait(p, 15) { $0.dialog == nil }
        }
        if st.working {
            try keys(p, "Escape"); interrupted = true
            st = try wait(p, 15) { !$0.working || $0.dialog != nil }
            if st.dialog != nil { throw Fail("A new question appeared after interrupting. Check the chat.") }
        }
        st = try wait(p, 20) { $0.ready }
        if let d = st.draft, !d.isEmpty { try clearDraft(p, saved: !interrupted ? d : nil) }
        // bracketed paste (-p), keep newlines (-r), delete the buffer (-d)
        let buf = "pc-\(UInt32.random(in: 0...UInt32.max))"
        try tmux(p.socket, ["load-buffer", "-b", buf, "-"], input: Data(text.utf8))
        try tmux(p.socket, ["paste-buffer", "-p", "-r", "-d", "-b", buf, "-t", p.paneId])
        let first = String(text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces).prefix(20) ?? "")
        do {
            _ = try wait(p, 4, 0.12) { s in
                guard let d = s.draft, !d.isEmpty else { return false }
                return first.isEmpty || d.contains(first) || d.contains("Pasted text") || d.contains("[Pasted") || d.contains("[Image")
            }
        } catch { throw Fail("The text didn't appear in the prompt; nothing was sent.") }
        try keys(p, "Enter")
        do { _ = try wait(p, 6) { $0.working || $0.dialog != nil || ($0.draft ?? "x").isEmpty } }
        catch { throw Fail("Pasted, but the terminal didn't confirm it was sent. Check the chat before sending again.") }
    }

    private func clearDraft(_ p: Pane, saved: String?) throws {
        if let saved {
            let u = Self.home.appendingPathComponent("cleared-drafts.txt")
            let old = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let entry = "--- \(Date()) \(p.id)\n\(saved.prefix(8000))\n"
            try? String((old + entry).suffix(60000)).write(to: u, atomically: true, encoding: .utf8)
        }
        for _ in 0..<80 {
            try keys(p, "C-u")
            if (observe(p).draft ?? "").isEmpty { return }
            try keys(p, "BSpace")
            if (observe(p).draft ?? "").isEmpty { return }
        }
        throw Fail("Couldn't clear the unsent text in the terminal prompt.")
    }

    func stop(_ id: String) throws {
        let p = try pane(id)
        let st = observe(p)
        if !st.working && st.dialog == nil { return }      // never send keys to an idle TUI
        try keys(p, "Escape")
        _ = try wait(p, 15) { !$0.working && $0.dialog == nil }
    }

    func key(_ id: String, _ k: String) throws {
        let map = ["up": "Up", "down": "Down", "enter": "Enter", "escape": "Escape", "tab": "Tab", "left": "Left", "right": "Right", "btab": "BTab"]
        guard let t = map[k] else { throw Fail("Unsupported key.") }
        try keys(try pane(id), t)
    }

    func approve(_ id: String, approval: String, choice: String) throws {
        let p = try pane(id)
        guard let d = observe(p).dialog, d.approvalId == approval else { throw Fail("This question is no longer shown in the terminal.") }
        guard let target = d.options.first(where: { d.choiceId($0) == choice }) else { throw Fail("That choice isn't offered any more.") }
        if let n = target.number, (1...9).contains(n) { try keys(p, String(n)) }
        else {
            var done = false
            for _ in 0..<(d.options.count + 2) {
                guard let cur = observe(p).dialog, cur.fingerprint == d.fingerprint else { throw Fail("The question changed while selecting.") }
                guard let c = cur.cursor else { throw Fail("Can't see the selection cursor.") }
                if c == target.index { try keys(p, "Enter"); done = true; break }
                try keys(p, c < target.index ? "Down" : "Up")
                Thread.sleep(forTimeInterval: 0.15)
            }
            if !done { throw Fail("Couldn't move the selection to that choice.") }
        }
        do { _ = try wait(p, 5) { $0.dialog == nil || $0.dialog?.fingerprint != d.fingerprint } }
        catch {
            // the choice may have ended the agent ("No, exit"): a gone pane still means it was answered
            if (try? pane(id)) == nil { return }
            throw Fail("The terminal didn't accept the choice.")
        }
    }

    func preview(_ id: String) throws -> String {
        let p = try pane(id)
        var lines = AgentScreen.stripAnsi(capture(p, history: 200)).components(separatedBy: "\n").map { s -> String in
            var s = Substring(s); while s.last?.isWhitespace == true { s.removeLast() }; return String(s)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return String(AgentText.redact(lines.joined(separator: "\n")).suffix(24000))
    }

    // MARK: starting

    static func binary(_ agent: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cands = ["\(home)/.local/bin/\(agent)", "/opt/homebrew/bin/\(agent)", "/usr/local/bin/\(agent)"]
        if let c = cands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        for dir in (loginEnv()["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/\(agent)"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    private static var envCache: [String: String]?
    private static let envLock = NSLock()
    /// The user's login-shell environment (PATH etc.) for sessions started from the phone.
    static func loginEnv() -> [String: String] {
        envLock.lock(); defer { envLock.unlock() }
        if let e = envCache { return e }
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let (_, out) = runTool(shell, ["-l", "-c", "env -0"], timeout: 8)
        var parsed: [String: String] = [:]
        for item in out.split(separator: 0) {
            guard let eq = item.firstIndex(of: UInt8(ascii: "=")) else { continue }
            parsed[String(decoding: item[item.startIndex..<eq], as: UTF8.self)] = String(decoding: item[(eq + 1)...], as: UTF8.self)
        }
        if parsed["PATH"] != nil { env.merge(parsed) { $1 } }
        envCache = env
        return env
    }

    /// Start a new chat (or resume a native one) in a fresh managed pane. Returns the pane id ("t:<tag>").
    func start(agent: String, cwd: String, model: String?, prompt: String?, resume: String? = nil) throws -> String {
        guard agent == "claude" || agent == "codex" else { throw Fail("Unknown agent.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { throw Fail("That folder doesn't exist.") }
        guard let bin = Self.binary(agent) else { throw Fail("\(agent) isn't installed.") }
        if let resume, let live = panes().first(where: { !$0.dead && $0.agent == agent && nativeId($0) == resume }) { return live.id }
        var argv = [bin]
        var native: String?
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if agent == "claude" {
            if let resume { argv += ["--resume", resume]; native = resume }
            else { native = UUID().uuidString.lowercased(); argv += ["--session-id", native!] }
            if let model, model != "default" { argv += ["--model", model] }
            if let prompt { argv += ["--", prompt] }
        } else {
            if resume != nil { argv.append("resume") }
            if let model { argv += ["--model", model] }
            if let resume { argv.append(resume); native = resume }
            if let prompt { if resume == nil { argv.append("--") }; argv.append(prompt) }
        }
        let tag = String((0..<12).map { _ in "0123456789abcdef".randomElement()! })
        var env = Self.loginEnv()
        for k in Self.envDeny { env.removeValue(forKey: k) }
        env["PHONECAST_AGENT_ID"] = tag
        var envArgs: [String] = []
        for (k, v) in env where !k.contains("=") && !k.contains("\n") && !v.contains("\n") { envArgs += ["-e", "\(k)=\(v)"] }
        let name = "pc-\(tag)"
        let pid = try tmux(Self.socket, ["new-session", "-d", "-s", name, "-x", "160", "-y", "48", "-c", cwd] + envArgs + ["-P", "-F", "#{pane_id}", "--"] + argv)
        guard pid.hasPrefix("%") else { throw Fail("tmux didn't start the session.") }
        try tmux(Self.socket, ["set-option", "-t", name, "@pc_id", tag, ";", "set-option", "-t", name, "@pc_agent", agent]
                 + (native.map { [";", "set-option", "-t", name, "@pc_native", $0] } ?? []))
        return "t:" + tag
    }

    /// Opens a Terminal window attached to the pane (the Mac's "Open in Terminal").
    func openInTerminal(_ id: String) throws {
        let p = try pane(id)
        guard let bin = Self.tmuxBin else { return }
        let conf = p.socket == Self.legacySocket ? Self.legacyConf : Self.conf
        let cmd = "unset TMUX; exec \(bin) -S '\(p.socket)' -f '\(conf)' attach-session -t '\(p.session)'"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        runTool("/usr/bin/osascript", ["-e", script], timeout: 10)
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
