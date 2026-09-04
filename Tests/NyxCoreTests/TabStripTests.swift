import Testing
@testable import NyxCore

/// A stand-in for the tab bar's font: every character is one unit wide.
private let monospace: (String) -> Double = { Double($0.count) }

// MARK: - Bar visibility

@Test func autoHidesTheBarUntilThereIsASecondTab() {
    #expect(TabStrip.isBarVisible(.auto, tabCount: 1) == false)
    #expect(TabStrip.isBarVisible(.auto, tabCount: 2) == true)
}

@Test func alwaysAndNeverIgnoreTheTabCount() {
    #expect(TabStrip.isBarVisible(.always, tabCount: 1) == true)
    #expect(TabStrip.isBarVisible(.always, tabCount: 5) == true)
    #expect(TabStrip.isBarVisible(.never, tabCount: 1) == false)
    #expect(TabStrip.isBarVisible(.never, tabCount: 5) == false)
}

@Test func anEmptyStripHasNoBar() {
    #expect(TabStrip.isBarVisible(.auto, tabCount: 0) == false)
}

// MARK: - ⌘1…⌘9

@Test func commandNumbersSelectByPosition() {
    #expect(TabStrip.index(forCommandNumber: 1, tabCount: 4) == 0)
    #expect(TabStrip.index(forCommandNumber: 3, tabCount: 4) == 2)
}

@Test func aCommandNumberPastTheEndSelectsNothing() {
    #expect(TabStrip.index(forCommandNumber: 5, tabCount: 4) == nil)
    #expect(TabStrip.index(forCommandNumber: 8, tabCount: 4) == nil)
}

@Test func commandNineIsTheLastTabWhateverTheCount() {
    #expect(TabStrip.index(forCommandNumber: 9, tabCount: 3) == 2)
    // Exactly nine: the ninth tab and the last tab are the same one.
    #expect(TabStrip.index(forCommandNumber: 9, tabCount: 9) == 8)
    // Ten or more: the last tab, not the ninth.
    #expect(TabStrip.index(forCommandNumber: 9, tabCount: 10) == 9)
    #expect(TabStrip.index(forCommandNumber: 9, tabCount: 12) == 11)
}

@Test func commandEightStillMeansTheEighthTabWithMoreThanNine() {
    #expect(TabStrip.index(forCommandNumber: 8, tabCount: 12) == 7)
}

@Test func numbersOutsideOneToNineSelectNothing() {
    #expect(TabStrip.index(forCommandNumber: 0, tabCount: 4) == nil)
    #expect(TabStrip.index(forCommandNumber: 10, tabCount: 12) == nil)
}

@Test func nothingIsSelectableWithNoTabs() {
    #expect(TabStrip.index(forCommandNumber: 1, tabCount: 0) == nil)
    #expect(TabStrip.index(forCommandNumber: 9, tabCount: 0) == nil)
}

// MARK: - Cycling

@Test func cyclingWalksForwardsAndBackwards() {
    #expect(TabStrip.next(after: 0, tabCount: 3) == 1)
    #expect(TabStrip.next(after: 1, tabCount: 3) == 2)
    #expect(TabStrip.previous(before: 2, tabCount: 3) == 1)
    #expect(TabStrip.previous(before: 1, tabCount: 3) == 0)
}

@Test func cyclingWrapsAtBothEnds() {
    #expect(TabStrip.next(after: 2, tabCount: 3) == 0)
    #expect(TabStrip.previous(before: 0, tabCount: 3) == 2)
}

@Test func cyclingWithOneTabStaysPut() {
    #expect(TabStrip.next(after: 0, tabCount: 1) == 0)
    #expect(TabStrip.previous(before: 0, tabCount: 1) == 0)
}

// MARK: - What is selected after a close

@Test func closingATabToTheLeftShiftsTheSelectionDown() {
    #expect(TabStrip.selectionAfterClosing(0, selected: 2, tabCount: 4) == 1)
}

@Test func closingATabToTheRightLeavesTheSelectionAlone() {
    #expect(TabStrip.selectionAfterClosing(3, selected: 1, tabCount: 4) == 1)
}

@Test func closingTheSelectedTabSelectsTheOneThatTakesItsPlace() {
    #expect(TabStrip.selectionAfterClosing(1, selected: 1, tabCount: 4) == 1)
}

@Test func closingTheSelectedLastTabSelectsTheNewLastTab() {
    #expect(TabStrip.selectionAfterClosing(3, selected: 3, tabCount: 4) == 2)
}

@Test func closingTheOnlyTabLeavesNothingSelected() {
    #expect(TabStrip.selectionAfterClosing(0, selected: 0, tabCount: 1) == nil)
}

// MARK: - Indicators

@Test func outputInAnUnselectedTabShowsTheDot() {
    #expect(TabIndicator.none.afterOutput(isSelected: false) == .activity)
}

@Test func outputInTheSelectedTabShowsNothing() {
    #expect(TabIndicator.none.afterOutput(isSelected: true) == .none)
    #expect(TabIndicator.activity.afterOutput(isSelected: true) == .none)
}

