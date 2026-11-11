import Foundation
// Parser parity test: swiftc ... ../Sources/AgentScreen.swift ScreenTest.swift && ./screentest screens
let dir = CommandLine.arguments[1]
let exp = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/expected.json"))) as! [String: [String: Any]]
var fails = 0
for (f, e) in exp.sorted(by: { $0.key < $1.key }) {
    let t = try! String(contentsOfFile: dir + "/" + f, encoding: .utf8)
    let st = AgentScreen.parse(agent: f.hasPrefix("claude") ? "claude" : "codex", styled: t)
    var got: [String: Any] = ["status": st.status, "activity": st.activity ?? NSNull(), "draft": st.draft ?? NSNull(), "input": st.inputVisible]
    if let d = st.dialog { got["dialog"] = ["title": d.title, "detail": d.detail, "options": d.options.map { [$0.label, $0.number ?? NSNull()] as [Any] }, "cursor": d.cursor ?? NSNull(), "fp": d.fingerprint] }
    else { got["dialog"] = NSNull() }
    func norm(_ v: Any) -> String {
        let d = try! JSONSerialization.data(withJSONObject: ["v": v], options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: d, as: UTF8.self).replacingOccurrences(of: "<null>", with: "null")
    }
    var bad: [String] = []
    for k in ["status", "activity", "draft", "input", "dialog"] {
        let a = norm(e[k] ?? NSNull()), b = norm(got[k] ?? NSNull())
        if a != b { bad.append("\(k): want \(a) got \(b)") }
    }
    print(bad.isEmpty ? "ok   \(f)" : "FAIL \(f)\n  " + bad.joined(separator: "\n  "))
    fails += bad.isEmpty ? 0 : 1
}
print(fails == 0 ? "ALL PASS" : "\(fails) failing"); exit(fails == 0 ? 0 : 1)
