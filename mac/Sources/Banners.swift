import AppKit
import SwiftUI

/// PhoneCast's own notification banners (top right, stacked), so replies, Answer/Decline and
/// "open on phone" work without macOS's notification permission.
final class Banners {
    static let shared = Banners()

    private final class Item {
        let key: String
        let panel: NSPanel
        var hideWork: DispatchWorkItem?
        init(key: String, panel: NSPanel) { self.key = key; self.panel = panel }
    }
    private var items: [Item] = []
    private let width: CGFloat = 360

    // MARK: kinds

    func show(_ n: PhoneNotif, icon: NSImage?) {
        if Store.shared.notifSound { NSSound(named: "Tink")?.play() }
        present(key: n.key, sticky: false) { close in
            NotificationBanner(n: n, icon: icon, close: close)
        }
    }

    func call(_ c: [String: String]) {
        let ringing = c["state"] == "ringing"
        if ringing { NSSound(named: "Glass")?.play() }
        present(key: "call", sticky: true) { close in
            CallBanner(call: c, close: close)
        }
    }

    func endCall() { remove("call") }

    func file(_ url: URL, from phone: String) {
        present(key: UUID().uuidString, sticky: false) { close in
            SimpleBanner(symbol: "arrow.down.doc.fill", title: tr("From %@: %@", phone, url.lastPathComponent),
                         text: tr("Saved in Downloads/PhoneCast"), buttons: [
                            ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                            ("Open", { NSWorkspace.shared.open(url) }),
                         ], close: close)
        }
    }

    func clipboard(_ text: String, from phone: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = URL(string: t).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        present(key: UUID().uuidString, sticky: false) { close in
            SimpleBanner(symbol: link == nil ? "doc.on.clipboard.fill" : "link", title: link == nil ? tr("Copied from %@", phone) : tr("Link from %@", phone),
                         text: String(t.prefix(240)), buttons: link.map { u in [("Open link", { NSWorkspace.shared.open(u) })] } ?? [], close: close)
        }
    }

    func info(_ title: String, _ text: String) {
        present(key: UUID().uuidString, sticky: false) { close in
            SimpleBanner(symbol: "smartphone", title: title, text: text, buttons: [], close: close)
        }
    }

    // MARK: panels

    private func present<V: View>(key: String, sticky: Bool, _ make: (@escaping () -> Void) -> V) {
        let close: () -> Void = { [weak self] in self?.remove(key) }
        let host = NSHostingView(rootView: make(close).frame(width: width).fixedSize(horizontal: false, vertical: true))
        if let i = items.first(where: { $0.key == key }) {
            // same notification updated (new message in the same chat): replace content in place
            i.panel.contentView = host
            let size = host.fittingSize
            i.panel.setContentSize(size)
            schedule(i, sticky: sticky)
            layout()
            return
        }
        let size = host.fittingSize
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = host
        let item = Item(key: key, panel: p)
        items.insert(item, at: 0)
        if items.count > 4, let last = items.last { remove(last.key) }
        layout(animatedNew: p)
        p.orderFrontRegardless()
        schedule(item, sticky: sticky)
    }

    private func schedule(_ i: Item, sticky: Bool) {
        i.hideWork?.cancel()
        guard !sticky else { return }
        let w = DispatchWorkItem { [weak self, weak i] in
            guard let self, let i else { return }
            // keep it while the pointer is on it or you're typing a reply
            if i.panel.frame.contains(NSEvent.mouseLocation) || i.panel.isKeyWindow { self.schedule(i, sticky: false); return }
            self.remove(i.key)
        }
        i.hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: w)
    }

    func remove(_ key: String) {
        guard let idx = items.firstIndex(where: { $0.key == key }) else { return }
        let i = items.remove(at: idx)
        i.hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            i.panel.animator().alphaValue = 0
        }, completionHandler: { i.panel.orderOut(nil) })
        layout()
    }

    func removeAll() { items.map(\.key).forEach(remove) }

    private func layout(animatedNew: NSPanel? = nil) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.maxY - 10
        for i in items {
            let s = i.panel.frame.size
            let f = NSRect(x: screen.maxX - s.width - 12, y: y - s.height, width: s.width, height: s.height)
            if i.panel === animatedNew {
                i.panel.setFrame(f.offsetBy(dx: 40, dy: 0), display: false)
                i.panel.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    i.panel.animator().setFrame(f, display: true)
                    i.panel.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; i.panel.animator().setFrame(f, display: true) }
            }
            y -= s.height + 8
        }
    }
}

