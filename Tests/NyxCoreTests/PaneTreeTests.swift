import Testing
@testable import NyxCore

private func id(_ n: Int) -> PaneID { PaneID(n) }
private let full = PaneRect(x: 0, y: 0, width: 100, height: 100)

@Test func aSingleLeafFillsTheBounds() {
    let t = PaneTree.leaf(id(1))
    #expect(t.panes == [id(1)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == full)
}

@Test func splittingHorizontallyPutsPanesSideBySide() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.panes == [id(1), id(2)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == PaneRect(x: 0, y: 0, width: 49, height: 100))
    #expect(l[id(2)] == PaneRect(x: 51, y: 0, width: 49, height: 100))
}

@Test func splittingVerticallyStacksPanes() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .vertical, with: id(2), ratio: 0.5)
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)] == PaneRect(x: 0, y: 0, width: 100, height: 49))
    #expect(l[id(2)] == PaneRect(x: 0, y: 51, width: 100, height: 49))
}

@Test func anUnevenRatioSplitsProportionally() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.25)
    let l = t.layout(in: PaneRect(x: 0, y: 0, width: 102, height: 10), dividerThickness: 2)
    #expect(l[id(1)]?.width == 25)
    #expect(l[id(2)]?.width == 75)
}

@Test func splittingASplitOnlyAffectsTheTargetLeaf() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    #expect(t.panes == [id(1), id(2), id(3)])
    let l = t.layout(in: full, dividerThickness: 2)
    #expect(l[id(1)]?.height == 100)
    #expect(l[id(2)]?.height == 49)
    #expect(l[id(3)]?.height == 49)
}

@Test func removingALeafPromotesItsSibling() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.removing(id(2)) == .leaf(id(1)))
    #expect(t.removing(id(1)) == .leaf(id(2)))
}

@Test func removingTheLastLeafEmptiesTheTree() {
    #expect(PaneTree.leaf(id(1)).removing(id(1)) == nil)
}

@Test func removingFromANestedTreeKeepsTheRest() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    let after = t.removing(id(3))
    #expect(after?.panes == [id(1), id(2)])
}

@Test func removingAnAbsentPaneChangesNothing() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.removing(id(99)) == t)
}

@Test func focusMovesToTheGeometricNeighbour() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    #expect(t.neighbour(of: id(1), direction: .right, in: full, dividerThickness: 2) == id(2))
    #expect(t.neighbour(of: id(2), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(1), direction: .left, in: full, dividerThickness: 2) == nil)
    #expect(t.neighbour(of: id(1), direction: .up, in: full, dividerThickness: 2) == nil)
}

@Test func focusCrossesNestedSplits() {
    // 1 on the left; on the right, 2 above 3.
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .vertical, with: id(3), ratio: 0.5)
    #expect(t.neighbour(of: id(2), direction: .down, in: full, dividerThickness: 2) == id(3))
    #expect(t.neighbour(of: id(3), direction: .up, in: full, dividerThickness: 2) == id(2))
    #expect(t.neighbour(of: id(2), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(3), direction: .left, in: full, dividerThickness: 2) == id(1))
    #expect(t.neighbour(of: id(1), direction: .right, in: full, dividerThickness: 2) != nil)
}

@Test func resizingMovesTheDividerAndKeepsTheTotal() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    let wider = t.resizing(id(1), direction: .right, by: 0.1)
    let l = wider.layout(in: PaneRect(x: 0, y: 0, width: 102, height: 10), dividerThickness: 2)
    #expect(l[id(1)]!.width > 50)
    #expect(l[id(1)]!.width + l[id(2)]!.width == 100)
}

/// Three panes chained on one axis: `A | B | C`, built as an outer horizontal split whose `first`
/// is an inner horizontal split of A and B. Resizing A rightwards must move the A/B divider and
/// nothing else -- C is not A's neighbour and its width must not change.
@Test func resizingAChainedSplitMovesOnlyTheAdjacentDivider() {
    let abc = PaneTree.split(
        axis: .horizontal, ratio: 0.5,
        first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(id(1)), second: .leaf(id(2))),
        second: .leaf(id(3))
    )
    let bounds = PaneRect(x: 0, y: 0, width: 1000, height: 10)
    let before = abc.layout(in: bounds, dividerThickness: 2)
    let after = abc.resizing(id(1), direction: .right, by: 0.1).layout(in: bounds, dividerThickness: 2)

    #expect(after[id(1)]!.width > before[id(1)]!.width)
    #expect(after[id(2)]!.width < before[id(2)]!.width)
    #expect(after[id(3)]!.width == before[id(3)]!.width)   // not a neighbour: must not move
}

/// The split that separates a pane from its neighbour is not always the nearest one. B's right-hand
/// neighbour is C, and the divider between them belongs to the OUTER split -- the inner A/B split
/// separates B leftwards, not rightwards. So resizing B rightwards must walk past the inner split.
@Test func resizingWalksPastASplitThatDoesNotSeparateInThatDirection() {
    let abc = PaneTree.split(
        axis: .horizontal, ratio: 0.5,
        first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(id(1)), second: .leaf(id(2))),
        second: .leaf(id(3))
    )
    let bounds = PaneRect(x: 0, y: 0, width: 1000, height: 10)
    let before = abc.layout(in: bounds, dividerThickness: 2)
    let after = abc.resizing(id(2), direction: .right, by: 0.1).layout(in: bounds, dividerThickness: 2)

    #expect(after[id(2)]!.width > before[id(2)]!.width)
    #expect(after[id(3)]!.width < before[id(3)]!.width)
    // Moving the outer divider widens the whole A|B column, so A grows too -- that is what dragging
    // a divider means. What must NOT change is the inner split's own ratio: A and B keep their
    // proportion to each other, taking an equal share of the space C gave up.
    #expect(after[id(1)]!.width - before[id(1)]!.width == after[id(2)]!.width - before[id(2)]!.width)
}

