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

/// Addendum 1: block chrome steps aside for a full-screen program -- spines, summaries and the
/// gutter all do, and the pinned strip did not, so vim was drawn under a band naming the command
/// that started it (and, on the alternate screen, one whose exit status was gone).
@Test func nothingIsPinnedWhileAFullScreenProgramOwnsTheDisplay() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "swift build\r\n" + mark("C"))
    for line in 1...40 { t.feed("compiling \(line)\r\n") }
    t.feed(mark("D;0"))
    #expect(t.stickyPrompt() != nil)
    t.feed("\u{1B}[?1049h")            // vim takes the screen
    #expect(t.stickyPrompt() == nil)
    t.feed("\u{1B}[?1049l")
    #expect(t.stickyPrompt() != nil)
    // And while a TUI owns the mouse, for the same reason `CommandBlockChrome.isAllowed` says so.
    t.feed("\u{1B}[?1000h")
    #expect(t.stickyPrompt() == nil)
}

/// The band said "Running command" for a command that finished half an hour ago (a11y 7.1). It
/// says what it is and what pressing it does, and carries the same summary the strip shows.
@Test func thePinnedBandSaysWhatItIsAndWhatItDid() {
    #expect(StickyPromptLabel.accessibilityLabel(text: "$ swift build", summary: "exit 1 \u{b7} 8.8s")
        == "Pinned command: $ swift build \u{b7} exit 1 \u{b7} 8.8s. Scrolls back to it.")
    #expect(StickyPromptLabel.accessibilityLabel(text: "$ ls", summary: "")
        == "Pinned command: $ ls. Scrolls back to it.")
}

/// The band begins at the gutter's edge, which is not a column boundary: at the shipping
/// `padding = 8` a 20 pt gutter puts it two thirds of the way into column 1, and the pinned command
/// line was then drawn a fraction of a cell out of step with the output under it -- which reads as
/// a smeared duplicate rather than as a different surface (Task 2's review).
@Test func theBandsTextStartsOnAColumnBoundaryClearOfTheArrow() {
    // padding 8, cells 7.2 pt wide, band at the gutter's 20 pt edge: the first column at or past
    // the arrow (20 + 14 = 34 pt) starts at 8 + 4 * 7.2 = 36.8, which is 16.8 into the band.
    let inset = StickyPromptLabel.textInset(bandLeft: 20, padding: 8, cellWidth: 7.2, minimum: 14)
    #expect(abs(inset - 16.8) < 0.001)
    // A column boundary is a column boundary: the inset plus the band's own left edge is a whole
    // number of cells from the first column.
    #expect(abs((20 + inset - 8).remainder(dividingBy: 7.2)) < 0.001)
    // Never less than the arrow needs, whatever the geometry says.
    #expect(StickyPromptLabel.textInset(bandLeft: 20, padding: 20, cellWidth: 7.2, minimum: 14) >= 14)
    // A pane with no metrics yet (a view laid out before its font is measured) gets the minimum
    // rather than a division by zero.
    #expect(StickyPromptLabel.textInset(bandLeft: 20, padding: 8, cellWidth: 0, minimum: 14) == 14)
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
    folding.fold(2, .all)

    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows.contains(.row(2)))
    #expect(rows.contains { if case .fold(2, let hidden, _) = $0 { return hidden > 1 } else { return false } })
    #expect(!rows.contains(.row(6)))     // a row of the folded output
    #expect(rows.contains(.row(13)))     // the prompt after it is untouched
}

@Test func unfoldingPutsEverythingBack() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(2, .all)
    folding.unfold(2)
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

@Test func togglingSwitchesBothWays() {
    var folding = OutputFolding()
    folding.toggle(2, keep: 3)
    #expect(folding.isFolded(2))
    folding.toggle(2, keep: 3)
    #expect(!folding.isFolded(2))
}

/// Folding a command that produced nothing would replace nothing with a placeholder saying nothing
/// was hidden -- worse than leaving it alone.
@Test func foldingACommandWithNoOutputChangesNothing() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(3, .all)                // the prompt being typed at, id 3
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

/// Folds are keyed by command id, not by row -- an id with no matching command in the buffer folds
/// nothing, rather than landing on whatever text happens to sit at some coincidental row.
@Test func aFoldOnANonexistentCommandIsIgnored() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(99, .all)
    let rows = t.displayRows(in: 0..<14, folding: folding)
    #expect(rows == (0..<14).map { .row($0) })
}

/// "Tidy up": collapse everything long in one action, since by then most of the screen is output
/// that has already been read.
@Test func longOutputsCanBeFoldedInOneAction() {
    let t = session()
    var folding = OutputFolding()
    folding.foldLongOutput(in: t, longerThan: 3, keep: 3)
    #expect(folding.isFolded(2))      // ten rows of output
    #expect(!folding.isFolded(1))     // one row
}

/// Folds are keyed by command id rather than by row, so pruning against the oldest id still in the
/// buffer is what keeps the set from growing over a long session; `OutputFoldingTests` covers the
/// rule itself. What is left to check here is the plain viewport shape once a fold is in force.
@Test func aFullFoldMakesTheDisplayedRangeShorterThanTheRequestedOne() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(2, .all)
    let folded = t.displayRows(in: 0..<14, folding: folding)
    let unfolded = t.displayRows(in: 0..<14, folding: OutputFolding())
    #expect(folded.count < 14)
    #expect(unfolded.count == 14)
}

// MARK: - The strip's own text
//
// One row, as wide as the terminal, over a prompt string that is mostly padding. What survives the
// cut is decided here so it can be asserted rather than squinted at.

