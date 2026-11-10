import AppKit
import SwiftUI

/// Once a day: is there a newer PhoneCast release on GitHub? Shown on Overview and in Settings.
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()
    @Published var latest: String?          // e.g. "0.2.2" when newer than this app
    @Published var url: URL?

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
            DispatchQueue.main.async {
                if Self.newer(v, than: Self.current) { self.latest = v; self.url = page } else { self.latest = nil }
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
}

struct UpdateBanner: View {
    @ObservedObject var up = UpdateCheck.shared
    var body: some View {
        if let v = up.latest, let url = up.url {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PhoneCast \(v) is available").font(.headline)
                    Text("You have \(UpdateCheck.current). Update the phone app too.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
