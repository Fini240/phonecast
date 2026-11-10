import AppKit
import SwiftUI

/// my-pc through the Hermes dashboard on ZimaOS (its JSON API): live stats, wake, sleep,
/// shut down, boot into Linux or Windows, monitors, RGB, AI engine, loaded models, tokens.
/// Control needs a Tailscale address (the dashboard only accepts it from the tailnet).
final class PcDashboard: ObservableObject {
    static let shared = PcDashboard()

    @Published var stats: [String: Any] = [:]
    @Published var reachable = false
    @Published var lastError: String?
    @Published var message: String?
    @Published var busy: String?
    private var timer: Timer?
    private var watchers = 0

    var base: String {
        get { UserDefaults.standard.string(forKey: "dashboardURL") ?? "http://100.64.0.4:8765" }
        set { UserDefaults.standard.set(newValue, forKey: "dashboardURL") }
    }

    /// Poll every 2 s while a view shows it.
    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        if watchers > 0, timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        } else if watchers <= 0 { timer?.invalidate(); timer = nil; watchers = 0 }
    }

    func refresh() {
        guard let u = URL(string: base + "/api/stats") else { return }
        var r = URLRequest(url: u); r.timeoutInterval = 4
        URLSession.shared.dataTask(with: r) { d, _, e in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.reachable = o != nil
                self.lastError = o == nil ? (e?.localizedDescription ?? "no answer") : nil
                if let o { self.stats = o }
            }
        }.resume()
    }

    func post(_ path: String, _ body: [String: Any], label: String) {
        guard let u = URL(string: base + "/api/" + path) else { return }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"; r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        busy = label
        URLSession.shared.dataTask(with: r) { d, resp, e in
            let o = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                self.busy = nil
                if let m = o?["message"] as? String { self.message = m }
                else if let m = o?["error"] as? String { self.message = m }
                else { self.message = e?.localizedDescription ?? "HTTP \(code)" }
                self.refresh()
            }
        }.resume()
    }

    // convenience
    var pc: [String: Any] { stats["pc"] as? [String: Any] ?? [:] }
    var online: Bool { stats["online"] as? Bool ?? false }
    var os: String { pc["os"] as? String ?? "" }
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
private func gb(_ v: Any?) -> String { num(v).map { String(format: "%.1f GB", $0 / 1e9) } ?? "—" }
private func pct(_ v: Any?) -> String { num(v).map { String(format: "%.0f %%", $0) } ?? "—" }
private func temp(_ v: Any?) -> String { num(v).map { String(format: "%.0f °C", $0) } ?? "—" }

