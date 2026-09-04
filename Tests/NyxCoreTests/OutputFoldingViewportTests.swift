import Testing
@testable import NyxCore

/// Everything the *viewport* needs from folding, as opposed to what `OutputFolding` decides on its
/// own: a fixed number of rows to draw, a placeholder to draw for the hidden ones, somewhere for a
/// highlight to land afterwards, and a way out of a fold you scrolled into.

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// Three commands, the middle one with ten rows of output and enough after it that the viewport
/// can actually get past the fold:
///
///     0  $ echo one
///     1  one
///     2  $ build
///     3..12  ten rows of output
///     13 $ tail
///     14..21 eight rows of output
///     22 $ (typing here)
private func session() -> Terminal {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "echo one\r\n" + mark("C") + "one\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...10 { t.feed("output line \(i)\r\n") }
    t.feed(mark("D", 1))
    t.feed(mark("A") + "$ " + mark("B") + "tail\r\n" + mark("C"))
    for i in 1...8 { t.feed("tail line \(i)\r\n") }
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ ")
    return t
}

private func folded(_ rows: Int...) -> OutputFolding {
    var folding = OutputFolding()
    for row in rows { folding.fold(promptRow: row) }
    return folding
}

// MARK: - Filling a screen

/// The plain path, which is what every frame of every ordinary session takes: absolute rows, no
/// buffer walk, and exactly as many of them as the screen has.
@Test func anUnfoldedViewportIsAPlainRunOfRows() {
    let t = session()
    #expect(t.displayRows(from: 4, count: 6, folding: OutputFolding()) == (4..<10).map { .row($0) })
}

/// The reason this exists at all: collapsing a range gives back fewer rows than were asked about,
/// and a viewport that came up short would leave the bottom of the screen blank.
@Test func aFoldedViewportStillFillsTheScreen() {
    let t = session()
    let rows = t.displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows.count == 6)
}

@Test func theFoldStandsWhereTheOutputWas() {
    let t = session()
    let rows = t.displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows[0] == .row(0))
    #expect(rows[1] == .row(1))
    #expect(rows[2] == .row(2))                      // the command itself stays
    #expect(rows[3] == .fold(promptRow: 2, hiddenRows: 10))
    #expect(rows[4] == .row(13))                     // straight past the output
    #expect(rows[5] == .row(14))
}

/// Scrolling into the middle of a fold has to show the placeholder rather than the rows it stands
/// for -- those rows are exactly what was hidden.
@Test func aViewportStartingInsideAFoldStartsOnItsPlaceholder() {
    let t = session()
    let rows = t.displayRows(from: 7, count: 4, folding: folded(2))
    #expect(rows.first == .fold(promptRow: 2, hiddenRows: 10))
    #expect(rows[1] == .row(13))
}

@Test func aViewportPastTheEndOfTheBufferSimplyRunsOut() {
    let t = session()
    let rows = t.displayRows(from: 20, count: 6, folding: folded(2))
    #expect(rows.count < 6)
    #expect(!rows.contains { if case .row(let r) = $0 { return r >= t.totalRows } else { return false } })
}

@Test func askingForNoRowsGivesNone() {
    let t = session()
    #expect(t.displayRows(from: 0, count: 0, folding: folded(2)).isEmpty)
}

// MARK: - The placeholder

@Test func thePlaceholderNamesHowMuchIsHidden() {
    #expect(OutputFolding.placeholder(hiddenRows: 2431) == "\u{2026} 2,431 lines hidden")
}

@Test func onehiddenRowIsALineNotLines() {
    #expect(OutputFolding.placeholder(hiddenRows: 1) == "\u{2026} 1 line hidden")
}

/// Grouping is done by hand rather than by `NumberFormatter`: a row count is not a currency, and a
/// locale-dependent placeholder would make the test depend on the machine it ran on.
@Test func thousandsAreGroupedWithoutAskingTheLocale() {
    #expect(OutputFolding.grouped(0) == "0")
    #expect(OutputFolding.grouped(999) == "999")
    #expect(OutputFolding.grouped(1000) == "1,000")
    #expect(OutputFolding.grouped(1234567) == "1,234,567")
}

@Test func thePlaceholderRowIsARowOfCellsLikeAnyOther() {
    let t = session()
    let row = t.foldPlaceholderRow(hiddenRows: 10)
    #expect(row.cells.count == t.cols)
    var text = ""
    for cell in row.cells where cell.content != 0 { text.unicodeScalars.append(Unicode.Scalar(cell.content)!) }
    #expect(text == OutputFolding.placeholder(hiddenRows: 10))
    #expect(row.cells[0].attrs.contains(.dim))
}

