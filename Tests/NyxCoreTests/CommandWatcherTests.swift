import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

// MARK: - Noticing that a command ended

/// There is no "command ended" event: what happens is that a new prompt appears below the old one.
@Test func aNewPromptEndsTheCommandBeforeIt() {
    var w = CommandWatcher(minimumDuration: 10)
    #expect(w.observe(bottomPromptRow: 0, outputStarted: false, now: 0) == nil)
    #expect(w.observe(bottomPromptRow: 0, outputStarted: true, now: 1) == nil)
    let finished = w.observe(bottomPromptRow: 5, outputStarted: false, now: 30)
    #expect(finished == FinishedCommand(promptRow: 0, duration: 29))
}

/// A notification per `ls` is noise that gets the whole feature turned off within a day.
@Test func aShortCommandIsNotWorthANotification() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, now: 0)
    #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: 3) == nil)
}

@Test func aCommandExactlyAtTheThresholdCounts() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, now: 0)
    #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: 10)?.duration == 10)
}

/// Timing from the `C` mark rather than from the prompt appearing: a terminal left open overnight
/// must not report the first command of the morning as a nine-hour job.
@Test func aPromptThatNeverRanAnythingIsNotTimed() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: false, now: 0)
    _ = w.observe(bottomPromptRow: 0, outputStarted: false, now: 40_000)
    #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: 40_001) == nil)
}

@Test func theFirstPromptSeenIsNotReportedAsAFinishedCommand() {
    var w = CommandWatcher(minimumDuration: 0)
    #expect(w.observe(bottomPromptRow: 3, outputStarted: true, now: 100) == nil)
}

@Test func aCommandIsReportedOnlyOnce() {
    var w = CommandWatcher(minimumDuration: 1)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, now: 0)
    #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: 20) != nil)
    #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: 21) == nil)
}

/// A command that starts the instant the prompt is replaced -- output already flowing -- is timed
/// from that moment, not from whenever the next update happens to arrive.
@Test func aCommandRunningWhenItsPromptAppearsIsTimedFromThere() {
    var w = CommandWatcher(minimumDuration: 5)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, now: 0)
    _ = w.observe(bottomPromptRow: 5, outputStarted: true, now: 10)
    #expect(w.observe(bottomPromptRow: 9, outputStarted: false, now: 16)?.promptRow == 5)
}

// MARK: - What it says

@Test func aFailureSaysSoAndCarriesTheStatus() {
    #expect(CommandNotification.title(failed: true) == "Command failed")
    #expect(CommandNotification.body(command: "$ make test", exitStatus: 2) == "$ make test — exited 2")
}

@Test func aSuccessIsJustTheCommand() {
    #expect(CommandNotification.title(failed: false) == "Command finished")
    #expect(CommandNotification.body(command: "$ make test", exitStatus: 0) == "$ make test")
}

@Test func whitespaceIsCollapsedSoAPromptDoesNotArriveAsAColumnOfSpaces() {
    #expect(CommandNotification.body(command: "$    make    test  ", exitStatus: nil) == "$ make test")
}

/// A notification is a glance; the scrollback is where the whole command line lives.
@Test func aVeryLongCommandIsTruncated() {
    let long = String(repeating: "x", count: 200)
    let body = CommandNotification.body(command: long, exitStatus: nil)
    #expect(body.count == CommandNotification.commandLimit)
    #expect(body.hasSuffix("…"))
}

// MARK: - Reading the command back out of the buffer

@Test func theCommandTextIsThePromptRowUpToItsOutput() throws {
    let t = makeTerminal(cols: 30, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "make test\r\n" + mark("C") + "ok\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let region = try #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandText(of: region) == "$ make test")
}

@Test func aCommandThatProducedNoOutputStillHasItsText() throws {
    let t = makeTerminal(cols: 30, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "true\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let region = try #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandText(of: region) == "$ true")
}

/// Absolute rows shift every time the scrollback trims, which is every new line once the buffer is
/// full. Using the row as identity made a long build look like a new command on each tick, so the
/// clock restarted and the notification never fired -- exactly the case the feature exists for.
@Test func aRunningCommandSurvivesItsRowShiftingUnderneath() {
    var w = CommandWatcher(minimumDuration: 10)
    // A build running for 30 seconds while the scrollback trims a row off the front each tick.
    var row = 9_000
    for tick in 0...60 {
        let finished = w.observe(bottomPromptRow: row, outputStarted: true, now: Double(tick) * 0.5)
        #expect(finished == nil)
        row -= 1
    }
    // The prompt comes back: the command ended.
    let finished = w.observe(bottomPromptRow: row, outputStarted: false, now: 31)
    #expect(finished != nil)
    #expect((finished?.duration ?? 0) >= 30)
}

/// Two commands in a row must each be timed from their own start, not from the first one.
@Test func aSecondCommandIsTimedFromItsOwnStart() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 10, outputStarted: true, now: 0)
    _ = w.observe(bottomPromptRow: 10, outputStarted: false, now: 50)   // ran 50s, reported

    _ = w.observe(bottomPromptRow: 20, outputStarted: true, now: 100)
    let second = w.observe(bottomPromptRow: 20, outputStarted: false, now: 105)
    #expect(second == nil)                                             // only 5s, not worth saying
}

/// Sitting at a prompt doing nothing must never produce a notification, however long it lasts.
@Test func anIdleTerminalNeverReportsAnything() {
    var w = CommandWatcher(minimumDuration: 10)
    for tick in 0...100 {
        #expect(w.observe(bottomPromptRow: 5, outputStarted: false, now: Double(tick)) == nil)
    }
}

// MARK: - Arming a notification for one command

@Test func theFinishedCommandCarriesItsID() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, runningID: 42, now: 0)
    let finished = w.observe(bottomPromptRow: 5, outputStarted: false, runningID: 0, now: 30)
    #expect(finished?.id == 42)
    #expect(finished?.duration == 30)
}

/// The watcher reports short commands too, so an armed one can be noticed; the rule decides.
@Test func anArmedCommandIsReportedHoweverShort() {
    var w = CommandWatcher(minimumDuration: 10)
    _ = w.observe(bottomPromptRow: 0, outputStarted: true, runningID: 42, now: 0)
    let finished = w.observe(bottomPromptRow: 5, outputStarted: false, runningID: 0, now: 2)
    #expect(finished?.id == 42)
    #expect(finished?.duration == 2)
}

@Test func armedBeatsDurationAndFocus() {
    let quick = FinishedCommand(promptRow: 0, duration: 2, id: 42)
    #expect(CommandNotificationRule.shouldNotify(quick, armed: [42], windowFocused: true, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(quick, armed: [], windowFocused: true, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(quick, armed: [], windowFocused: false, minimumDuration: 10))
}

@Test func anUnarmedLongCommandNotifiesOnlyWhenTheWindowIsNotFocused() {
    let long = FinishedCommand(promptRow: 0, duration: 30, id: 7)
    #expect(CommandNotificationRule.shouldNotify(long, armed: [], windowFocused: false, minimumDuration: 10))
    #expect(!CommandNotificationRule.shouldNotify(long, armed: [], windowFocused: true, minimumDuration: 10))
}
