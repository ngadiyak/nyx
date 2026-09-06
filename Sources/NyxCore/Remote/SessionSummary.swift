import Foundation

/// What a host publishes about one of its sessions -- the `Session` row on the wire -- built from
/// whatever pieces `NyxApp` has to hand, most of which are optional because a session may have no
/// repo, no command run yet, or no known cwd.
public enum SessionSummary {
    public static func make(sessionID: String, title: String, cwd: String?, processName: String?,
                             lastCommand: String?, lastActivity: Date?, cols: Int, rows: Int,
                             repo: (name: String, branch: String)?) -> RemoteSessionInfo {
        RemoteSessionInfo(sessionID: sessionID, title: title, cwd: cwd ?? "",
                          repo: repo?.name ?? "", branch: repo?.branch ?? "",
                          process: processName ?? "", lastCommand: lastCommand ?? "",
                          lastActivity: lastActivity.map(iso8601) ?? "", cols: cols, rows: rows)
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Walks from `cwd` up to the filesystem root looking for a `.git/HEAD`. Stops at the first repo
    /// found, so a session inside a submodule reports the submodule, not the superproject.
    ///
    /// A worktree's `.git` is a *file* containing `gitdir: <path>`, not a directory -- `readFile` on
    /// `<dir>/.git/HEAD` then simply finds nothing, which this reports as "no repo here" and keeps
    /// walking up. That undercounts worktrees rather than crashing on one; a real `gitdir:` redirect
    /// is a follow-up, not something this call needs to get right on day one.
    public static func repo(atPath cwd: String, readFile: (String) -> String?) -> (name: String, branch: String)? {
        var dir = cwd
        while true {
            if let head = readFile(dir + "/.git/HEAD") {
                return (lastPathComponent(dir), branch(fromHead: head))
            }
            guard let parent = parentPath(dir), parent != dir else { return nil }
            dir = parent
        }
    }

    /// `Terminal.lastFinishedCommand` names the region; `commandLine(of:)` reads the text back out
    /// of the grid. Neither call needs anything this type does not already have a reference to.
    public static func lastCommand(in t: Terminal) -> String? {
        // Collapsed to one line: `commandLine(of:)` gives back a `\`-continued command with its
        // real newlines, and this is a *row* in another Mac's palette. A newline in it would be
        // drawn as a box or would end the row early.
        t.lastFinishedCommand.map {
            t.commandLine(of: $0).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }
    }

    private static func branch(fromHead head: String) -> String {
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if trimmed.hasPrefix(prefix) { return String(trimmed.dropFirst(prefix.count)) }
        return String(trimmed.prefix(8)) // detached HEAD: the commit hash, shortened
    }

    private static func lastPathComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func parentPath(_ path: String) -> String? {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}