@Test func theStripShowsTheCommandWithItsWhitespaceCollapsed() {
    let text = StickyPromptLabel.text(command: "$    make    test", exitStatus: 0, columns: 40)
    #expect(text == "$ make test")
}

@Test func aFailedCommandCarriesItsStatusInTheTextAsWellAsTheColour() {
    let text = StickyPromptLabel.text(command: "$ make test", exitStatus: 2, columns: 40)
    #expect(text == "$ make test  exit 2")
}

/// A command still running has no status, and neither has a shell that reports `D` without one.
@Test func aRunningCommandGetsNoStatusSuffix() {
    #expect(StickyPromptLabel.text(command: "$ build", exitStatus: nil, columns: 40) == "$ build")
}

/// The status is why the user scrolled back; it survives a cut that the tail of the command line
/// does not.
@Test func alongCommandIsCutButItsStatusIsKept() {
    let long = "$ " + String(repeating: "x", count: 100)
    let text = StickyPromptLabel.text(command: long, exitStatus: 1, columns: 20)
    #expect(text.hasSuffix("  exit 1"))
    #expect(text.count == 20)
    #expect(text.contains("\u{2026}"))
}

@Test func aCommandThatFitsIsNotCut() {
    let text = StickyPromptLabel.text(command: "$ ls", exitStatus: 0, columns: 40)
    #expect(!text.contains("\u{2026}"))
}

@Test func aStripWithNoRoomAtAllIsEmptyRatherThanNegative() {
    #expect(StickyPromptLabel.text(command: "$ ls", exitStatus: 0, columns: 0) == "")
}

@Test func collapsingTrimsBothEnds() {
    #expect(StickyPromptLabel.collapsed("   a  b   ") == "a b")
    #expect(StickyPromptLabel.collapsed("") == "")
    #expect(StickyPromptLabel.collapsed("   ") == "")
}

// MARK: - The cheap "is this shell integrated at all" answer
//
// Asked once per frame by the strip and several times per keystroke by menu validation. It used to
// mean scanning every row of the buffer to find out that a shell without integration has no marks.

@Test func aShellWithNoIntegrationNeverClaimsPromptMarks() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed("hello\r\nthere\r\n")
    #expect(t.shellEmitsPromptMarks == false)
    #expect(t.stickyPrompt() == nil)
}

@Test func theFirstPromptMarkIsEnoughToSaySo() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed("\u{1b}]133;A\u{7}$ ")
    #expect(t.shellEmitsPromptMarks)
}

/// A `clear` wipes the rows, not the shell's habits: the very next prompt would set it again, and
/// flipping it back would only make the answer flap.
@Test func clearingTheScrollbackLeavesTheShellIntegrated() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed("\u{1b}]133;A\u{7}$ ")
    t.feed("\u{1b}[H\u{1b}[2J\u{1b}[3J")
    #expect(t.shellEmitsPromptMarks)
}

/// A full reset is a new terminal in every other respect, and this is no exception.
@Test func aFullResetForgetsThatTheShellWasIntegrated() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed("\u{1b}]133;A\u{7}$ ")
    t.feed("\u{1b}c")
    #expect(t.shellEmitsPromptMarks == false)
}

// MARK: - The strip over a request

/// A curl scrolled far enough that its command line is off screen, with a real transcript under it.
private func requestSession() -> Terminal {
    let t = makeTerminal(cols: 80, rows: 6, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "curl -sSi https://nyx.agentforge.cc/healthz\r\n" + mark("C"))
    for line in ["HTTP/2 200",
                 "content-type: application/json",
                 "content-length: 61",
                 "",
                 "{\"online\":0,\"pairings\":0,\"attachments\":0,\"dropped_binary\":0}",
                 "",
                 "--nyx-http-- 200 0.142 0.003208 0.049189 0.106052 0.140538 1229 0 application/json"] {
        t.feed(line + "\r\n")
    }
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ ")
    return t
}

/// The strip is the only thing on screen naming the command whose output fills the viewport, so
/// what it says about a request has to be what the block's own header says -- built from the same
/// `BlockHeader`, so the two cannot come apart.
@Test func stripShowsHTTPSummary() throws {
    let t = requestSession()
    let pinned = try #require(t.stickyPrompt(viewportTop: 4))
    let region = try #require(t.command(containingAbsoluteRow: pinned.row))
    #expect(CurlDetection.isCurl(t.commandLine(of: region)))

    let lines = t.outputText(of: region).components(separatedBy: "\n")
    let exchange = HTTPExchange.parse(lines: lines)
    let summary = HTTPSummary.make(exchange: exchange, exitStatus: region.exitStatus,
                                   duration: region.duration)
    let header = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
        .header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false,
                hasOutput: true, httpSummary: summary)

    #expect(header.summary == "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json")
    #expect(header.tone == .success)
    // The command line itself is still what the strip's left-hand side reads.
    #expect(StickyPromptLabel.text(command: t.commandText(of: region), exitStatus: pinned.exitStatus,
                                   columns: 80).hasPrefix("$ curl -sSi"))
}

/// The strip over an ordinary command keeps saying what it always said. Nothing about the request
/// workbench may cost a non-curl block its duration.
@Test func stripOverAnOrdinaryCommandIsUnchanged() throws {
    let t = session()
    let pinned = try #require(t.stickyPrompt(viewportTop: 8))
    let region = try #require(t.command(containingAbsoluteRow: pinned.row))
    #expect(!CurlDetection.isCurl(t.commandLine(of: region)))
    let header = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
        .header(now: 100, folding: OutputFolding(), notifyArmed: false, anyFolds: false, hasOutput: true)
    #expect(header.summary == "exit 1")
    #expect(header.tone == .failure)
}
