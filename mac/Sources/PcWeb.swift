import AppKit
import SwiftUI
import WebKit

/// The dashboard's own Chat, Builder and Studio pages inside the PC page
/// (`<dashboard>/?embed=chat|builder|studio`: the page drops its header and tab bar).
/// One web view per page, made on first use and kept, so a running chat or render
/// carries on while another page is shown.
final class PcWeb: NSObject, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    static let shared = PcWeb()
    private var views: [String: WKWebView] = [:]
    private var loaded: [String: String] = [:]
    /// Hosts that are the dashboard (its address and where it redirects to); other links open in the browser.
    private var dashHosts = Set<String>()

    func view(_ kind: String, base: String) -> WKWebView {
        let w = views[kind] ?? make(kind)
        let url = "\(base)/?embed=\(kind)&" + Self.look()
        if loaded[kind] != url, let u = URL(string: url) {
            loaded[kind] = url
            if let h = u.host { dashHosts.insert(h) }
            w.load(URLRequest(url: u))
        }
        return w
    }

    func reload(_ kind: String) { views[kind]?.reload() }

    /// PhoneCast's look for the page: the Mac's own colours (accent, window, text) in the current light/dark mode.
    static func look() -> String {
        let app = NSApp.effectiveAppearance
        let dark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var out = "theme=\(dark ? "dark" : "light")&skin=phonecast"
        app.performAsCurrentDrawingAppearance {
            // system text colours are partly transparent: flatten them onto the window background
            let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            func h(_ c: NSColor) -> String {
                guard let s = c.usingColorSpace(.sRGB) else { return "" }
                let a = s.alphaComponent
                func ch(_ v: CGFloat, _ b: CGFloat) -> Int { Int(((v * a + b * (1 - a)) * 255).rounded()) }
                return String(format: "%02x%02x%02x", ch(s.redComponent, base.redComponent), ch(s.greenComponent, base.greenComponent),
                              ch(s.blueComponent, base.blueComponent))
            }
            func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { a.usingColorSpace(.sRGB)!.blended(withFraction: t, of: b.usingColorSpace(.sRGB)!) ?? a }
            let bg = NSColor.windowBackgroundColor, accent = NSColor.controlAccentColor
            let surface = dark ? mix(bg, .white, 0.06) : NSColor.white
            out += "&bg=\(h(bg))&surface=\(h(surface))&surface2=\(h(mix(bg, dark ? .white : .black, 0.04)))"
            out += "&accent=\(h(accent))&onaccent=ffffff&tint=\(h(mix(surface, accent, dark ? 0.28 : 0.16)))&ontint=\(h(.labelColor))"
            out += "&ink=\(h(.labelColor))&muted=\(h(.secondaryLabelColor))&line=\(h(mix(bg, dark ? .white : .black, 0.12)))"
        }
        return out
    }

    private func make(_ kind: String) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.mediaTypesRequiringUserActionForPlayback = []      // voice answers play on their own
        let w = WKWebView(frame: .zero, configuration: c)
        w.uiDelegate = self
        w.navigationDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.setValue(false, forKey: "drawsBackground")         // no white flash before the page paints
        views[kind] = w
        return w
    }

    // MARK: links

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, let host = u.host else { return decisionHandler(.allow) }
        if a.shouldPerformDownload { return decisionHandler(.download) }
        if a.navigationType == .other || dashHosts.contains(host) {
            // the dashboard's own loads and redirects (to its https name, for the microphone)
            if a.targetFrame?.isMainFrame == true { dashHosts.insert(host) }
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(u)                        // Builder previews, links in answers
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }

    /// target=_blank: the browser.
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    // MARK: files, microphone, dialogs

    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ w: WKWebView, requestMediaCapturePermissionFor o: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone && dashHosts.contains(o.host) ? .grant : .deny)
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler()
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m
        a.addButton(withTitle: "OK"); a.addButton(withTitle: tr("Cancel"))
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = p
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = d ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: tr("Cancel"))
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: downloads (Studio's clips) → ~/Downloads

    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = dir.appendingPathComponent(name)
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        completionHandler(url)
    }

    func downloadDidFinish(_ d: WKDownload) {
        if let u = d.progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
}

/// SwiftUI host for one kept web view.
struct PcWebView: NSViewRepresentable {
    let kind: String
    let base: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        let w = PcWeb.shared.view(kind, base: base)
        guard w.superview !== host else { return }
        w.removeFromSuperview()
        host.subviews.forEach { $0.removeFromSuperview() }
        w.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(w)
        NSLayoutConstraint.activate([
            w.leadingAnchor.constraint(equalTo: host.leadingAnchor), w.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            w.topAnchor.constraint(equalTo: host.topAnchor), w.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
