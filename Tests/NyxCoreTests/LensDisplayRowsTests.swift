import Foundation
import Testing
@testable import NyxCore

/// The same ground `OutputFoldingViewportTests` covers, with a lens in place of a fold: a fixed
/// number of rows to draw, something to draw for the replaced ones, somewhere for a highlight to
/// land afterwards, and a way out of a region you scrolled into.

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// Three commands, the middle one with ten rows of output. `build` is command id 2 with output on
/// rows 3...12; `tail` is id 3 with output on 14...21.
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

private func lensed(_ id: UInt32, _ lens: ResponseLens = .pretty) -> LensChoices {
    var choices = LensChoices()
    choices.set(lens, for: id)
    return choices
}

private func buffers(_ id: UInt32, lines: Int) -> (UInt32) -> LensBuffer? {
    let buffer = LensBuffer(commandID: id, lens: .pretty,
                            lines: (0..<lines).map { LensLine("lens line \($0)") },
                            contentVersion: 0)
    return { $0 == id ? buffer : nil }
}

// MARK: - The mapping

/// Ten rows of output, three lines of lens: the block's prompt stays, the output is gone, and the
/// next command follows immediately.
@Test func lensReplacesOutputRows() {
    let rows = session().displayRows(from: 0, count: 8, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 3))
    #expect(rows == [.row(0), .row(1), .row(2),
                     .lens(commandID: 2, line: 0),
                     .lens(commandID: 2, line: 1),
                     .lens(commandID: 2, line: 2),
                     .row(13), .row(14)])
}

/// The other direction: two rows of output shown as ten lines. A lens is not bound to the size of
/// what it replaces.
@Test func lensLongerThanOutput() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "curl x\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\nsentinel\r\n")
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "next\r\n" + mark("C") + "done\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let rows = t.displayRows(from: 0, count: 13, folding: OutputFolding(),
                             lenses: lensed(1), buffers: buffers(1, lines: 10))
    #expect(rows.prefix(11) == [.row(0)] + (0..<10).map { .lens(commandID: 1, line: $0) })
    #expect(rows[11] == .row(3))
    #expect(rows.count == 13)
}

/// A folded block shows the fold, not the lens. Both are "show me less"; the fold is the one the
/// user asked for most recently and the one whose placeholder they can click.
@Test func foldWinsOverLens() {
    var folding = OutputFolding()
    folding.fold(2, .all)
    let rows = session().displayRows(from: 0, count: 6, folding: folding,
                                     lenses: lensed(2), buffers: buffers(2, lines: 3))
    #expect(rows[3] == .fold(commandID: 2, hiddenRows: 10, status: .failed))
    #expect(rows[4] == .row(13))
}

/// Scrolled into the middle of a lensed block, the viewport shows the lens from the line the
/// absolute row corresponds to -- lens lines stand in for output rows one for one where the
/// viewport is concerned. See the note on `displayRows`: past the end of a shorter lens the offset
/// clamps, which is why a long lens scrolls faster than the rows it replaced.
@Test func viewportStartingInsideALens() {
    let rows = session().displayRows(from: 5, count: 4, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 6))
    #expect(rows == [.lens(commandID: 2, line: 2),
                     .lens(commandID: 2, line: 3),
                     .lens(commandID: 2, line: 4),
                     .lens(commandID: 2, line: 5)])
}

/// An absolute row past the end of a shorter lens clamps to the lens's last line and then carries
/// on with what follows the block. It used to show nothing of the block at all and jump straight to
/// the next one, which is how a search match inside a lensed response scrolled somewhere the match
/// was not.
@Test func aViewportPastTheEndOfAShortLensClampsToItsLastLine() {
    let rows = session().displayRows(from: 11, count: 3, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 2))
    #expect(rows == [.lens(commandID: 2, line: 1), .row(13), .row(14)])
}

