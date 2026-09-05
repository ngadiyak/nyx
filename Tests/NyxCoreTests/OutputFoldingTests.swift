import Testing
@testable import NyxCore

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

private func region(output: Int, id: UInt32 = 7) -> CommandRegion {
    CommandRegion(promptRow: 10, outputStart: output == 0 ? nil : 11, endRow: 10 + output,
                  exitStatus: 0, duration: 1, id: id)
}

@Test func aTailFoldHidesEverythingButTheLastLines() {
    let hidden = OutputFolding.hiddenRange(of: region(output: 10), shape: .tail(keep: 3))
    #expect(hidden == 11..<18)          // rows 18, 19, 20 stay visible
}

@Test func aFullFoldHidesAllOfTheOutput() {
    #expect(OutputFolding.hiddenRange(of: region(output: 10), shape: .all) == 11..<21)
}

/// Hiding one line behind a one-line placeholder is a net loss, so a short output folds fully.
@Test func outputTooShortForATailFoldsFully() {
    #expect(OutputFolding.effectiveShape(.tail(keep: 3), outputRows: 4) == .all)
    #expect(OutputFolding.effectiveShape(.tail(keep: 3), outputRows: 5) == .tail(keep: 3))
    #expect(OutputFolding.effectiveShape(.tail(keep: 0), outputRows: 50) == .all)
}

@Test func toggleGoesOpenTailOpen() {
    var f = OutputFolding()
    f.toggle(7, keep: 3)
    #expect(f.shape(of: 7) == .tail(keep: 3))
    f.toggle(7, keep: 3)
    #expect(f.shape(of: 7) == nil)
}

@Test func toggleFullGoesOpenAllOpenAndOverridesATail() {
    var f = OutputFolding()
    f.fold(7, .tail(keep: 3))
    f.toggleFull(7)
    #expect(f.shape(of: 7) == .all)
    f.toggleFull(7)
    #expect(f.shape(of: 7) == nil)
}

@Test func pruneDropsCommandsOlderThanTheOldestInTheBuffer() {
    var f = OutputFolding()
    f.fold(3, .all)
    f.fold(9, .all)
    f.prune(olderThan: 5)
    #expect(!f.isFolded(3))
    #expect(f.isFolded(9))
}

@Test func autoFoldFoldsLongOutputAndLeavesShortAlone() {
    var f = OutputFolding()
    let folded = f.autoFold(region(output: 300), longerThan: 200, keep: 3)
    #expect(folded)
    #expect(f.shape(of: 7) == .tail(keep: 3))
    let short = f.autoFold(region(output: 10, id: 8), longerThan: 200, keep: 3)
    #expect(!short)
    #expect(f.shape(of: 8) == nil)
}

/// A block the user opened by hand stays open: refolding it would be the terminal arguing.
@Test func autoFoldNeverRefoldsWhatTheUserOpened() {
    var f = OutputFolding()
    f.fold(7, .tail(keep: 3))
    f.unfold(7)
    let folded = f.autoFold(region(output: 300), longerThan: 200, keep: 3)
    #expect(!folded)
}

@Test func thePlaceholderNamesTheCountWithAChevron() {
    #expect(OutputFolding.placeholder(hiddenRows: 2431) == "\u{25B8} \u{2026} 2,431 lines hidden")
    #expect(OutputFolding.placeholder(hiddenRows: 1) == "\u{25B8} \u{2026} 1 line hidden")
}

/// Grouping is done by hand rather than through a formatter so the placeholder does not change
/// with the machine's locale. The boundaries are where a hand-rolled loop goes wrong: the first
/// number that needs no comma, the first that needs one, and one that needs two.
@Test func thousandsAreGroupedAtEveryBoundary() {
    #expect(OutputFolding.grouped(0) == "0")
    #expect(OutputFolding.grouped(999) == "999")
    #expect(OutputFolding.grouped(1000) == "1,000")
    #expect(OutputFolding.grouped(1234567) == "1,234,567")
}

/// The placeholder is longer than a narrow pane is wide, and a row that writes past its last column
/// is a crash in the renderer rather than a truncated line.
@Test func thePlaceholderIsClampedToANarrowPane() {
    let t = makeTerminal(cols: 10, rows: 4)
    let row = t.foldPlaceholderRow(hiddenRows: 1234, status: .succeeded)
    #expect(row.cells.count == 10)
    #expect(row.cells.allSatisfy { $0.content != 0 })   // every column it could reach is written
    let text = String(String.UnicodeScalarView(row.cells.compactMap { Unicode.Scalar($0.content) }))
    #expect(text == String(OutputFolding.placeholder(hiddenRows: 1234).prefix(10)))
}
