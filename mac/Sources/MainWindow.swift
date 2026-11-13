import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", mirror = "Mirror", pc = "PC", agents = "Agents", notifications = "Notifications", messages = "Messages", calls = "Calls"
    case contacts = "Contacts", photos = "Photos", files = "Files", apps = "Apps", transfers = "Transfers", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .mirror: "rectangle.on.rectangle"
        case .pc: "desktopcomputer"
        case .agents: "sparkles.rectangle.stack"
        case .notifications: "bell"
        case .messages: "message"
        case .calls: "phone"
        case .contacts: "person.crop.circle"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .apps: "square.grid.2x2"
        case .transfers: "arrow.up.arrow.down"
        case .settings: "gearshape"
        }
    }
}

/// The main PhoneCast window (the phone mirror is a separate window).
final class MainWindowController {
    static let shared = MainWindowController()
    private var window: NSWindow?
    let nav = Nav()

    final class Nav: ObservableObject { @Published var section: Pane = .overview }

    func show(_ section: Pane? = nil) {
        if let section { nav.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "PhoneCast"
            w.titleVisibility = .hidden              // each page has its own big title
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView().environmentObject(Store.shared).environmentObject(nav))
            w.setFrameAutosaveName("PhoneCastMain")
            if !w.setFrameUsingName("PhoneCastMain") { w.center() }
            w.minSize = NSSize(width: 760, height: 480)
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: MainWindowController.Nav
    @ObservedObject var dash = PcDashboard.shared
    /// The PC page only for people with a Hermes dashboard (address in Settings).
    private var hasPc: Bool { !dash.base.isEmpty }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                PhoneHeader()
                ForEach(Pane.allCases.filter { $0 != .pc || hasPc }) { s in
                    Label(tr(s.rawValue), systemImage: s.symbol)
                        .badge(badge(s))
                        .tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                switch nav.section {
                case .overview: OverviewView()
                case .mirror: MirrorView()
                case .pc: PcView()
                case .agents: AgentsView()
                case .notifications: NotificationsView()
                case .messages: MessagesView()
                case .calls: CallsView()
                case .contacts: ContactsView()
                case .photos: PhotosView()
                case .files: FilesView()
                case .apps: AppsView()
                case .transfers: TransfersView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func badge(_ s: Pane) -> Int {
        switch s {
        case .notifications: store.notifications.count
        case .messages: store.threads.reduce(0) { $0 + $1.unread }
        case .transfers: store.transfers.filter { $0.state == .running }.count
        case .agents: AgentHub.shared.sessions.filter { !$0.isSubagent && $0.status == "needs_input" }.count
        default: 0
        }
    }
}

struct PhoneHeader: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone").font(.title2).foregroundStyle(store.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.phoneName).font(.headline).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(store.connected ? (store.rttMs >= 0 ? "Connected · \(Int(store.rttMs.rounded())) ms" : "Connected") : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.connected, !store.phoneSummary.isEmpty { Text(store.phoneSummary).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}

// MARK: shared bits

struct Placeholder: View {
    let symbol: String
    let title: String
    let text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(tr(title)).font(.title3.weight(.semibold))
            Text(tr(text)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action { Button(tr(action.0), action: action.1).padding(.top, 4) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows "not connected" / "allow on the phone" / errors instead of an empty list.
struct Gate<Content: View>: View {
    @EnvironmentObject var store: Store
    let section: String
    let what: String
    var perm: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        if !store.connected {
            Placeholder(symbol: "antenna.radiowaves.left.and.right.slash", title: "Phone not connected",
                        text: tr("Open PhoneCast on the phone. It connects by itself on the same Wi-Fi or over Tailscale.") + "\n" + tr(store.linkState))
        } else if let perm, store.perms[perm] == false || store.errors[section] == "permission" {
            Placeholder(symbol: "lock", title: "Allow \(what) on the phone",
                        text: "In the PhoneCast app on the phone, tap “\(perm == "files" ? "Allow browsing phone files from the Mac" : "Allow messages, calls, contacts & photos")”.")
        } else if let e = store.errors[section] {
            Placeholder(symbol: "exclamationmark.triangle", title: "Couldn't load \(what)", text: e)
        } else {
            content
        }
    }
}

let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()
func when(_ d: Date) -> String {
    if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.day().month(.abbreviated))
}
func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// MARK: overview

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: MainWindowController.Nav

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Overview").font(.largeTitle.bold())
                UpdateBanner()
                HStack(alignment: .top, spacing: 16) {
                    Panel(title: store.phoneName, symbol: "smartphone") {
                        if store.connected {
                            let s = store.phoneStatus
                            Row("Link", store.rttMs >= 0 ? "\(Int(store.rttMs.rounded())) ms round trip" : "—")
                            if let b = s["battery"] as? Int {
                                BarRow("Battery", Double(b) / 100, "\(b) %" + ((s["charging"] as? Bool ?? false) ? " · charging" : ""),
                                       tint: b <= 15 ? .red : b <= 30 ? .orange : .green)
                            } else { Row("Battery", "—") }
                            Row("Temperature", (s["batteryTemp"] as? Double).map { String(format: "%.1f °C", $0) } ?? "—")
                            let heat = min(6, max(0, s["thermal"] as? Int ?? 0))
                            BarRow("Heat", Double(heat + 1) / 7, ["normal", "warm", "hot", "throttling", "very hot", "emergency", "shutdown"][heat],
                                   tint: heat == 0 ? .green : heat <= 2 ? .orange : .red)
                            Row("Network", (s["net"] as? String ?? "—") + ((s["rssi"] as? Int).map { " · \($0) dBm" } ?? ""))
                            Row("Free storage", (s["freeGB"] as? Double).map { String(format: "%.0f GB", $0) } ?? "—")
                            Row("Screen", store.phoneCasting ? "shared with this Mac" : "not shared")
                        } else {
                            Text(tr(store.linkState)).foregroundStyle(.secondary)
                        }
                    }
                    Panel(title: Host.current().localizedName ?? "This Mac", symbol: "laptopcomputer") {
                        let m = store.macStats
                        if let b = m["battery"] as? Int {
                            BarRow("Battery", Double(b) / 100, "\(b) %" + ((m["charging"] as? Bool ?? false) ? " · on power" : ""),
                                   tint: b <= 15 ? .red : b <= 30 ? .orange : .green)
                        } else { Row("Battery", "—") }
                        if let c = m["cpu"] as? Int { BarRow("CPU", Double(c) / 100, "\(c) %", tint: c > 85 ? .orange : .accentColor) } else { Row("CPU", "—") }
                        if let c = m["mem"] as? Int { BarRow("Memory", Double(c) / 100, "\(c) %", tint: c > 90 ? .orange : .accentColor) } else { Row("Memory", "—") }
                        Row("Heat", m["thermal"] as? String ?? "—")
                        Row("Mac screen on the phone", store.phoneControlsMac ? "in use" : "not in use")
                    }
                }
                if store.connected, let np = store.nowPlaying { NowPlayingCard(np: np) }
                HStack(spacing: 10) {
                    // icons only: the row is too narrow for the words; hovering shows the full name
                    Button { Hub.shared.mirror() } label: {
                        Label(store.phoneCasting ? "Show mirror" : "Mirror phone", systemImage: "rectangle.on.rectangle").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help(store.phoneCasting ? "Show mirror (⇧⌘M)" : "Mirror phone (⇧⌘M)")
                    Button { Hub.shared.chooseFiles(nil) } label: { Label("Send files…", systemImage: "square.and.arrow.up") }
                        .help("Send files…")
                    Button { Hub.shared.sendClipboard(nil) } label: { Label("Send clipboard", systemImage: "doc.on.clipboard") }
                        .help("Send clipboard")
                    Button { nav.section = .messages } label: { Label("New message", systemImage: "square.and.pencil") }
                        .help("New message")
                    Button { Hub.shared.ring(!store.ringing) } label: {
                        Label(store.ringing ? "Stop ringing" : "Find phone", systemImage: store.ringing ? "bell.slash" : "bell.and.waves.left.and.right")
                    }
                    .help(store.ringing ? "Stop ringing" : "Find phone")
                    Button { Continuity.locatePhone() } label: { Label("Show on map", systemImage: "map") }
                        .help("Show on map")
                    Button { Continuity.sendTabToPhone() } label: { Label("Tab to phone", systemImage: "safari") }
                        .help("Tab to phone")
                    Button { Continuity.openInFinder() } label: { Label("Phone in Finder", systemImage: "externaldrive.connected.to.line.below") }
                        .help("Phone in Finder")
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .disabled(!store.connected)
                Panel(title: "Devices", symbol: "point.3.connected.trianglepath.dotted") {
                    ForEach(store.devices) { d in
                        HStack {
                            Circle().fill(d.ms == nil ? Color.secondary.opacity(0.4) : .green).frame(width: 8, height: 8)
                            Text(d.name)
                            Spacer()
                            Text(d.ms.map { "\(Int($0.rounded())) ms" } ?? "offline").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text("Time to open a connection, every 5 s. Edit the list in Settings.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
    }
}

/// What the phone is playing, with play/pause and skip (v0.3).
struct NowPlayingCard: View {
    let np: Store.NowPlaying
    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let art = np.art { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title).font(.headline).lineLimit(1)
                Text([np.artist, np.app].filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 18) {
                Button { Hub.shared.mediaCommand("prev") } label: { Image(systemName: "backward.fill") }
                Button { Hub.shared.mediaCommand("toggle") } label: { Image(systemName: np.playing ? "pause.fill" : "play.fill").font(.title2) }
                Button { Hub.shared.mediaCommand("next") } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain).font(.title3)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tr(title), systemImage: symbol).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A row with a small capacity bar (battery, CPU, memory, heat).
struct BarRow: View {
    let k: String, frac: Double, v: String, tint: Color
    init(_ k: String, _ frac: Double, _ v: String, tint: Color) { self.k = k; self.frac = frac; self.v = v; self.tint = tint }
    var body: some View {
        HStack(spacing: 10) {
            Text(tr(k)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Capsule().fill(.quaternary).frame(width: 70, height: 6)
                .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 70 * max(0.04, min(1, frac)), height: 6) }
            Text(v).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
        }.font(.callout)
    }
}

struct Row: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack { Text(tr(k)).foregroundStyle(.secondary); Spacer(); Text(tr(v)).monospacedDigit() }.font(.callout)
    }
}

// MARK: mirror

struct MirrorView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Placeholder(symbol: "rectangle.on.rectangle", title: store.phoneCasting ? "The phone is sharing its screen" : "Mirror the phone",
                    text: store.phoneCasting
                        ? "Open the mirror window to see and control it with mouse and keyboard."
                        : "PhoneCast asks the phone to share its screen. Tap “Start now” on the phone once. Faster on the phone: the “Cast to Mac” Quick Settings tile.",
                    action: (store.phoneCasting ? "Open mirror window" : "Mirror phone", { Hub.shared.mirror() }))
    }
}

// MARK: notifications

struct NotificationsView: View {
    @EnvironmentObject var store: Store
    @State private var replyTo: String?
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Mute all", isOn: $store.muteAll).toggleStyle(.switch).controlSize(.small)
                if store.quietNow { Text("Quiet hours").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                Spacer()
                Button("Clear all") { store.clearAll() }.disabled(store.notifications.isEmpty)
            }
            .padding(12)
            Divider()
            if store.notifications.isEmpty {
                Placeholder(symbol: "bell.slash", title: "No notifications",
                            text: store.perms["notifications"] == false
                                ? "Allow notification access in the PhoneCast app on the phone."
                                : "Notifications from the phone show up here and as banners.")
            } else {
                List(store.notifications) { n in
                    HStack(alignment: .top, spacing: 10) {
                        AppIcon(image: store.icons[n.pkg], size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(n.app).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(when(n.date)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if !n.title.isEmpty { Text(n.title).font(.headline) }
                            if !n.text.isEmpty { Text(n.text).textSelection(.enabled) }
                            if replyTo == n.key {
                                HStack {
                                    TextField("Reply…", text: $text).textFieldStyle(.roundedBorder).onSubmit { send(n) }
                                    Button("Send") { send(n) }.disabled(text.isEmpty)
                                    Button("Cancel") { replyTo = nil }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    if n.canReply { Button("Reply") { replyTo = n.key; text = "" } }
                                    Button("Open on phone") { store.open(n) }
                                    Button("Clear") { store.dismiss(n) }
                                }
                                .controlSize(.small).buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button(store.mutedApps.contains(n.pkg) ? "Show banners from \(n.app)" : "No banners from \(n.app)") {
                            if store.mutedApps.contains(n.pkg) { store.mutedApps.remove(n.pkg) } else { store.mutedApps.insert(n.pkg) }
                        }
                        Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n.title + "\n" + n.text, forType: .string) }
                    }
                }
            }
        }
    }
    private func send(_ n: PhoneNotif) { guard !text.isEmpty else { return }; store.reply(n, text); replyTo = nil; text = "" }
}

// MARK: messages

struct MessagesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: Int64?
    @State private var composing = false
    @State private var search = ""

    var body: some View {
        Gate(section: "sms", what: "messages", perm: "sms") {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                        Button { composing = true; selected = nil } label: { Image(systemName: "square.and.pencil") }.help("New message")
                        Button { store.loadThreads() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    }
                    .padding(8)
                    List(filtered, selection: $selected) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title).font(.headline).lineLimit(1)
                                Spacer()
                                Text(when(t.date)).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text((t.mine ? "You: " : "") + t.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                if t.unread > 0 { Spacer(); Text("\(t.unread)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule()).foregroundStyle(.white) }
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(t.id)
                    }
                }
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)

                Group {
                    if composing {
                        NewMessageView(to: prefill) { composing = false; prefill = "" }.id(prefill)
                    } else if let id = selected, let t = store.threads.first(where: { $0.id == id }) {
                        ThreadView(thread: t)
                    } else {
                        Placeholder(symbol: "message", title: "Messages", text: "SMS from the phone. Pick a conversation or start a new one.\nChats in WhatsApp, Signal or RCS are answered from Notifications.")
                    }
                }
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if store.threads.isEmpty { store.loadThreads() } }
        .onReceive(NotificationCenter.default.publisher(for: .openThread)) { n in
            if let id = n.object as? Int64 { selected = id; composing = false }
            else if let num = n.object as? String { prefill = num; composing = true; selected = nil }
        }
    }
    @State private var prefill = ""