/// A pane at the edge of the tree has no neighbour in that direction, so there is no divider to
/// move and the tree comes back untouched -- rather than the nearest divider moving the wrong way.
@Test func resizingAnEdgePaneAwayFromTheTreeIsANoOp() {
    let abc = PaneTree.split(
        axis: .horizontal, ratio: 0.5,
        first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(id(1)), second: .leaf(id(2))),
        second: .leaf(id(3))
    )
    #expect(abc.resizing(id(1), direction: .left, by: 0.1) == abc)
    #expect(abc.resizing(id(3), direction: .right, by: 0.1) == abc)
}

/// A split on the other axis is transparent to a resize: moving a horizontal divider must not be
/// stopped, or absorbed, by a vertical split sitting between the pane and that divider.
@Test func resizingIgnoresSplitsOnTheOtherAxis() {
    // (A above B) beside C, all inside one horizontal split.
    let t = PaneTree.split(
        axis: .horizontal, ratio: 0.5,
        first: .split(axis: .vertical, ratio: 0.5, first: .leaf(id(1)), second: .leaf(id(2))),
        second: .leaf(id(3))
    )
    let bounds = PaneRect(x: 0, y: 0, width: 1000, height: 100)
    let before = t.layout(in: bounds, dividerThickness: 2)
    let after = t.resizing(id(1), direction: .right, by: 0.1).layout(in: bounds, dividerThickness: 2)

    #expect(after[id(1)]!.width > before[id(1)]!.width)
    #expect(after[id(2)]!.width > before[id(2)]!.width)   // shares the column, so it grows too
    #expect(after[id(1)]!.height == before[id(1)]!.height)  // the vertical divider stays put
}

/// `removing` splices the sibling into the parent's place; the grandparent's own axis and ratio are
/// not the parent's to change. Leaf order alone would not catch a scrambled ratio.
@Test func removingPreservesTheGrandparentsAxisAndRatio() {
    let t = PaneTree.split(
        axis: .vertical, ratio: 0.25,
        first: .leaf(id(1)),
        second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(id(2)), second: .leaf(id(3)))
    )
    #expect(t.removing(id(3)) == .split(axis: .vertical, ratio: 0.25,
                                        first: .leaf(id(1)), second: .leaf(id(2))))
}

/// Below the divider thickness there is no room for either pane, but a zero-area frame must still
/// sit inside the bounds it was laid out in -- a view layer that trusts the origin would otherwise
/// place a pane off the edge of its container.
@Test func degenerateBoundsStillProduceFramesInsideTheBounds() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    let bounds = PaneRect(x: 5, y: 5, width: 1, height: 10)
    for (_, frame) in t.layout(in: bounds, dividerThickness: 2) {
        #expect(frame.x >= bounds.x)
        #expect(frame.x + frame.width <= bounds.x + bounds.width)
        #expect(frame.y >= bounds.y)
        #expect(frame.y + frame.height <= bounds.y + bounds.height)
    }
}

/// Fifty presses in one direction must stop at the clamp rather than pushing the neighbour out of
/// existence. The direction matters: resizing a `first` child *leftwards* is a no-op -- nothing lies
/// to its left -- so it would never reach the clamp and this test would pass without exercising it.
@Test func resizingClampsSoAPaneNeverDisappears() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    var grown = t
    for _ in 0..<50 { grown = grown.resizing(id(1), direction: .right, by: 0.1) }
    #expect(grown == .split(axis: .horizontal, ratio: 0.95, first: .leaf(id(1)), second: .leaf(id(2))))

    let l = grown.layout(in: PaneRect(x: 0, y: 0, width: 1000, height: 10), dividerThickness: 2)
    #expect(l[id(2)]!.width > 0)   // the pane being squeezed still exists

    // And symmetrically from the other side, which drives the ratio down to the lower clamp.
    var shrunk = t
    for _ in 0..<50 { shrunk = shrunk.resizing(id(2), direction: .left, by: 0.1) }
    #expect(shrunk == .split(axis: .horizontal, ratio: 0.05, first: .leaf(id(1)), second: .leaf(id(2))))
    #expect(shrunk.layout(in: PaneRect(x: 0, y: 0, width: 1000, height: 10), dividerThickness: 2)[id(1)]!.width > 0)
}

@Test func layoutNeverProducesNegativeSizes() {
    let t = PaneTree.leaf(id(1))
        .splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
        .splitting(id(2), axis: .horizontal, with: id(3), ratio: 0.5)
    let l = t.layout(in: PaneRect(x: 0, y: 0, width: 4, height: 4), dividerThickness: 2)
    for (_, r) in l {
        #expect(r.width >= 0 && r.height >= 0)
    }
}
