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
    // The padding is the ceiling, not `maximumWidth`: at the default eight the gutter is eight.
    #expect(PromptGutter.width(padding: 8) == 8)
    #expect(PromptGutter.width(padding: 100) == PromptGutter.maximumWidth)
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
    #expect(GutterMarkLabel.text(mark: .succeeded, folded: false, hasOutput: true, line: 4)
        == "Command on line 4 succeeded. Fold its output. Option-click selects its output.")
    #expect(GutterMarkLabel.text(mark: .failed, folded: true, hasOutput: true, line: 1)
        == "Command on line 1 failed. Unfold its output. Option-click selects its output.")
}

@Test func aRunningCommandsMarkSaysSo() {
    #expect(GutterMarkLabel.text(mark: .running, folded: false, hasOutput: true, line: 2)
        == "Command on line 2 is still running. Fold its output. Option-click selects its output.")
}

/// `cd ..`, `export FOO=1`, `true`: the dot is a record of what happened, and there is nothing to
/// fold and nothing to select, so it promises neither. It used to offer both and then beep.
@Test func aMarkOnACommandThatPrintedNothingPromisesNothing() {
    #expect(GutterMarkLabel.text(mark: .succeeded, folded: false, hasOutput: false, line: 3)
        == "Command on line 3 succeeded.")
    #expect(GutterMarkLabel.text(mark: .failed, folded: false, hasOutput: false, line: 3)
        == "Command on line 3 failed.")
}

@Test func onlyAMarkWithOutputCanBePressed() {
    #expect(GutterMark.succeeded.isActionable(hasOutput: true))
    #expect(!GutterMark.succeeded.isActionable(hasOutput: false))
    // Drawn and not pressable at once: a command that has started and printed nothing.
    #expect(GutterMark.running.isDrawn(hasStarted: true))
    #expect(!GutterMark.running.isActionable(hasOutput: false))
}

/// The prompt you are typing at carries a prompt mark and no status, so it reads as running. A ring
/// there would sit beside an idle cursor for the rest of the session. What tells the two apart is
/// the shell's `C` -- not whether anything has been printed, because a `sleep 10` has printed
/// nothing and is exactly what the ring is for.
@Test func aRunningMarkIsDrawnOnlyOnceTheShellSaidTheCommandStarted() {
    #expect(!GutterMark.running.isDrawn(hasStarted: false))
    #expect(GutterMark.running.isDrawn(hasStarted: true))
    #expect(GutterMark.succeeded.isDrawn(hasStarted: false))   // a record, whatever it printed
    #expect(GutterMark.failed.isDrawn(hasStarted: false))
}

// MARK: - Which commands printed anything

@Test func aCommandThatPrintedNothingHasNoOutput() {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "cd ..\r\n" + mark("C") + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a.txt\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    #expect(!t.commandHasOutput(atAbsoluteRow: 0))          // cd ..
    #expect(t.commandHasOutput(atAbsoluteRow: 1))           // ls
    #expect(!t.commandHasOutput(atAbsoluteRow: 3))          // the prompt being typed at
}

