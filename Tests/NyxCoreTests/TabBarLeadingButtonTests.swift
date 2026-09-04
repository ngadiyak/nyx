import Testing
@testable import NyxCore

private let metrics = TabBarMetrics.standard
/// A `+` and a tab-list button, then three quick actions.
private let buttons: [Double] = [26, 26, 60, 60, 60]

private func slots(_ count: Int) -> [TabBarGeometry.Slot] {
    (0..<count).map { .tab(index: $0, group: nil) }
}

private func rects(_ widths: [Double], barWidth: Double, tabs: Int) -> [PaneRect] {
    TabBarGeometry.leadingRects(buttonWidths: widths, barWidth: barWidth, barHeight: 28,
                                slotCount: tabs, headerHeight: 0)
}

private func leading(_ widths: [Double], barWidth: Double, tabs: Int) -> Double {
    TabBarGeometry.leadingWidth(buttonWidths: widths, barWidth: barWidth, barHeight: 28,
                                slotCount: tabs, headerHeight: 0)
}

// MARK: - Fitting

@Test func theButtonsSitInARowFromTheLeftEdge() {
    let laid = rects(buttons, barWidth: 900, tabs: 3)
    #expect(laid.count == 5)
    #expect(laid[0].x == 0)
    #expect(laid[1].x == 26)
    #expect(laid[2].x == 52)
    #expect(laid.allSatisfy { $0.height == 28 })
}

/// The tabs are what the bar is for: a button that would squeeze them below a usable width is not
/// shown at all, rather than shown at the cost of unreadable tabs.
@Test func overflowingButtonsAreDroppedRatherThanSqueezingTheTabs() {
    let laid = rects(buttons, barWidth: 300, tabs: 6)
    // Six tabs need 240pt, leaving 60pt: the two built-ins fit and nothing else does.
    #expect(laid.count == 2)
    #expect(leading(buttons, barWidth: 300, tabs: 6) == 52)
}

@Test func withNoRoomAtAllNoButtonIsShown() {
    #expect(rects(buttons, barWidth: 200, tabs: 20).isEmpty)
    #expect(leading(buttons, barWidth: 200, tabs: 20) == 0)
}

/// The invariant worth pinning: the buttons never overlap the first tab, at any tab count.
@Test func theButtonsNeverOverlapTheFirstTab() {
    for count in 1...40 {
        let width = leading(buttons, barWidth: 800, tabs: count)
        let first = TabBarGeometry.slotRect(index: 0, slotCount: count, barWidth: 800, barHeight: 28,
                                            headerHeight: 0, leading: width)
        #expect(first.x >= width - 0.001, "\(count) tabs: first tab started at \(first.x), buttons ended at \(width)")
    }
}

/// And the tabs still fit inside what is left of the bar.
@Test func theTabsStillFitBesideTheButtons() {
    for count in 1...40 {
        let width = leading(buttons, barWidth: 800, tabs: count)
        let last = TabBarGeometry.slotRect(index: count - 1, slotCount: count, barWidth: 800,
                                           barHeight: 28, headerHeight: 0, leading: width)
        #expect(last.x + last.width <= 800.001, "\(count) tabs overflowed the bar")
    }
}

@Test func theButtonsSitBelowTheGroupHeaderRow() {
    let laid = TabBarGeometry.leadingRects(buttonWidths: [26], barWidth: 800, barHeight: 42,
                                           slotCount: 3, headerHeight: 14)
    #expect(laid[0].y == 14)
    #expect(laid[0].height == 28)
}

// MARK: - Clicks

@Test func aClickOnAButtonMeansThatButton() {
    let hit = TabBarGeometry.hit(atX: 30, y: 14, slots: slots(3), barWidth: 800, barHeight: 28,
                                 headerHeight: 0, leadingWidths: buttons)
    #expect(hit == .leadingButton(1))
}

