import Testing
@testable import NyxCore

/// Everything the *viewport* needs from folding, as opposed to what `OutputFolding` decides on its
/// own: a fixed number of rows to draw, a placeholder to draw for the hidden ones, somewhere for a
/// highlight to land afterwards, and a way out of a fold you scrolled into.

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// Three commands, the middle one with ten rows of output and enough after it that the viewport
/// can actually get past the fold. `build` is command id 2, `tail` is command id 3.
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

private func folded(_ ids: UInt32..., shape: FoldShape = .all) -> OutputFolding {
    var folding = OutputFolding()
    for id in ids { folding.fold(id, shape) }
    return folding
}

@Test func nothingFoldedIsThePlainRange() {
    let rows = session().displayRows(from: 0, count: 6, folding: OutputFolding())
    #expect(rows == (0..<6).map { .row($0) })
}

@Test func aFullFoldReplacesTheOutputWithOnePlaceholder() {
    let rows = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows[2] == .row(2))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 10, status: .failed))
    #expect(rows[4] == .row(13))
}

@Test func aTailFoldKeepsTheLastLinesAfterThePlaceholder() {
    let rows = session().displayRows(from: 0, count: 8, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows[2] == .row(2))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 7, status: .failed))
    #expect(rows[4] == .row(10))
    #expect(rows[5] == .row(11))
    #expect(rows[6] == .row(12))
    #expect(rows[7] == .row(13))
}

@Test func aViewportStartingInsideHiddenRowsStartsOnThePlaceholder() {
    let t = session()
    let rows = t.displayRows(from: 5, count: 4, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows.first == .fold(commandID: 2, hiddenRows: 7, status: .failed))
    #expect(rows[1] == .row(10))
}

@Test func aViewportStartingInTheKeptTailIsOrdinary() {
    let rows = session().displayRows(from: 11, count: 3, folding: folded(2, shape: .tail(keep: 3)))
    #expect(rows == [.row(11), .row(12), .row(13)])
}

@Test func theViewportIsAlwaysFilledPastAFold() {
    let rows = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows.count == 6)
}

/// Not dim: dimmed bright black reads as a comment the shell printed, and the placeholder is the
/// button that puts the output back. It keeps the italic and takes the block's own status colour --
/// the same three the spine uses, so a folded running build is amber on both.
@Test func thePlaceholderRowIsItalicInTheBlocksStatusColour() {
    let t = session()
    let row = t.foldPlaceholderRow(hiddenRows: 10, status: .succeeded)
    let text = String(row.cells.prefix(30).map { $0.content == 0 ? " " : Character(UnicodeScalar($0.content)!) })
        .trimmingCharacters(in: .whitespaces)
    #expect(text == OutputFolding.placeholder(hiddenRows: 10))
    #expect(row.cells[0].fg == .indexed(8))
    #expect(!row.cells[0].attrs.contains(.dim))
    #expect(row.cells[0].attrs.contains(.italic))

    let failed = t.foldPlaceholderRow(hiddenRows: 10, status: .failed)
    #expect(failed.cells[0].fg == .indexed(1))
    #expect(!failed.cells[0].attrs.contains(.dim))
    #expect(failed.cells[0].attrs.contains(.italic))

    let running = t.foldPlaceholderRow(hiddenRows: 10, status: .running)
    #expect(running.cells[0].fg == .indexed(3))     // the amber the spine uses for the same state
    #expect(running.cells[0].attrs.contains(.italic))
}

/// A fold placeholder carries its command's status, so the pane can colour the row without
/// re-deriving the region on the render path.
@Test func aPlaceholderKnowsHowItsCommandEnded() {
    let rows = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 10, status: .failed))
    let ok = session().displayRows(from: 13, count: 3, folding: folded(3))
    #expect(ok[1] == .fold(commandID: 3, hiddenRows: 8, status: .succeeded))
}

