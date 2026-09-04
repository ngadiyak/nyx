import Testing
@testable import NyxCore

private let metrics = TabBarMetrics.standard

/// Five tabs with tabs 1 and 2 in one group.
private func grouped(collapsed: Bool = false) -> TabGrouping {
    var g = TabGrouping(tabCount: 5)
    guard let made = g.newGroup(named: "build", colorIndex: 2, fromTabAt: 1) else { return g }
    _ = g.add(tabAt: 2, toGroup: made.id)
    if collapsed { g.setCollapsed(true, forGroup: made.id) }
    return g
}

private func groupID(_ g: TabGrouping) -> Int { g.groups.first?.id ?? -1 }

// MARK: - Slots

@Test func withNoGroupsEverySlotIsATab() {
    let slots = TabBarGeometry.slots(tabCount: 3, grouping: TabGrouping(tabCount: 3))
    #expect(slots == [.tab(index: 0, group: nil), .tab(index: 1, group: nil), .tab(index: 2, group: nil)])
}

/// An expanded group keeps a slot per tab and adds one for its own name, in front of them.
///
/// The name used to live in a row above the bar, which spent vertical space across the whole window
/// to label two tabs and still read as unrelated to them. In the row, in front of its own tabs, it
/// is unmistakably theirs -- and it is the control that collapses them.
@Test func anExpandedGroupIsLabelledInFrontOfItsTabs() {
    let g = grouped()
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: g)
    #expect(slots.count == 6)
    #expect(slots[0] == .tab(index: 0, group: nil))
    #expect(slots[1] == .groupLabel(id: groupID(g)))
    #expect(slots[2] == .tab(index: 1, group: groupID(g)))
    #expect(slots[4] == .tab(index: 3, group: nil))
}

/// The label is announced once, however many tabs the group holds.
@Test func aGroupIsLabelledOnlyOnce() {
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: grouped())
    let labels = slots.filter { if case .groupLabel = $0 { return true } else { return false } }
    #expect(labels.count == 1)
}

/// The bar is one height whatever the groups are doing -- it used to grow a row.
@Test func groupsDoNotChangeTheHeightOfTheBar() {
    #expect(TabBarGeometry.barHeight(base: 28, grouping: grouped()) == 28)
    #expect(TabBarGeometry.barHeight(base: 28, grouping: grouped(collapsed: true)) == 28)
    #expect(TabBarGeometry.barHeight(base: 28, grouping: TabGrouping(tabCount: 3)) == 28)
}

/// The point of collapsing: however many tabs it holds, it takes one chip.
@Test func aCollapsedGroupTakesOneSlotHoweverManyTabsItHolds() {
    let g = grouped(collapsed: true)
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: g)
    #expect(slots == [.tab(index: 0, group: nil),
                      .collapsedGroup(id: groupID(g), tabCount: 2),
                      .tab(index: 3, group: nil),
                      .tab(index: 4, group: nil)])
}

// MARK: - Where things sit

/// The band covers the group's label and every one of its tabs, and nothing else: a band that
/// stopped short of the label would leave the name floating outside the thing it names.
@Test func aBandSpansTheLabelAndTheGroupsTabs() {
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: grouped())
    let headers = TabBarGeometry.groupHeaders(slots: slots)
    #expect(headers.count == 1)
    #expect(headers[0].first == 1)   // the label
    #expect(headers[0].last == 3)    // through the group's second tab

    let rect = TabBarGeometry.groupBandRect(fromSlot: 1, toSlot: 3, slotCount: 5,
                                            barWidth: 500, barHeight: 28)
    #expect(rect.x == 100)
    #expect(rect.width == 300)   // the label plus the group's two tabs
    #expect(rect.y == 0)
    #expect(rect.height == 28)   // full height: there is no separate header row any more
}

@Test func aCollapsedGroupHasNoHeader() {
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: grouped(collapsed: true))
    #expect(TabBarGeometry.groupHeaders(slots: slots).isEmpty)
}

/// Two groups next to each other must not be drawn as one strip.
@Test func adjacentGroupsGetSeparateHeaders() {
    var g = TabGrouping(tabCount: 4)
    guard let a = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0),
          let b = g.newGroup(named: "b", colorIndex: 2, fromTabAt: 1) else { return }
    let headers = TabBarGeometry.groupHeaders(slots: TabBarGeometry.slots(tabCount: 4, grouping: g))
    #expect(headers.count == 2)
    #expect(headers[0].id == a.id)
    #expect(headers[1].id == b.id)
}

/// The invariant the ungrouped bar always had, now over slots: everything fits inside the bar
/// however many there are.
@Test func everySlotFitsInsideTheBarAtAnyCount() {
    for count in 1...40 {
        let last = TabBarGeometry.slotRect(index: count - 1, slotCount: count, barWidth: 800,
                                           barHeight: 28, headerHeight: 0)
        #expect(last.x + last.width <= 800.001, "\(count) slots overflowed")
    }
}

// MARK: - Clicks

@Test func clickingACollapsedChipExpandsItsGroup() {
    let g = grouped(collapsed: true)
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: g)
    // Four slots across 400pt: the chip is the second, 100...200.
    let hit = TabBarGeometry.hit(atX: 150, y: 20, slots: slots, barWidth: 400, barHeight: 28,
                                 headerHeight: 0)
    #expect(hit == .expandGroup(groupID(g)))
}

@Test func clickingTheHeaderRowMeansTheGroup() {
    let g = grouped()
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: g)
    let hit = TabBarGeometry.hit(atX: 150, y: 5, slots: slots, barWidth: 500, barHeight: 42,
                                 headerHeight: 14)
    #expect(hit == .groupHeader(groupID(g)))
}

/// A click on a grouped tab means the tab's own index -- not its position in the bar, which the
/// group's label and any collapsed group to its left have shifted.
@Test func aClickOnAGroupedTabSelectsThatTab() {
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: grouped())
    // Six slots across 600pt: [tab 0][label][tab 1][tab 2][tab 3][tab 4].
    let hit = TabBarGeometry.hit(atX: 250, y: 14, slots: slots, barWidth: 600, barHeight: 28,
                                 headerHeight: 0)
    #expect(hit == .select(1))
}

/// The name is the collapse control, and it is the one part of a group that is obviously about the
/// group rather than about one of its tabs.
@Test func aClickOnTheGroupsNameCollapsesIt() {
    let g = grouped()
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: g)
    let hit = TabBarGeometry.hit(atX: 150, y: 14, slots: slots, barWidth: 600, barHeight: 28,
                                 headerHeight: 0)
    #expect(hit == .groupHeader(groupID(g)))
}

@Test func aClickAfterACollapsedGroupSelectsTheRightTab() {
    let slots = TabBarGeometry.slots(tabCount: 5, grouping: grouped(collapsed: true))
    // Four slots across 400pt; the third is tab 3.
    let hit = TabBarGeometry.hit(atX: 250, y: 20, slots: slots, barWidth: 400, barHeight: 28,
                                 headerHeight: 0)
    #expect(hit == .select(3))
}

/// The rule the ungrouped bar already had, still true of a grouped one.
@Test func aTabTooNarrowForACloseButtonShowsNone() {
    let slot = TabBarGeometry.slotRect(index: 0, slotCount: 40, barWidth: 400, barHeight: 28,
                                       headerHeight: 0)
    #expect(TabBarGeometry.closeRect(in: slot) == nil)
}
