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

// MARK: - Where "the bottom" is

/// With nothing replaced, the bottom is what `viewportOffset = 0` always meant, and it is reached
/// without walking anything.
@Test func theBottomWithoutALensIsTheTerminalsOwn() {
    let t = session()
    #expect(t.displayBottomCursor(folding: OutputFolding()) == DisplayCursor(row: t.scrollback.count))
}

/// A lens taller than the rows it replaces, on a block still on the live screen, puts more display
/// lines below the terminal's own bottom than the window has rows. The bottom is then the cursor
/// that keeps the *last* line -- the shell's prompt -- on the last row, not the terminal's top row.
@Test func theBottomKeepsThePromptOnScreenUnderATallLens() {
    let t = makeTerminal(cols: 40, rows: 10, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "curl x\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let region = t.command(containingAbsoluteRow: 0)
    let id = region?.id ?? 0
    let choices = lensed(id)
    let get = buffers(id, lines: 60)

    let plain = DisplayCursor(row: max(0, t.viewportTopRow))
    let fromPlain = t.displayRows(from: plain, count: 10, folding: OutputFolding(),
                                  lenses: choices, buffers: get)
    // From the terminal's own bottom the window fills with lens lines and runs out before the rows
    // that follow the block -- the shell's prompt among them.
    if case .lens = fromPlain[9] {} else { Issue.record("the window should still be inside the lens") }
    #expect(!fromPlain.contains(.row(t.totalRows - 1)))

    let bottom = t.displayBottomCursor(folding: OutputFolding(), lenses: choices, viewportRows: 10,
                                       buffers: get)
    #expect(bottom != plain)
    let fromBottom = t.displayRows(from: bottom, count: 10, folding: OutputFolding(),
                                   lenses: choices, buffers: get)
    #expect(fromBottom.count == 10)
    // The last display line is the last row of the buffer -- the row the shell is prompting on.
    #expect(fromBottom.last == .row(t.totalRows - 1))
    // And what is above it is the tail of the response, not its head.
    if case .lens(_, let line) = fromBottom[0] { #expect(line > 0) } else { Issue.record("not a lens") }
}

/// Scrolling forward from anywhere lands on exactly that cursor and goes no further, so "the bottom"
/// is one place however it is reached.
@Test func advancingToTheEndLandsOnTheDisplayBottom() {
    let t = makeTerminal(cols: 40, rows: 10, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "curl x\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let id = t.command(containingAbsoluteRow: 0)?.id ?? 0
    let choices = lensed(id)
    let get = buffers(id, lines: 60)
    let bottom = t.displayBottomCursor(folding: OutputFolding(), lenses: choices, viewportRows: 10,
                                       buffers: get)
    let walked = t.advance(DisplayCursor(row: 0), by: 500, folding: OutputFolding(),
                           lenses: choices, viewportRows: 10, buffers: get)
    #expect(walked == bottom)
}

// MARK: - Which cursor a viewport draws from

/// A window the session has never scrolled: `viewportTopRow` is 0 from the first keystroke to the
/// last, so an anchor stored while the command was being typed -- row 0, back when there were no
/// lenses -- still matches. Used, it draws from the prompt down and puts the shell's own prompt a
/// hundred display lines below the window; the caret is nowhere and typing has no echo. This is the
/// rule the pane follows once the anchor is forgotten.
@Test func aNeverScrolledSessionLandsWithThePromptOnScreen() {
    let t = makeTerminal(cols: 40, rows: 12, scrollback: 200)
    t.feed(mark("A") + "$ " + mark("B") + "curl x\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    #expect(t.viewportTopRow == 0, "nothing has scrolled")
    let id = t.command(containingAbsoluteRow: 0)?.id ?? 0
    let choices = lensed(id)
    let get = buffers(id, lines: 40)
    let promptRow = t.totalRows - 1

    // The anchor `send` left behind while the command was typed, before any lens existed.
    let stale = t.viewportCursor(anchor: DisplayCursor(row: 0), anchorTop: 0,
                                 anchorIsDisplayBottom: false,
                                 folding: OutputFolding(), lenses: choices, viewportRows: 12,
                                 buffers: get)
    let fromStale = t.displayRows(from: stale, count: 12, folding: OutputFolding(),
                                  lenses: choices, buffers: get)
    #expect(!fromStale.contains(.row(promptRow)), "the symptom: no prompt row, so no caret")

    // Forgotten, the rule takes the display's bottom instead.
    let fresh = t.viewportCursor(anchor: nil, anchorTop: -1, anchorIsDisplayBottom: false,
                                 folding: OutputFolding(),
                                 lenses: choices, viewportRows: 12, buffers: get)
    let fromFresh = t.displayRows(from: fresh, count: 12, folding: OutputFolding(),
                                  lenses: choices, buffers: get)
    #expect(fromFresh.contains(.row(promptRow)), "the prompt row is on screen")
    #expect(fromFresh.last == .row(promptRow))
}

/// A viewport scrolled up into the scrollback keeps its top: the bottom rule is for a reader pinned
/// to the live screen and must not drag anyone else down to it.
///
/// The top it keeps is the *display* cursor that row names, not the row: `build`'s output starts on
/// row 3, so a viewport whose top row is 4 is one line into the lens. Answering `DisplayCursor(row:
/// 4)` sent that reader back to line 0 of the response -- on every eviction, which is continuously
/// while anything else prints.
@Test func aScrolledBackViewportKeepsItsTop() {
    let t = session()
    _ = t.scrollToAbsoluteRow(4, margin: 0)
    let cursor = t.viewportCursor(anchor: nil, anchorTop: -1, anchorIsDisplayBottom: false,
                                  folding: OutputFolding(),
                                  lenses: lensed(2), viewportRows: 6,
                                  buffers: buffers(2, lines: 40))
    #expect(cursor == DisplayCursor(row: 3, line: 1))
    // Not the display bottom, which is what the live-screen branch would have answered.
    #expect(cursor != t.displayBottomCursor(folding: OutputFolding(), lenses: lensed(2),
                                            viewportRows: 6, buffers: buffers(2, lines: 40)))
}

/// The same rule outside a lens is the row itself, unchanged: an ordinary scrolled-back viewport
/// must not start costing a walk.
@Test func aScrolledBackViewportOutsideALensIsStillItsRow() {
    let t = session()
    _ = t.scrollToAbsoluteRow(15, margin: 0)
    #expect(t.viewportCursor(anchor: nil, anchorTop: -1, anchorIsDisplayBottom: false,
                             folding: OutputFolding(),
                             lenses: lensed(2), viewportRows: 6,
                             buffers: buffers(2, lines: 40)) == DisplayCursor(row: 15))
}