/// The cheap test is *stricter* than the region -- it also rejects output rows that are all blank --
/// so wherever it says yes the region must too. The other direction is the point of the rule and is
/// covered by the running-command cases below.
@Test func theCheapOutputTestIsNeverLooserThanTheRegion() {
    let t = makeTerminal(cols: 20, rows: 10, scrollback: 100)
    // A wrapped command line, so the walk crosses rows that carry no marks at all.
    t.feed(mark("A") + "$ " + mark("B") + "echo abcdefghijklmnop\r\n" + mark("C") + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a.txt\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "echo\r\n" + mark("C") + "\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    var sawADivergence = false
    for row in 0..<t.totalRows where t.promptMarks(atAbsoluteRow: row).contains(.promptStart) {
        let regionHas = !(t.command(containingAbsoluteRow: row)?.outputRows.isEmpty ?? true)
        let cheap = t.commandHasOutput(atAbsoluteRow: row)
        if cheap { #expect(regionHas, "row \(row): cheap said yes where the region said no") }
        if regionHas && !cheap { sawADivergence = true }
    }
    // The `echo` whose only output row is empty is exactly where the two part company.
    #expect(sawADivergence)
}

// MARK: - Output means something on the rows, not just a mark saying it began

// `OSC 133;C` arrives when the command *starts*, before it prints. A `sleep 10` one second in has
// an output region made of the blank rows below it, and folding it collapsed five empty lines into
// "… 5 lines hidden".

@Test func aJustStartedCommandHasNothingToFoldYet() throws {
    let t = makeTerminal(cols: 40, rows: 24, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "sleep 10\r\n" + mark("C"))
    #expect(t.commandDidStart(atAbsoluteRow: 0))       // the shell said it began
    #expect(!t.commandHasOutput(atAbsoluteRow: 0))     // and it has printed nothing
    // So the ring is drawn -- something *is* running -- and it cannot be pressed.
    let m = try #require(t.gutterMarks(rows: 24)[0])
    #expect(m == .running)
    #expect(m.isDrawn(hasStarted: true))
    #expect(!m.isActionable(hasOutput: false))
    #expect(GutterMarkLabel.text(mark: m, folded: false, hasOutput: false, line: 1)
        == "Command on line 1 is still running.")
}

/// The prompt waiting for you to type has not started anything, so it has no ring.
@Test func anIdlePromptHasNotStarted() {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a.txt\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    #expect(!t.commandDidStart(atAbsoluteRow: 2))
    #expect(t.commandDidStart(atAbsoluteRow: 0))
}

@Test func theSameCommandIsFoldableOnceItPrintsALine() throws {
    let t = makeTerminal(cols: 40, rows: 24, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "sleep 10\r\n" + mark("C"))
    #expect(!t.commandHasOutput(atAbsoluteRow: 0))
    t.feed("compiling...\r\n")
    #expect(t.commandHasOutput(atAbsoluteRow: 0))
    let m = try #require(t.gutterMarks(rows: 24)[0])
    #expect(m.isDrawn(hasStarted: true))
    #expect(m.isActionable(hasOutput: true))
}

/// `echo` prints one empty line. There is nothing in it to fold.
@Test func aFinishedCommandWhoseOutputIsOneEmptyLineHasNothingToFold() {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "echo\r\n" + mark("C") + "\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    #expect(!t.commandHasOutput(atAbsoluteRow: 0))
}

/// Eight blank lines and still going: the rest is taken on trust rather than scanned, which is the
/// trade `outputScanLimit` names.
@Test func outputThatStaysBlankPastTheScanLimitIsAssumedToHaveContent() {
    let t = makeTerminal(cols: 40, rows: 24, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "run\r\n" + mark("C"))
    for _ in 0..<Terminal.outputScanLimit { t.feed("\r\n") }
    #expect(t.commandHasOutput(atAbsoluteRow: 0))
}

@Test func outputStatesFollowTheRowsOnScreen() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "cd ..\r\n" + mark("C") + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a.txt\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let states = t.outputStates(rows: 6)
    #expect(!states[0])
    #expect(states[1])
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

/// The gutter's hit area is wider than the mark it draws.
///
/// The owner's report: the dots are hard to click. A 5-point-wide strip is a 5-point-wide target,
/// and the mark inside it is smaller still. The strip may take up to fourteen points of the pane's
/// own padding now -- it can never take more than the padding, so nothing moves at the default
/// eight -- while the capsule keeps exactly the size and the position it had, and the extra width
/// is empty space on the *text* side, which is where a pointer reaching for a dot overshoots to.
@Test func theGutterIsWiderThanItsMark() {
    // Never more than the padding: the gutter lives inside it and must not reach a glyph.
    #expect(PromptGutter.width(padding: 8) == 8)
    #expect(PromptGutter.width(padding: 20) == 14)
    #expect(PromptGutter.width(padding: 4) == 4)
    // Below the floor there is no gutter at all rather than one over the first column.
    #expect(PromptGutter.width(padding: 3) == 0)
    #expect(PromptGutter.width(padding: 0) == 0)

    // The drawn capsule, at every gutter width it can have: same place, same size.
    let atSix = PromptGutter.markRect(gutterWidth: 6)
    #expect(atSix.x == 1)
    #expect(atSix.width == 4)
    for width in [8.0, 10, 14] {
        let rect = PromptGutter.markRect(gutterWidth: width)
        #expect(rect == atSix, "gutter \(width) moved or resized the mark")
    }
    // A gutter too narrow for the whole capsule draws what fits rather than overflowing.
    #expect(PromptGutter.markRect(gutterWidth: 4).width == 2)
    #expect(PromptGutter.markRect(gutterWidth: 0).width == 0)
}
