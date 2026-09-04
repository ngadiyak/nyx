import Testing
@testable import NyxCore

private func pos(_ r: Int, _ c: Int) -> AbsolutePosition { AbsolutePosition(row: r, col: c) }

/// "alpha beta gamma" on row 0, "delta epsilon" on row 1. Word columns:
/// alpha 0..<5, beta 6..<10, gamma 11..<16; delta 0..<5, epsilon 6..<13.
private func wordTerminal() -> Terminal {
    makeTerminal(cols: 20, rows: 3).run("alpha beta gamma\r\ndelta epsilon")
}

// MARK: - Press

@Test func aSingleClickStartsAnEmptyCharacterSelection() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 7), clickCount: 1, block: false, in: t)
    #expect(c.isDragging)
    #expect(c.selection?.mode == .character)
    #expect(c.selection?.isEmpty == true)
    #expect(c.selection?.start == pos(0, 7))
}

@Test func aDoubleClickSelectsTheWordUnderTheCursor() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 7), clickCount: 2, block: false, in: t)
    #expect(c.selection?.mode == .word)
    #expect(t.text(in: c.selection!) == "beta")
}

@Test func aTripleClickSelectsTheWholeLine() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(1, 3), clickCount: 3, block: false, in: t)
    #expect(c.selection?.mode == .line)
    #expect(c.selection?.columnRange(onRow: 1, cols: t.cols) == 0..<20)
    #expect(t.text(in: c.selection!) == "delta epsilon")
}

@Test func moreThanThreeClicksStaysOnTheLine() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 5, block: false, in: t)
    #expect(c.selection?.mode == .line)
}

@Test func optionForcesBlockModeWhateverTheClickCount() {
    let t = wordTerminal()
    for count in 1...3 {
        var c = SelectionController()
        c.begin(at: pos(0, 2), clickCount: count, block: true, in: t)
        #expect(c.selection?.mode == .block)
    }
}

@Test func aDoubleClickOnAnEmptyCellSelectsNothing() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 18), clickCount: 2, block: false, in: t)
    #expect(c.selection?.isEmpty == true)
}

// MARK: - Drag

@Test func draggingACharacterSelectionMovesOnlyTheHead() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 2), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 9), in: t)
    #expect(t.text(in: c.selection!) == "pha bet")
    #expect(c.selection?.anchor == pos(0, 2))
}

@Test func draggingRightThenBackPastTheAnchorFlipsDirection() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 6), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 10), in: t)
    #expect(t.text(in: c.selection!) == "beta")
    c.drag(to: pos(0, 0), in: t)
    #expect(c.selection?.start == pos(0, 0) && c.selection?.end == pos(0, 6))
    #expect(t.text(in: c.selection!) == "alpha")
}

@Test func draggingInWordModeTakesWholeWordsAtBothEnds() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 8), clickCount: 2, block: false, in: t)   // middle of "beta"
    c.drag(to: pos(0, 13), in: t)                                // middle of "gamma"
    #expect(t.text(in: c.selection!) == "beta gamma")
}

@Test func draggingBackwardsInWordModeStillTakesWholeWords() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 13), clickCount: 2, block: false, in: t)  // middle of "gamma"
    c.drag(to: pos(0, 2), in: t)                                 // middle of "alpha"
    #expect(t.text(in: c.selection!) == "alpha beta gamma")
}

@Test func aWordDragThatComesBackShrinksAgain() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 2), clickCount: 2, block: false, in: t)
    c.drag(to: pos(0, 13), in: t)
    #expect(t.text(in: c.selection!) == "alpha beta gamma")
    c.drag(to: pos(0, 7), in: t)
    #expect(t.text(in: c.selection!) == "alpha beta")
}

@Test func draggingInLineModeTakesWholeRows() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 9), clickCount: 3, block: false, in: t)
    c.drag(to: pos(1, 4), in: t)
    #expect(t.text(in: c.selection!) == "alpha beta gamma\ndelta epsilon")
}

@Test func draggingWithoutAPressDoesNothing() {
    let t = wordTerminal()
    var c = SelectionController()
    let changed = c.drag(to: pos(0, 5), in: t)
    #expect(changed == false)
    #expect(c.selection == nil)
}

// MARK: - End and clear

@Test func aClickWithNoMovementSelectsNothing() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 4), clickCount: 1, block: false, in: t)
    let ended = c.end()
    #expect(ended)
    #expect(c.selection == nil)      // an empty selection is the gesture for "deselect"
    #expect(!c.isDragging)
}

@Test func aDoubleClickSurvivesTheButtonComingUp() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 1), clickCount: 2, block: false, in: t)
    c.end()
    #expect(t.text(in: c.selection!) == "alpha")
}

@Test func clearEmptiesTheSelectionAndTheDrag() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 5), in: t)
    let cleared = c.clear()
    #expect(cleared)
    #expect(c.selection == nil)
    #expect(!c.isDragging)
    let again = c.clear()
    #expect(again == false)      // nothing to change the second time
}

@Test func draggingAfterAnEndDoesNothing() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 5), in: t)
    c.end()
    let changed = c.drag(to: pos(0, 15), in: t)
    #expect(changed == false)
    #expect(t.text(in: c.selection!) == "alpha")
}

@Test func aDragThatChangesNothingReportsNoChange() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 2), clickCount: 1, block: false, in: t)
    let first = c.drag(to: pos(0, 9), in: t)
    #expect(first)
    let second = c.drag(to: pos(0, 9), in: t)
    #expect(second == false)
}

@Test func aBlockDragKeepsTheColumnsOnEveryRow() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdef\r\nghijkl\r\nmnopqr")
    var c = SelectionController()
    c.begin(at: pos(0, 1), clickCount: 1, block: true, in: t)
    c.drag(to: pos(2, 4), in: t)
    #expect(t.text(in: c.selection!) == "bcd\nhij\nnop")
}

// MARK: - Invalidation

@Test func clearingTheScrollbackDropsASelectionAnchoredInIt() {
    // The reviewer's reproduction: without this the selection survives `clear -x` and silently
    // addresses whatever the live screen now holds at those absolute rows.
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("one\r\ntwo\r\nthree\r\nfour")
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 3), in: t)
    c.end()
    #expect(t.text(in: c.selection!) == "one")
    t.feed("\u{1B}[3J")
    let dropped = c.invalidateIfStale(t)
    #expect(dropped)
    #expect(c.selection == nil)
}

@Test func invalidationKeepsASelectionMadeAfterTheChange() {
    let t = makeTerminal(cols: 10, rows: 2, scrollback: 10).run("one\r\ntwo\r\nthree\r\nfour")
    t.feed("\u{1B}[3J")
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 1, block: false, in: t)
    c.drag(to: pos(0, 5), in: t)
    c.end()
    let dropped = c.invalidateIfStale(t)
    #expect(dropped == false)
    #expect(t.text(in: c.selection!) == "three")
}

@Test func invalidationLeavesAStableCoordinateSpaceAlone() {
    let t = wordTerminal()
    var c = SelectionController()
    c.begin(at: pos(0, 0), clickCount: 2, block: false, in: t)
    c.end()
    t.feed("\r\nmore\r\n")
    t.resize(cols: 12, rows: 4)
    let dropped = c.invalidateIfStale(t)
    #expect(dropped == false)
    #expect(c.selection != nil)
}
