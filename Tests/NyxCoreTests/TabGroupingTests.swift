import Testing
@testable import NyxCore

/// Six tabs, none grouped.
private func grouping() -> TabGrouping { TabGrouping(tabCount: 6) }

/// The tab order the caller would end up with after applying a move, as letters, so a test can say
/// what the strip looks like rather than what indices changed.
private func reorder(_ tabs: [String], _ move: TabMove?) -> [String] {
    guard let move, tabs.indices.contains(move.from) else { return tabs }
    var result = tabs
    let moved = result.remove(at: move.from)
    result.insert(moved, at: min(move.to, result.count))
    return result
}

// MARK: - Making groups

@Test func aNewGroupHoldsTheTabItWasMadeFrom() throws {
    var g = grouping()
    let created = g.newGroup(named: "build", colorIndex: 2, fromTabAt: 3)
    let made = try #require(created)
    #expect(g.group(ofTabAt: 3)?.id == made.id)
    #expect(g.group(withID: made.id)?.name == "build")
    #expect(made.move == nil)
    #expect(g.isContiguous)
}

@Test func aTabCanOnlyBeInOneGroup() throws {
    var g = grouping()
    let createdFirst = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let first = try #require(createdFirst)
    let createdSecond = g.newGroup(named: "b", colorIndex: 2, fromTabAt: 0)
    let second = try #require(createdSecond)
    #expect(g.group(ofTabAt: 0)?.id == second.id)
    #expect(g.group(withID: first.id) == nil)   // its last tab left, so it is gone
}

// MARK: - Contiguity, which is the whole invariant

/// A group split in two by an ungrouped tab is not a state the bar should ever have to draw, so it
/// is not a state that can be reached: adding a tab moves it next to the group.
@Test func addingATabFromTheRightMovesItNextToTheGroup() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let group = try #require(createdGroup).id
    _ = g.add(tabAt: 1, toGroup: group)
    let move = g.add(tabAt: 4, toGroup: group)
    #expect(move == TabMove(from: 4, to: 2))
    #expect(reorder(["A", "B", "C", "D", "E", "F"], move) == ["A", "B", "E", "C", "D", "F"])
    #expect(g.range(ofGroup: group) == 0..<3)
    #expect(g.isContiguous)
}

@Test func addingATabFromTheLeftMovesItToTheEndOfTheGroup() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 3)
    let group = try #require(createdGroup).id
    _ = g.add(tabAt: 4, toGroup: group)
    let move = g.add(tabAt: 0, toGroup: group)
    #expect(move == TabMove(from: 0, to: 4))
    #expect(reorder(["A", "B", "C", "D", "E", "F"], move) == ["B", "C", "D", "E", "A", "F"])
    #expect(g.range(ofGroup: group) == 2..<5)
    #expect(g.isContiguous)
}

@Test func addingATabAlreadyInTheGroupChangesNothing() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 2)
    let group = try #require(createdGroup).id
    #expect(g.add(tabAt: 2, toGroup: group) == nil)
    #expect(g.range(ofGroup: group) == 2..<3)
}

/// Moving a tab between two groups leaves both contiguous in one move: taking it out closes the gap
/// behind it.
@Test func movingATabBetweenGroupsLeavesBothWhole() throws {
    var g = grouping()
    let createdA = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let a = try #require(createdA).id
    _ = g.add(tabAt: 1, toGroup: a)
    _ = g.add(tabAt: 2, toGroup: a)
    let createdB = g.newGroup(named: "b", colorIndex: 2, fromTabAt: 4)
    let b = try #require(createdB).id
    _ = g.add(tabAt: 1, toGroup: b)
    #expect(g.isContiguous)
    #expect(g.range(ofGroup: a)?.count == 2)
    #expect(g.range(ofGroup: b)?.count == 2)
}

/// Taking a tab out of the *middle* of a run would split the group around it, so it moves clear.
@Test func removingATabFromTheMiddleMovesItClearOfTheGroup() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let group = try #require(createdGroup).id
    _ = g.add(tabAt: 1, toGroup: group)
    _ = g.add(tabAt: 2, toGroup: group)
    let move = g.removeFromGroup(tabAt: 1)
    #expect(move == TabMove(from: 1, to: 2))
    #expect(reorder(["A", "B", "C", "D", "E", "F"], move) == ["A", "C", "B", "D", "E", "F"])
    #expect(g.range(ofGroup: group) == 0..<2)
    #expect(g.group(ofTabAt: 2) == nil)
    #expect(g.isContiguous)
}

@Test func removingATabFromTheEndOfARunNeedsNoMove() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let group = try #require(createdGroup).id
    _ = g.add(tabAt: 1, toGroup: group)
    #expect(g.removeFromGroup(tabAt: 1) == nil)
    #expect(g.range(ofGroup: group) == 0..<1)
    #expect(g.isContiguous)
}

/// An empty group would leave a header over nothing and a name in "Add to Group" that adds
/// to nowhere.
@Test func aGroupDisappearsWithItsLastTab() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 2)
    let group = try #require(createdGroup).id
    _ = g.removeFromGroup(tabAt: 2)
    #expect(g.groups.isEmpty)
    #expect(g.group(withID: group) == nil)
}

@Test func closingTheLastTabOfAGroupDeletesTheGroup() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 2)
    let group = try #require(createdGroup).id
    g.tabRemoved(at: 2)
    #expect(g.group(withID: group) == nil)
    #expect(g.tabCount == 5)
}

// MARK: - Keeping up with the strip

@Test func anInsertedTabStartsUngroupedAndShiftsTheRest() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 2)
    let group = try #require(createdGroup).id
    g.tabInserted(at: 0)
    #expect(g.group(ofTabAt: 0) == nil)
    #expect(g.range(ofGroup: group) == 3..<4)
}

@Test func aBatchCloseRemovesEveryTabItNames() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 4)
    let group = try #require(createdGroup).id
    g.tabsRemoved(at: [0, 2])
    #expect(g.tabCount == 4)
    #expect(g.range(ofGroup: group) == 2..<3)
}

// MARK: - Names, colours and collapsing

@Test func aGroupCanBeRenamedRecolouredAndCollapsed() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let group = try #require(createdGroup).id
    g.rename(group: group, to: "deploy")
    g.setColor(5, forGroup: group)
    g.toggleCollapsed(group: group)
    #expect(g.group(withID: group)?.name == "deploy")
    #expect(g.group(withID: group)?.colorIndex == 5)
    #expect(g.group(withID: group)?.isCollapsed == true)
    g.toggleCollapsed(group: group)
    #expect(g.group(withID: group)?.isCollapsed == false)
}

/// A blank name would leave a group nobody can point at in a menu.
@Test func aGroupCannotBeRenamedToNothing() throws {
    var g = grouping()
    let createdGroup = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)
    let group = try #require(createdGroup).id
    g.rename(group: group, to: "")
    #expect(g.group(withID: group)?.name == "a")
}

@Test func operationsOnIndicesOutsideTheStripDoNothing() {
    var g = grouping()
    let made = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 99)
    let added = g.add(tabAt: 0, toGroup: 42)
    let removed = g.removeFromGroup(tabAt: 0)
    #expect(made == nil)
    #expect(added == nil)
    #expect(removed == nil)
    #expect(g.groups.isEmpty)
}
