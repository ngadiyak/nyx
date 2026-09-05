import Testing
@testable import NyxCore

/// The sequences a shell integration emits. `A` before the prompt, `B` before the user's typing,
/// `C` before the output, `D;<status>` when the command ends.
private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

/// Two finished commands and a third prompt waiting for input, the way a real session looks:
///
///     $ echo one     <- rows 0
///     one            <- row 1, output
///     $ false        <- row 2, exits 1
///     $ |            <- row 3, the prompt being typed at
private func session() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

// MARK: - Parsing

@Test func theMarksAreRecordedOnTheRowsTheyArriveOn() {
    let t = session()
    // A and B arrive on the same physical row; keeping only the last would lose the prompt.
    #expect(t.promptMarks(atAbsoluteRow: 0).contains(.commandStart))
    #expect(t.promptMarks(atAbsoluteRow: 0).contains(.promptStart))
    #expect(t.promptMarks(atAbsoluteRow: 1).contains(.outputStart))
    #expect(t.promptMarks(atAbsoluteRow: 2).contains(.promptStart))
}

/// The status is the whole reason the `D` mark is interesting: without it a command that failed
/// looks exactly like one that succeeded.
@Test func theExitStatusIsCapturedFromTheEndMark() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("D", 3))
    #expect(t.exitStatus(atAbsoluteRow: 0) == 3)
}

@Test func anEndMarkWithNoStatusReportsNone() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("D"))
    #expect(t.exitStatus(atAbsoluteRow: 0) == nil)
    #expect(t.promptMarks(atAbsoluteRow: 0).contains(.commandDone))
}

@Test func aRowWithNoMarkReportsNone() {
    let t = makeTerminal(cols: 20, rows: 4).run("plain text")
    #expect(t.promptMarks(atAbsoluteRow: 0).isEmpty)
    #expect(t.promptMarks(atAbsoluteRow: 999).isEmpty)
}

// MARK: - Navigating

@Test func promptRowsListsEveryPromptInOrder() {
    #expect(session().promptRows == [0, 2, 3])
}

@Test func jumpingMovesToTheNearestPromptInThatDirection() {
    let t = session()
    #expect(t.previousPrompt(before: 3) == 2)
    #expect(t.previousPrompt(before: 2) == 0)
    #expect(t.nextPrompt(after: 0) == 2)
    #expect(t.nextPrompt(after: 1) == 2)
}

/// At the ends there is nowhere to go, which the caller has to be able to tell from "moved".
@Test func jumpingPastTheEndsReportsNothingRatherThanClamping() {
    let t = session()
    #expect(t.previousPrompt(before: 0) == nil)
    #expect(t.nextPrompt(after: 3) == nil)
    #expect(t.nextPrompt(after: 999) == nil)
}

@Test func aBufferWithNoMarksHasNowhereToJump() {
    let t = makeTerminal(cols: 20, rows: 4).run("no shell integration here")
    #expect(t.promptRows.isEmpty)
    #expect(t.previousPrompt(before: 2) == nil)
    #expect(t.nextPrompt(after: 0) == nil)
}

// MARK: - Regions

/// Clicking anywhere inside a command -- its prompt, or any row of its output -- has to identify
/// the same command, or "copy this command's output" depends on exactly where you clicked.
@Test func everyRowOfACommandResolvesToTheSameRegion() {
    let t = session()
    let fromPrompt = try! #require(t.command(containingAbsoluteRow: 0))
    let fromOutput = try! #require(t.command(containingAbsoluteRow: 1))
    #expect(fromPrompt == fromOutput)
    #expect(fromPrompt.promptRow == 0)
    #expect(fromPrompt.outputStart == 1)
    #expect(fromPrompt.endRow == 1)      // stops before the next prompt
    #expect(fromPrompt.exitStatus == 0)
}

@Test func aFailedCommandIsDistinguishableFromASuccessfulOne() {
    let t = session()
    #expect(try! #require(t.command(containingAbsoluteRow: 0)).failed == false)
    #expect(try! #require(t.command(containingAbsoluteRow: 2)).failed == true)
}

/// A command still running has no status yet, and "no status" must not read as failure -- otherwise
/// the gutter turns red the moment anything starts.
@Test func aRunningCommandIsNotReportedAsFailed() {
    let t = session()
    let current = try! #require(t.command(containingAbsoluteRow: 3))
    #expect(current.exitStatus == nil)
    #expect(current.failed == false)
}

@Test func aRowAboveTheFirstPromptBelongsToNoCommand() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed("output from before the shell started\r\n" + mark("A") + "$ ")
    #expect(t.command(containingAbsoluteRow: 0) == nil)
}

@Test func aCommandThatProducedNoOutputHasAnEmptyOutputRange() {
    let t = session()
    let failing = try! #require(t.command(containingAbsoluteRow: 2))
    #expect(failing.outputRows.isEmpty || failing.outputStart == nil)
    #expect(t.selectionForOutput(of: failing) == nil)
}

