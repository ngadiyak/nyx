import Testing
@testable import NyxCore

private func palette(_ titles: [String]) -> CommandPalette {
    CommandPalette(items: titles.map { PaletteItem(title: $0, detail: "", kind: .theme($0)) })
}

// MARK: - The list

/// Actions first, then themes, then tabs: the order a user builds a habit around.
@Test func theListIsActionsThenThemesThenTabs() {
    let items = PaletteSource.items(actions: [.newTab, .copy], chord: { _ in nil },
                                    themes: ["dracula"], tabTitles: ["zsh"])
    #expect(items.map(\.kind) == [.action(.newTab), .action(.copy), .theme("dracula"), .tab(0)])
    #expect(items[0].title == "New Tab")
}

@Test func anActionShowsItsCurrentChord() {
    let bindings = KeyBindingTable(user: [])
    let items = PaletteSource.items(actions: [.newTab], chord: { bindings.binding(for: $0)?.displayName },
                                    themes: [], tabTitles: [])
    #expect(items[0].detail == "⌘T")
}

@Test func anActionWithNoBindingShowsNoChord() {
    let items = PaletteSource.items(actions: [.newTab], chord: { _ in nil }, themes: [], tabTitles: [])
    #expect(items[0].detail == "")
}

@Test func anUntitledTabIsNamedByItsNumber() {
    let items = PaletteSource.items(actions: [], chord: { _ in nil }, themes: [], tabTitles: ["", "vim"])
    #expect(items[0].title == "Tab 1")
    #expect(items[1].title == "vim")
    #expect(items[1].kind == .tab(1))
}

// MARK: - Filtering

@Test func anEmptyQueryShowsEverythingInOrder() {
    let p = palette(["one", "two", "three"])
    #expect(p.results.map(\.item.title) == ["one", "two", "three"])
    #expect(p.selected?.title == "one")
}

@Test func typingNarrowsTheListAndRanksTheBestAnswerFirst() {
    var p = CommandPalette(items: [
        PaletteItem.action(.fontSmaller, chord: nil),
        PaletteItem.action(.newTab, chord: nil),
        PaletteItem.action(.nextTab, chord: nil),
    ])
    p.setQuery("newtab")
    #expect(p.results.first?.item.title == "New Tab")
    #expect(!p.results.contains { $0.item.title == "Smaller" })
}

/// The point of carrying the category into the search text: a palette you have to know the answer's
/// name to use is a list, not a search.
@Test func aCategoryNameFindsItsMembers() {
    var p = CommandPalette(items: [PaletteItem.theme("dracula"), PaletteItem.action(.copy, chord: nil)])
    p.setQuery("theme")
    #expect(p.results.map(\.item.title) == ["dracula"])
}

/// Highlighting is drawn over the title, so an offset that landed in the invisible category text
/// would underline the wrong character -- or a character that is not there at all.
@Test func onlyPositionsInsideTheTitleAreReported() {
    var p = CommandPalette(items: [PaletteItem.theme("dracula")])
    p.setQuery("dth")
    let result = p.results.first
    #expect(result?.item.title == "dracula")
    #expect(result?.positions.allSatisfy { $0 < 7 } == true)
}

@Test func aQueryThatMatchesNothingLeavesNoSelection() {
    var p = palette(["one", "two"])
    p.setQuery("zzzz")
    #expect(p.results.isEmpty)
    #expect(p.selected == nil)
}

/// Typing rearranges the list under the cursor, so the selection has to go back to the best answer
/// rather than stay at an index that now means something else.
@Test func retypingResetsTheSelectionToTheTop() {
    var p = palette(["alpha", "beta", "gamma"])
    p.moveSelection(by: 2)
    #expect(p.selected?.title == "gamma")
    p.setQuery("a")
    #expect(p.selection == 0)
}

// MARK: - Moving

@Test func theSelectionMovesAndWrapsAtBothEnds() {
    var p = palette(["one", "two", "three"])
    p.moveSelection(by: 1)
    #expect(p.selected?.title == "two")
    p.moveSelection(by: -1)
    #expect(p.selected?.title == "one")
    p.moveSelection(by: -1)
    #expect(p.selected?.title == "three")
    p.moveSelection(by: 1)
    #expect(p.selected?.title == "one")
}

@Test func movingInAnEmptyListDoesNothing() {
    var p = palette([])
    p.moveSelection(by: 1)
    #expect(p.selection == 0)
    #expect(p.selected == nil)
}

// MARK: - Chords

@Test func aChordIsWrittenInTheOrderAMacMenuUsesIt() {
    let binding = KeyBinding(key: .char("p"), modifiers: [.cmd, .shift, .ctrl, .alt], action: .commandPalette)
    #expect(binding.displayName == "⌃⌥⇧⌘P")
}

@Test func specialKeysGetTheirSymbols() {
    #expect(KeyBinding(key: .up, modifiers: [.cmd], action: .previousPrompt).displayName == "⌘↑")
    #expect(KeyBinding(key: .enter, modifiers: [], action: .copy).displayName == "↩")
    #expect(KeyBinding(key: .f(5), modifiers: [], action: .copy).displayName == "F5")
}
