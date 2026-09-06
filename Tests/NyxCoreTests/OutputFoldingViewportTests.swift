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

/// Not the `.dim` *attribute*: dimmed bright black reads as a comment the shell printed, and the
/// placeholder is the button that puts the output back. It keeps the italic and takes the block's own status colour --
/// the same three the spine uses, so a folded running build is amber on both.
@Test func thePlaceholderRowIsItalicInTheBlocksStatusColour() {
    let t = session()
    let row = t.foldPlaceholderRow(hiddenRows: 10, status: .succeeded)
    let text = String(row.cells.prefix(30).map { $0.content == 0 ? " " : Character(UnicodeScalar($0.content)!) })
        .trimmingCharacters(in: .whitespaces)
    #expect(text == OutputFolding.placeholder(hiddenRows: 10))
    // The theme's dim, resolved, not `.indexed(8)` handed over raw: bright black on nyx-dark's
    // background is 1.91:1, and a placeholder nobody can read is a button nobody can find.
    #expect(row.cells[0].fg == LensPalette.forTheme(t.palette).dim)
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
    // Eight: the eight lines it printed. Its region stops at the last row it wrote, so neither the
    // blank row the cursor waits on nor the unwritten screen below is counted -- the placeholder
    // says what it hides.
    #expect(rows[1] == .fold(commandID: id, hiddenRows: 8, status: .running))
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

/// A fold is one display line whichever way you step over it, which is what `snapViewportOutOfFold`
/// used to arrange after the fact: a viewport top can no longer land inside the hidden rows because
/// nothing steps into them.
@Test func advancingDownStepsOverAFoldInOneLine() {
    let t = session()
    let f = folded(2, shape: .tail(keep: 3))
    // Row 2 is the block's prompt; one line down is the fold placeholder, one more is the first
    // kept row of the tail.
    let placeholder = t.advance(DisplayCursor(row: 2), by: 1, folding: f)
    #expect(placeholder == DisplayCursor(row: 3))
    #expect(t.advance(placeholder, by: 1, folding: f) == DisplayCursor(row: 10))
}

@Test func advancingUpStepsBackOverAFoldInOneLine() {
    let t = session()
    let f = folded(2, shape: .tail(keep: 3))
    #expect(t.advance(DisplayCursor(row: 10), by: -1, folding: f) == DisplayCursor(row: 3))
    #expect(t.advance(DisplayCursor(row: 10), by: -2, folding: f) == DisplayCursor(row: 2))
}

@Test func advancingStopsAtTheOldestRow() {
    let t = session()
    #expect(t.advance(DisplayCursor(row: 3), by: -50, folding: folded(2)) == DisplayCursor(row: 0))
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

// MARK: - A folded running command is a live tail, not a frozen screen

// `command(containingAbsoluteRow:)` used to end the last command at the end of the *buffer*, which
// for a running command is the whole unwritten screen below its cursor. `npm install` two lines in
// owned forty rows: folding it said "… 38 lines hidden" for two real lines, and every further line
// it printed landed inside the hidden range, so the screen stopped changing.

/// Two real lines printed, in a 44-row pane.
private func runningInATallPane() -> Terminal {
    let t = makeTerminal(cols: 40, rows: 44, scrollback: 1000)
    t.feed(mark("A") + "$ " + mark("B") + "echo done\r\n" + mark("C") + "done\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "npm install\r\n" + mark("C")
           + "added 2 packages\r\nauditing...\r\n")
    return t
}

@Test func aRunningCommandsRegionStopsAtTheLastRowItWrote() throws {
    let t = runningInATallPane()
    let region = try #require(t.command(containingAbsoluteRow: 2))
    #expect(region.isLastInBuffer)
    #expect(region.outputRows.count == 2)          // the two lines, not the forty-row screen
    #expect(region.endRow == 4)
}

@Test func foldingARunningCommandHidesOnlyWhatItPrinted() throws {
    let t = runningInATallPane()
    let region = try #require(t.command(containingAbsoluteRow: 2))
    var folding = OutputFolding()
    folding.fold(region.id, .tail(keep: 3))
    // Two output rows behind a one-row placeholder is not a tail worth keeping, so the small-output
    // rule makes it a full fold: both rows hidden.
    let rows = t.displayRows(from: 0, count: 44, folding: folding)
    #expect(rows[3] == .fold(commandID: region.id, hiddenRows: 2, status: .running))
    // And what follows the placeholder is the rest of the buffer, not the blank screen the fold
    // used to swallow.
    #expect(rows[4] == .row(5))
}

@Test func aFoldedRunningCommandKeepsGrowing() throws {
    let t = runningInATallPane()
    let region = try #require(t.command(containingAbsoluteRow: 2))
    var folding = OutputFolding()
    folding.fold(region.id, .tail(keep: 3))
    let before = t.displayRows(from: 0, count: 44, folding: folding)
    for i in 1...5 { t.feed("progress line \(i)\r\n") }
    let after = t.displayRows(from: 0, count: 44, folding: folding)
    #expect(before != after)

    let grown = try #require(t.command(containingAbsoluteRow: 2))
    #expect(grown.outputRows.count == 7)
    // A tail fold of seven rows keeping three hides four and shows the newest three.
    #expect(after[3] == .fold(commandID: region.id, hiddenRows: 4, status: .running))
    let tail = after[4...6].compactMap { entry -> String? in
        guard case .row(let absolute) = entry else { return nil }
        return t.rowText(absoluteRow: absolute).text.trimmingCharacters(in: .whitespaces)
    }
    #expect(tail == ["progress line 3", "progress line 4", "progress line 5"])
}

/// A finished command's region is unchanged: it still ends on the row before the next prompt.
@Test func aFinishedCommandsRegionStillEndsAtTheNextPrompt() throws {
    let t = runningInATallPane()
    let finished = try #require(t.command(containingAbsoluteRow: 0))
    #expect(!finished.isLastInBuffer)
    #expect(finished.endRow == 1)
    #expect(finished.outputRows == 1..<2)
}

/// ⌥-click on a running command's gutter mark selects what it printed, not the empty screen.
@Test func selectingARunningCommandsOutputStopsAtTheLastWrittenRow() throws {
    let t = runningInATallPane()
    let region = try #require(t.command(containingAbsoluteRow: 2))
    let selection = try #require(t.selectionForOutput(of: region))
    #expect(selection.start.row == 3)
    #expect(selection.end.row == 4)
    #expect(t.text(in: selection).contains("auditing..."))
    #expect(!t.text(in: selection).contains("\n\n\n"))
}

/// Every command on screen is one block. With the running command's region clamped, the rows below
/// its cursor map back to it, and a walk that stepped past `endRow` found it again on each of them.
@Test func aRunningCommandIsOneBlockNotOnePerBlankRow() {
    let t = runningInATallPane()
    let blocks = t.visibleBlocks(rows: 44)
    #expect(blocks.count == 2)
    #expect(blocks.map(\.region.promptRow) == [0, 2])
}

/// The fold placeholder and a lens' own fold placeholder are the same grey.
///
/// They are the same control in two places -- `▸ … 75 lines hidden` over a block's output and
/// `▸ […] 40 items` inside a pretty-printed body -- and two different greys on one screen reads as
/// two different kinds of thing. The lens' came down `LensPalette`'s ladder from the first;
/// the block's was `.indexed(8)` raw, which on nyx-dark is 1.91:1 against the background.
@Test func theFoldPlaceholderIsTheSameDimAsALensPlaceholder() {
    for (name, palette) in Themes.builtin {
        let t = Terminal(cols: 40, rows: 4, scrollbackLimit: 50, palette: palette)
        let colour = t.foldPlaceholderRow(hiddenRows: 10, status: .succeeded).cells[0].fg
        #expect(colour == LensPalette.forTheme(palette).dim, "\(name)")
        #expect(colour.kind == .rgb, "\(name)")
        #expect(RGB.contrast(RGB(colour.r, colour.g, colour.b), palette.background) >= 4.5, "\(name)")
    }
}