/// "Copy the last command's output" means the last command that *ended*, not the empty prompt the
/// user is sitting at.
@Test func theLastFinishedCommandSkipsThePromptBeingTypedAt() {
    let region = try! #require(session().lastFinishedCommand)
    #expect(region.promptRow == 2)
    #expect(region.exitStatus == 1)
}

/// The auto-fold trigger needs "the command before this one", not "the last one that finished" --
/// at the instant a new command starts, the region *containing* its own first output row is
/// already the new command, so `lastFinishedCommand` would answer with the wrong one.
@Test func previousCommandIsTheOneWhoseRegionEndsJustAbove() {
    let t = session()
    let false_ = try! #require(t.command(containingAbsoluteRow: 2))
    let previous = try! #require(t.previousCommand(of: false_))
    #expect(previous.promptRow == 0)
}

@Test func theFirstCommandHasNoPreviousCommand() {
    let t = session()
    let first = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(t.previousCommand(of: first) == nil)
}

@Test func theOutputSelectionCoversExactlyTheOutputRows() {
    let t = session()
    let region = try! #require(t.command(containingAbsoluteRow: 0))
    let selection = try! #require(t.selectionForOutput(of: region))
    #expect(selection.start.row == 1)
    #expect(selection.end.row == 1)
    #expect(t.text(in: selection).contains("one"))
    #expect(!t.text(in: selection).contains("echo"))   // the command line itself is not output
}

// MARK: - Reflow

/// Marks already survived a resize; the status did not, so every command looked successful after
/// the window was made narrower. Both have to travel together.
@Test func theExitStatusSurvivesAResizeAlongsideItsMark() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ a command long enough to wrap when narrowed" + mark("D", 7) + "\r\n")
    t.resize(cols: 20, rows: 6)

    let row = try! #require((0..<t.totalRows).first { t.promptMarks(atAbsoluteRow: $0).contains(.promptStart) })
    #expect(t.exitStatus(atAbsoluteRow: row) == 7)
}

// MARK: - The current command line

/// Reading what the user has typed but not yet run is what makes "edit this curl" possible: the
/// command has not run, so history has nothing to offer, and the prompt shares its row with the
/// typing, so a row of text is not an answer either.
@Test func theCurrentInputIsTheTypingWithoutThePrompt() {
    let t = makeTerminal(cols: 60, rows: 4, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "curl -X POST https://api.example.com")
    #expect(t.currentInput == "curl -X POST https://api.example.com")
}

@Test func anEmptyPromptHasNoCurrentInput() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B"))
    #expect(t.currentInput == nil)
}

/// While a command is running there is no command line to edit, and offering the output as one
/// would be worse than offering nothing.
@Test func aRunningCommandHasNoCurrentInput() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C") + "working...\r\n")
    #expect(t.currentInput == nil)
}

/// A shell that emits no marks cannot say where its prompt ends, so there is nothing to separate.
@Test func withoutMarksThereIsNoCurrentInput() {
    #expect(makeTerminal(cols: 40, rows: 4).run("$ something typed").currentInput == nil)
}

/// A pasted command long enough to wrap is the whole point -- it must come back joined, not cut at
/// the width of the window.
@Test func aWrappedCommandLineIsReadWhole() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "curl -X POST -d 'a=1&b=2' https://example.com/very/long")
    let input = try! #require(t.currentInput)
    #expect(input.hasPrefix("curl -X POST"))
    #expect(input.hasSuffix("/very/long"))
    #expect(!input.contains("\n"))
}

// MARK: - Clicking into the command line

/// The arithmetic behind clicking where you want to fix something: the difference between the
/// caret's offset and the clicked cell's offset is the number of arrow keys to send.
@Test func anOffsetIsCountedFromWhereTypingBegins() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "curl example.com")
    // "$ " is two columns, so typing starts at column 2.
    #expect(t.inputOffset(atAbsoluteRow: 0, column: 2) == 0)
    #expect(t.inputOffset(atAbsoluteRow: 0, column: 6) == 4)
    #expect(t.currentInputCursorOffset == 16)
}

/// A click on the prompt itself, or above the command line, is not a place the caret can go.
@Test func aClickOutsideTheCommandLineHasNoOffset() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50)
    t.feed("earlier output\r\n" + mark("A") + "$ " + mark("B") + "curl example.com")
    #expect(t.inputOffset(atAbsoluteRow: 1, column: 0) == nil)   // on the prompt
    #expect(t.inputOffset(atAbsoluteRow: 0, column: 3) == nil)   // above it
}

/// The case that matters: a pasted command longer than the window is wide. Counting has to run
/// through the wrap, or clicking on the second line moves the caret to the wrong place.
@Test func anOffsetCountsThroughAWrappedLine() {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "curl -X POST https://example.com/a")
    // Row 0 holds "$ " plus 18 characters of the command; the next row continues it.
    #expect(t.inputOffset(atAbsoluteRow: 1, column: 0) == 18)
    #expect(t.inputOffset(atAbsoluteRow: 1, column: 5) == 23)
}

@Test func withoutMarksThereIsNothingToClickInto() {
    let t = makeTerminal(cols: 40, rows: 4).run("$ curl example.com")
    #expect(t.inputOffset(atAbsoluteRow: 0, column: 5) == nil)
    #expect(t.currentInputCursorOffset == nil)
}

