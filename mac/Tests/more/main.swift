import Foundation
// v0.6 checks: limit parser (offline) and, with a scratch folder argument, live terminal/type/files/fork on a real haiku chat.
setvbuf(stdout, nil, _IONBF, 0)
let f = DateFormatter(); f.dateFormat = "HH:mm"
for t in ["You've hit your limit · resets 3pm (Europe/Berlin)", "5-hour limit reached ∙ resets 4:30am", "You've hit your usage limit. Upgrade to Pro or try again at 3:15 PM.", "Claude usage limit reached. Your limit will reset at 11pm", "no limit here"] {
    print(AgentLimits.resetTime(in: t).map { f.string(from: $0) } ?? "-", "←", t)
}
print("ports:", AgentPreview.ports(in: "Server running at http://localhost:5173/ and api http://127.0.0.1:8080/health"))
guard CommandLine.arguments.count > 1 else { exit(0) }
let dir = CommandLine.arguments[1]
try! "hello\n".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)
let tm = AgentTmux()
let id = try! tm.start(agent: "claude", cwd: dir, model: "haiku", prompt: nil)
var end = Date().addingTimeInterval(30)
while Date() < end { let s = tm.observe(try! tm.pane(id)); if let d = s.dialog { try! tm.approve(id, approval: d.approvalId, choice: d.choiceId(d.options.first { $0.label.hasPrefix("Yes") }!)) }; if s.ready { break }; Thread.sleep(forTimeInterval: 0.5) }
try! tm.type(id, "/help", enter: false)
Thread.sleep(forTimeInterval: 1)
let live = try! tm.live(id)
print("live has ANSI:", (live["ansi"] as! String).contains("\u{1b}["), "typed text visible:", (live["ansi"] as! String).contains("/help"), "cursor:", live["cursor"]!)
_ = try? tm.tmux(AgentTmux.socket, ["send-keys", "-t", (try! tm.pane(id)).paneId, "C-u"]); Thread.sleep(forTimeInterval: 0.5)
print("files:", (try! AgentFiles.list(dir, "")["items"] as! [[String: Any]]).map { $0["name"]! })
print("read:", try! AgentFiles.read(dir, "notes.txt")["text"]!)
print("escape refused:", (try? AgentFiles.read(dir, "../../../../etc/passwd")) == nil)
print("find:", AgentFiles.find(dir, "note"))
try! tm.send(id, "Reply with exactly the word FIG."); print("sent")
end = Date().addingTimeInterval(60); while Date() < end && !(try! tm.preview(id)).contains("FIG\n") && (try! tm.preview(id)).components(separatedBy: "FIG").count < 3 { Thread.sleep(forTimeInterval: 1) }
let native = tm.nativeId(try! tm.pane(id))!
let fid = try! tm.start(agent: "claude", cwd: dir, model: "haiku", prompt: nil, resume: native, fork: true)
_ = try? tm.tmux(AgentTmux.socket, ["set-option", "-t", "pc-" + fid.dropFirst(2), "remain-on-exit", "on"])
Thread.sleep(forTimeInterval: 6)
if let p = tm.panes().first(where: { $0.id == fid }) { print("fork pane dead:", p.dead); print(tm.capture(p).suffix(800)) }
let fnative = (try? tm.pane(fid)).flatMap { tm.nativeId($0) }
print("fork:", fid != id, "new native:", fnative ?? "-", fnative != native)
for x in [id, fid] { _ = try? tm.tmux(AgentTmux.socket, ["kill-session", "-t", "pc-" + x.dropFirst(2)]) }
print("DONE")
