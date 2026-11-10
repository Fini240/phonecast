import AppKit
import Combine

struct PhoneNotif: Identifiable, Equatable {
    let key: String
    var id: String { key }
    let pkg, app, title, text: String
    let date: Date
    let canReply: Bool
}

struct SmsThread: Identifiable, Equatable {
    let id: Int64
    let address, name, snippet: String
    let date: Date
    let unread: Int
    let mine: Bool
    var title: String { name.isEmpty ? address : name }
}

struct SmsMessage: Identifiable, Equatable { let id: Int64; let text: String; let date: Date; let mine: Bool }
struct Contact: Identifiable { let id = UUID(); let name: String; let numbers: [(n: String, label: String)] }
struct CallEntry: Identifiable { let id = UUID(); let number, name, type: String; let date: Date; let duration: Int }
struct PhonePhoto: Identifiable { var id: String { uri }; let uri, name: String; let video: Bool; let date: Date; let size: Int64; let thumb: NSImage? }
struct PhoneFile: Identifiable { var id: String { name }; let name: String; let dir: Bool; let size: Int64; let date: Date }
struct PhoneApp: Identifiable { var id: String { pkg }; let pkg, name: String; let icon: NSImage? }

struct Transfer: Identifiable {
    enum State { case running, done, failed }
    let id: Int
    let name: String
    let outgoing: Bool
    let size: Int64
    var progress: Double = 0
    var state: State = .running
    var url: URL?
    let started = Date()
}

/// Everything the windows show. Main thread only.
final class Store: ObservableObject {
    static let shared = Store()
    private var hub: Hub { Hub.shared }

    // connection & monitor
    @Published var connected = false
    @Published var linkState = "Looking for the phone…"
    @Published var phoneName = "Phone"
    @Published var phoneStatus: [String: Any] = [:]
    @Published var perms: [String: Bool] = [:]
    @Published var rttMs: Double = -1
    @Published var phoneCasting = false
    @Published var phoneControlsMac = false
    @Published var macStats: [String: Any] = [:]
    @Published var devices: [DeviceProbes.Result] = []

    // v0.3: what the phone is playing, and whether it's ringing (Find my phone)
    struct NowPlaying: Equatable { var title, artist, app: String; var playing: Bool; var art: NSImage? }
    @Published var nowPlaying: NowPlaying?
    @Published var ringing = false

