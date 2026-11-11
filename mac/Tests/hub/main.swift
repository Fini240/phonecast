import Foundation
// Drives AgentHub exactly like the phone does (AGENT_REQ JSON in, AGENT_RESP/EVENT JSON out).
let scratch = CommandLine.arguments[1]
let hub = AgentHub.shared
var events: [[String: Any]] = []
let lock = NSLock()
hub.emit = { o in
    lock.lock(); events.append(o); lock.unlock()
    let size = (try? JSONSerialization.data(withJSONObject: o).count) ?? 0
    let e = o["e"] as? String ?? ""
    if e == "sessions" { print("EVENT sessions: \((o["list"] as? [Any])?.count ?? 0) rows, \(size / 1024) KB") }
    else if e == "msgs" { print("EVENT msgs: +\((o["add"] as? [Any])?.count ?? 0) reset=\(o["reset"] ?? "") more=\(o["more"] ?? "")") }
    else { print("EVENT \(e): \(o.filter { $0.key != "e" }.map { "\($0.key)=\(String(describing: $0.value).prefix(80))" }.sorted().joined(separator: " "))") }
}
func req(_ m: String, _ p: [String: Any] = [:], timeout: Double = 90) -> [String: Any] {
    let sem = DispatchSemaphore(value: 0); var out: [String: Any] = [:]
    hub.handle(["id": 1, "m": m, "p": p]) { r in out = r; sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut { print("TIMEOUT \(m)"); exit(1) }
    print("RESP \(m): ok=\(out["ok"] ?? "") \(String(describing: out["data"] ?? out["message"] ?? "").prefix(140))")
    return out
}
func session(_ id: String) -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    for e in events.reversed() where e["e"] as? String == "sessions" {
        return (e["list"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }
    return nil
}
func waitFor(_ what: String, _ secs: Double, _ ok: () -> Bool) {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if ok() { print("  ✓ \(what)"); return }; Thread.sleep(forTimeInterval: 0.5) }
    print("  ✗ \(what)"); exit(1)
}
hub.start()
hub.phoneConnected = true
_ = req("hello")
waitFor("first session list", 20) { session("t:61f05cd2c09b") != nil }
let me = session("t:61f05cd2c09b")!
print("  this chat:", me["title"] ?? "", me["status"] ?? "", "managed=\(me["managed"] ?? "")")
_ = req("watch", ["sid": "t:61f05cd2c09b"])
Thread.sleep(forTimeInterval: 2)
_ = req("older", ["sid": "t:61f05cd2c09b", "have": 120])
_ = req("terminal", ["sid": "t:61f05cd2c09b"])
_ = req("folders")
let models = req("models", [:], timeout: 70)
let start = req("start", ["agent": "claude", "cwd": scratch, "model": "haiku", "prompt": ""])
let sid = (start["data"] as? [String: Any])?["sid"] as? String ?? ""
_ = req("watch", ["sid": sid])
waitFor("trust question pushed with the list (+ input alert)", 30) { session(sid)?["ask"] != nil }
let ask = session(sid)!["ask"] as! [String: Any]
let yes = (ask["choices"] as! [[String: Any]]).first { ($0["label"] as? String ?? "").hasPrefix("Yes") }!
_ = req("approve", ["sid": sid, "ask": ask["id"]!, "choice": yes["id"]!])
waitFor("ready", 30) { session(sid)?["status"] as? String == "idle" }
_ = req("send", ["sid": sid, "text": "Reply with exactly the word KIWI and nothing else."])
waitFor("completed alert", 60) { lock.lock(); defer { lock.unlock() }; return events.contains { $0["e"] as? String == "alert" && $0["kind"] as? String == "completed" && $0["sid"] as? String == sid } }
waitFor("KIWI in pushed messages", 10) { lock.lock(); defer { lock.unlock() }; return events.contains { $0["e"] as? String == "msgs" && "\($0["add"] ?? "")".contains("KIWI") } }
_ = req("stop", ["sid": sid])
let tag = String(sid.dropFirst(2))
_ = try? AgentTmux().tmux(AgentTmux.socket, ["kill-session", "-t", "pc-" + tag])
_ = models
print("PASS")
exit(0)
