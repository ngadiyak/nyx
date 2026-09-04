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