/// A running command may be folded -- its tail is a live `tail -f` -- and the placeholder says so
/// in the same amber as its spine.
@Test func aFoldedRunningCommandsPlaceholderSaysItIsRunning() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...8 { t.feed("out \(i)\r\n") }
    let id = t.command(containingAbsoluteRow: 0)!.id
    var folding = OutputFolding()
    folding.fold(id, .all)
    let rows = t.displayRows(from: 0, count: 4, folding: folding)
    // Nine, not eight: a running command's region reaches the end of the buffer, so the row the
    // cursor is waiting on is hidden with the rest -- which is what makes a folded build a live tail.
    #expect(rows[1] == .fold(commandID: id, hiddenRows: 9, status: .running))
}

// MARK: - Where the cursor goes when a fold is on screen

// The cursor and the IME preedit are positioned by screen row while every line in the frame is a
// display slot. With a fold on screen those are different numbers, and the caret was drawn as far
// below the prompt as the fold had hidden rows above it.

@Test func theCursorLandsOnItsOwnRowWhenAFoldIsOnScreen() {
    let display = session().displayRows(from: 0, count: 6, folding: folded(2))
    // Row 13 is `$ tail`; ten hidden rows collapsed into one placeholder above it.
    #expect(DisplayRows.cursorSlot(absoluteRow: 13, in: display) == 4)
}

@Test func aCursorOnARowInsideAFoldIsNotDrawnAtAll() {
    let display = session().displayRows(from: 0, count: 6, folding: folded(2))
    #expect(DisplayRows.cursorSlot(absoluteRow: 5, in: display) == nil)
}

@Test func withoutFoldsTheCursorSlotIsTheOffsetFromTheViewportTop() {
    let display = session().displayRows(from: 10, count: 6, folding: OutputFolding())
    #expect(DisplayRows.cursorSlot(absoluteRow: 13, in: display) == 3)
}

@Test func searchHitsInsideAFoldAreNotDrawn() {
    let t = session()
    let display = t.displayRows(from: 0, count: 6, folding: folded(2))
    let matches = [SearchMatch(row: 5, columns: 0..<3), SearchMatch(row: 13, columns: 0..<4)]
    let ranges = SearchHighlights.visibleRanges(matches, displayRows: display, cols: 40)
    #expect(ranges[3].isEmpty)              // the placeholder slot
    #expect(ranges[4] == [0..<4])           // row 13 landed in slot 4
}

@Test func scrollingDownOutOfAFoldLandsPastTheHiddenRows() {
    let t = session()
    _ = t.scrollToAbsoluteRow(6, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: false, folding: folded(2, shape: .tail(keep: 3)))
    #expect(moved)
    #expect(t.viewportTopRow == 10)
}

@Test func scrollingUpOutOfAFoldLandsOnTheCommand() {
    let t = session()
    _ = t.scrollToAbsoluteRow(6, margin: 0)
    let moved = t.snapViewportOutOfFold(movingUp: true, folding: folded(2))
    #expect(moved)
    #expect(t.viewportTopRow == 2)
}

@Test func aViewportNotInsideAFoldDoesNotMove() {
    let t = session()
    _ = t.scrollToAbsoluteRow(11, margin: 0)
    #expect(!t.snapViewportOutOfFold(movingUp: false, folding: folded(2, shape: .tail(keep: 3))))
}

@Test func foldedCommandCoversHiddenRowsOnly() {
    let t = session()
    let f = folded(2, shape: .tail(keep: 3))
    #expect(t.foldedCommand(containingOutputRow: 2, folding: f) == nil)      // the prompt
    #expect(t.foldedCommand(containingOutputRow: 5, folding: f)?.region.id == 2)
    #expect(t.foldedCommand(containingOutputRow: 5, folding: f)?.hidden == 3..<10)
    #expect(t.foldedCommand(containingOutputRow: 11, folding: f) == nil)     // kept tail
}

@Test func foldLongOutputFoldsOnlyWhatIsLongerThanTheThreshold() {
    let t = session()
    var f = OutputFolding()
    f.foldLongOutput(in: t, longerThan: 9, keep: 3)
    #expect(f.isFolded(2))
    #expect(!f.isFolded(3))
}
