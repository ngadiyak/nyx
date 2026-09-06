import Foundation
import Testing
@testable import NyxCore

private func palette(_ titles: [String]) -> CommandPalette {
    CommandPalette(items: titles.map { PaletteItem(title: $0, detail: "", kind: .theme($0)) })
}

// MARK: - The list

/// Actions first, then quick actions, themes, then tabs, then remote sessions: the order a user
/// builds a habit around, with the newest category last so it never displaces what's already there.
@Test func theListIsActionsThenThemesThenTabsThenRemote() {
    let remote = PaletteItem.remoteSession(deviceID: "d", sessionID: "s", title: "iMac · zsh", detail: "")
    let items = PaletteSource.items(actions: [.newTab, .copy], chord: { _ in nil },
                                    themes: ["dracula"], tabTitles: ["zsh"], remote: [remote])
    #expect(items.map(\.kind) == [.action(.newTab), .action(.copy), .theme("dracula"), .tab(0),
                                  .remoteSession(deviceID: "d", sessionID: "s")])
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

// MARK: - Quick actions

@Test func quickActionsSitBetweenTheActionsAndTheThemes() {
    let quick = QuickAction(name: "Deploy", kind: .run, command: "./deploy.sh")
    let items = PaletteSource.items(actions: [.newTab], chord: { _ in nil },
                                    quickActions: [(quick, false)],
                                    themes: ["dracula"], tabTitles: ["zsh"])
    #expect(items.map(\.kind) == [.action(.newTab), .quickAction(0), .theme("dracula"), .tab(0)])
    #expect(items[1].title == "Deploy")
    #expect(items[1].detail == "Quick Action")
}

/// A palette row is a verb. "Caffeine" leaves the user guessing which way pressing it will go.
@Test func aToggleReadsAsWhatPressingItWouldDo() {
    let toggle = QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d")
    let stopped = PaletteItem.quickAction(toggle, index: 0, isRunning: false)
    let started = PaletteItem.quickAction(toggle, index: 0, isRunning: true)
    #expect(stopped.title == "Start Caffeine")
    #expect(started.title == "Stop Caffeine")
}

/// Its own name still finds it whichever way round the verb reads.
@Test func aRunningToggleIsStillFoundByItsName() {
    let toggle = QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d")
    var p = CommandPalette(items: [PaletteItem.quickAction(toggle, index: 0, isRunning: true)])
    p.setQuery("caffeine")
    #expect(p.selected?.kind == .quickAction(0))
}

// MARK: - Requests

/// Newest category last, again: the Requests section goes after Remote, so nothing a user already
/// reaches by muscle memory moves when it appears.
@Test func requestsComeAfterRemote() {
    let remote = PaletteItem.remoteSession(deviceID: "d", sessionID: "s", title: "iMac · zsh",
                                           detail: "")
    var history = RequestHistory(limit: 10)
    history.record("curl https://api.example.com/users", at: Date(timeIntervalSince1970: 1_000))
    let requests = history.paletteItems(now: Date(timeIntervalSince1970: 1_030))
    let items = PaletteSource.items(actions: [.newTab], chord: { _ in nil },
                                    themes: ["dracula"], tabTitles: ["zsh"], remote: [remote],
                                    requests: requests)
    let id = RequestHistory.identifier(for: "curl https://api.example.com/users")
    #expect(items.map(\.kind) == [.action(.newTab), .theme("dracula"), .tab(0),
                                  .remoteSession(deviceID: "d", sessionID: "s"), .request(id: id)])
    #expect(items.last?.title == "GET api.example.com/users")
    #expect(items.last?.detail == "Request \u{b7} just now")
}

/// A window with no history is the ordinary palette: the parameter defaults to nothing, so no
/// caller has to pass an empty list to keep the list it already had.
@Test func aWindowWithNoRequestsGetsNoSection() {
    let items = PaletteSource.items(actions: [.newTab], chord: { _ in nil },
                                    themes: [], tabTitles: [])
    #expect(items.map(\.kind) == [.action(.newTab)])
}
