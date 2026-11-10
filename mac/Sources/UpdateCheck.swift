import AppKit
import SwiftUI

/// Once a day: is there a newer PhoneCast release on GitHub? If so, Overview shows a banner with
/// "Install update", which downloads the Mac zip, swaps the app in place and restarts it.
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()
    @Published var latest: String?          // e.g. "0.3.1" when newer than this app
    @Published var url: URL?                // release page
    @Published var installing: String?      // progress text while updating
    private var zipURL: URL?

    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func start() {
        check()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard let api = URL(string: "https://api.github.com/repos/Fini240/phonecast/releases/latest") else { return }
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let zip = (j["assets"] as? [[String: Any]])?.first { ($0["name"] as? String)?.hasPrefix("PhoneCast-mac") == true }
            DispatchQueue.main.async {
                self.zipURL = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
                if Self.newer(v, than: Self.current) { self.latest = v; self.url = page } else { self.latest = nil }
                if self.latest != nil, ProcessInfo.processInfo.environment["PHONECAST_TEST_UPDATE"] != nil { self.install() }  // updater test
            }
        }.resume()
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: install

    /// Download -> unzip -> check it is PhoneCast and the new version -> keep the current signing identity
    /// (so macOS keeps PhoneCast's permissions where it can) -> swap the app -> restart.
    func install() {
        guard installing == nil, let zip = zipURL, let v = latest else { if let url { NSWorkspace.shared.open(url) }; return }
        installing = tr("Downloading %@…", v)
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            guard let tmp else { return self.fail(err?.localizedDescription ?? "Download failed") }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("phonecast-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let z = work.appendingPathComponent("update.zip")
            try? FileManager.default.moveItem(at: tmp, to: z)
            DispatchQueue.main.async { self.installing = tr("Installing %@…", v) }
            guard Self.run("/usr/bin/ditto", ["-x", "-k", z.path, work.path]) == 0 else { return self.fail("Couldn't unpack the update") }
            let newApp = work.appendingPathComponent("PhoneCast.app")
            guard let b = Bundle(url: newApp), b.bundleIdentifier == Bundle.main.bundleIdentifier,
                  (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == v else { return self.fail("The download isn't PhoneCast \(v)") }
            if let id = Self.signingIdentity(Bundle.main.bundleURL) {
                _ = Self.run("/usr/bin/codesign", ["--force", "--deep", "-s", id, newApp.path])
            }
            _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            let current = Bundle.main.bundleURL
            let old = work.appendingPathComponent("old.app")
            do {
                try FileManager.default.moveItem(at: current, to: old)
                try FileManager.default.moveItem(at: newApp, to: current)
            } catch {
                try? FileManager.default.moveItem(at: old, to: current)   // put the old one back
                return self.fail("Couldn't replace the app: \(error.localizedDescription)")
            }
            NSLog("update: installed \(v), restarting")
            // restart once this process has quit
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(current.path)\"; rm -rf \"\(work.path)\""]
            try? p.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }

    private func fail(_ why: String) {
        DispatchQueue.main.async {
            self.installing = nil
            Banners.shared.info("Update failed", why)
        }
    }

    /// "Authority=…" of a non-ad-hoc signature, e.g. a local development certificate.
    private static func signingIdentity(_ app: URL) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", app.path]; p.standardError = pipe; p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
}

struct UpdateBanner: View {
    @ObservedObject var up = UpdateCheck.shared
    var body: some View {
        if let v = up.latest {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PhoneCast \(v) is available").font(.headline)
                    Text(up.installing ?? tr("You have %@. The phone app shows its own update button.", UpdateCheck.current))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if up.installing != nil { ProgressView().controlSize(.small) }
                else {
                    if let url = up.url { Button("What's new") { NSWorkspace.shared.open(url) } }
                    Button("Install update") { up.install() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
