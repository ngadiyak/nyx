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
