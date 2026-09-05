import Foundation
import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

/// Three commands in a six-row terminal: one that succeeded, one that failed, and the prompt the
/// user is typing at.
///
///     row 0  $ echo one
///     row 1  one
///     row 2  $ false
///     row 3  $ |
private func session() -> Terminal {
    let t = makeTerminal(cols: 20, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

// MARK: - Marks

@Test func aFinishedCommandIsGreenAndAFailedOneIsRed() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[0] == .succeeded)
    #expect(marks[2] == .failed)
}

/// The prompt the user is typing at has not run anything, so there is nothing to say about it yet.
@Test func aPromptWithNoStatusYetIsRunning() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[3] == .running)
}

@Test func rowsWithoutAPromptCarryNoMark() {
    let marks = session().gutterMarks(rows: 6)
    #expect(marks[1] == nil)
    #expect(marks[4] == nil)
}

@Test func aBufferWithNoShellIntegrationHasAnEmptyGutter() {
    let t = makeTerminal(cols: 20, rows: 4).run("hello\r\nworld")
    let marks = t.gutterMarks(rows: 4)
    let empty = marks.allSatisfy { $0 == nil }
    #expect(empty)
}

@Test func thereIsOneMarkPerVisibleRowAndNoMore() {
    #expect(session().gutterMarks(rows: 3).count == 3)
    #expect(session().gutterMarks(rows: 0).isEmpty)
}

/// The `D` closing a command lands on the row the *next* prompt occupies, so a prompt on the last
/// visible row still has to find its status below the fold.
@Test func aPromptOnTheLastVisibleRowStillFindsItsStatus() {
    let marks = session().gutterMarks(rows: 3)
    #expect(marks[2] == .failed)
}

/// A fresh prompt must not inherit the failure of the command before it.
@Test func aNewPromptDoesNotInheritTheStatusAboveIt() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("B") + "false\r\n" + mark("C") + mark("D", 1))
    t.feed(mark("A") + "$ ")
    let marks = t.gutterMarks(rows: 4)
    #expect(marks[0] == .failed)
    #expect(marks[1] == .running)
}

/// A shell that emits `D` with no status is saying the command ended, not that it failed -- the
/// same rule `CommandRegion.failed` follows.
@Test func anEndMarkWithNoStatusCountsAsSuccess() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed(mark("A") + "$ " + mark("B") + "x\r\n" + mark("C") + mark("D"))
    t.feed(mark("A") + "$ ")
    #expect(t.gutterMarks(rows: 4)[0] == .succeeded)
}

// MARK: - Geometry

/// The gutter lives inside the pane's own padding, so it costs no columns and never touches a
/// glyph -- which means a pane with no padding gets no gutter rather than one over its text.
@Test func theGutterFitsInsideThePadding() {
    #expect(PromptGutter.width(padding: 8) == PromptGutter.maximumWidth)
    #expect(PromptGutter.width(padding: 5) == 5)
    #expect(PromptGutter.width(padding: 0) == 0)
    #expect(PromptGutter.width(padding: 2) == 0)
}

@Test func aPointMapsToTheRowItIsOver() {
    #expect(PromptGutter.row(atY: 8, cellHeight: 16, padding: 8, rows: 4) == 0)
    #expect(PromptGutter.row(atY: 25, cellHeight: 16, padding: 8, rows: 4) == 1)
}

@Test func aPointInThePaddingOrPastTheLastRowIsOverNothing() {
    #expect(PromptGutter.row(atY: 2, cellHeight: 16, padding: 8, rows: 4) == nil)
    #expect(PromptGutter.row(atY: 400, cellHeight: 16, padding: 8, rows: 4) == nil)
}

/// The gutter runs on every frame while holding the session lock. Searching forward for a `D` that
/// does not exist yet -- a command still running -- walked the whole buffer each time, in exactly
/// the situation this is used in: scrolled up, reading a long build that is still going.
@Test func theGutterCostsOnlyTheRowsOnScreen() {
    let t = makeTerminal(cols: 20, rows: 4, scrollback: 5000)
    // A running command at the top, then a great deal of output below it.
    t.feed("\u{1b}]133;A\u{07}$ build\r\n\u{1b}]133;C\u{07}")
    for i in 1...2000 { t.feed("line \(i)\r\n") }

    // Scrolled to the top, so the running command's prompt is on screen with the whole buffer
    // below it. Without that the loop leaves at once and measures nothing.
    _ = t.scrollToAbsoluteRow(0)

    let started = Date.timeIntervalSinceReferenceDate
    for _ in 0..<200 { _ = t.gutterMarks(rows: 4) }
    let elapsed = Date.timeIntervalSinceReferenceDate - started

    // 200 frames over a 2000-row buffer. Walking it each time is ~400k row lookups and shows up
    // plainly; stopping early is a few hundred. The bound is loose on purpose -- it is here to
    // catch a return to O(buffer), not to police milliseconds.
    // Measured at 95ms before the status was recorded on its prompt row, and 0.3ms after. The
    // bound is loose on purpose: it exists to catch a return to O(buffer), not to police
    // milliseconds on whatever machine happens to run it.
    #expect(elapsed < 0.02, "gutter took \(String(format: "%.1f", elapsed * 1000))ms for 200 frames")
}