    private var filtered: [SmsThread] {
        search.isEmpty ? store.threads : store.threads.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search) }
    }
}

struct ThreadView: View {
    @EnvironmentObject var store: Store
    let thread: SmsThread
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(thread.title).font(.headline)
                    if !thread.name.isEmpty { Text(thread.address).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { store.dial(thread.address) } label: { Image(systemName: "phone") }.help("Call from the phone")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.messages[thread.id] ?? []) { m in
                            HStack {
                                if m.mine { Spacer(minLength: 60) }
                                VStack(alignment: m.mine ? .trailing : .leading, spacing: 2) {
                                    if let t = m.thumb {
                                        // MMS picture: click for the full one
                                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: 240, maxHeight: 320)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            .onTapGesture { if let u = m.image { Hub.shared.fetchFile("photo.get", ["uri": u], keep: false) { QuickLook.shared.show($0) } } }
                                            .help("Click to open")
                                    }
                                    if !m.text.isEmpty {
                                    Text(m.text).textSelection(.enabled)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(m.mine ? Color.accentColor : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .foregroundStyle(m.mine ? .white : .primary)
                                    }
                                    Text(when(m.date)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if !m.mine { Spacer(minLength: 60) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.messages[thread.id]?.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
                .onAppear { if let last = store.messages[thread.id]?.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider()
            HStack {
                TextField("Text message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                    .onSubmit(send)
                Button("Send", action: send).keyboardShortcut(.return, modifiers: .command).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .onAppear { store.loadThread(thread.id) }
        .onChange(of: thread.id) { _, id in store.loadThread(id) }
        .onChange(of: thread.date) { _, _ in store.loadThread(thread.id) }
    }
    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.sendSms(to: thread.address, text: t, thread: thread.id)
        text = ""
    }
}

struct NewMessageView: View {
    @EnvironmentObject var store: Store
    @State var to: String
    let done: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New message").font(.title2.bold())
            TextField("To: name or number", text: $to).textFieldStyle(.roundedBorder)
            if !to.isEmpty, number == nil || !matches.isEmpty {
                List(matches.prefix(8), id: \.1) { m in
                    Button { to = m.1 } label: { HStack { Text(m.0); Spacer(); Text(m.1).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                }
                .frame(height: min(200, CGFloat(matches.prefix(8).count) * 28 + 10))
            }
            TextField("Message", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Send") {
                    guard let n = number else { return }
                    store.sendSms(to: n, text: text, thread: nil); done()
                }
                .keyboardShortcut(.defaultAction).disabled(number == nil || text.isEmpty)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { if store.contacts.isEmpty { store.loadContacts() } }
    }
    private var number: String? {
        let digits = to.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 3 && digits.count >= to.filter { !$0.isWhitespace && $0 != "-" && $0 != "/" }.count ? digits : nil
    }
    private var matches: [(String, String)] {
        store.contacts.filter { $0.name.localizedCaseInsensitiveContains(to) || $0.numbers.contains { $0.n.contains(to) } }
            .flatMap { c in c.numbers.map { (c.name, $0.n) } }
    }
}

// MARK: calls

struct CallsView: View {
    @EnvironmentObject var store: Store
    @State private var dialNumber = ""
    var body: some View {
        Gate(section: "calls", what: "calls", perm: "calls") {
            VStack(spacing: 0) {
                if let c = store.call {
                    HStack {
                        Image(systemName: "phone.fill").foregroundStyle(.green)
                        Text((c["state"] == "ringing" ? "Incoming: " : "On a call: ") + (c["name"].flatMap { $0.isEmpty ? nil : $0 } ?? c["number"] ?? ""))
                        Spacer()
                        if c["state"] == "ringing" { Button("Answer") { store.answer() } }
                        Button(c["state"] == "ringing" ? "Decline" : "End") { store.hangUp() }
                    }
                    .padding(12).background(.green.opacity(0.1))
                }
                HStack {
                    TextField("Number to call", text: $dialNumber).textFieldStyle(.roundedBorder).onSubmit(dial)
                    Button { dial() } label: { Label("Call", systemImage: "phone.fill") }.disabled(dialNumber.isEmpty)
                    Button { store.loadCalls() } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(12)
                Text("Calls are placed and answered on the phone; talk with the phone or its headset.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                Divider()
                List(store.calls) { c in
                    HStack {
                        Image(systemName: c.type == "in" ? "phone.arrow.down.left" : c.type == "out" ? "phone.arrow.up.right" : "phone.down")
                            .foregroundStyle(c.type == "missed" || c.type == "rejected" ? .red : .secondary).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(c.name.isEmpty ? c.number : c.name).foregroundStyle(c.type == "missed" ? .red : .primary)
                            if !c.name.isEmpty { Text(c.number).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if c.duration > 0 { Text(Duration.seconds(c.duration).formatted(.time(pattern: .minuteSecond))).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        Text(when(c.date)).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        Button { store.dial(c.number) } label: { Image(systemName: "phone") }.buttonStyle(.borderless).help("Call back")
                    }
                }
            }
        }
        .onAppear { if store.calls.isEmpty { store.loadCalls() } }
    }
    private func dial() { guard !dialNumber.isEmpty else { return }; store.dial(dialNumber); dialNumber = "" }
}

// MARK: contacts

struct ContactsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: MainWindowController.Nav
    @State private var search = ""
    var body: some View {
        Gate(section: "contacts", what: "contacts", perm: "contacts") {
            VStack(spacing: 0) {
                TextField("Search \(store.contacts.count) contacts", text: $search).textFieldStyle(.roundedBorder).padding(12)
                List(filtered) { c in
                    HStack(alignment: .top) {
                        Text(String(c.name.prefix(1)).uppercased()).font(.headline).frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.18), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name).font(.headline)
                            ForEach(c.numbers, id: \.n) { num in
                                HStack {
                                    Text(num.n).textSelection(.enabled).monospacedDigit()
                                    if !num.label.isEmpty { Text(num.label).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button { store.dial(num.n) } label: { Image(systemName: "phone") }.help("Call")
                                    Button { compose(num.n) } label: { Image(systemName: "message") }.help("Text")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { if store.contacts.isEmpty { store.loadContacts() } }
    }
    private var filtered: [Contact] {
        search.isEmpty ? store.contacts : store.contacts.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.numbers.contains { $0.n.contains(search) } }
    }
    private func compose(_ n: String) {
        let digits = n.filter { $0.isNumber }
        if let t = store.threads.first(where: { $0.address.filter(\.isNumber).hasSuffix(String(digits.suffix(9))) }) {
            nav.section = .messages
            DispatchQueue.main.async { NotificationCenter.default.post(name: .openThread, object: t.id) }
        } else {
            nav.section = .messages
            DispatchQueue.main.async { NotificationCenter.default.post(name: .openThread, object: n) }
        }
    }
}

extension Notification.Name { static let openThread = Notification.Name("pc.openThread") }

// MARK: photos

struct PhotosView: View {
    @EnvironmentObject var store: Store
    @State private var selection = Set<String>()
    var body: some View {
        Gate(section: "photos", what: "photos", perm: "photos") {
            VStack(spacing: 0) {
                HStack {
                    Text("\(store.photos.count) photos and videos\(store.photosDone ? "" : "+")").foregroundStyle(.secondary)
                    Spacer()
                    if !selection.isEmpty {
                        Button("Save \(selection.count) to Downloads") { save(Array(selection)) }
                    }
                    Button { store.loadPhotos() } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(12)
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 4)], spacing: 4) {
                        ForEach(store.photos) { p in
                            ZStack(alignment: .bottomTrailing) {
                                Group {
                                    if let t = p.thumb { Image(nsImage: t).resizable().scaledToFill() }
                                    else { Rectangle().fill(.quaternary) }
                                }
                                .frame(minWidth: 0, maxWidth: .infinity).frame(height: 130).clipped()
                                if p.video { Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white).shadow(radius: 2).padding(6) }
                                if selection.contains(p.uri) {
                                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Color.accentColor).padding(6)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                }
                            }
                            .overlay(selection.contains(p.uri) ? RoundedRectangle(cornerRadius: 0).stroke(Color.accentColor, lineWidth: 3) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { preview(p) }
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) || !selection.isEmpty {
                                    if selection.contains(p.uri) { selection.remove(p.uri) } else { selection.insert(p.uri) }
                                } else { preview(p) }
                            }
                            .contextMenu {
                                Button("Open") { preview(p) }
                                Button("Save to Downloads") { save([p.uri]) }
                                Button(selection.contains(p.uri) ? "Deselect" : "Select") {
                                    if selection.contains(p.uri) { selection.remove(p.uri) } else { selection.insert(p.uri) }
                                }
                            }
                            .help("\(p.name) · \(bytes(p.size)) · \(when(p.date))")
                            .onAppear { if p.id == store.photos.last?.id { store.loadPhotos(more: true) } }
                        }
                    }
                    .padding(4)
                    if store.loading.contains("photos") { ProgressView().padding() }
                }
            }
        }
        .onAppear { if store.photos.isEmpty { store.loadPhotos() } }
    }

    private func preview(_ p: PhonePhoto) {
        Hub.shared.fetchFile("photo.get", ["uri": p.uri], keep: false) { url in QuickLook.shared.show(url) }
    }

    private func save(_ uris: [String]) {
        for u in uris { Hub.shared.fetchFile("photo.get", ["uri": u], keep: true) { url in if uris.count == 1 { NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
        selection.removeAll()
    }
}

/// Quick Look preview of downloaded files.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?
    func show(_ u: URL) {
        url = u
        guard let p = QLPreviewPanel.shared() else { NSWorkspace.shared.open(u); return }
        p.dataSource = self
        p.reloadData()
        p.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

// MARK: files

struct FilesView: View {
    @EnvironmentObject var store: Store
    @State private var selected: String?
    @State private var dropping = false
    var body: some View {
        Gate(section: "files", what: "file browsing", perm: "files") {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button { up() } label: { Image(systemName: "chevron.left") }.disabled(store.filePath.isEmpty)
                    Button { store.loadFiles("") } label: { Image(systemName: "house") }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            Text("Phone").foregroundStyle(.secondary)
                            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                Button(c) { store.loadFiles(crumbs.prefix(i + 1).joined(separator: "/")) }.buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer()
                    Button { Continuity.openInFinder() } label: { Label("Open in Finder", systemImage: "externaldrive.connected.to.line.below") }
                        .help("Mount the phone's storage as a drive in Finder")
                    Button { Hub.shared.choose(dir: store.filePath) { refresh() } } label: { Label("Upload here…", systemImage: "square.and.arrow.up") }
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(12)
                Divider()
                Table(store.files, selection: $selected) {
                    TableColumn("Name") { f in
                        Label(f.name, systemImage: f.dir ? "folder.fill" : icon(f.name)).foregroundStyle(f.dir ? Color.accentColor : .primary)
                    }
                    TableColumn("Size") { f in Text(f.dir ? "\(f.size) items" : bytes(f.size)).foregroundStyle(.secondary).monospacedDigit() }.width(100)
                    TableColumn("Modified") { f in Text(f.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }.width(160)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let f = store.files.first(where: { $0.name == id }) {
                        if f.dir { Button("Open") { store.loadFiles(join(f.name)) } }
                        else { Button("Quick Look") { fetch(f, keep: false) } }
                        Button(f.dir ? "Download as .zip" : "Download") { fetch(f, keep: true) }
                        Divider()
                        Button("Delete on phone…", role: .destructive) { delete(f) }
                    }
                } primaryAction: { ids in
                    guard let id = ids.first, let f = store.files.first(where: { $0.name == id }) else { return }
                    if f.dir { store.loadFiles(join(f.name)) } else { fetch(f, keep: false) }
                }
                .overlay(dropping ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    var urls: [URL] = []
                    let g = DispatchGroup()
                    for p in providers {
                        g.enter()
                        _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; g.leave() }
                    }
                    g.notify(queue: .main) { Hub.shared.sendFiles(urls, dir: store.filePath) { refresh() } }
                    return true
                }
                Text("Double-click to open · drop files here to upload into this folder").font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .onAppear { if store.files.isEmpty { store.loadFiles(store.filePath) } }
    }
    private var crumbs: [String] { store.filePath.split(separator: "/").map(String.init) }
    private func join(_ n: String) -> String { store.filePath.isEmpty ? n : store.filePath + "/" + n }
    private func up() { store.loadFiles(crumbs.dropLast().joined(separator: "/")) }
    private func refresh() { store.loadFiles(store.filePath) }
    private func fetch(_ f: PhoneFile, keep: Bool) {
        Hub.shared.fetchFile("file.get", ["path": join(f.name)], keep: keep) { url in
            if keep { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { QuickLook.shared.show(url) }
        }
    }
    private func delete(_ f: PhoneFile) {
        let a = NSAlert()
        a.messageText = tr("Delete “%@” on the phone?", f.name)
        a.informativeText = tr(f.dir ? "The folder and everything in it is deleted. This can't be undone." : "This can't be undone.")
        a.addButton(withTitle: tr("Delete")); a.addButton(withTitle: tr("Cancel"))
        a.buttons[0].hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { Hub.shared.request("file.delete", ["path": join(f.name)]) { _ in refresh() } }
    }
    private func icon(_ name: String) -> String {
        let t = UTType(filenameExtension: (name as NSString).pathExtension)
        if t?.conforms(to: .image) == true { return "photo" }
        if t?.conforms(to: .movie) == true { return "film" }
        if t?.conforms(to: .audio) == true { return "music.note" }
        if t?.conforms(to: .archive) == true { return "doc.zipper" }
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        return "doc"
    }
}

// MARK: apps

struct AppsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    var body: some View {
        Gate(section: "apps", what: "apps") {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                    Button { store.loadApps() } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(12)
                Text("Click an app to open it on the phone and show it here. Right-click: open it in its own window (needs USB debugging, see Settings → Advanced).").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 16) {
                        ForEach(filtered) { a in
                            Button { store.openApp(a) } label: {
                                VStack(spacing: 6) {
                                    AppIcon(image: a.icon, size: 48)
                                    Text(a.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: 92)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open on the phone") { store.openApp(a) }
                                Button("Open in its own window (USB debugging)") { Advanced.openAppWindow(pkg: a.pkg, name: a.name) }
                            }
                        }
                    }
                    .padding(16)
                    if store.loading.contains("apps") { ProgressView() }
                }
            }
        }
        .onAppear { if store.apps.isEmpty { store.loadApps() } }
    }
    private var filtered: [PhoneApp] { search.isEmpty ? store.apps : store.apps.filter { $0.name.localizedCaseInsensitiveContains(search) } }
}

// MARK: transfers

struct TransfersView: View {
    @EnvironmentObject var store: Store
    @State private var dropping = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Hub.shared.chooseFiles(nil) } label: { Label("Send files or folders…", systemImage: "square.and.arrow.up") }.disabled(!store.connected)
                Spacer()
                Button("Open Downloads") {
                    NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                }
            }
            .padding(12)
            Divider()
            if store.transfers.isEmpty {
                Placeholder(symbol: "arrow.up.arrow.down", title: "Drop files here",
                            text: "They go to the phone's Downloads/PhoneCast folder. From the phone: Share → “PhoneCast to Mac”; files land in ~/Downloads.")
            } else {
                List(store.transfers) { t in
                    HStack {
                        Image(systemName: t.outgoing ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.name).lineLimit(1)
                            if t.state == .running { ProgressView(value: t.progress).controlSize(.small) }
                            else { Text((t.state == .failed ? "Failed" : t.outgoing ? "Sent to phone" : "Received") + (t.size > 0 ? " · \(bytes(t.size))" : "") + " · \(when(t.started))")
                                .font(.caption).foregroundStyle(t.state == .failed ? .red : .secondary) }
                        }
                        Spacer()
                        if let u = t.url, t.state == .done, FileManager.default.fileExists(atPath: u.path) {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
            }
        }
        .overlay(dropping ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            var urls: [URL] = []
            let g = DispatchGroup()
            for p in providers { g.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; g.leave() } }
            g.notify(queue: .main) { Hub.shared.sendFiles(urls) }
            return true
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var pin = UserDefaults.standard.string(forKey: "pin") ?? ""
    @State private var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @State private var tailnet = UserDefaults.standard.string(forKey: "tailnetHost") ?? ""
    @State private var devices = Hub.shared.probes.config
    @State private var dashURL = PcDashboard.shared.base
    @State private var qr = Pairing.qrImage(size: 360)
    @State private var login = Hub.loginEnabled
    @State private var axOK = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    private var phoneKeyShort: String {
        guard let k = UserDefaults.standard.string(forKey: "phoneKey") else { return "not paired yet" }
        return stride(from: 0, to: min(32, k.count), by: 4).map { i -> String in
            let a = k.index(k.startIndex, offsetBy: i); return String(k[a..<k.index(a, offsetBy: 4)])
        }.joined(separator: " ")
    }

    var body: some View {
        Form {
            Section("Pair a phone") {
                HStack(alignment: .top, spacing: 18) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                        .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this with PhoneCast on the phone").font(.headline)
                        Text("Phone app → Settings → “Scan computer's QR code”. Both sides then prove a shared key to each other on every connection: no PIN to type, and nothing secret crosses the network.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(tr(store.linkState)).font(.caption).foregroundStyle(store.connected ? .green : .secondary)
                        Button("New QR code (phones paired by QR must scan again)") {
                            Pairing.reset(); qr = Pairing.qrImage(size: 360); Hub.shared.pairingChanged()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section("Or pair with the PIN") {
                TextField("PIN (shown in the phone app)", text: $pin)
                TextField("Phone IP address (optional, found automatically on the same Wi-Fi)", text: $host)
                TextField("Phone Tailscale address (optional, for other networks)", text: $tailnet)
                HStack {
                    Text(tr(store.linkState)).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button("Save and connect") {
                        let d = UserDefaults.standard
                        d.set(pin.trimmingCharacters(in: .whitespaces), forKey: "pin")
                        d.set(host.trimmingCharacters(in: .whitespaces), forKey: "host")
                        d.set(tailnet.trimmingCharacters(in: .whitespaces), forKey: "tailnetHost")
                        Hub.shared.pairingChanged()
                    }
                }
            }
            Section("Security") {
                LabeledContent("Phone's link key") {
                    Text(phoneKeyShort).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Text("The link (notifications, messages, files, clipboard) is encrypted with TLS 1.3. Compare this key with the one in the phone app once. The mirror proves itself with a key it got over that link, so the PIN isn't sent in the clear. Mirror video isn't encrypted to keep it as fast as possible; away from home, Tailscale encrypts it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Forget phone key (after reinstalling PhoneCast on the phone)") {
                    UserDefaults.standard.removeObject(forKey: "phoneKey"); UserDefaults.standard.removeObject(forKey: "mirrorKey")
                    Hub.shared.reconnect()
                }
            }
            Section("Notifications") {
                Toggle("Show banners", isOn: Binding(get: { !store.muteAll }, set: { store.muteAll = !$0 }))
                Toggle("Play a sound", isOn: $store.notifSound)
                Toggle("Quiet while the phone is on Do Not Disturb", isOn: $store.followPhoneDnd)
                Toggle("Quiet hours", isOn: $store.quietHours)
                if store.quietHours {
                    HStack {
                        Picker("From", selection: $store.quietFrom) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        Picker("to", selection: $store.quietTo) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    }
                }
                let known = store.appNames.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
                if !known.isEmpty {
                    DisclosureGroup("Apps (\(known.count))") {
                        ForEach(known, id: \.key) { pkg, name in
                            Toggle(name, isOn: Binding(get: { !store.mutedApps.contains(pkg) },
                                                       set: { if $0 { store.mutedApps.remove(pkg) } else { store.mutedApps.insert(pkg) } }))
                        }
                    }
                }
            }
            Section("Clipboard") {
                Toggle("Copy to the phone automatically when I copy on the Mac", isOn: $store.autoClipboard)
                Text("From the phone: Share → “PhoneCast to Mac”, or the “Clipboard to Mac” Quick Settings tile. Android doesn't let apps read the clipboard in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lock this Mac when the phone leaves") {
                Toggle("Lock the Mac when the phone is gone and nobody is using the Mac", isOn: $store.autoLock)
                Picker("After", selection: $store.autoLockMinutes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!store.autoLock)
                Text("Locks only when the phone's link has been gone that long AND the Mac's keyboard and mouse haven't been touched for that long, so it never locks while you work. Needs Accessibility (below).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("PC (Hermes dashboard)") {
                TextField("Dashboard address, e.g. http://100.x.y.z:8765 (empty = no PC page)", text: $dashURL)
                HStack {
                    Text("Use its Tailscale address: the dashboard only accepts controls from Tailscale devices. The phone gets it too.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { PcDashboard.shared.base = dashURL.trimmingCharacters(in: .whitespaces); PcDashboard.shared.objectWillChange.send() }
                }
            }
            Section("Devices to watch") {
                TextEditor(text: $devices).font(.system(.body, design: .monospaced)).frame(height: 90)
                HStack { Text("One per line: name, then host:port").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save") { Hub.shared.probes.config = devices } }
            }
            Section("This Mac") {
                Toggle("Open PhoneCast at login", isOn: Binding(get: { login }, set: { Hub.loginEnabled = $0; login = Hub.loginEnabled }))
                Perm(ok: screenOK, title: "Screen Recording", why: "lets the phone see this Mac") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Perm(ok: axOK, title: "Accessibility", why: "lets the phone click and type on this Mac") {
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Section("Phone") {
                ForEach([("notifications", "Notifications"), ("sms", "Messages"), ("calls", "Calls"), ("callControl", "Answer & dial"),
                         ("contacts", "Contacts"), ("photos", "Photos"), ("files", "Files"), ("control", "Mouse & keyboard (mirror)")], id: \.0) { k, name in
                    HStack {
                        Image(systemName: store.perms[k] == true ? "checkmark.circle.fill" : "circle").foregroundStyle(store.perms[k] == true ? .green : .secondary)
                        Text(name)
                    }
                }
                Text("Missing ones are allowed in the PhoneCast app on the phone.").font(.caption).foregroundStyle(.secondary)
            }
            AdvancedSection()
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            axOK = AXIsProcessTrusted(); screenOK = CGPreflightScreenCaptureAccess()
        }
    }
}

/// Settings → Advanced (USB debugging): scrcpy-powered extras (Advanced.swift).
struct AdvancedSection: View {
    @State private var status = "…"
    @State private var shape = Advanced.appShape
    @State private var pairAddr = ""
    @State private var pairCode = ""
    @State private var connectAddr = UserDefaults.standard.string(forKey: "advancedConnect") ?? ""
    @State private var result = ""
    @State private var mic = false
    @State private var screenOff = UserDefaults.standard.bool(forKey: "advancedScreenOff")

    var body: some View {
        Section("Advanced (USB debugging)") {
            Text("With USB debugging (or Wireless debugging) on, PhoneCast can do what Android only lets a computer's debugger do: open phone apps in their own Mac windows, show the phone's camera in a window, play the phone's microphone on the Mac, and turn the phone's screen really off while it's mirrored. Uses scrcpy (brew install scrcpy).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Image(systemName: status.hasPrefix(tr("Ready")) ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(status.hasPrefix(tr("Ready")) ? .green : .orange)
                Text(status)
                Spacer()
                Button("Check again") { refresh() }
            }
            Picker("App windows", selection: $shape) {
                Text("Phone shape (tall)").tag("tall")
                Text("Tablet shape (wide)").tag("wide")
                Text("Same as the phone's screen").tag("phone")
            }
            .onChange(of: shape) { _, v in Advanced.appShape = v }
            Text("Apps: right-click an app → “Open in its own window”. Closing the window puts the app back on the phone.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Phone camera (back)") { Advanced.camera(facing: "back") }
                Button("Phone camera (front)") { Advanced.camera(facing: "front") }
            }
            Toggle("Play the phone's microphone on the Mac", isOn: Binding(get: { mic }, set: { mic = $0; Advanced.microphone($0) }))
            Toggle("Turn the phone's screen off while it's mirrored", isOn: Binding(get: { screenOff }, set: { screenOff = $0; Advanced.screenOff($0) }))
            DisclosureGroup("Wireless debugging (no cable)") {
                Text("On the phone: Developer options → Wireless debugging → Pair device with pairing code. Enter the address and code shown there.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("192.168.1.20:37099", text: $pairAddr)
                    TextField("Pairing code", text: $pairCode).frame(width: 110)
                    Button("Pair") { Advanced.pair(pairAddr, code: pairCode) { result = $0; refresh() } }
                }
                HStack {
                    TextField("Address under Wireless debugging (IP:port)", text: $connectAddr)
                    Button("Connect") {
                        UserDefaults.standard.set(connectAddr, forKey: "advancedConnect")
                        Advanced.connect(connectAddr) { result = $0; refresh() }
                    }
                }
                if !result.isEmpty { Text(result).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        }
        .onAppear { refresh(); mic = Advanced.running("mic") }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let s = Advanced.status()
            DispatchQueue.main.async { status = s }
        }
    }
}

struct Perm: View {
    let ok: Bool, title: String, why: String
    let fix: () -> Void
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) { Text(title); Text(why).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if !ok { Button("Allow…", action: fix) }
        }
    }
}
