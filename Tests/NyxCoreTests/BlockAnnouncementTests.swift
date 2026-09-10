import Testing
@testable import NyxCore

private func region(status: Int32?, seconds: Double?, id: UInt32 = 1) -> CommandRegion {
    CommandRegion(promptRow: 0, outputStart: 1, endRow: 5, exitStatus: status,
                  duration: seconds, id: id)
}

/// Announcing every command talks over the user; announcing none is a11y 0.2. The rule is the
/// commands that were worth waiting for and the ones that went wrong.
@Test func aQuickSuccessIsNotAnnounced() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 0.4), command: "ls",
                                   summary: "0.4s", paneIsFocused: true) == nil)
}

@Test func aCommandThatRanTwoSecondsIsAnnouncedWithTheSummaryTheStripShows() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 2), command: "swift build",
                                   summary: "2.0s", paneIsFocused: true) == "swift build \u{2014} 2.0s")
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 1.99), command: "swift build",
                                   summary: "2.0s", paneIsFocused: true) == nil)
}

@Test func aFailureIsAnnouncedHoweverShort() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 0.1), command: "false",
                                   summary: "exit 1 \u{b7} 0.1s", paneIsFocused: true)
            == "false \u{2014} exit 1 \u{b7} 0.1s")
}

/// The focused pane only: four panes in a window, three of them building, is four voices.
@Test func nothingIsAnnouncedInAnUnfocusedPane() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 9), command: "make",
                                   summary: "exit 1 \u{b7} 9s", paneIsFocused: false) == nil)
}

@Test func nothingIsAnnouncedWhileTheCommandIsStillRunning() {
    #expect(BlockAnnouncement.text(for: region(status: nil, seconds: nil), command: "make",
                                   summary: "12s", paneIsFocused: true) == nil)
}

@Test func nothingIsAnnouncedWithoutASummaryToSay() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 9), command: "make",
                                   summary: "", paneIsFocused: true) == nil)
}

/// The subject of the sentence. `exit 1 · 815ms` on its own names no command, and a VoiceOver user
/// with three panes building has no way to tell which of them just failed -- the announcement was
/// the one place in Nyx where the *words* said less than the screen did (PM P1, review F3).
///
/// Collapsed and truncated through `CommandNotification.summarise`, the same 60 characters the
/// notification for a finished command has always used: a spoken sentence is a glance, a
/// three-line `curl` with its headers is not, and the two now agree about how much of a command
/// line is worth saying.
@Test func theCommandLineIsCollapsedAndTruncatedLikeANotificationsIs() {
    // The `\`s are the user's own characters, which is why they survive the collapse: only the
    // newlines and the indentation they continue over are whitespace.
    let wrapped = "curl -sS \\\n  --header 'accept: application/json' \\\n  https://api.example.com/v1"
    let spoken = BlockAnnouncement.text(for: region(status: 22, seconds: 0.3), command: wrapped,
                                        summary: "exit 22 \u{b7} 300ms", paneIsFocused: true)
    #expect(spoken == "curl -sS \\ --header 'accept: application/json' \\ https://ap\u{2026}"
            + " \u{2014} exit 22 \u{b7} 300ms")
    // 60 characters of command, and nothing in it that a screen reader would read as a newline.
    #expect(spoken?.prefix(60).count == 60)
}

/// A pane whose shell emits no `B` mark, or a block whose command row has been trimmed out of the
/// scrollback, has a status and no command line. The summary is still the news, so it is still
/// said -- with no separator hanging off the front of it.
@Test func aFinishWithNoCommandLineToNameIsStillAnnounced() {
    #expect(BlockAnnouncement.text(for: region(status: 2, seconds: 5), command: "   ",
                                   summary: "exit 2 \u{b7} 5s", paneIsFocused: true)
            == "exit 2 \u{b7} 5s")
}