struct PcView: View {
    @ObservedObject var d = PcDashboard.shared
    @State private var confirm: (title: String, path: String, body: [String: Any])?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("my-pc").font(.largeTitle.bold())
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(string: d.base)!) } label: { Label("Full dashboard", systemImage: "safari") }
                        .help("Studio (video and pictures), agent chat and everything else")
                }
                if !d.reachable {
                    Text("Dashboard not reachable at \(d.base) (\(d.lastError ?? "…")). It runs on ZimaOS; Tailscale must be on.")
                        .foregroundStyle(.orange)
                }
                statusPanel
                HStack(alignment: .top, spacing: 14) { gpuPanel; cpuPanel }
                controls
                aiPanel
                if let m = d.message {
                    HStack { Image(systemName: "info.circle"); Text(m) }.font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .onAppear { d.watch(true) }
        .onDisappear { d.watch(false) }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) { confirm = nil }
            Button("Do it", role: .destructive) { if let c = confirm { d.post(c.path, c.body, label: c.title) }; confirm = nil }
        } message: { Text("Anything unsaved on the PC may be lost.") }
    }

    private var statusPanel: some View {
        Panel(title: d.online ? "Running \(d.os.capitalized)" : "Asleep or off", symbol: d.online ? "desktopcomputer" : "moon.zzz") {
            if let b = d.stats["boot"] as? [String: Any], let m = b["message"] as? String { Row("Last boot", m) }
            if let up = num(d.pc["uptime"]) { Row("Up for", Duration.seconds(up).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))) }
            if let m = d.pc["cpu_model"] as? String { Row("CPU", m) }
            if let t = d.stats["engine"] as? String { Row("AI engine", t) }
            if let busy = d.busy { HStack { ProgressView().controlSize(.small); Text(busy + "…") } }
        }
    }

    private var gpuPanel: some View {
        Panel(title: "Graphics (RX 6700 XT)", symbol: "cpu") {
            Row("Busy", pct(d.pc["busy"]))
            Row("Video memory", "\(gb(d.pc["vram_used"])) of \(gb(d.pc["vram_total"]))")
            Row("Temperature", temp(d.pc["temp"]) + (num(d.pc["temp_edge"]).map { String(format: " (edge %.0f)", $0) } ?? ""))
            Row("Power", num(d.pc["power"]).map { String(format: "%.0f W", $0) } ?? "—")
            Row("Fan", num(d.pc["fan"]).map { String(format: "%.0f rpm", $0) } ?? "—")
        }
    }

    private var cpuPanel: some View {
        Panel(title: "Processor & memory", symbol: "memorychip") {
            Row("CPU", pct(d.pc["cpu_pct"]))
            Row("CPU temperature", temp(d.pc["cpu_temp"]))
            Row("Clock", num(d.pc["cpu_freq"]).map { String(format: "%.2f GHz", $0) } ?? "—")
            Row("RAM", "\(gb(d.pc["mem_used"])) of \(gb(d.pc["mem_total"]))")
            Row("Whole PC", num(d.pc["total_watts"]).map { String(format: "%.0f W", $0) } ?? "—")
        }
    }

    private var controls: some View {
        Panel(title: "Control", symbol: "power") {
            HStack {
                Button { d.post("wake", [:], label: "Waking the PC") } label: { Label("Wake", systemImage: "sunrise") }.disabled(d.online)
                Button { confirm = ("Put the PC to sleep?", "power", ["action": "suspend"]) } label: { Label("Sleep", systemImage: "moon") }.disabled(!d.online)
                Button { confirm = ("Shut the PC down?", "power", ["action": "poweroff"]) } label: { Label("Shut down", systemImage: "power") }.disabled(!d.online)
            }
            HStack {
                Text("Start into").foregroundStyle(.secondary)
                Button("Linux") { confirm = ("Restart into Linux?", "boot", ["os": "linux"]) }.disabled(d.os == "linux")
                Button("Windows") { confirm = ("Restart into Windows?", "boot", ["os": "windows"]) }.disabled(d.os == "windows")
            }
            HStack {
                Text("Monitors").foregroundStyle(.secondary)
                Button("On") { d.post("display", ["action": "on"], label: "Monitors on") }
                Button("Off") { d.post("display", ["action": "off"], label: "Monitors off") }
                Spacer()
                Text("Lights").foregroundStyle(.secondary)
                ForEach(["red", "purple", "blue", "green"], id: \.self) { c in
                    Button { d.post("rgb", ["color": c], label: "Lights \(c)") } label: {
                        Circle().fill(Color(c == "red" ? NSColor.systemRed : c == "purple" ? .systemPurple : c == "blue" ? .systemBlue : .systemGreen)).frame(width: 14, height: 14)
                    }.help(c)
                }
                Button("Off") { d.post("rgb", ["color": "off"], label: "Lights off") }
                Toggle("Follow load", isOn: Binding(get: { d.stats["rgb_auto"] as? Bool ?? false },
                                                    set: { d.post("rgbauto", ["on": $0], label: "Lights") })).toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text("Stream").foregroundStyle(.secondary)
                Button { PC.stream(Array(PC.targets(d.os == "linux" ? PC.linux : PC.windows).prefix(1))) } label: { Label("Monitor 1", systemImage: "play.display") }
                Button { PC.stream(Array(PC.targets(d.os == "linux" ? PC.linux : PC.windows).suffix(1))) } label: { Label("Monitor 2", systemImage: "play.display") }
                Button { PC.stream(PC.targets(d.os == "linux" ? PC.linux : PC.windows)) } label: { Label("Both", systemImage: "rectangle.split.2x1") }
            }
            .disabled(!d.online)
            Text("Controls work from Tailscale devices only (the dashboard refuses everything else).").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var aiPanel: some View {
        Panel(title: "AI", symbol: "sparkles") {
            let models = d.stats["ollama"] as? [[String: Any]] ?? []
            if models.isEmpty { Row("Loaded models", "none") }
            ForEach(models.indices, id: \.self) { i in
                let m = models[i]
                Row(m["name"] as? String ?? "model", gb(m["size_vram"] ?? m["size"]))
            }
            HStack {
                Text("Engine").foregroundStyle(.secondary)
                Button("Ollama") { d.post("engine", ["engine": "ollama"], label: "Switching to Ollama") }
                Button("Strata") { d.post("engine", ["engine": "strata"], label: "Switching to Strata") }
            }
            .disabled(!d.online || d.os != "linux")
            if let t = d.stats["tokens"] as? [String: Any] {
                Row("Hermes tokens", "\(num(t["in"]).map { String(format: "%.1f M in", $0 / 1e6) } ?? "—") · \(num(t["out"]).map { String(format: "%.2f M out", $0 / 1e6) } ?? "—") · \(t["calls"] ?? "-") calls")
            }
        }
    }
}