@Test func aViewportStartingAfterALensedBlockIsOrdinary() {
    let rows = session().displayRows(from: 13, count: 3, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 3))
    #expect(rows == [.row(13), .row(14), .row(15)])
}

@Test func theViewportIsAlwaysFilledPastALens() {
    let rows = session().displayRows(from: 0, count: 6, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 1))
    #expect(rows.count == 6)
}

/// A lens chosen before its buffer exists shows the raw rows: the pane renders the response it
/// already has while the lines are built.
@Test func noBufferShowsRaw() {
    let rows = session().displayRows(from: 0, count: 6, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: { _ in nil })
    #expect(rows == (0..<6).map { .row($0) })
}

/// A lens on a command that has printed nothing has nothing to replace.
@Test func aLensOnACommandWithNoOutputIsIgnored() {
    let t = makeTerminal(cols: 40, rows: 4, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "sleep 10\r\n")
    let rows = t.displayRows(from: 0, count: 3, folding: OutputFolding(),
                             lenses: lensed(1), buffers: buffers(1, lines: 3))
    #expect(rows == [.row(0), .row(1), .row(2)])
}

/// The no-lens path is the path every ordinary frame takes, and it must be the same rows it was
/// before this feature existed -- with folds on screen and without.
@Test func unchangedWhenChoicesEmpty() {
    let t = session()
    #expect(t.displayRows(from: 0, count: 6, folding: OutputFolding(), lenses: LensChoices())
            == t.displayRows(from: 0, count: 6, folding: OutputFolding()))
    var folding = OutputFolding()
    folding.fold(2, .tail(keep: 3))
    #expect(t.displayRows(from: 0, count: 8, folding: folding, lenses: LensChoices())
            == t.displayRows(from: 0, count: 8, folding: folding))
    // And a lens whose buffer is missing changes nothing either.
    #expect(t.displayRows(from: 0, count: 8, folding: folding, lenses: lensed(2),
                          buffers: { _ in nil })
            == t.displayRows(from: 0, count: 8, folding: folding))
}

// MARK: - Where things land afterwards

@Test func indexByAbsoluteRowSkipsLens() {
    let display = session().displayRows(from: 0, count: 8, folding: OutputFolding(),
                                        lenses: lensed(2), buffers: buffers(2, lines: 3))
    let map = DisplayRows.indexByAbsoluteRow(display)
    #expect(map[2] == 2)
    #expect(map[5] == nil)            // replaced by the lens
    #expect(map[13] == 6)
}

@Test func cursorSlotOnLensedRegionIsNil() {
    let display = session().displayRows(from: 0, count: 8, folding: OutputFolding(),
                                        lenses: lensed(2), buffers: buffers(2, lines: 3))
    #expect(DisplayRows.cursorSlot(absoluteRow: 5, in: display) == nil)
    #expect(DisplayRows.cursorSlot(absoluteRow: 13, in: display) == 6)
}

@Test func searchHitsInsideALensAreNotDrawn() {
    let display = session().displayRows(from: 0, count: 8, folding: OutputFolding(),
                                        lenses: lensed(2), buffers: buffers(2, lines: 3))
    let matches = [SearchMatch(row: 5, columns: 0..<3), SearchMatch(row: 13, columns: 0..<4)]
    let ranges = SearchHighlights.visibleRanges(matches, displayRows: display, cols: 40)
    #expect(ranges[3].isEmpty)
    #expect(ranges[4].isEmpty)
    #expect(ranges[6] == [0..<4])
}

/// The lens lines belong to their block, the way a fold placeholder does: hovering or spining the
/// block has to cover them.
@Test func slotsCoverTheLensLines() {
    let display = session().displayRows(from: 0, count: 8, folding: OutputFolding(),
                                        lenses: lensed(2), buffers: buffers(2, lines: 3))
    #expect(DisplayRows.slots(coveredBy: 2..<13, commandID: 2, in: display, viewportTop: 0)
            == 2..<6)
    // Another block's lens lines are not part of this one.
    #expect(DisplayRows.slots(coveredBy: 13..<22, commandID: 3, in: display, viewportTop: 0)
            == 6..<8)
}

