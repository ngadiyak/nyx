import Testing
@testable import NyxCore

// MARK: - The catalog

/// The point of building the menu from `TerminalAction` is that a user cannot name an action in
/// their config that the menu does not also offer. If someone adds a case and forgets the menu,
/// this is what says so.
@Test func everyActionAppearsInTheMenuExactlyOnce() {
    let menu = ActionCatalog.allMenuActions
    for action in TerminalAction.allCases {
        #expect(menu.filter { $0 == action }.count == 1, "\(action.configName) is not in the menu exactly once")
    }
    #expect(menu.count == TerminalAction.allCases.count)
}

@Test func everyActionHasANonEmptyTitle() {
    for action in TerminalAction.allCases {
        #expect(!action.title.isEmpty)
    }
}

/// Titles are what a user reads in the menu; two actions sharing one would be indistinguishable.
@Test func actionTitlesAreDistinct() {
    let titles = TerminalAction.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
}

@Test func sectionsAreNamedAndNonEmpty() {
    for section in ActionCatalog.sections {
        #expect(!section.title.isEmpty)
        #expect(!section.actions.isEmpty)
        for group in section.groups { #expect(!group.actions.isEmpty) }
    }
}

// MARK: - The binding table

private func table(_ lines: String...) -> KeyBindingTable {
    KeyBindingTable(user: lines.compactMap { KeyBinding.parse($0) })
}

@Test func anUnboundChordBelongsToTheShell() {
    let t = table()
    #expect(t.action(for: .char("k"), modifiers: []) == nil)
    #expect(t.action(for: .char("j"), modifiers: [.cmd]) == nil)
}

/// The exact-match requirement, stated as the acceptance check does: `⌘K` clears the screen, but
/// plain `k` has to reach the shell and type a `k`.
@Test func modifiersMustMatchExactlyOrTheKeyReachesTheShell() {
    let t = table()
    #expect(t.action(for: .char("k"), modifiers: [.cmd]) == .clearScreen)
    #expect(t.action(for: .char("k"), modifiers: []) == nil)
    #expect(t.action(for: .char("k"), modifiers: [.cmd, .shift]) == nil)
    #expect(t.action(for: .char("k"), modifiers: [.ctrl]) == nil)
}

@Test func aUserBindingAddsAChordTheDefaultsDoNotHave() {
    let t = table("cmd+shift+t=new_tab")
    #expect(t.action(for: .char("t"), modifiers: [.cmd, .shift]) == .newTab)
    #expect(t.action(for: .char("t"), modifiers: [.cmd]) == .newTab)   // the default still stands
}

/// Acceptance check 4: rebinding a chord the defaults already use must take effect, not be ignored
/// because the default was found first.
@Test func aUserBindingBeatsTheDefaultForTheSameChord() {
    #expect(table().action(for: .char("d"), modifiers: [.cmd]) == .splitRight)
    #expect(table("cmd+d=new_tab").action(for: .char("d"), modifiers: [.cmd]) == .newTab)
}

/// A config file is read top to bottom, so the later line is the one the user meant.
@Test func theLastLineWinsAmongUserBindings() {
    let t = table("cmd+d=new_tab", "cmd+d=toggle_zoom")
    #expect(t.action(for: .char("d"), modifiers: [.cmd]) == .toggleZoom)
}

@Test func theMenuShortcutForAnActionIsItsDefaultChord() {
    let t = table()
    let b = t.binding(for: .newTab)
    #expect(b?.key == .char("t"))
    #expect(b?.modifiers == [.cmd])
}

/// Some actions ship with no chord and are menu-only; the menu still lists them, without a
/// shortcut. This used to name `fontBigger`, which was documenting a bug rather than a decision:
/// ⌘+ had quietly stopped working when the menu began reading its key equivalents from this table.
@Test func anActionWithNoBindingReportsNoShortcut() {
    #expect(table().binding(for: .copyCommandOutput) == nil)
    #expect(ActionCatalog.allMenuActions.contains(.copyCommandOutput))
}

/// The subtle one. Rebinding `⌘D` to `new_tab` leaves `split_right` with no chord at all. The menu
/// must stop advertising `⌘D` next to Split Right -- otherwise it shows a shortcut that now opens
/// a tab, which is worse than showing none.
@Test func anActionWhoseChordWasStolenAdvertisesNoShortcut() {
    let t = table("cmd+d=new_tab")
    #expect(t.binding(for: .splitRight) == nil)
    #expect(t.binding(for: .newTab)?.key == .char("d"))
}

/// Rebinding away and back again must not leave the action stranded.
@Test func anActionRebountToANewChordAdvertisesTheNewOne() {
    let t = table("cmd+d=new_tab", "cmd+ctrl+d=split_right")
    #expect(t.binding(for: .splitRight)?.modifiers == [.cmd, .ctrl])
    #expect(t.action(for: .char("d"), modifiers: [.cmd, .ctrl]) == .splitRight)
}

@Test func blockActionsSitTogetherInTheGoMenu() {
    let go = ActionCatalog.sections.first { $0.title == "Go" }!
    #expect(go.actions.contains(.copyBlockMarkdown))
    #expect(go.actions.contains(.saveCommandOutput))
    #expect(go.actions.contains(.notifyWhenDone))
}
