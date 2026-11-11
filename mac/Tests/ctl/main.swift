import Foundation
// End-to-end control test on a throwaway Claude session (haiku) in a scratch folder.
let dir = CommandLine.arguments[1]
let tm = AgentTmux()
func state(_ id: String) -> AgentScreen.State { tm.observe(try! tm.pane(id)) }
func waitFor(_ id: String, _ secs: Double, _ what: String, _ ok: (AgentScreen.State) -> Bool) -> AgentScreen.State {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { let s = state(id); if ok(s) { print("  ✓ \(what) [\(s.status)]"); return s }; Thread.sleep(forTimeInterval: 0.5) }
    print("  ✗ timeout: \(what)\n" + (try! tm.preview(id)).suffix(1500)); exit(1)
}
let id = try! tm.start(agent: "claude", cwd: dir, model: "haiku", prompt: nil)
print("started \(id)")
defer { }
var s = waitFor(id, 30, "dialog or prompt") { $0.dialog != nil || $0.ready }
if let d = s.dialog {
    print("  dialog: \(d.title) | options: \(d.options.map(\.label))")
    let yes = d.options.first { $0.label.lowercased().hasPrefix("yes") }!
    try! tm.approve(id, approval: d.approvalId, choice: d.choiceId(yes))
    s = waitFor(id, 30, "ready after trust") { $0.ready }
}
if CommandLine.arguments.count > 2 {
    try! tm.send(id, "Write the numbers 1 to 300, each on its own line, with a one-sentence fact about each number.")
    _ = waitFor(id, 40, "working") { $0.working }
    let t1 = Date()
    try! tm.send(id, "Stop that. Reply with exactly the word MANGO and nothing else.")
    print(String(format: "  ✓ interrupting send confirmed in %.1f s", Date().timeIntervalSince(t1)))
    _ = waitFor(id, 90, "answer after interrupt") { $0.ready && (try! tm.preview(id)).components(separatedBy: "MANGO").count > 2 }
    let p = try! tm.pane(id)
    print("  same native chat:", tm.nativeId(p)!, ClaudeSource.messages(path: nil, native: tm.nativeId(p)!, limit: 4).map { "\($0.role): \($0.text.prefix(30))" })
    _ = try? tm.tmux(AgentTmux.socket, ["kill-session", "-t", p.session]); print("PASS"); exit(0)
}
let t0 = Date()
try! tm.send(id, "Reply with exactly the word PINEAPPLE and nothing else.")
print(String(format: "  ✓ send confirmed in %.1f s", Date().timeIntervalSince(t0)))
_ = waitFor(id, 90, "answer finished") { $0.ready && (try! tm.preview(id)).contains("PINEAPPLE\n") || (try! tm.preview(id)).components(separatedBy: "PINEAPPLE").count > 2 }
let p = try! tm.pane(id)
let native = tm.nativeId(p)!
let msgs = ClaudeSource.messages(path: nil, native: native, limit: 10)
print("  transcript:", msgs.map { "\($0.role): \($0.text.prefix(40))" })
try! tm.stop(id)  // idle: must be a no-op
print("  ✓ stop on idle was a no-op:", state(id).status)
_ = try? tm.tmux(AgentTmux.socket, ["kill-session", "-t", p.session])
print("PASS")
