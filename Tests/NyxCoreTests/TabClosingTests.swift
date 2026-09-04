import Testing
@testable import NyxCore

// MARK: - Which tabs go

@Test func closeOthersNamesEveryTabButOne() {
    #expect(TabClosing.others(than: 2, tabCount: 5) == [0, 1, 3, 4])
}

@Test func closeOthersOnALoneTabClosesNothing() {
    #expect(TabClosing.others(than: 0, tabCount: 1).isEmpty)
}

@Test func closeToTheRightNamesOnlyWhatFollows() {
    #expect(TabClosing.toTheRight(of: 1, tabCount: 4) == [2, 3])
    #expect(TabClosing.toTheRight(of: 3, tabCount: 4).isEmpty)
}

@Test func anIndexOutsideTheStripNamesNothing() {
    #expect(TabClosing.others(than: 9, tabCount: 3).isEmpty)
    #expect(TabClosing.toTheRight(of: -1, tabCount: 3).isEmpty)
}

// MARK: - What is selected afterwards

/// A tab that survives keeps its tab -- at whatever index it has slid down to.
@Test func aSurvivingSelectionFollowsItsTab() {
    #expect(TabClosing.selectionAfterClosing([0, 1], selected: 3, tabCount: 5) == 1)
    #expect(TabClosing.selectionAfterClosing([3, 4], selected: 1, tabCount: 5) == 1)
}

@Test func closingOthersLeavesTheKeptTabSelected() {
    #expect(TabClosing.selectionAfterClosing(TabClosing.others(than: 2, tabCount: 5),
                                             selected: 4, tabCount: 5) == 0)
}

/// "Close to the Right" from a tab left of the selection takes the selection with it; the nearest
/// survivor is then the one it named.
@Test func aClosedSelectionLandsOnTheNearestSurvivorToItsRight() {
    #expect(TabClosing.selectionAfterClosing([1, 2], selected: 1, tabCount: 5) == 1)
}

@Test func aClosedSelectionWithNothingToItsRightLandsOnTheLast() {
    #expect(TabClosing.selectionAfterClosing(TabClosing.toTheRight(of: 1, tabCount: 5),
                                             selected: 4, tabCount: 5) == 1)
}

@Test func closingEverythingLeavesNothingSelected() {
    #expect(TabClosing.selectionAfterClosing([0, 1, 2], selected: 1, tabCount: 3) == nil)
}

@Test func closingNothingLeavesTheSelectionAlone() {
    #expect(TabClosing.selectionAfterClosing([], selected: 2, tabCount: 4) == 2)
}

@Test func indicesOutsideTheStripAreIgnoredRatherThanCountedAsClosed() {
    #expect(TabClosing.selectionAfterClosing([7, 0], selected: 2, tabCount: 4) == 1)
}

// MARK: - Titles

/// The whole point of renaming a tab: it keeps its name while its shell goes on setting titles.
@Test func aCustomTitleBeatsWhatTheProgramSets() {
    #expect(TabTitle.resolve(custom: "deploy", osc: "zsh", fallback: "zsh — nyx") == "deploy")
}

@Test func withoutACustomTitleTheProgramsTitleWins() {
    #expect(TabTitle.resolve(custom: nil, osc: "vim", fallback: "zsh — nyx") == "vim")
}

@Test func withNeitherTheFallbackIsUsed() {
    #expect(TabTitle.resolve(custom: nil, osc: "", fallback: "zsh — nyx") == "zsh — nyx")
}

/// "Reset Title" clears the custom name; an empty one is no name at all rather than a blank tab.
@Test func anEmptyCustomTitleIsNoTitle() {
    #expect(TabTitle.resolve(custom: "", osc: "vim", fallback: "x") == "vim")
}
