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
    let display: [DisplayRow] = [.row(0), .row(1), .row(2), .fold(commandID: 2, hiddenRows: 7, status: .succeeded),
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

// MARK: - DisplayRows.slots, shared by the hover above and the spine in Pane
//
// The spine used to walk `block.visibleRows` -- which spans everything a tail fold hides -- and
// look each row up in the display slots individually, a linear search per row. `DisplayRows.slots`
// walks the display once instead; these fixtures are the same ones `placed` uses above, so a
// passing spine reads exactly the same rows a passing hover would.

@Test func slotsCoveredMatchesThePlacedHoverForTheSameFold() {
    let display: [DisplayRow] = [.row(0), .row(1), .row(2), .fold(commandID: 2, hiddenRows: 7, status: .succeeded),
                                 .row(10), .row(11), .row(12), .row(13)]
    let slots = DisplayRows.slots(coveredBy: 2..<13, commandID: 2, in: display, viewportTop: 0)
    #expect(slots == 2..<7)
}

@Test func slotsCoveredIsNilForABlockWithNoDisplayedRows() {
    let display: [DisplayRow] = [.row(0), .row(1), .row(2)]
    #expect(DisplayRows.slots(coveredBy: 20..<25, commandID: 9, in: display, viewportTop: 0) == nil)
}

// MARK: - The cursor's block is drawn as a hovered one

@Test func theCursorsBlockHoversItselfAndSaysSo() {
    let hover = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    #expect(hover?.id == 2)
    #expect(hover?.rows == 3..<19)
    #expect(hover?.headerRow == 3)
    #expect(hover?.source == .cursor)
}

@Test func aCursorOnABlockThatIsNotOnScreenHoversNothing() {
    #expect(BlockHover.resolve(cursor: BlockCursor(commandID: 99), blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(cursor: BlockCursor(), blocks: blocks(), allowed: true) == nil)
    #expect(BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: false) == nil)
}

@Test func thePointerWinsWhileItIsOnABlockOfItsOwn() {
    let pointer = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    let chosen = BlockHover.choose(pointer: pointer, cursor: cursor, cursorMovedLast: false)
    #expect(chosen?.id == 1)
    #expect(chosen?.source == .pointer)
}

/// Inside the pane but on no block at all -- resting two rows below the last block, or on the blank
/// screen under a short session -- is not the pointer winning: it is the pointer having no answer.
/// The cursor's block stays raised, because otherwise brushing the trackpad after ⌘↑ put out the
/// only thing on screen saying where the keyboard was.
@Test func aPointerOnNoBlockLeavesTheCursorsBlockRaised() {
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    let chosen = BlockHover.choose(pointer: nil, cursor: cursor, cursorMovedLast: false)
    #expect(chosen?.id == 2)
    #expect(chosen?.source == .cursor)
}

/// With neither a pointer on a block nor a cursor there is nothing to raise: a pane nobody has
/// pressed ⌘↑ in draws no block chrome at idle.
@Test func aPointerOnNoBlockWithNoCursorRaisesNothing() {
    #expect(BlockHover.choose(pointer: nil, cursor: nil, cursorMovedLast: false) == nil)
}

@Test func theCursorReturnsWhenThePointerLeavesOrTheChordArrives() {
    let pointer = BlockHover.resolve(pointerRow: 1, blocks: blocks(), allowed: true)
    let cursor = BlockHover.resolve(cursor: BlockCursor(commandID: 2), blocks: blocks(), allowed: true)
    #expect(BlockHover.choose(pointer: nil, cursor: cursor, cursorMovedLast: false)?.id == 2)
    #expect(BlockHover.choose(pointer: pointer, cursor: cursor, cursorMovedLast: true)?.id == 2)
}

@Test func placingAHoverOnDisplayRowsKeepsItsSource() {
    let hover = try! #require(BlockHover.resolve(cursor: BlockCursor(commandID: 2),
                                                 blocks: blocks(), allowed: true))
    let display: [DisplayRow] = (0..<19).map { .row(12 + $0) }
    #expect(hover.placed(onDisplayRows: display, viewportTop: 12)?.source == .cursor)
    #expect(hover.attachingHeader(to: nil).source == .cursor)
}

// MARK: - Which block an action acts on

@Test func anActionTargetsTheCursorWhenThereIsOne() {
    #expect(BlockTarget.resolve(cursor: BlockCursor(commandID: 7), exists: { _ in true },
                                fallback: 9) == 7)
}

@Test func anActionFallsBackWhenTheCursorIsClearedOrItsBlockIsGone() {
    #expect(BlockTarget.resolve(cursor: BlockCursor(), exists: { _ in true }, fallback: 9) == 9)
    #expect(BlockTarget.resolve(cursor: BlockCursor(commandID: 7), exists: { _ in false },
                                fallback: 9) == 9)
    #expect(BlockTarget.resolve(cursor: BlockCursor(), exists: { _ in true }, fallback: nil) == nil)
}