    // notifications
    @Published var notifications: [PhoneNotif] = []
    @Published var icons: [String: NSImage] = [:]
    @Published var muteAll = UserDefaults.standard.bool(forKey: "muteAll") { didSet { UserDefaults.standard.set(muteAll, forKey: "muteAll") } }
    @Published var mutedApps = Set(UserDefaults.standard.stringArray(forKey: "mutedApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(mutedApps), forKey: "mutedApps") }
    }
    @Published var appNames: [String: String] = (UserDefaults.standard.dictionary(forKey: "appNames") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(appNames, forKey: "appNames") }
    }
    @Published var quietHours = UserDefaults.standard.bool(forKey: "quietHours") { didSet { UserDefaults.standard.set(quietHours, forKey: "quietHours") } }
    @Published var quietFrom = UserDefaults.standard.object(forKey: "quietFrom") as? Int ?? 22 { didSet { UserDefaults.standard.set(quietFrom, forKey: "quietFrom") } }
    @Published var quietTo = UserDefaults.standard.object(forKey: "quietTo") as? Int ?? 7 { didSet { UserDefaults.standard.set(quietTo, forKey: "quietTo") } }
    @Published var notifSound = UserDefaults.standard.object(forKey: "notifSound") as? Bool ?? true { didSet { UserDefaults.standard.set(notifSound, forKey: "notifSound") } }
    @Published var autoLock = UserDefaults.standard.bool(forKey: "autoLock") { didSet { UserDefaults.standard.set(autoLock, forKey: "autoLock") } }
    @Published var autoLockMinutes = UserDefaults.standard.object(forKey: "autoLockMinutes") as? Int ?? 2 { didSet { UserDefaults.standard.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    @Published var autoClipboard = UserDefaults.standard.bool(forKey: "autoClipboard") { didSet { UserDefaults.standard.set(autoClipboard, forKey: "autoClipboard") } }

    // phone data
    @Published var threads: [SmsThread] = []
    @Published var messages: [Int64: [SmsMessage]] = [:]
    @Published var contacts: [Contact] = []
    @Published var calls: [CallEntry] = []
    @Published var photos: [PhonePhoto] = []
    @Published var photosDone = false
    @Published var filePath = ""
    @Published var files: [PhoneFile] = []
    @Published var apps: [PhoneApp] = []
    @Published var transfers: [Transfer] = []
    @Published var errors: [String: String] = [:]     // section -> message
    @Published var loading: Set<String> = []
    @Published var call: [String: String]? = nil       // current call: state, number, name

    var phoneSummary: String {
        var p: [String] = []
        if let b = phoneStatus["battery"] as? Int { p.append("\(b) %" + ((phoneStatus["charging"] as? Bool ?? false) ? " ⚡" : "")) }
        if let t = phoneStatus["batteryTemp"] as? Double { p.append(String(format: "%.0f °C", t)) }
        if let n = phoneStatus["net"] as? String { p.append(n) }
        return p.joined(separator: " · ")
    }

    func applyStatus(_ o: [String: Any]) {
        phoneStatus = o
        phoneCasting = o["casting"] as? Bool ?? false
        if let n = o["name"] as? String { phoneName = n }
        if let p = o["perms"] as? [String: Bool] {
            let newlyAllowed = p.filter { $0.value && perms[$0.key] != true }.map(\.key)
            perms = p
            if !newlyAllowed.isEmpty, connected { refreshAll(only: Set(newlyAllowed)) }
        }
    }

    /// After connecting (or after a permission was granted): load what the sidebar shows.
    func refreshAll(only: Set<String>? = nil) {
        func want(_ k: String) -> Bool { only == nil || only!.contains(k) }
        if want("sms") { loadThreads() }
        if want("calls") { loadCalls() }
        if want("contacts") { loadContacts() }
    }

    // MARK: notifications

    var quietNow: Bool {
        guard quietHours else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return quietFrom <= quietTo ? (h >= quietFrom && h < quietTo) : (h >= quietFrom || h < quietTo)
    }

    func addNotification(_ o: [String: Any]) {
        guard let key = o["key"] as? String else { return }
        let pkg = o["pkg"] as? String ?? ""
        if let b64 = o["icon"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) { icons[pkg] = img }
        let n = PhoneNotif(key: key, pkg: pkg, app: o["app"] as? String ?? pkg, title: o["title"] as? String ?? "",
                           text: o["text"] as? String ?? "", date: Date(), canReply: o["reply"] as? Bool ?? false)
        if appNames[pkg] != n.app { appNames[pkg] = n.app }
        notifications.removeAll { $0.key == key }
        notifications.insert(n, at: 0)
        if notifications.count > 300 { notifications.removeLast(notifications.count - 300) }
        NSLog("hub: notification from \(n.app): \(n.title)")
        // SMS threads change with every message: keep Messages fresh
        if pkg.contains("messag") || pkg.contains("mms") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.loadThreads() } }
        if !muteAll && !quietNow && !mutedApps.contains(pkg) { Banners.shared.show(n, icon: icons[pkg]) }
    }

    func removeNotification(_ key: String) {
        notifications.removeAll { $0.key == key }
        Banners.shared.remove(key)
    }

    func dismiss(_ n: PhoneNotif) { hub.notifAction(n.key, "dismiss"); removeNotification(n.key) }
    func reply(_ n: PhoneNotif, _ text: String) { hub.notifAction(n.key, "reply", text) }
    func open(_ n: PhoneNotif) {
        hub.notifAction(n.key, "open")
        if phoneCasting { hub.onOpenWindow?() }
    }
    func clearAll() { notifications.forEach { hub.notifAction($0.key, "dismiss") }; notifications.removeAll(); Banners.shared.removeAll() }

    // MARK: calls

    func callEvent(_ o: [String: Any]) {
        let st = o["state"] as? String ?? "idle"
        if st == "idle" { call = nil; Banners.shared.endCall(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.loadCalls() }; return }
        var c = call ?? [:]
        c["state"] = st
        if let n = o["number"] as? String, !n.isEmpty { c["number"] = n }
        if let n = o["name"] as? String, !n.isEmpty { c["name"] = n }
        call = c
        Banners.shared.call(c)
    }

    func answer() { hub.request("call.answer") { _ in } }
    func hangUp() { hub.request("call.end") { _ in } }
    func dial(_ number: String) {
        hub.request("call.dial", ["number": number]) { r in self.report("calls", r) }
    }

    // MARK: loading

    private func report(_ section: String, _ r: Result<Any, Hub.HubError>) {
        loading.remove(section)
        if case .failure(let e) = r { errors[section] = e.permission ? "permission" : e.message } else { errors[section] = nil }
    }

    private func load(_ section: String, _ m: String, _ p: [String: Any] = [:], _ apply: @escaping (Any) -> Void) {
        loading.insert(section)
        hub.request(m, p) { r in
            self.report(section, r)
            if case .success(let d) = r { apply(d) }
        }
    }

