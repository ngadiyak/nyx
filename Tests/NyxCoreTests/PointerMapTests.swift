import Testing
@testable import NyxCore

/// An 8-point padding around 10x20 cells, like the real view at its default font.
private func position(_ x: Double, _ y: Double, viewportTop: Int = 0,
                      cols: Int = 20, totalRows: Int = 30) -> AbsolutePosition {
    PointerMap.position(x: x, y: y, cellWidth: 10, cellHeight: 20, padding: 8,
                        viewportTop: viewportTop, cols: cols, totalRows: totalRows)
}

@Test func aPointLandsOnTheCellUnderIt() {
    #expect(position(8 + 25, 8 + 45) == AbsolutePosition(row: 2, col: 2))
    #expect(position(8, 8) == AbsolutePosition(row: 0, col: 0))
    #expect(position(8 + 9.9, 8 + 19.9) == AbsolutePosition(row: 0, col: 0))
}

@Test func theViewportOffsetShiftsTheAbsoluteRow() {
    #expect(position(8 + 5, 8 + 5, viewportTop: 17) == AbsolutePosition(row: 17, col: 0))
}

@Test func draggingPastTheRightEdgeSelectsToTheEndOfTheLine() {
    // The clamp is inclusive of `cols` on purpose: `cols` is "past the last column", which is what
    // `Selection.columnRange` reads as "to the end of the row".
    #expect(position(8 + 20 * 10 + 500, 8 + 5).col == 20)
    #expect(position(-400, 8 + 5).col == 0)
}

@Test func draggingAboveAndBelowStaysInsideTheRowRange() {
    #expect(position(8 + 5, -1000, viewportTop: 3).row == 0)
    #expect(position(8 + 5, 100_000, viewportTop: 3).row == 29)
    #expect(position(8 + 5, 100_000, viewportTop: 3, totalRows: 0).row == 0)
}

@Test func aPointJustAboveTheFirstRowIsTheRowAbove() {
    // Inside the padding, so it must floor to -1 and land one row up in the scrollback rather than
    // rounding into the top visible row and stalling a drag towards the scrollback.
    #expect(position(8 + 5, 2, viewportTop: 5).row == 4)
}

@Test func theReportCellStaysStrictlyInsideTheGrid() {
    func cell(_ x: Double, _ y: Double) -> (col: Int, row: Int) {
        PointerMap.reportCell(x: x, y: y, cellWidth: 10, cellHeight: 20, padding: 8, cols: 20, rows: 6)
    }
    #expect(cell(8 + 25, 8 + 45) == (col: 2, row: 2))
    #expect(cell(100_000, 100_000) == (col: 19, row: 5))
    #expect(cell(-100, -100) == (col: 0, row: 0))
}
