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

/// Past the end of the lens the viewport carries on with what follows the block, rather than
/// showing nothing.
@Test func aViewportPastTheEndOfAShortLensIsOrdinary() {
    let rows = session().displayRows(from: 11, count: 3, folding: OutputFolding(),
                                     lenses: lensed(2), buffers: buffers(2, lines: 2))
    #expect(rows == [.row(13), .row(14), .row(15)])
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

// MARK: - Scrolling out

@Test func snapOutOfLens() {
    let t = session()
    _ = t.scrollToAbsoluteRow(6, margin: 0)
    #expect(t.snapViewportOutOfFold(movingUp: true, folding: OutputFolding(), lenses: lensed(2),
                                    buffers: buffers(2, lines: 3)))
    #expect(t.viewportTopRow == 2)

    _ = t.scrollToAbsoluteRow(6, margin: 0)
    #expect(t.snapViewportOutOfFold(movingUp: false, folding: OutputFolding(), lenses: lensed(2),
                                    buffers: buffers(2, lines: 3)))
    #expect(t.viewportTopRow == 13)
}

@Test func aViewportNotInsideALensDoesNotMove() {
    let t = session()
    _ = t.scrollToAbsoluteRow(14, margin: 0)
    #expect(!t.snapViewportOutOfFold(movingUp: false, folding: OutputFolding(), lenses: lensed(2),
                                     buffers: buffers(2, lines: 3)))
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

/// A viewport that starts on a *wrapped command line* -- between the prompt and the output --
/// shows the raw rows rather than the lens, because the mapping only replaces output when it walks
/// past the block's own prompt row. The fold path has the same hole and has always had it. Written
/// down here rather than discovered later; the scroll snapping keeps a viewport off that row.
@Test func aViewportOnAWrappedCommandLineShowsRaw() {
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

    // From the continuation row: raw, and the lens is not applied at all.
    let fromWrap = t.displayRows(from: 1, count: 3, folding: OutputFolding(), lenses: lensed(1),
                                 buffers: buffers(1, lines: 2))
    #expect(fromWrap == [.row(1), .row(2), .row(3)])
}