/// A narrow pane must not write off the end of the row.
@Test func thePlaceholderIsCutToTheTerminalWidth() {
    let t = makeTerminal(cols: 8, rows: 3)
    let row = t.foldPlaceholderRow(hiddenRows: 123456)
    #expect(row.cells.count == 8)
}

// MARK: - Where a highlight lands

@Test func aHighlightOnAVisibleRowFollowsTheFoldsAboveIt() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let ranges = SearchHighlights.visibleRange(onAbsoluteRow: 13, columns: 0..<3,
                                               displayRows: display, cols: 40)
    #expect(ranges[4] == 0..<3)
    #expect(ranges[0] == nil)
}

/// The bug this prevents: a hit on folded text painted onto whatever row the fold pulled into its
/// slot, which is a highlight over text nobody searched for.
@Test func aHighlightOnFoldedTextIsDrawnNowhere() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let ranges = SearchHighlights.visibleRange(onAbsoluteRow: 6, columns: 0..<3,
                                               displayRows: display, cols: 40)
    #expect(ranges.allSatisfy { $0 == nil })
}

@Test func severalMatchesArePlacedThroughTheSameMap() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let matches = [SearchMatch(row: 0, columns: 0..<2), SearchMatch(row: 6, columns: 0..<2),
                   SearchMatch(row: 13, columns: 1..<4)]
    let ranges = SearchHighlights.visibleRanges(matches, displayRows: display, cols: 40)
    #expect(ranges[0] == [0..<2])
    #expect(ranges[3].isEmpty)          // the fold placeholder
    #expect(ranges[4] == [1..<4])
}

@Test func aMatchRunningOffTheRightEdgeIsClippedNotDropped() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let ranges = SearchHighlights.visibleRanges([SearchMatch(row: 0, columns: 38..<48)],
                                                displayRows: display, cols: 40)
    #expect(ranges[0] == [38..<40])
}

// MARK: - Getting out of a fold you scrolled into

/// Without this, scrolling into a fold of two thousand rows means two thousand more wheel clicks:
/// every row it covers is hidden, so the screen does not change however far the top moves.
@Test func scrollingDownStepsOverAFoldRatherThanThroughIt() {
    let t = session()
    _ = t.scrollToAbsoluteRow(7, margin: 0)
    #expect(t.viewportTopRow == 7)
    let moved = t.snapViewportOutOfFold(movingUp: false, folding: folded(2))
    #expect(moved)
    #expect(t.viewportTopRow == 13)
}

@Test func scrollingUpLandsOnTheCommandThatProducedTheOutput() {
    let t = session()
    _ = t.scrollToAbsoluteRow(7, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: true, folding: folded(2))
    #expect(moved)
    #expect(t.viewportTopRow == 2)
}

@Test func aViewportOutsideEveryFoldIsLeftAlone() {
    let t = session()
    _ = t.scrollToAbsoluteRow(0, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: false, folding: folded(2))
    #expect(!moved)
    #expect(t.viewportTopRow == 0)
}

@Test func nothingFoldedMeansNothingToSnapOutOf() {
    let t = session()
    _ = t.scrollToAbsoluteRow(7, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: false, folding: OutputFolding())
    #expect(!moved)
}

/// A prompt row is never inside its own fold: folding hides what a command printed, not the
/// command -- so the strip, the gutter and a click on the prompt all keep working.
@Test func aPromptRowIsNotInsideItsOwnFold() {
    let t = session()
    #expect(t.foldedCommand(containingOutputRow: 2, folding: folded(2)) == nil)
    #expect(t.foldedCommand(containingOutputRow: 5, folding: folded(2))?.promptRow == 2)
}

// MARK: - Folds that stop meaning anything

/// A fold is an absolute row index, and once the scrollback ring is full every eviction shifts them
/// all down by one. A fold whose row is no longer a prompt row is a fold on somebody else's text.
@Test func aFoldWhoseRowIsNoLongerAPromptIsDropped() {
    let t = session()
    var folding = folded(2, 5)
    folding.prune(in: t)
    #expect(folding.isFolded(promptRow: 2))
    #expect(!folding.isFolded(promptRow: 5))
}

@Test func pruningAnEmptySetIsHarmless() {
    let t = session()
    var folding = OutputFolding()
    folding.prune(in: t)
    #expect(folding.isEmpty)
}

/// A shell with no integration has no commands, so it can have no folds -- and asking must not
/// walk the buffer to find that out.
@Test func aShellWithNoMarksHasNothingToFold() {
    let t = makeTerminal(cols: 20, rows: 4)
    t.feed("hello\r\nthere\r\n")
    #expect(t.foldedCommand(containingOutputRow: 1, folding: folded(0)) == nil)
}