/// A fold under the same branch: the top row inside a fold is the fold's own first hidden row, so
/// the viewport starts on the placeholder rather than a row the display does not contain.
@Test func aScrolledBackViewportInsideAFoldStartsOnThePlaceholder() {
    let t = session()
    var folding = OutputFolding()
    folding.fold(2, .all)
    _ = t.scrollToAbsoluteRow(7, margin: 0)
    let cursor = t.viewportCursor(anchor: nil, anchorTop: -1, anchorIsDisplayBottom: false,
                                  folding: folding, lenses: LensChoices(), viewportRows: 6)
    #expect(cursor == DisplayCursor(row: 3))
}

/// And an anchor that still describes this viewport is what is used, clamped to what the buffer
/// holds now.
@Test func aLiveAnchorIsUsedAndClamped() {
    let t = session()
    let cursor = t.viewportCursor(anchor: DisplayCursor(row: 3, line: 99), anchorTop: t.viewportTopRow,
                                  anchorIsDisplayBottom: false,
                                  folding: OutputFolding(), lenses: lensed(2), viewportRows: 6,
                                  buffers: buffers(2, lines: 5))
    #expect(cursor == DisplayCursor(row: 3, line: 4))
}

// MARK: - Keeping the anchor across an eviction

/// The ring throwing a row away must not throw the reader's place away with it.
///
/// `Pane` forgot the anchor whenever `Terminal.evictedRows` moved, which is once per row for as
/// long as anything is printing into a full buffer. With no anchor, `viewportCursor` falls back to
/// the row the terminal is parked on, and a reader seventy lines into a pretty-printed response was
/// put back to line thirteen of it -- the row offset is all a bare row can carry -- every time
/// something else printed. The rows moved by a known amount, so the anchor moves by the same
/// amount and the line index, which indexes a lens buffer rather than the buffer, does not move
/// at all.
@Test func anAnchorSurvivesAnEvictionByMovingWithTheRows() {
    let shifted = DisplayCursor.shifted(anchor: DisplayCursor(row: 120, line: 70), anchorTop: 118,
                                        evictedBefore: 40, evictedAfter: 55, viewportTopRow: 103)
    #expect(shifted?.anchor == DisplayCursor(row: 105, line: 70))
    // The top comes back as the terminal's current one rather than being derived: a scrolled-back
    // viewport has already followed the same rows down by growing `viewportOffset`.
    #expect(shifted?.anchorTop == 103)
}

