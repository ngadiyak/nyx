import Testing
@testable import NyxCore

private func id(_ n: Int) -> PaneID { PaneID(n) }
private let full = PaneRect(x: 0, y: 0, width: 100, height: 100)

/// Two panes side by side, ratio 0.5.
private func horizontalPair() -> PaneTree {
    PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
}

/// Two panes stacked, ratio 0.5.
private func verticalPair() -> PaneTree {
    PaneTree.leaf(id(1)).splitting(id(1), axis: .vertical, with: id(2), ratio: 0.5)
}

// MARK: - Divider geometry

@Test func aLeafHasNoDividers() {
    #expect(PaneTree.leaf(id(1)).dividers(in: full, dividerThickness: 1).isEmpty)
}

@Test func aHorizontalSplitHasOneVerticalLineInTheGap() throws {
    let dividers = horizontalPair().dividers(in: full, dividerThickness: 2)
    #expect(dividers.count == 1)
    let d = try #require(dividers.first)
    #expect(d.axis == .horizontal)
    // layout() puts pane 1 at 0..<49 and pane 2 at 51..<100, so the gap is 49..<51.
    #expect(d.rect == PaneRect(x: 49, y: 0, width: 2, height: 100))
    #expect(d.bounds == full)
    #expect(d.path == SplitPath())
}

@Test func aVerticalSplitHasOneHorizontalLineInTheGap() throws {
    let d = try #require(verticalPair().dividers(in: full, dividerThickness: 2).first)
    #expect(d.axis == .vertical)
    #expect(d.rect == PaneRect(x: 0, y: 49, width: 100, height: 2))
}

@Test func theDividerAlwaysSitsExactlyBetweenTheTwoPanesItSeparates() {
    // Whatever the rounding does, the gap the layout leaves and the divider rect must agree.
    for ratio in [0.05, 0.13, 0.5, 0.77, 0.95] {
        let tree = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: ratio)
        let frames = tree.layout(in: full, dividerThickness: 1)
        let divider = tree.dividers(in: full, dividerThickness: 1)[0]
        #expect(divider.rect.x == frames[id(1)]!.x + frames[id(1)]!.width)
        #expect(divider.rect.x + divider.rect.width == frames[id(2)]!.x)
    }
}

@Test func nestedSplitsEachGetTheirOwnDividerWithItsOwnPath() {
    let tree = horizontalPair().splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    let dividers = tree.dividers(in: full, dividerThickness: 1)
    #expect(dividers.count == 2)
    #expect(dividers[0].path == SplitPath())
    #expect(dividers[0].axis == .horizontal)
    #expect(dividers[1].path == SplitPath([.second]))
    #expect(dividers[1].axis == .vertical)
    // The nested divider spans only the right-hand half, not the whole view.
    #expect(dividers[1].rect.x > 0)
    #expect(dividers[1].bounds.width < full.width)
}

// MARK: - Hit testing

@Test func aPointOnTheDividerHitsIt() throws {
    let tree = horizontalPair()
    let d = try #require(tree.divider(atX: 50, y: 20, in: full, dividerThickness: 1, hitSlop: 6))
    #expect(d.path == SplitPath())
}

@Test func aPointWithinTheSlopHitsTheDividerEvenThoughItIsOverAPane() {
    let tree = horizontalPair()
    #expect(tree.divider(atX: 48, y: 20, in: full, dividerThickness: 1, hitSlop: 6) != nil)
    #expect(tree.divider(atX: 52, y: 20, in: full, dividerThickness: 1, hitSlop: 6) != nil)
}

@Test func aPointBeyondTheSlopMissesTheDivider() {
    let tree = horizontalPair()
    #expect(tree.divider(atX: 20, y: 20, in: full, dividerThickness: 1, hitSlop: 6) == nil)
    #expect(tree.divider(atX: 80, y: 20, in: full, dividerThickness: 1, hitSlop: 6) == nil)
}

@Test func aPointOutsideTheDividersSpanMissesIt() {
    // The nested divider only spans the right half; the same y on the left half must miss it.
    let tree = horizontalPair().splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    let nested = tree.dividers(in: full, dividerThickness: 1)[1]
    let y = nested.rect.y
    #expect(tree.divider(atX: 10, y: y, in: full, dividerThickness: 1, hitSlop: 6) == nil)
    #expect(tree.divider(atX: 90, y: y, in: full, dividerThickness: 1, hitSlop: 6)?.path == SplitPath([.second]))
}

@Test func overlappingHitAreasResolveToTheNearestDivider() throws {
    // Two horizontal splits close together: 1 | 2 | 3 with the second divider a few points away.
    let tree = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .horizontal, with: id(3), ratio: 0.05)
    let dividers = tree.dividers(in: full, dividerThickness: 1)
    #expect(dividers.count == 2)
    let outer = dividers[0].rect.x, inner = dividers[1].rect.x
    #expect(inner - outer < 6)   // their hit areas really do overlap
    let hit = try #require(tree.divider(atX: inner, y: 50, in: full, dividerThickness: 1, hitSlop: 6))
    #expect(hit.path == dividers[1].path)
    let other = try #require(tree.divider(atX: outer, y: 50, in: full, dividerThickness: 1, hitSlop: 6))
    #expect(other.path == dividers[0].path)
}

// MARK: - Pane hit testing

@Test func aPointInAPaneFindsThatPane() {
    let tree = horizontalPair()
    #expect(tree.pane(atX: 10, y: 10, in: full, dividerThickness: 2) == id(1))
    #expect(tree.pane(atX: 90, y: 10, in: full, dividerThickness: 2) == id(2))
}

