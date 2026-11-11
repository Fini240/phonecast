import AppKit
import SwiftUI
import WebKit

/// The Mac's Agents page: the same web UI an iPad or any browser gets (AgentWebUI), plus the terminal
/// integration switch and how to open Agents on another device.
struct AgentsView: View {
    @State private var installed = AgentShell.installed()
    @State private var legacy = AgentShell.legacyInstalled()
    @State private var error: String?
    @State private var code = AgentWeb.shared.code
    @State private var showWeb = false

    var body: some View {
        VStack(spacing: 0) {
            if !installed || legacy { integrationBanner }
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text(tr("Open Agents in a browser (iPad, laptop): ")) + Text(AgentWeb.addresses().first.map { "http://\($0):\(AgentWeb.port)" } ?? "—").bold()
                    + Text("  ·  " + tr("code ")) + Text(code).bold().monospacedDigit()
                Spacer()
                Button(tr("Details")) { showWeb.toggle() }
                    .popover(isPresented: $showWeb) { webDetails }
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            AgentsWebView()
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} }
    }

    private var webDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Agents in a browser")).font(.headline)
            Text(tr("Any browser on the same Wi-Fi or on Tailscale can open Agents without installing anything. Sign in once with the code; it stays signed in.")).font(.caption).foregroundStyle(.secondary).frame(width: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            ForEach(AgentWeb.addresses(), id: \.self) { a in Text("http://\(a):\(AgentWeb.port)").textSelection(.enabled).font(.system(.body, design: .monospaced)) }
            HStack {
                Button(tr("New code")) { AgentWeb.shared.newCode(); code = AgentWeb.shared.code }
                Button(tr("Sign out all browsers")) { AgentWeb.shared.signOutAll() }
            }
            Text(tr("%@ browsers signed in", String(AgentWeb.shared.devices))).font(.caption).foregroundStyle(.secondary)
        }.padding()
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

/// WKWebView with the local Agents UI, signed in through the one-time local token.
struct AgentsWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.uiDelegate = context.coordinator
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: URL(string: "http://127.0.0.1:\(AgentWeb.port)/local?t=\(AgentWeb.shared.localToken)")!))
        return w
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        // prompt()/confirm()/alert() and links that open elsewhere
        func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let a = NSAlert(); a.messageText = m; a.runModal(); completionHandler()
        }
        func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let a = NSAlert(); a.messageText = m; a.addButton(withTitle: "OK"); a.addButton(withTitle: tr("Cancel")); completionHandler(a.runModal() == .alertFirstButtonReturn)
        }
        func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText d: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let a = NSAlert(); a.messageText = p
            let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); t.stringValue = d ?? ""; a.accessoryView = t
            a.addButton(withTitle: "OK"); a.addButton(withTitle: tr("Cancel"))
            completionHandler(a.runModal() == .alertFirstButtonReturn ? t.stringValue : nil)
        }
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = a.request.url { NSWorkspace.shared.open(u) }
            return nil
        }
        func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let o = NSOpenPanel(); o.allowsMultipleSelection = p.allowsMultipleSelection
            completionHandler(o.runModal() == .OK ? o.urls : nil)
        }
    }
}
