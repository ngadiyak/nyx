import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// A short command, then one with a long output, then a fresh prompt:
///
///     0  $ echo one
///     1  one
///     2  $ build
///     3..12  twelve rows of output
///     13 $ (typing here)
private func session() -> Terminal {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...10 { t.feed("output line \(i)\r\n") }
    t.feed(mark("D", 1))
    t.feed(mark("A") + "$ ")
    return t
}

// MARK: - Sticky prompt

/// The case it exists for: scrolled into the middle of a long build, with the command that started
/// it far above.
@Test func readingInsideACommandsOutputPinsItsCommandLine() {
    let t = session()
    let pinned = t.stickyPrompt(viewportTop: 8)
    let sticky = try! #require(pinned)
    #expect(sticky.row == 2)
    #expect(sticky.failed)
    #expect(sticky.exitStatus == 1)
}

/// Pinning a copy of a line already on screen wastes a row and reads as a rendering bug.
@Test func nothingIsPinnedWhileThePromptIsStillVisible() {
    let pinned = session().stickyPrompt(viewportTop: 2)
    #expect(pinned == nil)
}

@Test func nothingIsPinnedAboveTheFirstCommand() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50)
    t.feed("output from before any prompt\r\n")
    let pinned = t.stickyPrompt(viewportTop: 0)
    #expect(pinned == nil)
}

/// A shell with no integration emits no marks, so there is no command line to name.
@Test func nothingIsPinnedWithoutShellIntegration() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 50).run("plain\r\noutput\r\nhere")
    let pinned = t.stickyPrompt(viewportTop: 2)
    #expect(pinned == nil)
}

/// The prompt being typed at has produced nothing, so there is nothing to lose track of -- and a
/// strip appearing over it would be actively in the way.
@Test func nothingIsPinnedAtThePromptBeingTypedAt() {
    let t = session()
    let pinned = t.stickyPrompt(viewportTop: t.totalRows - 1)
    #expect(pinned == nil)
}

@Test func aSuccessfulCommandIsPinnedWithoutBeingMarkedFailed() {
    let t = session()
    let pinned = t.stickyPrompt(viewportTop: 1)
    let sticky = try! #require(pinned)
    #expect(sticky.row == 0)
    #expect(!sticky.failed)
    #expect(sticky.exitStatus == 0)
}

// MARK: - Folding

@Test func nothingIsHiddenUntilSomethingIsFolded() {
    let t = session()
    let rows = t.displayRows(in: 0..<14, folding: OutputFolding())
    #expect(rows == (0..<14).map { .row($0) })
}

/// The prompt stays: the point is to hide the output, not the command that produced it.
@Test func foldingHidesTheOutputAndKeepsTheCommand() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(promptRow: 2)

    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows.contains(.row(2)))
    #expect(rows.contains { if case .fold(2, let hidden) = $0 { return hidden > 1 } else { return false } })
    #expect(!rows.contains(.row(6)))     // a row of the folded output
    #expect(rows.contains(.row(13)))     // the prompt after it is untouched
}

@Test func unfoldingPutsEverythingBack() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(promptRow: 2)
    folding.unfold(promptRow: 2)
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

@Test func togglingSwitchesBothWays() {
    var folding = OutputFolding()
    folding.toggle(promptRow: 2)
    #expect(folding.isFolded(promptRow: 2))
    folding.toggle(promptRow: 2)
    #expect(!folding.isFolded(promptRow: 2))
}

/// Folding a command that produced nothing would replace nothing with a placeholder saying nothing
/// was hidden -- worse than leaving it alone.
@Test func foldingACommandWithNoOutputChangesNothing() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(promptRow: 13)          // the prompt being typed at
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

@Test func aFoldOnARowThatIsNotAPromptIsIgnored() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(promptRow: 5)           // a row of output, not a prompt
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

/// "Tidy up": collapse everything long in one action, since by then most of the screen is output
/// that has already been read.
@Test func longOutputsCanBeFoldedInOneAction() {
    let t = session()
    var folding = OutputFolding()
    folding.foldLongOutput(in: t, longerThan: 3)
    #expect(folding.isFolded(promptRow: 2))      // ten rows of output
    #expect(!folding.isFolded(promptRow: 0))     // one row
}

/// Folds are keyed by absolute row, so a long session would accumulate them for rows that have
/// scrolled out of the buffer entirely.
@Test func foldsForRowsThatScrolledAwayArePruned() {
    var folding = OutputFolding()
    folding.fold(promptRow: 2)
    folding.fold(promptRow: 900)
    folding.prune(below: 100)
    #expect(!folding.isFolded(promptRow: 2))
    #expect(folding.isFolded(promptRow: 900))
}

@Test func theFoldedRowCountIsWhatTheViewportShouldMeasure() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(promptRow: 2)
    let folded = t.displayRowCount(in: 0..<14, folding: folding)
    let unfolded = t.displayRowCount(in: 0..<14, folding: OutputFolding())
    #expect(folded < 14)
    #expect(unfolded == 14)
}
