import Foundation
// Live discovery dump: compares with the old helper's view. Usage: disco [json]
let t0 = Date()
let live = ClaudeSource.liveRegistry()
let top = ClaudeSource.discover(live: live) + CodexSource.discover()
let kids = ClaudeSource.children(top, now: Date().timeIntervalSince1970) + CodexSource.children(top, now: Date().timeIntervalSince1970)
let t1 = Date()
let tm = AgentTmux()
let panes = tm.panes()
var screens: [String] = []
for p in panes where !p.dead { let st = tm.observe(p); screens.append("\(p.id) \(p.agent) \(st.status) native=\(tm.nativeId(p) ?? "-") \(st.activity ?? "") \(st.dialog?.title ?? "")") }
let t2 = Date()
print(String(format: "discover %.0f ms (%d top, %d children), panes %.0f ms (%d)", t1.timeIntervalSince(t0) * 1000, top.count, kids.count, t2.timeIntervalSince(t1) * 1000, panes.count))
for s in top.prefix(25) { print(s.status.padding(toLength: 11, withPad: " ", startingAt: 0), s.id.prefix(44), "|", s.title.prefix(50)) }
print("--- panes"); screens.forEach { print($0) }
print("--- children (first 8)"); for s in kids.prefix(8) { print(s.status, s.id, s.parentId ?? "", s.title.prefix(40)) }
let w0 = Date()
let top2 = ClaudeSource.discover(live: ClaudeSource.liveRegistry()) + CodexSource.discover()
_ = ClaudeSource.children(top2, now: Date().timeIntervalSince1970) + CodexSource.children(top2, now: Date().timeIntervalSince1970)
let w1 = Date()
_ = tm.panes()
let w2 = Date()
print(String(format: "warm: discover %.0f ms, list-panes %.0f ms; codex chats: %d", w1.timeIntervalSince(w0) * 1000, w2.timeIntervalSince(w1) * 1000, top2.filter { $0.agent == "codex" }.count))
for s in top2.filter({ $0.agent == "codex" }).prefix(4) { print(s.status, s.title.prefix(40), CodexSource.messages(path: s.transcript, native: s.nativeId, limit: 5).count, "msgs") }
let c = top2.first { $0.agent == "claude" && $0.status == "working" }!
let ms = ClaudeSource.messages(path: c.transcript, native: c.nativeId, limit: 100)
print("claude msgs:", ms.count, ms.suffix(2).map { "\($0.role): \($0.text.prefix(60))" })