@Test func aClickPastTheButtonsMeansTheFirstTab() {
    let width = leading(buttons, barWidth: 800, tabs: 3)
    let hit = TabBarGeometry.hit(atX: width + 5, y: 14, slots: slots(3), barWidth: 800,
                                 barHeight: 28, headerHeight: 0, leadingWidths: buttons)
    #expect(hit == .select(0))
}

/// A dropped button must not still answer clicks where it would have been.
@Test func aDroppedButtonIsNotClickable() {
    let hit = TabBarGeometry.hit(atX: 100, y: 14, slots: slots(6), barWidth: 300, barHeight: 28,
                                 headerHeight: 0, leadingWidths: buttons)
    #expect(hit != .leadingButton(2))
}

@Test func withNoButtonsTheBarBehavesExactlyAsBefore() {
    let hit = TabBarGeometry.hit(atX: 5, y: 14, slots: slots(3), barWidth: 800, barHeight: 28,
                                 headerHeight: 0)
    #expect(hit == .select(0))
}

// MARK: - The pinned last button

/// The bar's last leading button is the `+` that adds a quick action, and it is the only way to
/// add one from the interface. Dropping it first -- which is what plain overflow does, and did --
/// takes that away exactly when there are enough buttons to fill the bar.
@Test func thePinnedButtonSurvivesOverflowAndTheOthersGoFirst() {
    // The real shape of the bar: the tab-list button, three quick actions, then the 26pt `+`.
    let bar: [Double] = [26, 60, 60, 60, 26]
    // Six tabs need 240pt of a 300pt bar, leaving 60: the tab list, the pinned `+`, nothing else.
    let laid = TabBarGeometry.leadingLayout(buttonWidths: bar, barWidth: 300, barHeight: 28,
                                            slotCount: 6, headerHeight: 0, pinLast: true)
    #expect(laid.map(\.index) == [0, 4])
    #expect(laid.last?.rect.x == 26)          // straight after the buttons that did fit
    #expect(laid.last?.rect.width == 26)

    // Unpinned, the same bar drops the `+` and keeps a quick action nobody asked to keep.
    let plain = TabBarGeometry.leadingLayout(buttonWidths: bar, barWidth: 300, barHeight: 28,
                                             slotCount: 6, headerHeight: 0)
    #expect(plain.map(\.index) == [0])
}

/// A quick action is dropped so the pinned button can be shown, not in addition to it.
@Test func thePinnedButtonTakesItsRoomFromTheOthers() {
    let widths: [Double] = [26, 60, 60, 26]
    let laid = TabBarGeometry.leadingLayout(buttonWidths: widths, barWidth: 400, barHeight: 28,
                                            slotCount: 4, headerHeight: 0, pinLast: true)
    // Four tabs need 160pt, leaving 240: 26 + 60 + 60 + 26 = 172 all fit.
    #expect(laid.map(\.index) == [0, 1, 2, 3])

    let tighter = TabBarGeometry.leadingLayout(buttonWidths: widths, barWidth: 300, barHeight: 28,
                                               slotCount: 4, headerHeight: 0, pinLast: true)
    // 140pt of room: 26 + 60 fits with the pinned 26 reserved; the second quick action does not.
    #expect(tighter.map(\.index) == [0, 1, 3])
}

/// Where a click lands has to agree with what was drawn: the hit test reports the button's own
/// index, not its position among the ones that fit.
@Test func aClickOnThePinnedButtonReportsThePinnedButton() {
    let bar: [Double] = [26, 60, 60, 60, 26]
    let hit = TabBarGeometry.hit(atX: 30, y: 14, slots: slots(6), barWidth: 300, barHeight: 28,
                                 headerHeight: 0, trailingWidth: 26, leadingWidths: bar,
                                 pinLastLeading: true)
    #expect(hit == .leadingButton(4))
}

/// Without pinning, nothing changes: the plain overflow rule is what every other bar layout uses.
@Test func pinningIsOptOut() {
    let laid = TabBarGeometry.leadingLayout(buttonWidths: buttons, barWidth: 300, barHeight: 28,
                                            slotCount: 6, headerHeight: 0)
    #expect(laid.map(\.index) == [0, 1])
}
