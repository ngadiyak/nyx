import Testing
@testable import NyxCore

private func match(_ row: Int, _ columns: Range<Int>) -> SearchMatch {
    SearchMatch(row: row, columns: columns)
}

@Test func matchesAreIndexedByVisibleRow() {
    let ranges = SearchHighlights.visibleRanges([match(10, 0..<3), match(12, 4..<6)],
                                                viewportTop: 10, rows: 4, cols: 20)
    #expect(ranges.count == 4)
    #expect(ranges[0] == [0..<3])
    #expect(ranges[1].isEmpty)
    #expect(ranges[2] == [4..<6])
}

@Test func severalMatchesOnOneRowAreAllKept() {
    let ranges = SearchHighlights.visibleRanges([match(5, 0..<2), match(5, 7..<9)],
                                                viewportTop: 5, rows: 2, cols: 20)
    #expect(ranges[0] == [0..<2, 7..<9])
}

/// A buffer being searched is usually far longer than the screen, so most hits are off it.
@Test func matchesOutsideTheViewportAreDropped() {
    let ranges = SearchHighlights.visibleRanges([match(0, 0..<2), match(99, 0..<2)],
                                                viewportTop: 10, rows: 4, cols: 20)
    let empty = ranges.allSatisfy { $0.isEmpty }
    #expect(empty)
}

/// A match that runs off the right edge is clipped rather than dropped: the part on screen still
/// has to be painted, and a range past `cols` would index cells that do not exist.
@Test func aMatchIsClampedToTheGrid() {
    let ranges = SearchHighlights.visibleRanges([match(0, 8..<14)], viewportTop: 0, rows: 1, cols: 10)
    #expect(ranges[0] == [8..<10])
}

@Test func aMatchEntirelyPastTheRightEdgeIsDropped() {
    let ranges = SearchHighlights.visibleRanges([match(0, 12..<14)], viewportTop: 0, rows: 1, cols: 10)
    #expect(ranges[0].isEmpty)
}

@Test func theCurrentMatchIsReportedOnItsOwnRow() {
    let ranges = SearchHighlights.visibleRange(of: match(11, 2..<5), viewportTop: 10, rows: 3, cols: 20)
    #expect(ranges == [nil, 2..<5, nil])
}

@Test func noCurrentMatchHighlightsNothing() {
    #expect(SearchHighlights.visibleRange(of: nil, viewportTop: 0, rows: 2, cols: 20) == [nil, nil])
}

@Test func aZeroRowViewportProducesNoRows() {
    #expect(SearchHighlights.visibleRanges([match(0, 0..<1)], viewportTop: 0, rows: 0, cols: 10).isEmpty)
    #expect(SearchHighlights.visibleRange(of: match(0, 0..<1), viewportTop: 0, rows: 0, cols: 10).isEmpty)
}