@Test func lensedCommandCoversOutputRowsOnly() {
    let t = session()
    let choices = lensed(2)
    let get = buffers(2, lines: 3)
    #expect(t.lensedCommand(containingOutputRow: 2, lenses: choices, buffers: get) == nil)
    #expect(t.lensedCommand(containingOutputRow: 5, lenses: choices, buffers: get)?.region.id == 2)
    #expect(t.lensedCommand(containingOutputRow: 5, lenses: choices, buffers: get)?.buffer.lineCount == 3)
    #expect(t.lensedCommand(containingOutputRow: 13, lenses: choices, buffers: get) == nil)
    #expect(t.lensedCommand(containingOutputRow: 5, lenses: LensChoices(), buffers: get) == nil)
}

/// A buffer with no lines is not a lens: it would take the block's output off the screen and put
/// nothing in its place, which reads as a command that printed nothing. The raw rows stand until
/// there is something to show instead.
@Test func anEmptyBufferShowsRaw() {
    let t = session()
    let empty = LensBuffer(commandID: 2, lens: .pretty, lines: [], contentVersion: 0)
    let rows = t.displayRows(from: 0, count: 6, folding: OutputFolding(), lenses: lensed(2),
                             buffers: { $0 == 2 ? empty : nil })
    #expect(rows == (0..<6).map { .row($0) })
    #expect(t.lensedCommand(containingOutputRow: 5, lenses: lensed(2),
                            buffers: { $0 == 2 ? empty : nil }) == nil)
}

/// A viewport that starts on a *wrapped command line* -- between the prompt and the output -- used
/// to show the whole block raw, because the mapping only replaced output where it walked past the
/// block's own prompt row. The cursor walk asks the same question of every row, so entering a block
/// one row below its prompt applies the lens exactly as entering it at the prompt does.
@Test func aViewportOnAWrappedCommandLineStillShowsTheLens() {
    let t = makeTerminal(cols: 10, rows: 6, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "curl a-long-url\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\nsecond\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)
    #expect(region?.promptRow == 0)
    #expect(region?.outputRows.lowerBound == 2, "the command line wrapped onto row 1")

    // From the prompt: the command line stays and the output becomes the lens.
    let fromTop = t.displayRows(from: 0, count: 5, folding: OutputFolding(), lenses: lensed(1),
                                buffers: buffers(1, lines: 2))
    #expect(fromTop.prefix(4) == [.row(0), .row(1),
                                  .lens(commandID: 1, line: 0), .lens(commandID: 1, line: 1)])

    // From the continuation row: the row itself, then the lens.
    let fromWrap = t.displayRows(from: 1, count: 3, folding: OutputFolding(), lenses: lensed(1),
                                 buffers: buffers(1, lines: 2))
    #expect(fromWrap == [.row(1), .lens(commandID: 1, line: 0), .lens(commandID: 1, line: 1)])
}

// MARK: - Scrolling a lens, line by line

/// The defect this whole type exists for. A twenty-user JSON response is fourteen rows of
/// transcript and a hundred and twenty-six lines pretty-printed; addressed by absolute row, the only
/// lines a reader could reach were the first `outputRows.count + viewportRows` of them, and from
/// user nine onwards the response did not exist. Every line is reachable now, by advancing.
@Test func everyLineOfALongLensIsReachable() {
    let t = makeTerminal(cols: 100, rows: 40, scrollback: 500)
    t.feed(mark("A") + "$ " + mark("B") + "curl -s https://api.test/users\r\n" + mark("C"))
    for i in 1...14 { t.feed("transcript row \(i)\r\n") }
    t.feed(mark("D", 0) + mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)
    #expect(region?.outputRows.count == 14)
    let id = region?.id ?? 0

    let choices = lensed(id)
    let get = buffers(id, lines: 126)
    // Scroll from the top, a wheel click at a time, and collect every lens line that was ever on
    // screen. Before `DisplayCursor` this reached 53 of 126.
    var cursor = DisplayCursor(row: 0)
    var seen: Set<Int> = []
    for _ in 0..<200 {
        for entry in t.displayRows(from: cursor, count: 40, folding: OutputFolding(),
                                   lenses: choices, buffers: get) {
            if case .lens(_, let line) = entry { seen.insert(line) }
        }
        cursor = t.advance(cursor, by: 3, folding: OutputFolding(), lenses: choices, buffers: get)
    }
    #expect(seen.count == 126, "saw \(seen.count) of 126 lens lines")
}