@Test func anAnchorWhoseOwnRowWasEvictedIsForgotten() {
    // The block it pointed at has left the ring; there is nothing to move it to.
    #expect(DisplayCursor.shifted(anchor: DisplayCursor(row: 10, line: 70), anchorTop: 8,
                                  evictedBefore: 0, evictedAfter: 11, viewportTopRow: 0) == nil)
    // Exactly at the edge: row 11 with eleven rows gone is row 0, which is still in the buffer.
    let edge = DisplayCursor.shifted(anchor: DisplayCursor(row: 11, line: 2), anchorTop: 11,
                                     evictedBefore: 0, evictedAfter: 11, viewportTopRow: 0)
    #expect(edge?.anchor == DisplayCursor(row: 0, line: 2))
    #expect(edge?.anchorTop == 0)
}

@Test func nothingEvictedLeavesTheAnchorExactlyWhereItWas() {
    let same = DisplayCursor.shifted(anchor: DisplayCursor(row: 12, line: 3), anchorTop: 10,
                                     evictedBefore: 7, evictedAfter: 7, viewportTopRow: 99)
    #expect(same?.anchor == DisplayCursor(row: 12, line: 3))
    // Nothing moved, so nothing is re-read either.
    #expect(same?.anchorTop == 10)
    // No anchor to move, and a counter that has gone backwards (it never does, but a caller that
    // read the two numbers in the wrong order must not shift rows upwards).
    #expect(DisplayCursor.shifted(anchor: nil, anchorTop: 10, evictedBefore: 0, evictedAfter: 5,
                                  viewportTopRow: 0) == nil)
    #expect(DisplayCursor.shifted(anchor: DisplayCursor(row: 12), anchorTop: 10,
                                  evictedBefore: 9, evictedAfter: 4,
                                  viewportTopRow: 0)?.anchor == DisplayCursor(row: 12))
    // An anchor that was never given a top -- `viewportAnchorTop` starts at -1 -- is not an anchor.
    #expect(DisplayCursor.shifted(anchor: DisplayCursor(row: 12), anchorTop: -1,
                                  evictedBefore: 0, evictedAfter: 1, viewportTopRow: 0) == nil)
}