@Test func aBellOutranksTheActivityDot() {
    #expect(TabIndicator.activity.afterBell(isSelected: false) == .bell)
    // Output after a bell must not demote it back to a dot.
    #expect(TabIndicator.bell.afterOutput(isSelected: false) == .bell)
}

@Test func aBellInTheSelectedTabShowsNothing() {
    #expect(TabIndicator.none.afterBell(isSelected: true) == .none)
}

@Test func selectingATabClearsBothIndicators() {
    #expect(TabIndicator.activity.afterSelection() == .none)
    #expect(TabIndicator.bell.afterSelection() == .none)
}

// MARK: - Fallback titles

@Test func theFallbackTitleIsTheProgramAndWhereItIsRunning() {
    #expect(TabTitle.fallback(processName: "vim", directory: "/Users/nik/projects/nyx",
                              home: "/Users/nik") == "vim — nyx")
}

@Test func theHomeDirectoryIsShownAsATilde() {
    #expect(TabTitle.fallback(processName: "zsh", directory: "/Users/nik", home: "/Users/nik") == "zsh — ~")
    #expect(TabTitle.fallback(processName: "zsh", directory: "/Users/nik/", home: "/Users/nik") == "zsh — ~")
}

@Test func theRootDirectoryIsItsOwnLastComponent() {
    #expect(TabTitle.fallback(processName: "zsh", directory: "/", home: "/Users/nik") == "zsh — /")
}

@Test func aMissingPieceIsLeftOutRatherThanShownEmpty() {
    #expect(TabTitle.fallback(processName: "zsh", directory: nil, home: "/Users/nik") == "zsh")
    #expect(TabTitle.fallback(processName: nil, directory: "/tmp/work", home: "/Users/nik") == "work")
    #expect(TabTitle.fallback(processName: nil, directory: nil, home: "/Users/nik") == "")
    #expect(TabTitle.fallback(processName: "  ", directory: "", home: "/Users/nik") == "")
}

// MARK: - Middle truncation

@Test func aTitleThatFitsIsLeftAlone() {
    #expect(TabTitle.truncatedInMiddle("zsh", maxWidth: 10, measure: monospace) == "zsh")
    // Exactly the available width still fits.
    #expect(TabTitle.truncatedInMiddle("zsh", maxWidth: 3, measure: monospace) == "zsh")
}

@Test func aLongTitleLosesItsMiddle() {
    #expect(TabTitle.truncatedInMiddle("abcdefgh", maxWidth: 5, measure: monospace) == "ab…gh")
    #expect(TabTitle.truncatedInMiddle("abcdefgh", maxWidth: 4, measure: monospace) == "ab…h")
}

@Test func truncationKeepsBothEndsOfTheTitle() {
    let truncated = TabTitle.truncatedInMiddle("vim — nyx", maxWidth: 6, measure: monospace)
    #expect(truncated.hasPrefix("vi"))
    #expect(truncated.hasSuffix("yx"))
    #expect(monospace(truncated) <= 6)
}

@Test func anImpossiblyNarrowTabGetsAnEllipsisOrNothing() {
    #expect(TabTitle.truncatedInMiddle("abcdefgh", maxWidth: 1, measure: monospace) == "…")
    #expect(TabTitle.truncatedInMiddle("abcdefgh", maxWidth: 0.5, measure: monospace) == "")
    #expect(TabTitle.truncatedInMiddle("abcdefgh", maxWidth: 0, measure: monospace) == "")
}

@Test func truncationNeverReturnsSomethingWiderThanAsked() {
    let title = "a very long tab title that will not fit anywhere"
    for width in stride(from: 1.0, through: 20.0, by: 1.0) {
        #expect(monospace(TabTitle.truncatedInMiddle(title, maxWidth: width, measure: monospace)) <= width)
    }
}

@Test func aSingleCharacterTitleIsNotWorthAnEllipsis() {
    // Two characters cannot be middle-truncated into anything shorter than the ellipsis itself.
    #expect(TabTitle.truncatedInMiddle("ab", maxWidth: 1, measure: monospace) == "…")
}

/// The bar carries the quick-action buttons as well as the tabs. `auto` hid it whenever there was
/// a single tab -- which is most of the time -- so a button you had configured stayed invisible
/// until you happened to open a second tab. A button you cannot see is not a button.
@Test func theBarStaysVisibleForQuickActionsWithASingleTab() {
    #expect(TabStrip.isBarVisible(.auto, tabCount: 1, quickActionCount: 1))
    #expect(!TabStrip.isBarVisible(.auto, tabCount: 1, quickActionCount: 0))
}

@Test func quickActionsDoNotOverrideAnExplicitChoice() {
    #expect(!TabStrip.isBarVisible(.never, tabCount: 1, quickActionCount: 3))
    #expect(TabStrip.isBarVisible(.always, tabCount: 1, quickActionCount: 0))
}

@Test func severalTabsShowTheBarWithOrWithoutButtons() {
    #expect(TabStrip.isBarVisible(.auto, tabCount: 2, quickActionCount: 0))
    #expect(TabStrip.isBarVisible(.auto, tabCount: 2, quickActionCount: 2))
}