/// And backwards: from below the block, every line again, ending on the command row above it.
@Test func advancingBackThroughALensReachesThePromptRow() {
    let t = session()                                   // block 2, output rows 3...12
    let choices = lensed(2)
    let get = buffers(2, lines: 30)
    var cursor = DisplayCursor(row: 13)                 // the next command's prompt
    var lines: [Int] = []
    for _ in 0..<31 {
        cursor = t.advance(cursor, by: -1, folding: OutputFolding(), lenses: choices, buffers: get)
        if case .lens(_, let line)? = t.displayEntry(at: cursor, folding: OutputFolding(),
                                                     lenses: choices, buffers: get)?.row {
            lines.append(line)
        }
    }
    #expect(lines == Array((0..<30).reversed()))
    #expect(cursor == DisplayCursor(row: 2), "one more step lands on the block's own command row")
}

/// A lens *shorter* than the rows it replaces does not skip what follows: stepping off its last
/// line lands on the row after the block, not somewhere past the next one.
@Test func aShortLensDoesNotJumpPastTheNextBlock() {
    let t = session()
    let choices = lensed(2)
    let get = buffers(2, lines: 2)
    var cursor = DisplayCursor(row: 2)                  // the block's command row
    var rows: [DisplayRow] = []
    for _ in 0..<5 {
        if let entry = t.displayEntry(at: cursor, folding: OutputFolding(), lenses: choices,
                                      buffers: get) {
            rows.append(entry.row)
        }
        cursor = t.advance(cursor, by: 1, folding: OutputFolding(), lenses: choices, buffers: get)
    }
    #expect(rows == [.row(2), .lens(commandID: 2, line: 0), .lens(commandID: 2, line: 1),
                     .row(13), .row(14)])
}

/// Stepping forwards stops at the newest row the viewport can be set to, so the cursor is always one
/// the terminal can actually be scrolled to.
@Test func advancingForwardStopsAtTheLiveScreen() {
    let t = session()
    let cursor = t.advance(DisplayCursor(row: 0), by: 10_000, folding: OutputFolding(),
                           lenses: lensed(2), buffers: buffers(2, lines: 30))
    #expect(cursor.row == t.scrollback.count)
    #expect(cursor.line == 0)
}

/// A cursor whose line is past the end of a rebuilt, shorter buffer is clamped rather than trusted.
@Test func aCursorPastAShrunkenBufferIsClamped() {
    let t = session()
    let cursor = t.canonicalised(DisplayCursor(row: 3, line: 99), folding: OutputFolding(),
                                 lenses: lensed(2), buffers: buffers(2, lines: 4))
    #expect(cursor == DisplayCursor(row: 3, line: 3))
}

/// Without a lens or a fold the cursor is the row, and advancing is the row arithmetic it always
/// was -- the path every ordinary frame takes must not have changed.
@Test func advancingWithNoLensIsRowArithmetic() {
    let t = session()
    #expect(t.advance(DisplayCursor(row: 5), by: 4, folding: OutputFolding()) == DisplayCursor(row: 9))
    #expect(t.advance(DisplayCursor(row: 5), by: -4, folding: OutputFolding()) == DisplayCursor(row: 1))
}