    private static func date(_ v: Any?) -> Date { Date(timeIntervalSince1970: ((v as? NSNumber)?.doubleValue ?? 0) / 1000) }

    func loadThreads() {
        load("sms", "sms.threads") { d in
            self.threads = (d as? [[String: Any]] ?? []).map {
                SmsThread(id: ($0["thread"] as? NSNumber)?.int64Value ?? 0, address: $0["address"] as? String ?? "",
                          name: $0["name"] as? String ?? "", snippet: $0["snippet"] as? String ?? "",
                          date: Self.date($0["date"]), unread: $0["unread"] as? Int ?? 0, mine: $0["mine"] as? Bool ?? false)
            }
        }
    }

    func loadThread(_ id: Int64) {
        load("thread", "sms.thread", ["thread": id]) { d in
            self.messages[id] = (d as? [[String: Any]] ?? []).map {
                SmsMessage(id: ($0["id"] as? NSNumber)?.int64Value ?? 0, text: $0["text"] as? String ?? "",
                           date: Self.date($0["date"]), mine: $0["mine"] as? Bool ?? false)
            }
        }
    }

    func sendSms(to: String, text: String, thread: Int64?) {
        hub.request("sms.send", ["to": to, "text": text]) { r in
            self.report("sms", r)
            if case .failure(let e) = r { Banners.shared.info("Message not sent", e.permission ? "Allow Messages in the phone app." : e.message); return }
            // the phone stores sent messages a moment later
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let thread { self.loadThread(thread) }
                self.loadThreads()
            }
        }
    }

    func loadContacts() {
        load("contacts", "contacts") { d in
            self.contacts = (d as? [[String: Any]] ?? []).map { o in
                Contact(name: o["name"] as? String ?? "",
                        numbers: (o["numbers"] as? [[String: Any]] ?? []).map { (n: $0["n"] as? String ?? "", label: $0["label"] as? String ?? "") })
            }
        }
    }

    func loadCalls() {
        load("calls", "calls.log") { d in
            self.calls = (d as? [[String: Any]] ?? []).map {
                CallEntry(number: $0["number"] as? String ?? "", name: $0["name"] as? String ?? "", type: $0["type"] as? String ?? "",
                          date: Self.date($0["date"]), duration: $0["duration"] as? Int ?? 0)
            }
        }
    }

    func loadPhotos(more: Bool = false) {
        if !more { photos = []; photosDone = false }
        guard !loading.contains("photos"), !photosDone else { return }
        load("photos", "photos", ["offset": photos.count, "limit": 60]) { d in
            let page = (d as? [[String: Any]] ?? []).map { o in
                PhonePhoto(uri: o["uri"] as? String ?? "", name: o["name"] as? String ?? "", video: o["video"] as? Bool ?? false,
                           date: Self.date(o["date"]), size: (o["size"] as? NSNumber)?.int64Value ?? 0,
                           thumb: (o["thumb"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) })
            }
            self.photos += page
            if page.count < 60 { self.photosDone = true }
        }
    }

    func loadFiles(_ path: String) {
        load("files", "files", ["path": path]) { d in
            guard let o = d as? [String: Any] else { return }
            self.filePath = o["path"] as? String ?? path
            self.files = (o["items"] as? [[String: Any]] ?? []).map {
                PhoneFile(name: $0["name"] as? String ?? "", dir: $0["dir"] as? Bool ?? false,
                          size: ($0["size"] as? NSNumber)?.int64Value ?? 0, date: Self.date($0["date"]))
            }
        }
    }

    func loadApps() {
        load("apps", "apps") { d in
            self.apps = (d as? [[String: Any]] ?? []).map { o in
                PhoneApp(pkg: o["pkg"] as? String ?? "", name: o["name"] as? String ?? "",
                         icon: (o["icon"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) })
            }
        }
    }

    func openApp(_ a: PhoneApp) {
        hub.request("app.open", ["pkg": a.pkg]) { _ in }
        hub.mirror()
    }

    // MARK: transfers

    private var nextTransfer = 1

    func beginTransfer(name: String, outgoing: Bool, size: Int64) -> Int {
        nextTransfer += 1
        transfers.insert(Transfer(id: nextTransfer, name: name, outgoing: outgoing, size: size), at: 0)
        if transfers.count > 100 { transfers.removeLast() }
        return nextTransfer
    }

    func progress(_ id: Int, _ f: Double) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        if f - transfers[i].progress >= 0.01 || f >= 1 { transfers[i].progress = f }
    }

    func finishTransfer(_ id: Int, url: URL) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].progress = 1; transfers[i].state = .done; transfers[i].url = url
    }

    func failTransfer(_ id: Int) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].state = .failed
    }
}
