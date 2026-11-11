import Foundation
import CryptoKit

/// What a native agent TUI (Claude Code / Codex) currently shows, read from one `tmux capture-pane -e -J`.
/// Only observed state is reported: a selection dialog (permission, trust folder, …), the "working" spinner
/// and the prompt box with its draft. Unknown layouts give status "unknown" rather than a guess.
/// Patterns come from real captures of Claude Code 2.1.29x–2.1.32x and Codex 0.160–0.163.

/// Tiny NSRegularExpression wrapper with named groups.
struct Rx {
    let re: NSRegularExpression
    init(_ p: String, _ o: NSRegularExpression.Options = []) { re = try! NSRegularExpression(pattern: p, options: o) }
    struct M {
        let m: NSTextCheckingResult; let s: NSString
        func g(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : s.substring(with: r)
        }
        /// UTF-16 offset where a named group starts.
        func start(_ name: String) -> Int { m.range(withName: name).location }
        var end: Int { m.range.location + m.range.length }
    }
    func match(_ s: String, at: Int = 0) -> M? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: at, length: ns.length - at)) else { return nil }
        return M(m: m, s: ns)
    }
    func search(_ s: String) -> M? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return M(m: m, s: ns)
    }
    func test(_ s: String) -> Bool { search(s) != nil }
    func all(_ s: String) -> [M] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { M(m: $0, s: ns) }
    }
    func replace(_ s: String, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }
}