/// A status arriving after the output, with the prompt still on screen, has to reach the mark it
/// belongs to -- the mark is drawn beside the prompt, not beside the `D`.
@Test func aStatusAfterTheOutputReachesItsPrompt() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed("\u{1b}]133;A\u{07}$ x\r\n\u{1b}]133;C\u{07}a\r\nb\r\nc\r\n\u{1b}]133;D;1\u{07}")
    let marks = t.gutterMarks(rows: 8)
    #expect(marks[0] == .failed)
}

/// The mark stays `.running` while the command is still producing, which is the honest answer --
/// and the case where the search for a status has nothing to find.
@Test func aRunningCommandIsMarkedRunningRatherThanGuessedAt() {
    let t = makeTerminal(cols: 20, rows: 8, scrollback: 100)
    t.feed("\u{1b}]133;A\u{07}$ build\r\n\u{1b}]133;C\u{07}working\r\n")
    #expect(t.gutterMarks(rows: 8)[0] == .running)
}

// MARK: - Durations on the row

/// The number has to be on screen without hovering, folding or scrolling. A figure you can only
/// reach by doing something first is a figure nobody reads.
@Test func aSlowCommandGetsItsDurationOnItsOwnRow() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    var clock = 0.0
    t.now = { clock }
    t.feed("\u{1b}]133;A\u{07}$ build\r\n\u{1b}]133;C\u{07}")
    clock = 2.4
    t.feed("done\r\n\u{1b}]133;D;0\u{07}")

    let notes = t.durationNotes(rows: 6)
    #expect(notes[0] == "2.4s")
    #expect(notes[1] == nil)      // output rows say nothing
}

/// `3ms` beside every `cd` is noise that hides the one figure anybody cares about.
@Test func aFastCommandGetsNoNumber() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    var clock = 0.0
    t.now = { clock }
    t.feed("\u{1b}]133;A\u{07}$ cd\r\n\u{1b}]133;C\u{07}")
    clock = 0.003
    t.feed("\u{1b}]133;D;0\u{07}")
    #expect(t.durationNotes(rows: 6).allSatisfy { $0 == nil })
}

@Test func aRunningCommandHasNoNumberYet() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 50)
    t.feed("\u{1b}]133;A\u{07}$ build\r\n\u{1b}]133;C\u{07}working\r\n")
    #expect(t.durationNotes(rows: 6).allSatisfy { $0 == nil })
}

@Test func withoutShellIntegrationNoRowSaysAnything() {
    let t = makeTerminal(cols: 40, rows: 6).run("$ build\r\ndone")
    #expect(t.durationNotes(rows: 6).allSatisfy { $0 == nil })
}

// MARK: - What a mark says it does

// Pressing a mark folds the block; ⌥-click selects its output. The label promised the opposite.

@Test func aMarkSaysItFoldsAndHowToSelectInstead() {
    #expect(GutterMarkLabel.text(mark: .succeeded, folded: false, line: 4)
        == "Command on line 4 succeeded. Fold its output. Option-click selects its output.")
    #expect(GutterMarkLabel.text(mark: .failed, folded: true, line: 1)
        == "Command on line 1 failed. Unfold its output. Option-click selects its output.")
}

@Test func aRunningCommandsMarkSaysSo() {
    #expect(GutterMarkLabel.text(mark: .running, folded: false, line: 2)
        == "Command on line 2 is still running. Fold its output. Option-click selects its output.")
}

@Test func theGutterKnowsWhichOfItsCommandsAreFolded() {
    let t = session()
    var folding = OutputFolding()
    let first = t.command(containingAbsoluteRow: 0)!
    folding.fold(first.id, .all)
    let states = t.foldStates(rows: 6, folding: folding)
    #expect(states[0])                       // the folded command's prompt row
    #expect(!states[1])                      // its output, which carries no prompt
    #expect(!states[2])                      // the command that is not folded
}

@Test func aFoldPlaceholderSlotIsNotAFoldedCommandsPrompt() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(t.command(containingAbsoluteRow: 0)!.id, .all)
    let display = t.displayRows(from: 0, count: 4, folding: folding)
    let states = t.foldStates(onDisplayRows: display, folding: folding)
    #expect(states[0])                       // slot 0 is the prompt of the folded command
    #expect(!states[1])                      // slot 1 is the placeholder itself
}
