import Foundation
import Testing
@testable import NyxCore

/// What a display walk is allowed to *cost*, which is a correctness question here rather than a
/// taste one: `displayBottomCursor` runs inside `session.withTerminal` on the frame path, so a walk
/// that re-resolves the same block once per row blocks the PTY reader for as long as it takes.
///
/// The assertions count `Terminal.command(containingAbsoluteRow:)` resolutions rather than
/// milliseconds: a wall-clock bound passes or fails with whatever else the machine is doing, and
/// the defect being pinned is an algorithmic one -- `rows × blockLength` where `blockLength` is
/// enough.

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// A lensed `curl` (id 1) with twelve rows of output, then a `cat` (id 2) of `bigRows` rows, then a
/// prompt. The shape of the report in the brief: a lens open and one large block below it.
private func bigSession(bigRows: Int, running: Bool = false) -> Terminal {
    let t = makeTerminal(cols: 60, rows: 20, scrollback: 20_000)
    t.feed(mark("A") + "$ " + mark("B") + "curl https://example.com/things\r\n" + mark("C"))
    for i in 1...12 { t.feed("  \"row \(i)\": \"a value\",\r\n") }
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ " + mark("B") + "cat big.log\r\n" + mark("C"))
    for i in 1...bigRows { t.feed("line \(i)\r\n") }
    if !running {
        t.feed(mark("D", 0))
        t.feed(mark("A") + "$ ")
    }
    return t
}

private func prettyLens(lines: Int) -> (LensChoices, (UInt32) -> LensBuffer?) {
    var choices = LensChoices()
    choices.set(.pretty, for: 1)
    let buffer = LensBuffer(commandID: 1, lens: .pretty,
                            lines: (0..<lines).map { LensLine("  \"line \($0)\": 1,") },
                            contentVersion: 0)
    return (choices, { $0 == 1 ? buffer : nil })
}

@Test func theBottomWalkResolvesEachBlockOnceNotEachRow() {
    let t = bigSession(bigRows: 2_000)
    let (lenses, buffers) = prettyLens(lines: 40)
    let memo = CommandRegionMemo()
    let cursor = t.displayBottomCursor(folding: OutputFolding(), lenses: lenses, viewportRows: 20,
                                       buffers: buffers, memo: memo)
    // Twenty display lines, all inside the one block the walk starts in.
    #expect(memo.resolutions <= 2)
    // …and it still lands where the unmemoised walk landed.
    #expect(cursor == t.displayBottomCursor(folding: OutputFolding(), lenses: lenses,
                                            viewportRows: 20, buffers: buffers))
}

@Test func theBottomWalkOfARunningBlockIsAlsoOnce() {
    let t = bigSession(bigRows: 2_000, running: true)
    let (lenses, buffers) = prettyLens(lines: 40)
    let memo = CommandRegionMemo()
    _ = t.displayBottomCursor(folding: OutputFolding(), lenses: lenses, viewportRows: 20,
                              buffers: buffers, memo: memo)
    #expect(memo.resolutions <= 2)
}

@Test func aWheelClickInsideABigBlockResolvesItOnce() {
    let t = bigSession(bigRows: 2_000)
    let (lenses, buffers) = prettyLens(lines: 40)
    let inside = DisplayCursor(row: t.scrollback.count - 500)
    let memo = CommandRegionMemo()
    let to = t.advance(inside, by: -3, folding: OutputFolding(), lenses: lenses, viewportRows: 20,
                       buffers: buffers, memo: memo)
    #expect(memo.resolutions <= 2)
    #expect(to == DisplayCursor(row: inside.row - 3))
}

@Test func aWalkCrossingBlocksResolvesOnePerBlockCrossed() {
    // Small blocks so a screenful of display lines crosses several of them: the bound is the number
    // of blocks touched, which is what "O(blocks) not O(rows)" means.
    let t = makeTerminal(cols: 60, rows: 20, scrollback: 2_000)
    for command in 1...12 {
        t.feed(mark("A") + "$ " + mark("B") + "step \(command)\r\n" + mark("C"))
        for i in 1...9 { t.feed("out \(command).\(i)\r\n") }
        t.feed(mark("D", 0))
    }
    t.feed(mark("A") + "$ ")
    let (lenses, buffers) = prettyLens(lines: 3)
    let memo = CommandRegionMemo()
    _ = t.displayBottomCursor(folding: OutputFolding(), lenses: lenses, viewportRows: 20,
                              buffers: buffers, memo: memo)
    // Twenty display lines over ten-row blocks: three blocks, not twenty rows.
    #expect(memo.resolutions <= 4)
}

@Test func drawingAViewportInsideABigBlockResolvesItOnce() {
    let t = bigSession(bigRows: 2_000)
    let (lenses, buffers) = prettyLens(lines: 40)
    let inside = DisplayCursor(row: t.scrollback.count - 500)
    let memo = CommandRegionMemo()
    let rows = t.displayRows(from: inside, count: 20, folding: OutputFolding(), lenses: lenses,
                             buffers: buffers, memo: memo)
    #expect(rows.count == 20)
    #expect(memo.resolutions <= 2)
}

@Test func theMemoAnswersTheSameThingTheScanDoes() {
    let t = bigSession(bigRows: 60)
    let memo = CommandRegionMemo()
    for row in 0..<t.totalRows {
        #expect(t.region(containing: row, memo: memo) == t.command(containingAbsoluteRow: row))
    }
    // Backwards too: a memo is walked in both directions and the range it trusts has to hold at
    // both ends of the block it cached.
    for row in stride(from: t.totalRows - 1, through: 0, by: -1) {
        #expect(t.region(containing: row, memo: memo) == t.command(containingAbsoluteRow: row))
    }
    #expect(t.region(containing: -1, memo: memo) == nil)
    #expect(t.region(containing: t.totalRows, memo: memo) == nil)
}
