import Testing
@testable import NyxCore

private func region(status: Int32?, seconds: Double?) -> CommandRegion {
    CommandRegion(promptRow: 0, outputStart: 1, endRow: 5, exitStatus: status,
                  duration: seconds, id: 1)
}

/// Announcing every command talks over the user; announcing none is a11y 0.2. The rule is the
/// commands that were worth waiting for and the ones that went wrong.
@Test func aQuickSuccessIsNotAnnounced() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 0.4), summary: "0.4s",
                                   paneIsFocused: true) == nil)
}

@Test func aCommandThatRanTwoSecondsIsAnnouncedWithTheSummaryTheStripShows() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 2), summary: "2.0s",
                                   paneIsFocused: true) == "2.0s")
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 1.99), summary: "2.0s",
                                   paneIsFocused: true) == nil)
}

@Test func aFailureIsAnnouncedHoweverShort() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 0.1),
                                   summary: "exit 1 \u{b7} 0.1s", paneIsFocused: true)
            == "exit 1 \u{b7} 0.1s")
}

/// The focused pane only: four panes in a window, three of them building, is four voices.
@Test func nothingIsAnnouncedInAnUnfocusedPane() {
    #expect(BlockAnnouncement.text(for: region(status: 1, seconds: 9), summary: "exit 1 \u{b7} 9s",
                                   paneIsFocused: false) == nil)
}

@Test func nothingIsAnnouncedWhileTheCommandIsStillRunning() {
    #expect(BlockAnnouncement.text(for: region(status: nil, seconds: nil), summary: "12s",
                                   paneIsFocused: true) == nil)
}

@Test func nothingIsAnnouncedWithoutASummaryToSay() {
    #expect(BlockAnnouncement.text(for: region(status: 0, seconds: 9), summary: "",
                                   paneIsFocused: true) == nil)
}
