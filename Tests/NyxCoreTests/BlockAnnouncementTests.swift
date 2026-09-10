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

// MARK: - Which finish a check is looking at

/// `false` at the prompt was silent, and "however short" above is why that was a bug rather than
/// the rule: `CommandWatcher.observe` only ever reports a command it *saw running*, and the check
/// is coalesced half a second after output arrives, so a command that starts and ends between two
/// checks was never reported at all. The prompt marks know it finished -- the region above the
/// bottom-most one carries its exit status -- so that is the second signal.
@Test func anInstantFailureNobodySawRunningIsAnnouncedFromThePredecessor() {
    let finish = BlockAnnouncement.finish(observed: nil,
                                          predecessor: region(status: 1, seconds: 0.02, id: 7),
                                          lastHandled: 5)
    #expect(finish?.region.id == 7)
    #expect(finish?.isNews == true)
}

/// The two signals name the same command whenever both fire -- a command seen running is also the
/// bottom's predecessor once its prompt appears -- so one id is recorded on **both** paths and a
/// three-second build is spoken once, not twice.
@Test func aCommandAlreadyDealtWithIsNotAnnouncedAgain() {
    let observed = region(status: 0, seconds: 3, id: 9)
    #expect(BlockAnnouncement.finish(observed: observed, predecessor: observed, lastHandled: nil)?
            .region.id == 9)
    #expect(BlockAnnouncement.finish(observed: observed, predecessor: observed, lastHandled: 9) == nil)
    // And the predecessor alone, on the next check half a second later, is the same command.
    #expect(BlockAnnouncement.finish(observed: nil, predecessor: observed, lastHandled: 9) == nil)
}

/// A pane's **first** look is not news. The command above the prompt has already finished: a
/// restored session's last build, or a snapshot fed into a pane before its shell ever started.
/// Speaking it would be a terminal telling you about something that happened yesterday -- so the
/// first predecessor is *recorded* (`isNews` false) and the check after it has a baseline.
///
/// A command this pane watched run is news whatever else is true, first look or not: `observed`
/// exists only because the watcher saw it start here.
@Test func theFirstLookAtAPaneRecordsItsHistoryWithoutSpeakingIt() {
    let restored = region(status: 1, seconds: 12, id: 4)
    let first = BlockAnnouncement.finish(observed: nil, predecessor: restored, lastHandled: nil)
    #expect(first?.region.id == 4)
    #expect(first?.isNews == false)
    let watched = BlockAnnouncement.finish(observed: region(status: 1, seconds: 12, id: 4),
                                           predecessor: restored, lastHandled: nil)
    #expect(watched?.isNews == true)
}

/// **A decision, not an accident:** with several prompts between two checks -- a script that runs
/// three commands, or a pane that was occluded -- only the newest predecessor is announced. The
/// check has exactly one predecessor to look at, the ones before it are already history by the
/// time anybody could be told, and three sentences spoken over each other is worse than one.
@Test func onlyTheNewestFinishIsAnnouncedWhenSeveralHappenedBetweenTwoChecks() {
    let newest = region(status: 1, seconds: 0.1, id: 12)
    let finish = BlockAnnouncement.finish(observed: nil, predecessor: newest, lastHandled: 6)
    #expect(finish?.region.id == 12)
    #expect(finish?.isNews == true)
}

/// The prompt you are typing at is the bottom's predecessor for as long as the command you just
/// started is running: it has no status and no duration, and there is nothing to say about it yet.
@Test func aPredecessorThatHasNotEndedIsNotAFinish() {
    #expect(BlockAnnouncement.finish(observed: nil, predecessor: region(status: nil, seconds: nil, id: 3),
                                     lastHandled: 1) == nil)
    #expect(BlockAnnouncement.finish(observed: nil, predecessor: nil, lastHandled: 1) == nil)
}

/// Block id 0 is "no command": a region whose prompt row carries no id at all. Recording it would
/// make the *next* real finish look like one already dealt with.
@Test func aRegionWithNoIDIsNotAFinish() {
    #expect(BlockAnnouncement.finish(observed: nil, predecessor: region(status: 1, seconds: 1, id: 0),
                                     lastHandled: 1) == nil)
}
