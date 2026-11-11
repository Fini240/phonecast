import AppKit
import SwiftUI

extension AgentSession: Identifiable {}

/// The Mac's Agents page: the same chats the phone sees, plus the terminal integration switch.
struct AgentsView: View {
    @ObservedObject var hub = AgentHub.shared
    @State private var selection: String?
    @State private var filter = "all"
    @State private var query = ""
    @State private var installed = AgentShell.installed()
    @State private var legacy = AgentShell.legacyInstalled()
    @State private var error: String?

    private var tops: [AgentSession] {
        hub.sessions.filter { s in
            !s.isSubagent && (query.isEmpty || s.title.localizedCaseInsensitiveContains(query) || (s.cwd ?? "").localizedCaseInsensitiveContains(query))
                && (filter == "all" || (filter == "you" && (s.status == "needs_input" || hub.asks[s.id] != nil)) || (filter == "running" && (s.live || s.status == "working")))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !installed || legacy { integrationBanner }
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $filter) {
                            Text(tr("All")).tag("all")
                            Text(tr("Needs you")).tag("you")
                            Text(tr("Running")).tag("running")
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    .padding(10)
                    TextField(tr("Search"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 6)
                    List(selection: $selection) {
                        ForEach(tops) { s in
                            AgentRow(s: s, ask: hub.asks[s.id] != nil).tag(s.id)
                            ForEach(hub.sessions.filter { $0.parentId == s.id && $0.status == "working" }) { c in
                                AgentRow(s: c, ask: false).padding(.leading, 18).tag(c.id)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
                Group {
                    if let sid = selection, let s = hub.sessions.first(where: { $0.id == sid }) {
                        AgentChatView(s: s, ask: hub.asks[s.id]).id(sid)
                    } else {
                        Placeholder(symbol: "sparkles.rectangle.stack", title: "Agents",
                                    text: "Claude Code and Codex chats on this Mac. The phone shows the same list in its Agents tab: reply, stop and answer questions from anywhere.")
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} }
    }

    private var integrationBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(legacy ? "Switch from Agent Deck" : "Terminal integration")).font(.headline)
                Text(tr(legacy
                        ? "Your ~/.zshrc still routes claude/codex through Agent Deck. Switch to PhoneCast: new terminals open in PhoneCast's own managed tmux; sessions already running keep working and stay controllable."
                        : "Makes claude and codex in new terminals open in a managed tmux pane, so the phone can reply, stop them and answer their questions. Normal terminal use is unchanged."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(tr(legacy ? "Switch" : "Turn on")) {
                do { try AgentShell.install(); installed = true; legacy = false } catch { self.error = "\(error)" }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5))
    }
}

struct AgentRow: View {
    let s: AgentSession
    let ask: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(s.agent == "codex" ? "›_" : "✻").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(s.agent == "codex" ? Color(white: 0.15) : Color.orange.opacity(0.2)))
                    .foregroundStyle(s.agent == "codex" ? Color.white : Color.orange)
                Circle().fill(dot).frame(width: 9, height: 9).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(s.title).font(.body.weight(s.isSubagent ? .regular : .medium)).lineLimit(1)
                    Spacer()
                    Text(Date(timeIntervalSince1970: s.updatedAt), style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundStyle(ask || s.status == "needs_input" ? Color.orange : Color.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
    private var dot: Color {
        switch s.status {
        case "working": .green
        case "needs_input": .orange
        case "error": .red
        case "idle", "completed": .gray
        default: .clear
        }
    }
    private var subtitle: String {
        let folder = ((s.cwd ?? "") as NSString).lastPathComponent
        let what: String
        switch s.status {
        case "working": what = s.stage ?? tr("Working…")
        case "needs_input": what = s.stage ?? tr("Waiting for you")
        case "idle": what = s.managed ? tr("Ready") : tr("Open in a terminal")
        case "offline": what = tr("Finished")
        case "completed": what = tr("Done")
        case "error": what = tr("Error")
        default: what = s.stage ?? ""
        }
        return [s.isSubagent ? s.agentRole : folder, what].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

struct AgentChatView: View {
    let s: AgentSession
    let ask: [String: Any]?
    @State private var messages: [AgentMessage] = []
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stamp: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text([s.agent == "codex" ? "Codex" : "Claude Code", s.model, s.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if s.managed && (s.status == "working" || s.status == "needs_input") {
                    Button { call("stop") } label: { Label(tr("Stop"), systemImage: "stop.fill") }
                }
                if s.managed {
                    Button { call("open") } label: { Label(tr("Open in Terminal"), systemImage: "terminal") }
                } else if s.canResume {
                    Button { call("resume") } label: { Label(tr("Reopen"), systemImage: "arrow.uturn.forward") }
                }
            }
            .padding(14)
            if s.status == "working" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(s.stage ?? tr("Working…")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages, id: \.id) { m in AgentMessageView(m: m).id(m.id) }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _ in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let ask { askCard(ask) }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(tr(placeholder), text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...6)
                    .disabled(!canSend)
                    .onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .onAppear { load() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            if let t = s.transcript, let st = fileStamp(t), st.mtime != stamp { load() }
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} }
    }

    private var canSend: Bool { !s.isSubagent && (s.managed || s.canResume) }
    private var placeholder: String {
        if s.isSubagent { return "Subagents can't be messaged" }
        if !canSend { return "Open in another terminal — read only" }
        if s.status == "working" { return "Message — interrupts the current turn" }
        return s.managed ? "Message" : "Message — reopens this chat in a managed terminal"
    }

    private func load() {
        let s = self.s
        DispatchQueue.global(qos: .userInitiated).async {
            let m = AgentHub.shared.messages(s, limit: 150)
            let st = s.transcript.flatMap(fileStamp)?.mtime ?? 0
            DispatchQueue.main.async { messages = m; stamp = st }
        }
    }

    private func call(_ m: String, _ extra: [String: Any] = [:]) {
        busy = true
        AgentHub.shared.handle(["id": 0, "m": m, "p": extra.merging(["sid": s.id]) { a, _ in a }]) { r in
            DispatchQueue.main.async {
                busy = false
                if r["ok"] as? Bool != true { error = r["message"] as? String }
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, canSend, !busy else { return }
        text = ""
        call("send", ["text": t])
    }

    @ViewBuilder private func askCard(_ a: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Needs you")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(a["title"] as? String ?? "").font(.headline)
            if let d = a["detail"] as? String, !d.isEmpty {
                Text(d).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
            }
            HStack {
                ForEach(Array(((a["choices"] as? [[String: Any]]) ?? []).enumerated()), id: \.offset) { i, c in
                    if i == 0 {
                        Button(c["label"] as? String ?? "") { call("approve", ["ask": a["id"] ?? "", "choice": c["id"] ?? ""]) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(c["label"] as? String ?? "") { call("approve", ["ask": a["id"] ?? "", "choice": c["id"] ?? ""]) }
                    }
                }
            }
            .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

struct AgentMessageView: View {
    let m: AgentMessage
    @State private var expanded = false
    var body: some View {
        switch m.role {
        case "user":
            HStack { Spacer(minLength: 60); Text(m.text).textSelection(.enabled).padding(10).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)) }
        case "tool":
            Text((m.text.hasPrefix("Error") ? "✕  " : "⚙  ") + (expanded ? m.text : (m.text.split(separator: "\n").first.map(String.init) ?? "")))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(m.text.hasPrefix("Error") ? Color.red : Color.secondary)
                .lineLimit(expanded ? 40 : 1).onTapGesture { expanded.toggle() }
        case "system":
            Text(m.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        default:
            Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
