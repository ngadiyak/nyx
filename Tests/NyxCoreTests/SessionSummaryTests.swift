import Foundation
import Testing
@testable import NyxCore

@Test func repoFindsTheBranchFromASymbolicHead() {
    let repo = SessionSummary.repo(atPath: "/a/b") { path in
        path == "/a/b/.git/HEAD" ? "ref: refs/heads/main\n" : nil
    }
    #expect(repo?.name == "b")
    #expect(repo?.branch == "main")
}

@Test func repoWalksUpFromASubdirectory() {
    let repo = SessionSummary.repo(atPath: "/a/b/src/deep") { path in
        path == "/a/b/.git/HEAD" ? "ref: refs/heads/dev\n" : nil
    }
    #expect(repo?.name == "b")
    #expect(repo?.branch == "dev")
}

@Test func repoReportsAnEightCharacterHashForADetachedHead() {
    let repo = SessionSummary.repo(atPath: "/a/b") { path in
        path == "/a/b/.git/HEAD" ? "1234567890abcdef\n" : nil
    }
    #expect(repo?.branch == "12345678")
}

@Test func repoIsNilWhenNothingIsFoundUpToTheRoot() {
    let repo = SessionSummary.repo(atPath: "/a/b/c") { _ in nil }
    #expect(repo == nil)
}

/// Documented limitation: a worktree's `.git` is a *file* (`gitdir: …`), not a directory, so there
/// is never a `.git/HEAD` under it for `readFile` to find -- this reports "no repo" rather than
/// following the redirect.
@Test func repoIsNilForAWorktreeGitFile() {
    let repo = SessionSummary.repo(atPath: "/a/b") { path in
        path == "/a/b/.git" ? "gitdir: /elsewhere/.git/worktrees/b\n" : nil
    }
    #expect(repo == nil)
}

@Test func makeMapsEveryField() {
    let activity = Date(timeIntervalSince1970: 1_788_609_600) // 2026-09-05T12:00:00Z
    let info = SessionSummary.make(sessionID: "s1", title: "zsh", cwd: "/tmp",
                                   processName: "swift test", lastCommand: "make test",
                                   lastActivity: activity, cols: 80, rows: 24,
                                   repo: (name: "nyx", branch: "main"))
    #expect(info == RemoteSessionInfo(sessionID: "s1", title: "zsh", cwd: "/tmp", repo: "nyx",
                                      branch: "main", process: "swift test", lastCommand: "make test",
                                      lastActivity: "2026-09-05T12:00:00Z", cols: 80, rows: 24))
}

@Test func makeDefaultsMissingFieldsToEmptyStrings() {
    let info = SessionSummary.make(sessionID: "s1", title: "zsh", cwd: nil, processName: nil,
                                   lastCommand: nil, lastActivity: nil, cols: 80, rows: 24, repo: nil)
    #expect(info.cwd == "")
    #expect(info.repo == "")
    #expect(info.branch == "")
    #expect(info.process == "")
    #expect(info.lastCommand == "")
    #expect(info.lastActivity == "")
}

/// The shell-integration marks a real prompt emits: `A` before the prompt, `B` before what the
/// user typed, `C` before the output, `D;<status>` when the command ends -- matches the fixture
/// `PromptMarksTests` uses for the same escape sequences.
private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

@Test func lastCommandReadsTheLastFinishedCommandsLine() {
    let t = makeTerminal(cols: 20, rows: 5)
    t.feed(mark("A") + "$ " + mark("B") + "echo hi\r\n" + mark("C") + "hi\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    #expect(SessionSummary.lastCommand(in: t) == "echo hi")
}
