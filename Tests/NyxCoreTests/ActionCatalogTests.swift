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

/// The menu bar must not say "Last" for an action that targets the block the keyboard is on: the
/// user can put the cursor three blocks up, and a row promising the *last* command would be a
/// menu that lies about what pressing it does.
@Test func theBlockScopedTitlesNameTheBlockRatherThanTheLastOne() {
    let scoped: [TerminalAction] = [.selectCommandOutput, .copyCommandOutput, .copyBlockMarkdown,
                                    .saveCommandOutput, .editAndRunCommand, .foldCommand,
                                    .toggleHTTPLens, .stopWatch]
    for action in scoped {
        #expect(!action.title.contains("Last"), "\(action.configName) still says Last")
    }
    #expect(TerminalAction.copyCommandOutput.title == "Copy Command Output")
    #expect(TerminalAction.copyBlockMarkdown.title == "Copy Command as Markdown")
    #expect(TerminalAction.saveCommandOutput.title == "Save Command Output\u{2026}")
    // The ⋯ menu row's own words, so the menu bar and the block menu are not two spellings of one
    // act on one block (`BlockAction.editAndRun.title`).
    #expect(TerminalAction.editAndRunCommand.title == "Edit and Run This Command\u{2026}")
    // The four the plan leaves alone: they changed their target, not their words.
    #expect(TerminalAction.foldCommand.title == "Fold Command Output")
    #expect(TerminalAction.selectCommandOutput.title == "Select Command Output")
    #expect(TerminalAction.toggleHTTPLens.title == "Toggle Pretty Response")
    #expect(TerminalAction.stopWatch.title == "Stop Watching")
}

/// The relay-status palette row and `Settings → Remote` are one destination, so there is one action
/// for it. `.openConfig` is not it: it opens the settings window without choosing a page, which is
/// Appearance -- the page with nothing to do with a relay. The three remote verbs sit together in
/// the menu, because a user hunting for a token looks where the other two are.
@Test func openingTheRemotePageIsItsOwnAction() {
    #expect(TerminalAction.openRemoteSettings.configName == "open_remote_settings")
    #expect(TerminalAction.openRemoteSettings.title == "Remote Settings\u{2026}")
    let remoteGroup = ActionCatalog.sections
        .flatMap(\.groups)
        .first { $0.actions.contains(.remoteSessions) }
    #expect(remoteGroup?.actions == [.remoteSessions, .remotePair, .openRemoteSettings])
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

/// The curl-workbench actions: a new request lives in Shell, the response toggles in Go, in the
/// spots the brief names -- after `saveScrollback` and after `notifyWhenDone`, so a user scanning
/// either menu top to bottom finds them where the neighbouring, already-familiar action is.
@Test func newActionsAreInTheCatalogue() {
    #expect(ActionCatalog.allMenuActions.contains(.newRequest))
    #expect(ActionCatalog.allMenuActions.contains(.toggleHTTPLens))
    #expect(ActionCatalog.allMenuActions.contains(.stopWatch))

    let shell = ActionCatalog.sections.first { $0.title == "Shell" }!
    let shellActions = shell.actions
    let saveScrollbackIndex = shellActions.firstIndex(of: .saveScrollback)!
    let newRequestIndex = shellActions.firstIndex(of: .newRequest)!
    #expect(newRequestIndex > saveScrollbackIndex)

    let go = ActionCatalog.sections.first { $0.title == "Go" }!
    let goActions = go.actions
    let notifyIndex = goActions.firstIndex(of: .notifyWhenDone)!
    let toggleLensIndex = goActions.firstIndex(of: .toggleHTTPLens)!
    let stopWatchIndex = goActions.firstIndex(of: .stopWatch)!
    #expect(toggleLensIndex > notifyIndex)
    #expect(stopWatchIndex > notifyIndex)
}

@Test func blockActionsSitTogetherInTheGoMenu() {
    let go = ActionCatalog.sections.first { $0.title == "Go" }!
    #expect(go.actions.contains(.copyBlockMarkdown))
    #expect(go.actions.contains(.saveCommandOutput))
    #expect(go.actions.contains(.notifyWhenDone))
}

/// The one keyboard route to everything the hover strip offers. Without a chord it is not a route.
@Test func theBlockAndStickyActionsAreInTheGoSectionWithTheirTitles() {
    #expect(TerminalAction.blockActions.title == "Command Actions\u{2026}")
    #expect(TerminalAction.scrollToStickyPrompt.title == "Go to the Pinned Command")
    #expect(TerminalAction.blockActions.configName == "block_actions")
    #expect(TerminalAction.scrollToStickyPrompt.configName == "scroll_to_sticky_prompt")
    let go = ActionCatalog.sections.first { $0.title == "Go" }
    #expect(go?.actions.contains(.blockActions) == true)
    #expect(go?.actions.contains(.scrollToStickyPrompt) == true)
}
