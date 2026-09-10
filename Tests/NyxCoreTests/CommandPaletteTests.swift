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

// MARK: - The character a menu item carries for a key

/// One list, walked both ways, so a key cannot go out into a menu as one character and come back
/// as another. The menu bar hands AppKit these scalars for `keyEquivalent`; `MenuSnapshot` reads
/// them back to ask `Key.displayName` how to draw the chord, since AppKit's private-use scalars
/// have no glyph in the system font -- and a table that only went one way is how a picture drifts
/// from the menu it is a picture of.
@Test func everyKeyAMenuCanCarryGoesOutAndComesBackAsItself() {
    let keys: [Key] = [.up, .down, .left, .right, .home, .end, .pageUp, .pageDown, .insert,
                       .delete, .backspace, .tab, .enter, .escape, .f(1), .f(5), .f(35)]
    for key in keys {
        let scalar = key.menuKeyEquivalent
        #expect(scalar != nil, "\(key) has no menu key equivalent")
        #expect(scalar.flatMap(Key.init(menuKeyEquivalent:)) == key, "\(key) did not come back")
    }
}

/// AppKit's own numbers, pinned: they are Unicode private-use scalars (`NSUpArrowFunctionKey` and
/// friends, 0xF700 up), and NyxCore cannot import AppKit to read the constants. A typo here would
/// put the wrong chord in the menu bar, which no test on the round trip above could see.
@Test func theScalarsAreTheOnesAppKitDocuments() {
    #expect(Key.up.menuKeyEquivalent == "\u{F700}")
    #expect(Key.down.menuKeyEquivalent == "\u{F701}")
    #expect(Key.left.menuKeyEquivalent == "\u{F702}")
    #expect(Key.right.menuKeyEquivalent == "\u{F703}")
    #expect(Key.f(1).menuKeyEquivalent == "\u{F704}")
    #expect(Key.f(35).menuKeyEquivalent == "\u{F726}")
    #expect(Key.insert.menuKeyEquivalent == "\u{F727}")
    #expect(Key.delete.menuKeyEquivalent == "\u{F728}")
    #expect(Key.home.menuKeyEquivalent == "\u{F729}")
    #expect(Key.end.menuKeyEquivalent == "\u{F72B}")
    #expect(Key.pageUp.menuKeyEquivalent == "\u{F72C}")
    #expect(Key.pageDown.menuKeyEquivalent == "\u{F72D}")
    // The four that are real control characters rather than private-use scalars.
    #expect(Key.backspace.menuKeyEquivalent == "\u{8}")
    #expect(Key.tab.menuKeyEquivalent == "\u{9}")
    #expect(Key.enter.menuKeyEquivalent == "\u{d}")
    #expect(Key.escape.menuKeyEquivalent == "\u{1b}")
}

/// A character key has no entry: AppKit takes the character itself as the key equivalent, which is
/// why the menu builder switches on `.char` before it asks this at all -- and why reading a letter
/// back must answer nil rather than guessing at a key.
@Test func anOrdinaryCharacterIsNotInTheTable() {
    #expect(Key.char("a").menuKeyEquivalent == nil)
    #expect(Key(menuKeyEquivalent: "a") == nil)
    #expect(Key(menuKeyEquivalent: "\u{F7FF}") == nil)
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

// MARK: - What the palette may offer

/// An action the window cannot perform right now is not a row at all.
///
/// It was a *greyed* row, which is right for a menu and wrong for a search: a menu is a fixed list
/// you scan by position, so a greyed item is a landmark saying "that lives here". A palette is a
/// list you produce by typing, and in a fresh window twenty-nine of its rows were grey -- Tab 7
/// with three tabs open, Focus Left with one pane, Copy with nothing selected. A search result that
/// cannot be chosen is a wrong answer to what you typed.
@Test func actionsTheWindowCannotPerformAreNotOffered() {
    let refused: Set<TerminalAction> = [.toggleHTTPLens, .stopWatch, .copy]
    let items = PaletteSource.items(actions: [.copy, .paste, .toggleHTTPLens, .stopWatch, .newRequest],
                                    chord: { _ in nil },
                                    enabled: { !refused.contains($0) },
                                    themes: [], tabTitles: [])
    #expect(items.map(\.kind) == [.action(.paste), .action(.newRequest)])
}

/// With no opinion offered, everything is: the closure defaults to yes, so a caller that has
/// nothing to say about availability gets the whole catalogue.
@Test func withoutAnOpinionEveryActionIsOffered() {
    let items = PaletteSource.items(actions: [.copy, .paste], chord: { _ in nil },
                                    themes: [], tabTitles: [])
    #expect(items.count == 2)
}

/// The Remote section's placeholder rows stay, disabled, because they are not offers -- they are
/// the section explaining why it is empty. "Mac mini (office) — offline" removed from the list is
/// a user searching for their Mac and finding nothing at all.
@Test func remotePlaceholderRowsSurviveTheFilter() {
    let placeholder = PaletteItem.remoteSession(deviceID: "D1", sessionID: "", title: "Mac mini — offline",
                                                detail: "offline", isEnabled: false)
    let items = PaletteSource.items(actions: [.copy], chord: { _ in nil }, enabled: { _ in false },
                                    themes: [], tabTitles: [], remote: [placeholder])
    #expect(items.count == 1)
    #expect(items.first?.kind == .remoteSession(deviceID: "D1", sessionID: ""))
    #expect(items.first?.isEnabled == false)
}