// MARK: - Duration

/// The terminal knew how long everything took and could tell you about none of it: the timer lived
/// only for the running command and was thrown away after the notification.
@Test func aCommandsDurationIsRecordedOnItsPromptRow() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    var clock = 100.0
    t.now = { clock }
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    clock = 102.5
    t.feed("done\r\n" + mark("D", 0))

    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(region.duration != nil)
    #expect(abs((region.duration ?? 0) - 2.5) < 0.001)
}

/// Timed from when the command started running, not from when the prompt appeared -- otherwise a
/// terminal left open overnight reports the first command of the morning as a nine-hour job.
@Test func theClockStartsWhenTheCommandDoesNotWhenThePromptAppears() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    var clock = 0.0
    t.now = { clock }
    t.feed(mark("A") + "$ ")
    clock = 30_000            // the user went home
    t.feed(mark("B") + "ls\r\n" + mark("C"))
    clock = 30_001
    t.feed(mark("D", 0))

    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(abs((region.duration ?? 0) - 1) < 0.001)
}

@Test func aRunningCommandHasNoDurationYet() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C") + "working\r\n")
    #expect(try! #require(t.command(containingAbsoluteRow: 0)).duration == nil)
}

// MARK: - Writing a duration down

/// The difference between 4ms and 400ms is the whole reason to show a number; "0.0s" throws it away.
@Test func subSecondTimesAreGivenInMilliseconds() {
    #expect(DurationText.short(0.004) == "4ms")
    #expect(DurationText.short(0.4) == "400ms")
}

@Test func longerTimesGetCoarserAsTheyGrow() {
    #expect(DurationText.short(2.46) == "2.5s")
    #expect(DurationText.short(42) == "42s")
    #expect(DurationText.short(125) == "2m 5s")
    #expect(DurationText.short(7300) == "2h 1m")
}

@Test func nonsenseDurationsProduceNothing() {
    #expect(DurationText.short(-1).isEmpty)
    #expect(DurationText.short(.nan).isEmpty)
}

/// `3ms` beside every `cd` is noise that hides the number anyone actually cares about.
@Test func onlyCommandsThatTookLongEnoughAreWorthShowing() {
    #expect(!DurationText.isWorthShowing(0.003))
    #expect(DurationText.isWorthShowing(2.5))
}

/// The status already survived a resize; the duration has to travel with it, or every command
/// forgets how long it took the moment the window is made narrower.
@Test func theDurationSurvivesAResize() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    var clock = 0.0
    t.now = { clock }
    t.feed(mark("A") + "$ a command long enough to wrap when the window narrows" + mark("B"))
    t.feed("\r\n" + mark("C"))
    clock = 7
    t.feed(mark("D", 0))
    t.resize(cols: 20, rows: 6)

    let row = try! #require((0..<t.totalRows).first { t.promptMarks(atAbsoluteRow: $0).contains(.promptStart) })
    let region = try! #require(t.command(containingAbsoluteRow: row))
    #expect(abs((region.duration ?? 0) - 7) < 0.001)
}

// MARK: - The command line, without the shell's prompt

/// A real prompt is not `$ `. `nik@host ~ %` in front of every copied command is what "Copy
/// Command" used to produce, and "Run This Command Again" sent that whole string to the shell.
private func promptedSession(cols: Int = 40, command: String = "make test") -> Terminal {
    let t = makeTerminal(cols: cols, rows: 6, scrollback: 100)
    t.feed(mark("A") + "nik@host ~ % " + mark("B") + command + "\r\n" + mark("C") + "ok\r\n" + mark("D", 0))
    return t
}

@Test func theCommandLineDropsTheShellsOwnPrompt() {
    let t = promptedSession()
    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandLine(of: region) == "make test")
    // `commandText` is unchanged: a notification wants the host and directory for context.
    #expect(t.commandText(of: region).contains("nik@host"))
}

/// A command longer than the window is the case "Run Again" must not corrupt: the two rows are one
/// line, so they are joined with nothing between them rather than with a space.
@Test func aWrappedCommandLineIsJoinedBackTogether() {
    let t = promptedSession(cols: 20, command: "echo abcdefghij")
    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandLine(of: region) == "echo abcdefghij")
}

/// A shell that emits `A` and `C` but no `B` says nothing about where its prompt ends, so there is
/// nothing to slice at and the older, wider answer is better than an empty one.
@Test func withoutAnInputMarkTheCommandLineFallsBackToTheWholeRow() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "nik@host ~ % make test\r\n" + mark("C") + "ok\r\n" + mark("D", 0))
    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandLine(of: region) == t.commandText(of: region))
    #expect(t.commandLine(of: region).contains("nik@host"))
}

/// The prompt the user is typing at has no output yet; asking for its command line must not read
/// past the end of the buffer.
@Test func theCommandLineOfAPromptWithNothingTypedIsEmpty() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "nik@host ~ % " + mark("B"))
    let region = try! #require(t.command(containingAbsoluteRow: 0))
    #expect(t.commandLine(of: region).isEmpty)
}
