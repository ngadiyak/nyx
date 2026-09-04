import Testing
@testable import NyxCore

private let m = TabBarMetrics.standard
private let barHeight = 28.0

// MARK: - Widths

@Test func oneTabTakesAtMostTheMaximumWidth() {
    #expect(TabBarGeometry.tabWidth(barWidth: 1200, tabCount: 1) == m.maxTabWidth)
}

@Test func tabsShareTheBarEquallyBelowTheMaximum() {
    #expect(TabBarGeometry.tabWidth(barWidth: 600, tabCount: 4) == 150)
}

/// The bug this replaces: a minimum width made tabs run off the right-hand edge once enough were
/// open, and a tab past the edge cannot be clicked at all. However many tabs there are, they must
/// still all fit inside the bar.
@Test func tabsAlwaysFitInsideTheBarHoweverManyThereAre() {
    for count in [2, 12, 40, 200] {
        let width = TabBarGeometry.tabWidth(barWidth: 900, tabCount: count)
        #expect(width * Double(count) <= 900.0001, "\(count) tabs overflow the bar")
        let last = TabBarGeometry.tabRect(index: count - 1, barWidth: 900, barHeight: barHeight, tabCount: count)
        #expect(last.x + last.width <= 900.0001)
    }
}

@Test func anEmptyOrZeroWidthBarHasNoTabWidth() {
    #expect(TabBarGeometry.tabWidth(barWidth: 900, tabCount: 0) == 0)
    #expect(TabBarGeometry.tabWidth(barWidth: 0, tabCount: 3) == 0)
}

@Test func tabsAreLaidOutLeftToRightWithoutGapsOrOverlap() {
    let count = 5
    var previousEnd = 0.0
    for i in 0..<count {
        let r = TabBarGeometry.tabRect(index: i, barWidth: 700, barHeight: barHeight, tabCount: count)
        #expect(r.x == previousEnd)
        #expect(r.height == barHeight)
        previousEnd = r.x + r.width
    }
}

// MARK: - Parts of a tab

@Test func theCloseButtonSitsInsideTheTabsRightEdge() {
    let tab = TabBarGeometry.tabRect(index: 0, barWidth: 400, barHeight: barHeight, tabCount: 2)
    let close = try! #require(TabBarGeometry.closeRect(in: tab))
    #expect(close.x + close.width <= tab.x + tab.width)
    #expect(close.x > tab.x)
    #expect(close.y >= tab.y)
    #expect(close.y + close.height <= tab.y + tab.height)
}

/// Once tabs shrink far enough the close button goes, and the title keeps the room.
///
/// The threshold is deliberately generous rather than "the button physically fits": at twenty tabs
/// a bar of twenty identical `×` glyphs is one you cannot navigate, and the tab is there to be
/// identified before it is closed. ⌘W still closes.
@Test func aTabTooNarrowForACloseButtonHasNone() {
    let roomy = PaneRect(x: 0, y: 0, width: 140, height: barHeight)
    let cramped = PaneRect(x: 0, y: 0, width: 60, height: barHeight)
    let tiny = PaneRect(x: 0, y: 0, width: 20, height: barHeight)
    #expect(TabBarGeometry.closeRect(in: roomy) != nil)
    #expect(TabBarGeometry.closeRect(in: cramped) == nil)
    #expect(TabBarGeometry.closeRect(in: tiny) == nil)
}

@Test func theIndicatorSitsInsideTheTabsLeftEdge() {
    let tab = PaneRect(x: 100, y: 0, width: 150, height: barHeight)
    let dot = TabBarGeometry.indicatorRect(in: tab)
    #expect(dot.x >= tab.x)
    #expect(dot.x + dot.width < tab.x + tab.width)
}

@Test func theTitleGivesWayToTheIndicatorAndTheCloseButton() {
    let tab = PaneRect(x: 0, y: 0, width: 200, height: barHeight)
    let without = TabBarGeometry.titleRect(in: tab, hasIndicator: false)
    let with = TabBarGeometry.titleRect(in: tab, hasIndicator: true)
    #expect(with.x > without.x)
    #expect(with.width < without.width)

    let close = try! #require(TabBarGeometry.closeRect(in: tab))
    #expect(without.x + without.width <= close.x)
}

/// A title box with a negative width would be a crash or a garbled draw, depending on the API.
@Test func theTitleBoxIsNeverNegative() {
    for width in [0.0, 4, 12, 21, 30, 64] {
        let tab = PaneRect(x: 0, y: 0, width: width, height: barHeight)
        #expect(TabBarGeometry.titleRect(in: tab, hasIndicator: true).width >= 0)
        #expect(TabBarGeometry.titleRect(in: tab, hasIndicator: false).width >= 0)
    }
}