/// End to end, against a real buffer: the display the shifted anchor produces is the display the
/// unshifted one produced before the eviction.
@Test func theShiftedAnchorShowsTheSameLensLines() {
    let t = session()
    let choices = lensed(2)
    let get = buffers(2, lines: 40)
    let before = DisplayCursor(row: 3, line: 12)
    let seen = t.displayRows(from: before, count: 6, folding: OutputFolding(), lenses: choices,
                             buffers: get)
    // Three rows fall out of the top of the ring.
    let after = try? #require(DisplayCursor.shifted(anchor: before, anchorTop: 3,
                                                    evictedBefore: 0, evictedAfter: 3,
                                                    viewportTopRow: 0))
    #expect(after?.anchor == DisplayCursor(row: 0, line: 12))
    // The same lens lines, which is what the reader is looking at.
    let lines = seen.compactMap { if case .lens(_, let line) = $0 { return line } else { return nil } }
    #expect(lines == Array(12..<18))
}

/// An anchor recorded *as* the display bottom is not a place a reader chose, and must not outlive
/// the bottom moving.
///
/// The pane records one on every keystroke (`send` scrolls to the live screen first), and once the
/// ring is at capacity `viewportTopRow` stops moving -- `scrollback.count` is pinned at the cap and
/// `viewportOffset` is zero -- so the staleness check `anchorTop == top` keeps saying "still yours"
/// while the content underneath scrolls away. The pane then drew a frozen screen with no caret
/// while `make build` printed below the window, resyncing for one frame per keystroke. The bottom
/// is recomputed instead: it is a pure function of the buffer, so it is right every frame and
/// cannot go stale.
@Test func aDisplayBottomAnchorIsRecomputedRatherThanTrusted() {
    // Small enough that the ring is full within a few steps: the whole defect only exists once
    // rows are being evicted, so a test that never evicts passes against the broken semantics too.
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 8)
    t.feed(mark("A") + "$ " + mark("B") + "curl x\r\n" + mark("C"))
    t.feed("{\"a\":1}\r\n" + mark("D", 0))
    t.feed(mark("A") + "$ ")
    let id = t.command(containingAbsoluteRow: 0)?.id ?? 0
    let choices = lensed(id)
    let get = buffers(id, lines: 20)
    // What `send` records: the display bottom, and the viewport top it was taken at.
    var anchor = t.displayBottomCursor(folding: OutputFolding(), lenses: choices, viewportRows: 6,
                                       buffers: get)
    var anchorTop = t.viewportTopRow
    #expect(t.isDisplayBottom(anchor, folding: OutputFolding(), lenses: choices, viewportRows: 6,
                              buffers: get))

    var evictingSteps = 0
    for step in 1...20 {
        let before = t.evictedRows
        t.feed(mark("A") + "$ " + mark("B") + "echo \(step)\r\n" + mark("C") + "line \(step)\r\n"
               + mark("D", 0))
        if t.evictedRows > before { evictingSteps += 1 }
        let cursor = t.viewportCursor(anchor: anchor, anchorTop: anchorTop,
                                      anchorIsDisplayBottom: true, folding: OutputFolding(),
                                      lenses: choices, viewportRows: 6, buffers: get)
        let bottom = t.displayBottomCursor(folding: OutputFolding(), lenses: choices,
                                           viewportRows: 6, buffers: get)
        #expect(cursor == bottom, "step \(step)")
        // …and what it draws really does reach the last row of the buffer, which is where the
        // caret is and the whole reason the display bottom exists.
        let rows = t.displayRows(from: cursor, count: 6, folding: OutputFolding(), lenses: choices,
                                 buffers: get)
        #expect(rows.last == .row(t.totalRows - 1), "step \(step): \(rows)")
        // The anchor is carried forward exactly as the pane carries it: shifted by whatever the
        // ring threw away, never re-recorded, because nothing scrolled.
        if let moved = DisplayCursor.shifted(anchor: anchor, anchorTop: anchorTop,
                                             evictedBefore: before, evictedAfter: t.evictedRows,
                                             viewportTopRow: t.viewportTopRow) {
            anchor = moved.anchor
            anchorTop = moved.anchorTop
        }
    }
    // The regime the defect lives in was actually entered. Without this the test passes with the
    // flag ignored: with nothing evicted `anchorTop == top` is false anyway and the fallback saves
    // it, which is exactly how the first version of this test proved nothing.
    #expect(t.evictedRows > 0)
    #expect(evictingSteps >= 10, "\(evictingSteps) of 20 steps evicted")
}