@Test func aPointInTheGapBelongsToNoPane() {
    #expect(horizontalPair().pane(atX: 50, y: 10, in: full, dividerThickness: 2) == nil)
}

@Test func aPointOutsideTheBoundsBelongsToNoPane() {
    let tree = horizontalPair()
    #expect(tree.pane(atX: -1, y: 10, in: full, dividerThickness: 2) == nil)
    #expect(tree.pane(atX: 10, y: 200, in: full, dividerThickness: 2) == nil)
}

@Test func paneEdgesAreHalfOpenSoNoPointBelongsToTwoPanes() {
    let tree = verticalPair()
    let frames = tree.layout(in: full, dividerThickness: 0)
    let boundary = frames[id(1)]!.y + frames[id(1)]!.height
    #expect(tree.pane(atX: 10, y: boundary - 0.5, in: full, dividerThickness: 0) == id(1))
    #expect(tree.pane(atX: 10, y: boundary, in: full, dividerThickness: 0) == id(2))
}

// MARK: - Ratios

@Test func theRatioOfASplitIsReadableByPath() {
    let tree = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.25)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.75)
    #expect(tree.ratio(at: SplitPath()) == 0.25)
    #expect(tree.ratio(at: SplitPath([.second])) == 0.75)
    #expect(tree.ratio(at: SplitPath([.first])) == nil)          // a leaf, not a split
    #expect(tree.ratio(at: SplitPath([.first, .second])) == nil) // runs off the tree
}

@Test func settingARatioLeavesEveryOtherSplitAlone() throws {
    let tree = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    let changed = tree.settingRatio(0.8, at: SplitPath([.second]))
    #expect(changed.ratio(at: SplitPath()) == 0.5)
    #expect(changed.ratio(at: SplitPath([.second])) == 0.8)
    #expect(changed.panes == tree.panes)
}

@Test func settingARatioClampsIt() {
    let tree = horizontalPair()
    #expect(tree.settingRatio(2, at: SplitPath()).ratio(at: SplitPath()) == 0.95)
    #expect(tree.settingRatio(-1, at: SplitPath()).ratio(at: SplitPath()) == 0.05)
}

@Test func settingARatioAtAPathThatIsNotASplitIsANoOp() {
    let tree = horizontalPair()
    #expect(tree.settingRatio(0.9, at: SplitPath([.first])) == tree)
    #expect(PaneTree.leaf(id(1)).settingRatio(0.9, at: SplitPath()) == .leaf(id(1)))
}

// MARK: - Dragging

@Test func draggingADividerToAPositionProducesTheRatioThatPutsItThere() throws {
    let tree = horizontalPair()
    let d = try #require(tree.dividers(in: full, dividerThickness: 1).first)
    // Drop the divider's centre a quarter of the way across. The ratio is measured against the
    // space left after the divider's own thickness (99pt here), which is what `layout` divides.
    let ratio = PaneTree.ratio(forDividerCentre: 25.5, of: d, dividerThickness: 1)
    #expect(abs(ratio - 25.0 / 99.0) < 0.0001)
    // ...and the tree laid out with that ratio really does put the divider back there.
    let moved = tree.settingRatio(ratio, at: d.path)
    #expect(moved.dividers(in: full, dividerThickness: 1)[0].rect.x == 25)
}

@Test func draggingADividerIsAnIdentityAtItsCurrentPosition() throws {
    let tree = PaneTree.leaf(id(1)).splitting(id(1), axis: .vertical, with: id(2), ratio: 0.4)
    let d = try #require(tree.dividers(in: full, dividerThickness: 1).first)
    let centre = d.rect.y + d.rect.height / 2
    let ratio = PaneTree.ratio(forDividerCentre: centre, of: d, dividerThickness: 1)
    #expect(abs(ratio - 0.4) < 0.01)
}

@Test func draggingPastTheEndClampsRatherThanCollapsingAPane() throws {
    let tree = horizontalPair()
    let d = try #require(tree.dividers(in: full, dividerThickness: 1).first)
    #expect(PaneTree.ratio(forDividerCentre: -500, of: d, dividerThickness: 1) == 0.05)
    #expect(PaneTree.ratio(forDividerCentre: 500, of: d, dividerThickness: 1) == 0.95)
}

@Test func draggingANestedDividerIsMeasuredAgainstItsOwnBoundsNotTheWholeView() throws {
    // The nested divider lives in the right-hand half, x from 51 to 100.
    let tree = horizontalPair().splitting(id(2), axis: .horizontal, with: id(3), ratio: 0.5)
    let nested = tree.dividers(in: full, dividerThickness: 1)[1]
    #expect(nested.bounds.x == 51)
    // Its own midpoint is ratio 0.5 of *that* subrect, not of the view.
    let mid = nested.bounds.x + nested.bounds.width / 2
    let ratio = PaneTree.ratio(forDividerCentre: mid, of: nested, dividerThickness: 1)
    #expect(abs(ratio - 0.5) < 0.02)
}

@Test func draggingADividerInAZeroWidthSplitDoesNotDivideByZero() throws {
    let tree = horizontalPair()
    let empty = PaneRect(x: 0, y: 0, width: 1, height: 1)
    let d = try #require(tree.dividers(in: empty, dividerThickness: 1).first)
    #expect(PaneTree.ratio(forDividerCentre: 0.5, of: d, dividerThickness: 1) == 0.5)
}