// MARK: - Clicks

@Test func aClickInTheBodyOfATabSelectsIt() {
    #expect(TabBarGeometry.hit(atX: 10, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(0))
    #expect(TabBarGeometry.hit(atX: 210, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(1))
    #expect(TabBarGeometry.hit(atX: 410, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(2))
}

@Test func aClickOnTheCloseButtonClosesThatTabRatherThanSelectingIt() {
    let tab = TabBarGeometry.tabRect(index: 1, barWidth: 600, barHeight: barHeight, tabCount: 3)
    let close = try! #require(TabBarGeometry.closeRect(in: tab))
    let hit = TabBarGeometry.hit(atX: close.x + close.width / 2, y: close.y + close.height / 2,
                                 barWidth: 600, barHeight: barHeight, tabCount: 3)
    #expect(hit == .close(1))
}

/// The boundary between two tabs must belong to exactly one of them, and the click just left of a
/// close button must still select rather than close.
@Test func theEdgesBetweenTabsAndAroundTheCloseButtonAreUnambiguous() {
    let width = TabBarGeometry.tabWidth(barWidth: 600, tabCount: 3)
    #expect(TabBarGeometry.hit(atX: width - 0.5, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(0))
    #expect(TabBarGeometry.hit(atX: width, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(1))

    let tab = TabBarGeometry.tabRect(index: 0, barWidth: 600, barHeight: barHeight, tabCount: 3)
    let close = try! #require(TabBarGeometry.closeRect(in: tab))
    #expect(TabBarGeometry.hit(atX: close.x - 1, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == .select(0))
}

@Test func aClickPastTheLastTabOrOutsideTheBarHitsNothing() {
    // Two tabs at the maximum width leave empty bar to their right.
    #expect(TabBarGeometry.hit(atX: 800, y: 14, barWidth: 1200, barHeight: barHeight, tabCount: 2) == nil)
    #expect(TabBarGeometry.hit(atX: -1, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 3) == nil)
    #expect(TabBarGeometry.hit(atX: 10, y: 40, barWidth: 600, barHeight: barHeight, tabCount: 3) == nil)
    #expect(TabBarGeometry.hit(atX: 10, y: 14, barWidth: 600, barHeight: barHeight, tabCount: 0) == nil)
}

/// With tabs too narrow for a close button, every click selects -- there is no invisible close
/// target to hit by accident.
@Test func aClickOnAVeryNarrowTabAlwaysSelects() {
    for x in stride(from: 1.0, to: 40.0, by: 3.0) {
        let hit = TabBarGeometry.hit(atX: x, y: 14, barWidth: 400, barHeight: barHeight, tabCount: 40)
        #expect(hit != nil)
        if case .close = hit { Issue.record("a tab with no close button reported a close at x=\(x)") }
    }
}

// MARK: - When the bar runs out of room

/// Twenty tabs used to render as twenty identical close buttons and nothing else: the title got
/// whatever was left after the close button took its share, which was nothing. A tab exists to be
/// identified first and closed second.
@Test func aCrowdedTabKeepsItsTitleAndDropsItsCloseButton() {
    let tab = TabBarGeometry.tabRect(index: 0, barWidth: 900, barHeight: 28, tabCount: 20)
    #expect(TabBarGeometry.closeRect(in: tab) == nil)
    #expect(TabBarGeometry.titleRect(in: tab, hasIndicator: false).width > 20)
}

@Test func aRoomyTabKeepsBoth() {
    let tab = TabBarGeometry.tabRect(index: 0, barWidth: 900, barHeight: 28, tabCount: 4)
    #expect(TabBarGeometry.closeRect(in: tab) != nil)
    #expect(TabBarGeometry.titleRect(in: tab, hasIndicator: false).width > 100)
}

/// The `+` is how a tab gets opened with the mouse. Dropping it when the bar is busy takes it away
/// exactly when reaching for it any other way is hardest.
@Test func theNewTabButtonSurvivesACrowdedBar() {
    for count in [1, 8, 20, 60] {
        let rect = TabBarGeometry.trailingRect(buttonWidth: 26, barWidth: 900, barHeight: 28,
                                               slotCount: count, leading: 120, headerHeight: 0)
        #expect(rect != nil, "\(count) tabs")
        #expect(rect?.x == 900 - 26)
    }
}

/// Even so, the tabs must not run under it.
@Test func tabsStopBeforeTheNewTabButton() {
    let last = TabBarGeometry.tabRect(index: 19, barWidth: 900, barHeight: 28, tabCount: 20)
    #expect(last.x + last.width <= 900)
}
