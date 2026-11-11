import Foundation

/// New chats in their own git worktree: a separate checkout on a new branch next to the repository
/// (<repo>-worktrees/<branch>), so several agents can work on one project at once without editing the
/// same files. The chat's Changes view then shows that branch; Commit, Push and Create pull request
/// work from there as usual.
enum AgentWorktree {
    /// Returns the folder the chat should start in: a fresh worktree when [cwd] is inside a git repository.
    static func prepare(_ cwd: String) throws -> String {
        guard let top = try? AgentGit.run(cwd, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else {
            throw AgentTmux.Fail("\(cwd) isn't a git repository, so it can't get its own worktree.")
        }
        let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let branch = "agent/\(f.string(from: Date()))"
        let base = top + "-worktrees"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let path = base + "/" + branch.replacingOccurrences(of: "/", with: "-")
        // starts from what's checked out now (HEAD), including commits not pushed yet
        try AgentGit.run(top, ["worktree", "add", "-b", branch, path, "HEAD"], timeout: 60)
        return path
    }
}
