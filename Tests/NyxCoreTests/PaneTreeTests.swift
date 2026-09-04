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

@Test func resizingClampsSoAPaneNeverDisappears() {
    let t = PaneTree.leaf(id(1)).splitting(id(1), axis: .horizontal, with: id(2), ratio: 0.5)
    var shrunk = t
    for _ in 0..<50 { shrunk = shrunk.resizing(id(1), direction: .left, by: 0.1) }
    let l = shrunk.layout(in: PaneRect(x: 0, y: 0, width: 1000, height: 10), dividerThickness: 2)
    #expect(l[id(1)]!.width > 0)
    #expect(l[id(2)]!.width > 0)
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