/// The same, reached the way a *reader* reaches it: wheel back, then wheel down to the live edge.
///
/// This is the commonest way into the bug and it has nothing to do with lenses. `advance` clamps at
/// the bottom, so a reader scrolling down lands on exactly the cursor `displayBottomCursor` returns
/// -- and tagging that anchor by *who moved to it* called it "a place the reader chose". Once the
/// ring is at capacity `viewportTopRow` freezes, `anchorTop == top` is true for ever, the anchor
/// branch wins, and the window walks backwards through the buffer while the build prints below it:
/// no newest row, no caret, until the next keystroke.
@Test func aReaderWhoWheelsBackToTheBottomIsAtTheBottom() {
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 8)
    for i in 1...10 { t.feed("line \(i)\r\n") }
    let empty = OutputFolding()

    // Wheel back three display lines, then down again past the edge: `advance` clamps.
    let up = t.advance(t.displayBottomCursor(folding: empty, viewportRows: 6), by: -3,
                       folding: empty, viewportRows: 6)
    #expect(!t.isDisplayBottom(up, folding: empty, viewportRows: 6))
    var anchor = t.advance(up, by: 10, folding: empty, viewportRows: 6)
    #expect(t.isDisplayBottom(anchor, folding: empty, viewportRows: 6))
    var anchorTop = t.viewportTopRow
    let atBottom = t.isDisplayBottom(anchor, folding: empty, viewportRows: 6)

    var evictingSteps = 0
    for step in 1...20 {
        let before = t.evictedRows
        t.feed("build line \(step)\r\n")
        if t.evictedRows > before { evictingSteps += 1 }
        let cursor = t.viewportCursor(anchor: anchor, anchorTop: anchorTop,
                                      anchorIsDisplayBottom: atBottom, folding: empty,
                                      viewportRows: 6)
        let rows = t.displayRows(from: cursor, count: 6, folding: empty)
        #expect(rows.last == .row(t.totalRows - 1), "step \(step): \(rows)")
        if let moved = DisplayCursor.shifted(anchor: anchor, anchorTop: anchorTop,
                                             evictedBefore: before, evictedAfter: t.evictedRows,
                                             viewportTopRow: t.viewportTopRow) {
            anchor = moved.anchor
            anchorTop = moved.anchorTop
        }
    }
    #expect(t.evictedRows > 0)
    #expect(evictingSteps >= 10, "\(evictingSteps) of 20 steps evicted")
}

/// And a reader's own anchor is still honoured, on the same buffer, in the same state.
@Test func aReadersAnchorIsStillUsedWhileRowsAreEvicted() {
    let t = session()
    _ = t.scrollToAbsoluteRow(4, margin: 0)
    let cursor = t.viewportCursor(anchor: DisplayCursor(row: 3, line: 7), anchorTop: t.viewportTopRow,
                                  anchorIsDisplayBottom: false, folding: OutputFolding(),
                                  lenses: lensed(2), viewportRows: 6, buffers: buffers(2, lines: 40))
    #expect(cursor == DisplayCursor(row: 3, line: 7))
}


// MARK: - A display change under a reader

