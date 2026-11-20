import AppKit
import UniformTypeIdentifiers

/// Finder's (and any app's) Share menu → "PhoneCast". No UI of its own: it collects the shared files
/// (or a web link) and hands them to the PhoneCast app through the phonecast:// URL scheme. The app is
/// not sandboxed, so passing plain paths is enough; data without a file (a picture from Photos, say) is
/// written to this extension's own temp folder first, which the app can read too.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var paths: [String] = [], links: [String] = []
        let lock = NSLock(), group = DispatchGroup()

        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let u = Self.url(item), u.isFileURL { lock.lock(); paths.append(u.path); lock.unlock() }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let u = Self.url(item) {
                        lock.lock(); if u.isFileURL { paths.append(u.path) } else { links.append(u.absoluteString) }; lock.unlock()
                    }
                    group.leave()
                }
            } else if let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) {
                // a file representation keeps the original name when the sender has one
                p.loadFileRepresentation(forTypeIdentifier: type) { tmp, _ in
                    if let tmp {
                        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent(p.suggestedName.map { n in
                            UTType(type)?.preferredFilenameExtension.map { n.hasSuffix(".\($0)") ? n : "\(n).\($0)" } ?? n
                        } ?? tmp.lastPathComponent)
                        if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { lock.lock(); paths.append(dest.path); lock.unlock() }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            var c = URLComponents(); c.scheme = "phonecast"
            if !paths.isEmpty {
                c.host = "send"; c.queryItems = paths.map { URLQueryItem(name: "f", value: $0) }
            } else if let l = links.first {
                c.host = "link"; c.queryItems = [URLQueryItem(name: "u", value: l)]
            }
            if c.host != nil, let u = c.url { NSWorkspace.shared.open(u) }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func url(_ item: NSSecureCoding?) -> URL? {
        if let u = item as? URL { return u }
        if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
        if let s = item as? String { return URL(string: s) }
        return nil
    }
}