/// Borderless panels can't take typing by default; reply fields need it.
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

// MARK: banner views

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .padding(2)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .background(.quaternary, in: Circle())
    }
}

struct NotificationBanner: View {
    let n: PhoneNotif
    let icon: NSImage?
    let close: () -> Void
    @State private var replying = false
    @State private var text = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    AppIcon(image: icon, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(n.app).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if hover { CloseButton(action: close) } else { Text("now").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        if !n.title.isEmpty { Text(n.title).font(.headline).lineLimit(1) }
                        if !n.text.isEmpty { Text(n.text).font(.callout).lineLimit(4).foregroundStyle(.primary.opacity(0.85)) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { Store.shared.open(n); close() }
                if replying {
                    HStack {
                        TextField("Reply…", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(send)
                        Button("Send", action: send).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                    }
                } else if hover {
                    HStack(spacing: 8) {
                        if n.canReply { Button("Reply") { replying = true; activate() } }
                        Button("Open on phone") { Store.shared.open(n); close() }
                        Button("Clear") { Store.shared.dismiss(n); close() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onHover { hover = $0 }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
            focused = true
        }
    }

    private func send() {
        guard !text.isEmpty else { return }
        Store.shared.reply(n, text)
        close()
    }
}

struct CallBanner: View {
    let call: [String: String]
    let close: () -> Void
    var body: some View {
        let name = call["name"].flatMap { $0.isEmpty ? nil : $0 } ?? call["number"] ?? "Unknown number"
        let ringing = call["state"] == "ringing"
        Card {
            HStack(spacing: 12) {
                Image(systemName: ringing ? "phone.arrow.down.left.fill" : "phone.fill")
                    .font(.title2).foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(ringing ? Color.green : Color.blue, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(ringing ? "Incoming call" : "On a call").font(.caption).foregroundStyle(.secondary)
                    Text(name).font(.headline).lineLimit(1)
                    if ringing { Text("Answering picks up on the phone").font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                if ringing {
                    Button { Store.shared.hangUp() } label: { Image(systemName: "phone.down.fill") }
                        .buttonStyle(RoundButton(color: .red)).help("Decline")
                    Button { Store.shared.answer() } label: { Image(systemName: "phone.fill") }
                        .buttonStyle(RoundButton(color: .green)).help("Answer")
                } else {
                    Button { Store.shared.hangUp() } label: { Image(systemName: "phone.down.fill") }
                        .buttonStyle(RoundButton(color: .red)).help("End call")
                }
            }
        }
    }
}

struct RoundButton: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: Circle())
    }
}

struct SimpleBanner: View {
    let symbol: String
    let title: String
    let text: String
    let buttons: [(String, () -> Void)]
    let close: () -> Void
    @State private var hover = false
    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(tr(title)).font(.headline).lineLimit(2)
                        Spacer()
                        if hover { CloseButton(action: close) }
                    }
                    if !text.isEmpty { Text(tr(text)).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                    if !buttons.isEmpty {
                        HStack { ForEach(buttons.indices, id: \.self) { i in Button(tr(buttons[i].0)) { buttons[i].1(); close() } } }
                            .controlSize(.small).padding(.top, 2)
                    }
                }
            }
        }
        .onHover { hover = $0 }
    }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "app.badge").resizable().scaledToFit().padding(size * 0.2).foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