enum AgentScreen {
    static let ansi = Rx(#"\x1b\[[0-9;:?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]"#)
    static let separator = Rx(#"^\s*[─━╌┄-]{12,}\s*$"#)
    static let footer = Rx(#"(?i)(enter to (confirm|select|continue)|esc to (cancel|go back|exit)|press enter to confirm|↑/↓ to (navigate|select)|\(esc\)\s*$|to navigate · enter)"#)
    static let numbered = Rx(#"^(?<indent>\s*)(?<cur>[❯›>▶]\s*)?(?<num>\d{1,2})[.)]\s+(?<label>\S.*?)\s*$"#)
    static let cursorRe = Rx(#"^(?<indent>\s*)(?<cur>[❯›>▶])\s+(?<label>\S.*?)\s*$"#)
    static let claudeSpinner = Rx(#"^\s*\S\s+(?<verb>[A-Z][A-Za-z'\-]{2,30})…(?:\s*\((?<info>[^)]*)\))?"#)
    static let codexWorking = Rx(#"^\s*\S?\s*(?<verb>Working|Thinking|Running|Compacting[a-z ]*)\b.*?\((?<info>[^)]*)\)"#)
    static let escInterrupt = Rx(#"(?i)\besc to interrupt\b"#)
    static let claudePrompt = Rx(#"^❯[\x{00a0} ](?<text>.*)$|^❯$"#)
    static let codexPrompt = Rx(#"^›[\x{00a0} ](?<text>.*)$|^›$"#)
    static let claudePlaceholder = Rx(#"^(Try ".*"|Press up to edit queued messages)$"#)
    static let promptLine = Rx(#"^\s*[❯›][\x{00a0} ]\S"#)
    static let dashed = Rx(#"^\s*[╌┄]{8,}\s*$"#)
    static let codexFooter = Rx(#"(?i)(context \d+% left|\? for shortcuts|tab to queue|for agents)"#)
    static let modeRe = Rx(#"(?:⏵⏵|⏸|⏵)\s+([a-z][a-z ]+?)\s+on\b"#)
    static let sgr = Rx(#"\x1b\[([0-9;:]*)m"#)

    struct Option { let index: Int; let label: String; let number: Int? }

    struct Dialog {
        let title: String, detail: String, options: [Option], cursor: Int?, fingerprint: String
        var approvalId: String { "ap_" + fingerprint.prefix(16) }
        func choiceId(_ o: Option) -> String { String(o.number ?? (o.index + 1)) }
    }

    struct State {
        var working = false
        var activity: String?
        var dialog: Dialog?
        var inputVisible = false
        var draft: String?          // nil = no prompt box seen
        var mode: String?           // Claude permission mode: "default", "accept edits", "plan mode", "bypass permissions", …
        var status: String {
            if dialog != nil { return "needs_input" }
            if working { return "working" }
            return inputVisible ? "idle" : "unknown"
        }
        var ready: Bool { dialog == nil && !working && inputVisible }
    }

    static func stripAnsi(_ s: String) -> String { ansi.replace(s, "") }

    private static func trimEnd(_ s: String) -> String {
        var s = Substring(s)
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }
    private static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
    private static func blank(_ s: String) -> Bool { strip(s).isEmpty }
    private static func squash(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    /// `styled` = one `capture-pane -e -J` (ANSI kept); plain lines are the same lines with ANSI removed,
    /// so indices line up exactly.
    static func parse(agent: String, styled: String) -> State {
        let styledLines = styled.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var lines = styledLines.map { trimEnd(stripAnsi($0)) }
        while let l = lines.last, blank(l) { lines.removeLast() }
        var st = State()
        st.dialog = findDialog(agent, lines)
        var (visible, draft, top) = agent == "claude" ? claudeInput(lines, styledLines) : codexInput(lines, styledLines)
        if st.dialog != nil { visible = false; draft = nil }
        st.inputVisible = visible; st.draft = draft
        if agent == "claude" && visible {
            st.mode = "default"
            for ln in lines.suffix(6) { if let m = modeRe.search(ln) { st.mode = m.g(1); break } }
        }
        let end = top ?? lines.count
        let region = lines[max(0, end - 14)..<max(0, min(end, lines.count))]
        for ln in region.reversed() {
            if agent == "claude" {
                if let m = claudeSpinner.match(ln) {
                    st.working = true
                    let info = strip(m.g("info") ?? "")
                    st.activity = info.isEmpty ? "\(m.g("verb")!)…" : "\(m.g("verb")!)… (\(info))"
                    break
                }
            } else if codexWorking.match(ln) != nil {
                st.working = true; st.activity = String(strip(ln).prefix(120)); break
            }
            if escInterrupt.test(ln) { st.working = true; st.activity = String(strip(ln).prefix(120)); break }
        }
        return st
    }

    private static func fingerprint(_ agent: String, _ title: String, _ detail: String, _ labels: [String]) -> String {
        let norm = ([agent, squash(title), squash(detail)] + labels.map(squash)).joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(norm.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func leadingSpaces(_ s: String) -> Int { s.prefix(while: { $0 == " " || $0 == "\t" }).count }

    /// Column (in UTF-16 units, as the regex reports) where the cursor line's label starts.
    private static func aligned(_ line: String, _ col: Int) -> Bool {
        if (line as NSString).length <= col { return false }
        if (line as NSString).length - (strip(line) as NSString).length == col && leadingSpaces(line) == col { return true }
        if let m = cursorRe.match(line) { return m.start("label") == col }
        return false
    }

    static func findDialog(_ agent: String, _ lines: [String]) -> Dialog? {
        let windowStart = max(0, lines.count - 45)
        guard let footerIdx = (windowStart..<lines.count).reversed().first(where: { footer.test(lines[$0]) }) else { return nil }
        var j = footerIdx - 1
        while j >= windowStart && blank(lines[j]) { j -= 1 }
        let blockEnd = j
        var raw: [(Int, String)] = []
        var isNumbered = false
        var cont: [String] = []
        var k = blockEnd
        while k >= windowStart && k >= blockEnd - 30 {
            let ln = lines[k]
            if let m = numbered.match(ln) {
                isNumbered = true
                raw.append((k, ([m.g("label")!] + cont.reversed()).joined(separator: " ")))
                cont = []; k -= 1; continue
            }
            if isNumbered {
                if !blank(ln) && separator.match(ln) == nil && cursorRe.match(ln) == nil && ln.hasPrefix("    ") {
                    cont.append(strip(ln)); k -= 1; continue
                }
                break
            }
            if !blank(ln) && ln.hasPrefix("     ") && raw.isEmpty { cont.append(strip(ln)); k -= 1; continue }
            break
        }
        var options: [Option] = []
        var cursor: Int?
        var startIdx = 0
        if isNumbered && !raw.isEmpty {
            raw.reverse()
            startIdx = raw[0].0
            for (pos, (li, label)) in raw.enumerated() {
                let m = numbered.match(lines[li])
                if let c = m?.g("cur"), !c.isEmpty { cursor = pos }
                options.append(Option(index: pos, label: label, number: m.flatMap { Int($0.g("num") ?? "") }))
            }
        } else {
            var curLine: Int?
            var i = blockEnd
            while i >= max(windowStart, blockEnd - 15) { if cursorRe.match(lines[i]) != nil { curLine = i; break }; i -= 1 }
            guard let cl = curLine, let m = cursorRe.match(lines[cl]) else { return nil }
            let col = m.start("label")
            var s = cl
            while s - 1 >= windowStart && !blank(lines[s - 1]) && aligned(lines[s - 1], col) { s -= 1 }
            startIdx = s
            var e = cl
            while e + 1 <= blockEnd && !blank(lines[e + 1]) && aligned(lines[e + 1], col) { e += 1 }
            for (pos, li) in (s...e).enumerated() {
                let text = lines[li]
                var label = strip(text)
                if li == cl, let cm = cursorRe.match(text) { cursor = pos; label = cm.g("label")! }
                options.append(Option(index: pos, label: label, number: nil))
            }
            if options.count < 2 { return nil }
        }
        if options.isEmpty { return nil }
        // title: nearest question line above the options; detail: lines between + up to 14 above the title
        var t = startIdx - 1
        while t >= windowStart && blank(lines[t]) { t -= 1 }
        var titleIdx = t
        var titleCut: String.Index?
        var between: [String] = []
        var q = t, seen = 0, found = false
        while q >= windowStart && seen < 8 && separator.match(lines[q]) == nil {
            let s = strip(lines[q])
            if !s.isEmpty {
                if s.hasSuffix("?") { titleIdx = q; found = true; break }
                if let r = s.range(of: "? ") { titleIdx = q; titleCut = s.index(after: r.lowerBound); found = true; break }
                between.append(s); seen += 1
            }
            q -= 1
        }
        if !found { between = [] }
        var title = (titleIdx < windowStart || separator.match(lines[titleIdx]) != nil) ? "" : strip(lines[titleIdx])
        var detailLines = between
        if let cut = titleCut, !title.isEmpty, let r = title.range(of: "? ") {
            _ = cut
            let rest = strip(String(title[r.upperBound...]))
            if !rest.isEmpty { detailLines.append(rest) }
            title = String(title[..<title.index(after: r.lowerBound)])
        }
        var d = titleIdx - 1
        while d >= windowStart && detailLines.count < 14 {
            if promptLine.match(lines[d]) != nil { break }
            if separator.match(lines[d]) == nil && dashed.match(lines[d]) == nil { detailLines.append(strip(lines[d])) }
            d -= 1
        }
        let detail = detailLines.reversed().filter { !$0.isEmpty }.joined(separator: "\n")
        let fp = fingerprint(agent, title, detail, options.map(\.label))
        return Dialog(title: title.isEmpty ? "Choose an option" : title, detail: detail, options: options, cursor: cursor, fingerprint: fp)
    }

    private static func claudeInput(_ lines: [String], _ styled: [String]) -> (Bool, String?, Int?) {
        var i = lines.count - 1
        while i > max(-1, lines.count - 40) {
            defer { i -= 1 }
            guard let m = claudePrompt.match(lines[i]) else { continue }
            if i == 0 || separator.match(lines[i - 1]) == nil { continue }
            var parts = [m.g("text") ?? ""]
            var j = i + 1
            while j < lines.count && separator.match(lines[j]) == nil {
                parts.append(lines[j].hasPrefix("  ") ? String(lines[j].dropFirst(2)) : lines[j]); j += 1
            }
            var draft = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if claudePlaceholder.match(draft) != nil { draft = "" }
            // Claude 2.1.30x pre-fills the empty prompt with a dim suggestion; it isn't typed text
            else if !draft.isEmpty && i < styled.count && startsDim(styled[i], "❯") { draft = "" }
            return (true, draft, i - 1)
        }
        return (false, nil, nil)
    }

    private static func codexInput(_ lines: [String], _ styled: [String]) -> (Bool, String?, Int?) {
        var i = lines.count - 1
        while i > max(-1, lines.count - 25) {
            defer { i -= 1 }
            guard let m = codexPrompt.match(lines[i]) else { continue }
            var parts = [m.g("text") ?? ""]
            var j = i + 1
            while j < lines.count && !blank(lines[j]) && !codexFooter.test(lines[j]) && lines[j].hasPrefix("  ") {
                parts.append(String(lines[j].dropFirst(2))); j += 1
            }
            var draft = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if i < styled.count && !draft.isEmpty && codexPlaceholder(styled[i]) { draft = "" }
            else if draft == "Ask Codex to do anything" && !(i < styled.count && styled[i].contains("\u{1b}")) { draft = "" }
            return (true, draft, i)
        }
        return (false, nil, nil)
    }

    /// True when the first visible character after `marker` is drawn dim (SGR 2).
    static func startsDim(_ line: String, _ marker: String) -> Bool {
        guard let r = line.range(of: marker) else { return false }
        let rest = String(line[r.upperBound...])
        let ns = rest as NSString
        var dim = false, k = 0
        while k < ns.length {
            if let m = sgr.match(rest, at: k) {
                let params = (m.g(1) ?? "").split(separator: ";", omittingEmptySubsequences: false).flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }.map(String.init)
                var n = 0
                while n < params.count {
                    let v = params[n]
                    if v == "" || v == "0" || v == "22" { dim = false }
                    else if v == "2" { dim = true }
                    else if ["38", "48", "58"].contains(v) { n += (n + 1 < params.count && params[n + 1] == "5") ? 2 : 4 }
                    n += 1
                }
                k = m.end; continue
            }
            if let m = ansi.match(rest, at: k) { k = m.end; continue }
            let c = ns.character(at: k)
            if c == 0x20 || c == 0xa0 || c == 0x09 { k += 1; continue }
            return dim
        }
        return false
    }

    /// Codex draws the empty-composer placeholder dim.
    static func codexPlaceholder(_ line: String) -> Bool {
        let rest = Rx(#"^(\x1b\[[0-9;]*m)*›(\x1b\[[0-9;]*m)*[\x{00a0} ]"#).replace(line, "")
        return Rx(#"^(\x1b\[[0-9;]*m)*\x1b\[2m[^\x1b]*(\x1b\[[0-9;]*m)*\s*$"#).match(rest) != nil
    }
}
