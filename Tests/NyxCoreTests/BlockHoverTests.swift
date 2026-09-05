import Testing
@testable import NyxCore

private func blocks() -> [CommandBlock] {
    let a = CommandRegion(promptRow: 10, outputStart: 11, endRow: 14, exitStatus: 0, duration: 1, id: 1)
    let b = CommandRegion(promptRow: 15, outputStart: 16, endRow: 30, exitStatus: 1, duration: 1, id: 2)
    // Viewport top is absolute row 12: block a shows rows 0..<3 without its header, b shows 3..<19.
    return [CommandBlock(region: a, visibleRows: 0..<3, showsHeader: false),
            CommandBlock(region: b, visibleRows: 3..<19, showsHeader: true)]
}

@Test func thePointerOnAnyRowOfABlockHoversThatBlock() {
    let hover = BlockHover.resolve(pointerRow: 7, blocks: blocks(), allowed: true)
    #expect(hover?.id == 2)
    #expect(hover?.rows == 3..<19)
    #expect(hover?.headerRow == 3)
}

@Test func aBlockWhoseCommandIsOffScreenTintsButHasNoHeaderRow() {
    let hover = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    #expect(hover?.id == 1)
    #expect(hover?.headerRow == nil)
}

@Test func nothingIsHoveredOutsideEveryBlockOrWhenChromeIsDisallowed() {
    #expect(BlockHover.resolve(pointerRow: 19, blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(pointerRow: nil, blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(pointerRow: 7, blocks: blocks(), allowed: false) == nil)
}

// MARK: - Placed on display rows (folds on screen)
//
// `resolve` answers in viewport-relative absolute space, which only equals a display slot when
// nothing is folded. `placed` re-expresses the answer in the slots the renderer is about to draw.

/// With nothing folded, every display slot is `.row(viewportTop + slot)` in order, so `placed`
/// must be a no-op.
@Test func withNoFoldsPlacedReturnsTheSameRows() {
    let hover = try! #require(BlockHover.resolve(pointerRow: 7, blocks: blocks(), allowed: true))
    let display: [DisplayRow] = (0..<19).map { .row(12 + $0) }   // viewportTop 12, identity mapping
    #expect(hover.placed(onDisplayRows: display, viewportTop: 12) == hover)
}

/// The fixture from the brief: a fold at slot 3 stands in for 7 hidden rows of block 2's output,
/// and its kept tail resumes at slots 4-6 before wrapping to a fourth, unrelated row. The block's
/// own placeholder counts as one of its rows.
@Test func aFoldedBlocksHoverIsExpressedInDisplaySlots() {
    let display: [DisplayRow] = [.row(0), .row(1), .row(2), .fold(commandID: 2, hiddenRows: 7),
                                 .row(10), .row(11), .row(12), .row(13)]
    let hover = BlockHover(id: 2, rows: 2..<13, headerRow: 2)
    let placed = hover.placed(onDisplayRows: display, viewportTop: 0)
    #expect(placed?.rows == 2..<7)
    #expect(placed?.headerRow == 2)
}

/// A block whose rows have all scrolled out from under the display -- none of its slots survive --
/// hovers nothing rather than an empty or nonsensical range.
@Test func aHoverEntirelyOffTheDisplayIsNil() {
    let display: [DisplayRow] = [.row(0), .row(1), .row(2)]
    let hover = BlockHover(id: 9, rows: 20..<25, headerRow: 20)
    #expect(hover.placed(onDisplayRows: display, viewportTop: 0) == nil)
}
