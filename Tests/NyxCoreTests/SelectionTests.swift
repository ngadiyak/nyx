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
