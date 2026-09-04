import Testing
@testable import NyxCore

private func pos(_ r: Int, _ c: Int) -> AbsolutePosition { AbsolutePosition(row: r, col: c) }

@Test func positionsOrderByRowThenColumn() {
    #expect(pos(1, 5) < pos(2, 0))
    #expect(pos(1, 4) < pos(1, 5))
    #expect(!(pos(2, 0) < pos(1, 9)))
}

@Test func selectionNormalisesBackwardDrags() {
    let forward = Selection(anchor: pos(1, 2), head: pos(3, 4), mode: .character)
    let backward = Selection(anchor: pos(3, 4), head: pos(1, 2), mode: .character)
    #expect(forward.start == pos(1, 2) && forward.end == pos(3, 4))
    #expect(backward.start == pos(1, 2) && backward.end == pos(3, 4))
}

@Test func emptySelectionSelectsNothing() {
    let s = Selection(anchor: pos(2, 3), head: pos(2, 3), mode: .character)
    #expect(s.isEmpty)
    #expect(s.columnRange(onRow: 2, cols: 10) == nil)
}

@Test func characterSelectionSpansWholeMiddleRows() {
    let s = Selection(anchor: pos(1, 7), head: pos(3, 2), mode: .character)
    #expect(s.columnRange(onRow: 0, cols: 10) == nil)
    #expect(s.columnRange(onRow: 1, cols: 10) == 7..<10)
    #expect(s.columnRange(onRow: 2, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 3, cols: 10) == 0..<2)
    #expect(s.columnRange(onRow: 4, cols: 10) == nil)
}

@Test func singleRowCharacterSelection() {
    let s = Selection(anchor: pos(2, 3), head: pos(2, 8), mode: .character)
    #expect(s.columnRange(onRow: 2, cols: 10) == 3..<8)
}

@Test func blockSelectionUsesTheSameColumnsOnEveryRow() {
    let s = Selection(anchor: pos(1, 6), head: pos(3, 2), mode: .block)
    for row in 1...3 { #expect(s.columnRange(onRow: row, cols: 10) == 2..<6) }
    #expect(s.columnRange(onRow: 0, cols: 10) == nil)
    #expect(s.columnRange(onRow: 4, cols: 10) == nil)
}

@Test func blockSelectionOnASingleColumnIsEmpty() {
    let s = Selection(anchor: pos(1, 4), head: pos(3, 4), mode: .block)
    for row in 1...3 { #expect(s.columnRange(onRow: row, cols: 10) == nil) }
}

@Test func lineSelectionTakesWholeRows() {
    let s = Selection(anchor: pos(1, 5), head: pos(2, 1), mode: .line)
    #expect(s.columnRange(onRow: 1, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 2, cols: 10) == 0..<10)
    #expect(s.columnRange(onRow: 3, cols: 10) == nil)
}

@Test func columnRangeClampsToTheGridWidth() {
    let s = Selection(anchor: pos(1, 3), head: pos(1, 99), mode: .character)
    #expect(s.columnRange(onRow: 1, cols: 10) == 3..<10)
}

private let defaultSeparators: Set<Character> = Set(" ()[]{}'\"`,;:|<>")

@Test func absoluteRowsCoverScrollbackThenScreen() {
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("a\r\nb\r\nc\r\nd")
    #expect(t.scrollback.count == 2)
    #expect(t.totalRows == 4)
    #expect(t.absoluteRow(0)?.cells[0].scalar == "a")
    #expect(t.absoluteRow(3)?.cells[0].scalar == "d")
    #expect(t.absoluteRow(4) == nil)
    #expect(t.viewportTopRow == 2)
    t.scrollViewport(by: 1)
    #expect(t.viewportTopRow == 1)
}

@Test func extractsASingleRowOfText() {
    let t = makeTerminal(cols: 20, rows: 3).run("hello world")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 5), mode: .character)
    #expect(t.text(in: s) == "hello")
}

@Test func extractionTrimsTrailingBlanksOnEachRow() {
    let t = makeTerminal(cols: 20, rows: 3).run("ab\r\ncd")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 20), mode: .character)
    #expect(t.text(in: s) == "ab\ncd")
}

@Test func softWrappedRowsJoinWithoutANewline() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    #expect(t.screen.rows[0].wrapped)
    let s = Selection(anchor: pos(0, 0), head: pos(1, 5), mode: .character)
    #expect(t.text(in: s) == "abcdefgh")
}

@Test func extractionSkipsWideSpacerCells() {
    let t = makeTerminal(cols: 10, rows: 2).run("a漢b")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 10), mode: .character)
    #expect(t.text(in: s) == "a漢b")
}

@Test func extractionKeepsGraphemeClusters() {
    let t = makeTerminal(cols: 10, rows: 2).run("e\u{0301}x")
    let s = Selection(anchor: pos(0, 0), head: pos(0, 10), mode: .character)
    #expect(t.text(in: s) == "e\u{0301}x")
}

@Test func blockSelectionTakesColumnsLiterally() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdef\r\nghijkl\r\nmnopqr")
    let s = Selection(anchor: pos(0, 1), head: pos(2, 4), mode: .block)
    #expect(t.text(in: s) == "bcd\nhij\nnop")
}

@Test func blockSelectionDoesNotJoinWrappedRows() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 3), mode: .block)
    #expect(t.text(in: s) == "abc\nfgh")
}

@Test func selectionSpansScrollbackAndScreen() {
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("one\r\ntwo\r\nthree\r\nfour")
    #expect(t.scrollback.count == 2)
    let s = Selection(anchor: pos(0, 0), head: pos(3, 10), mode: .character)
    #expect(t.text(in: s) == "one\ntwo\nthree\nfour")
}

@Test func wordRangeFindsWordBoundaries() {
    let t = makeTerminal(cols: 30, rows: 2).run("hello  world/path")
    #expect(t.wordRange(at: pos(0, 1), separators: defaultSeparators) == 0..<5)
    #expect(t.wordRange(at: pos(0, 4), separators: defaultSeparators) == 0..<5)
    #expect(t.wordRange(at: pos(0, 8), separators: defaultSeparators) == 7..<17)
}

@Test func wordRangeOnASeparatorSelectsJustIt() {
    let t = makeTerminal(cols: 30, rows: 2).run("a b")
    #expect(t.wordRange(at: pos(0, 1), separators: defaultSeparators) == 1..<2)
}

@Test func wordRangeOnAnEmptyCellIsNil() {
    let t = makeTerminal(cols: 30, rows: 2).run("ab")
    #expect(t.wordRange(at: pos(0, 10), separators: defaultSeparators) == nil)
}

@Test func lineSelectionOfAWrappedLineTakesTheWholeLogicalLine() {
    let t = makeTerminal(cols: 5, rows: 3).run("abcdefgh")
    let s = Selection(anchor: pos(0, 0), head: pos(1, 0), mode: .line)
    #expect(t.text(in: s) == "abcdefgh")
}

@Test func narrowingUnderALiveSelectionKeepsTheRowsSeparated() {
    let t = makeTerminal(cols: 10, rows: 3).run("aaaa\r\nbbbb\r\ncccc")
    // Anchored past what becomes the right edge, so after the narrow row 0 selects no columns and
    // contributes no text. It must still contribute its line break.
    let s = Selection(anchor: pos(0, 9), head: pos(2, 4), mode: .character)
    t.resize(cols: 6, rows: 3)
    #expect(s.columnRange(onRow: 0, cols: t.cols) == nil)
    #expect(t.text(in: s) == "\nbbbb\ncccc")
}
