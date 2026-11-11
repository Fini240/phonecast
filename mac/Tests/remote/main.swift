import Foundation
// Remote (ssh) plumbing against a stand-in ssh that runs locally with another HOME (see run line in the README).
setvbuf(stdout, nil, _IONBF, 0)
UserDefaults.standard.set(["tester@fakehost"], forKey: "agentHosts")
defer { UserDefaults.standard.removeObject(forKey: "agentHosts") }
let tm = AgentTmux()
let id = try! tm.start(agent: "claude", cwd: "~", model: nil, prompt: nil, host: "tester@fakehost")
print("started", id)
Thread.sleep(forTimeInterval: 4)
let p = tm.panes().first { $0.id == id }!
print("listed on host:", p.host ?? "-", "agent:", p.agent, "native hint:", p.nativeHint ?? "-")
let st = tm.observe(p)
print("status:", st.status, "| screen:", AgentScreen.stripAnsi(tm.capture(p)).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(3).joined(separator: " / "))
try! tm.type(id, "hello remote", enter: false)
Thread.sleep(forTimeInterval: 0.8)
print("typed visible:", (try! tm.live(id))["ansi"].map { "\($0)".contains("hello remote") } ?? false)
try! tm.tmux(AgentTmux.remoteSocket("tester@fakehost"), ["kill-server"], check: false)
print("REMOTE OK")
exit(0)
