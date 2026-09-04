import Foundation
import Testing
@testable import NyxCore

// The tab bar draws itself, so these strings are the *only* name any of its controls has -- under
// the pointer and to a screen reader both. A control whose meaning is its state has to say which
// state it is in; a label that reads the same in both is a label that is wrong in one of them.

@Test func aTabSaysWhereItIsInTheStrip() {
    #expect(TabBarLabels.tab(titled: "vim Pane.swift", position: 2, of: 4, indicator: .none)
        == "vim Pane.swift, tab 2 of 4")
}

/// The indicator is a dot. A dot is not a word.
@Test func aTabSaysWhatItsIndicatorMeans() {
    #expect(TabBarLabels.tab(titled: "make", position: 1, of: 2, indicator: .activity)
        == "make, tab 1 of 2, new output")
    #expect(TabBarLabels.tab(titled: "make", position: 1, of: 2, indicator: .bell)
        == "make, tab 1 of 2, bell rang")
}

@Test func aCloseButtonNamesTheTabItCloses() {
    #expect(TabBarLabels.close(tabTitled: "make test") == "Close make test (⌘W)")
    #expect(TabBarLabels.close(tabTitled: nil) == "Close tab")
    #expect(TabBarLabels.close(tabTitled: "") == "Close tab")
}

/// One button that either expands or collapses: the only useful thing it can say is which.
@Test func aGroupSaysWhichWayItWillGo() {
    #expect(TabBarLabels.group(named: "work", isCollapsed: true) == "Expand “work”")
    #expect(TabBarLabels.group(named: "work", isCollapsed: false) == "Collapse “work”")
}

/// A collapsed chip stands in for tabs that are not on screen at all, so it says how many.
@Test func aCollapsedGroupSaysHowManyTabsAreBehindIt() {
    #expect(TabBarLabels.collapsedGroup(named: "work", tabCount: 3)
        == "work, group of 3 tabs, collapsed. Expand “work”")
    #expect(TabBarLabels.collapsedGroup(named: "work", tabCount: 1)
        == "work, group of 1 tab, collapsed. Expand “work”")
    #expect(TabBarLabels.expandedGroup(named: "work") == "work, group, expanded. Collapse “work”")
}

/// Pressing a quick action must never be a guess about what it runs, which is why the command is
/// in the name -- the same reasoning as the tooltip, because it is the same string.
@Test func aQuickActionSaysWhatItWillDoAndToWhat() {
    #expect(TabBarLabels.quickAction(named: "Deploy", kind: .send, command: "./deploy.sh",
                                     isRunning: false) == "Deploy — types: ./deploy.sh")
    #expect(TabBarLabels.quickAction(named: "Test", kind: .run, command: "make test",
                                     isRunning: false) == "Test — opens a tab and runs: make test")
}

/// A toggle's button is the same button whether it will start or stop something, so "running" has
/// to be said outright rather than implied by the verb.
@Test func aRunningToggleSaysSo() {
    let off = TabBarLabels.quickActionState(named: "Caffeine", kind: .toggle,
                                            command: "caffeinate -d", isRunning: false)
    let on = TabBarLabels.quickActionState(named: "Caffeine", kind: .toggle,
                                           command: "caffeinate -d", isRunning: true)
    #expect(off == "Caffeine — runs in the background: caffeinate -d")
    #expect(on == "Caffeine — stops: caffeinate -d, running now")
    #expect(off != on)
}

/// Every control the bar draws has a name, and none of them is empty -- an empty label reaches a
/// screen reader as "button", which is what having no label at all sounds like.
@Test func noControlInTheBarIsNameless() {
    var labels = [TabBarLabels.bar, TabBarLabels.newTab, TabBarLabels.tabList,
                  TabBarLabels.addQuickAction, TabBarLabels.close(tabTitled: nil)]
    labels.append(TabBarLabels.tab(titled: "", position: 1, of: 1, indicator: .none))
    labels.append(TabBarLabels.group(named: "g", isCollapsed: true))
    labels.append(TabBarLabels.collapsedGroup(named: "g", tabCount: 0))
    labels.append(TabBarLabels.expandedGroup(named: "g"))
    labels.append(TabBarLabels.quickActionState(named: "q", kind: .send, command: "c", isRunning: false))
    for label in labels {
        #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