/// Which anchors survive the display changing height under them.
///
/// A watch completes a run every five seconds, and each one opens a diff lens on the newest block.
/// The pane forgot the anchor every time, which threw a reader who had opened run 7 by hand and
/// parked seventy lines into it: scrolled back they landed on the raw row offset -- line 70 became
/// about line 0 -- and reading on the live screen they landed on the prompt. Every five seconds,
/// for as long as the watch ran.
///
/// The unconditional forget was protecting one real case, and only one: the anchor `send` records
/// while a command is typed, which is the display bottom and is stale the moment a lens opens
/// under it. That is the case the flag names, so the rule can name it too.
@Test func onlyTheLiveBottomAnchorIsForgottenWhenTheDisplayChanges() {
    #expect(!DisplayCursor.survivesDisplayChange(anchor: nil, isDisplayBottom: false))
    #expect(!DisplayCursor.survivesDisplayChange(anchor: DisplayCursor(row: 3, line: 70),
                                                 isDisplayBottom: true))
    #expect(DisplayCursor.survivesDisplayChange(anchor: DisplayCursor(row: 3, line: 70),
                                                isDisplayBottom: false))
}

/// And end to end: a reader parked at line 70 of an earlier run is still there after a later run
/// gets a lens of its own.
@Test func aReaderStaysInTheRunTheyOpenedWhenALaterRunIsLensed() {
    // Two runs of the same request, one after the other, each with output of its own.
    let t = makeTerminal(cols: 40, rows: 6, scrollback: 200)
    for run in 1...2 {
        t.feed(mark("A") + "$ " + mark("B") + "curl https://example.com/health\r\n" + mark("C"))
        t.feed("{\"n\":\(run)}\r\n" + mark("D", 0))
    }
    t.feed(mark("A") + "$ ")
    let rows = t.promptRows
    let older = try! #require(t.command(containingAbsoluteRow: rows[0]))
    let newer = try! #require(t.command(containingAbsoluteRow: rows[1]))
    let olderStart = try! #require(older.outputStart)

    var choices = LensChoices()
    choices.set(.pretty, for: older.id)
    var buffers: [UInt32: LensBuffer] = [
        older.id: LensBuffer(commandID: older.id, lens: .pretty,
                             lines: (0..<126).map { LensLine("  \"key\($0)\": 1,") },
                             contentVersion: 0),
    ]
    let get: (UInt32) -> LensBuffer? = { buffers[$0] }

    // The reader has opened the older run by hand and scrolled seventy lines into it.
    _ = t.scrollToAbsoluteRow(olderStart, margin: 0)
    let anchor = DisplayCursor(row: olderStart, line: 70)
    let anchorTop = t.viewportTopRow
    #expect(t.viewportCursor(anchor: anchor, anchorTop: anchorTop, anchorIsDisplayBottom: false,
                             folding: OutputFolding(), lenses: choices, viewportRows: 6,
                             buffers: get) == anchor)

    // The watch finishes the newer run and opens a diff lens on it. Nothing about the older run's
    // buffer changed, so neither does where the reader is.
    choices.set(.diff(previousCommandID: older.id), for: newer.id)
    buffers[newer.id] = LensBuffer(commandID: newer.id, lens: .diff(previousCommandID: older.id),
                                   lines: (0..<8).map { LensLine("+ line \($0)") },
                                   contentVersion: 0)
    let after = t.viewportCursor(anchor: anchor, anchorTop: anchorTop, anchorIsDisplayBottom: false,
                                 folding: OutputFolding(), lenses: choices, viewportRows: 6,
                                 buffers: get)
    #expect(after == DisplayCursor(row: olderStart, line: 70))
    let drawn = t.displayRows(from: after, count: 6, folding: OutputFolding(), lenses: choices,
                              buffers: get)
    #expect(drawn.first == .lens(commandID: older.id, line: 70))

    // A buffer that came back shorter is clamped rather than trusted, which is the other half of
    // what `canonicalised` is for.
    buffers[older.id] = LensBuffer(commandID: older.id, lens: .pretty,
                                   lines: (0..<12).map { LensLine("  \"key\($0)\": 1,") },
                                   contentVersion: 1)
    #expect(t.viewportCursor(anchor: anchor, anchorTop: anchorTop, anchorIsDisplayBottom: false,
                             folding: OutputFolding(), lenses: choices, viewportRows: 6,
                             buffers: get) == DisplayCursor(row: olderStart, line: 11))
}
