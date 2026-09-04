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
