import Testing
@testable import NyxCore

private func p(_ s: String) -> KeyBinding? { KeyBinding.parse(s) }

@Test func parsesASimpleBinding() {
    let b = p("cmd+t=new_tab")
    #expect(b?.modifiers == [.cmd])
    #expect(b?.key == .char("t"))
    #expect(b?.action == .newTab)
}

@Test func parsesSeveralModifiersInAnyOrder() {
    #expect(p("cmd+shift+d=split_down")?.modifiers == [.cmd, .shift])
    #expect(p("shift+cmd+d=split_down")?.modifiers == [.cmd, .shift])
    #expect(p("ctrl+alt+cmd+shift+k=clear_screen")?.modifiers == [.cmd, .shift, .alt, .ctrl])
}

@Test func acceptsModifierAliases() {
    #expect(p("control+a=copy")?.modifiers == [.ctrl])
    #expect(p("opt+a=copy")?.modifiers == [.alt])
    #expect(p("option+a=copy")?.modifiers == [.alt])
}

@Test func parsesNamedKeys() {
    #expect(p("cmd+enter=toggle_zoom")?.key == .enter)
    #expect(p("cmd+return=toggle_zoom")?.key == .enter)
    #expect(p("cmd+left=focus_left")?.key == .left)
    #expect(p("cmd+pageup=previous_tab")?.key == .pageUp)
    #expect(p("cmd+f5=reload_config")?.key == .f(5))
    #expect(p("cmd+f12=reload_config")?.key == .f(12))
    #expect(p("cmd+escape=close_pane")?.key == .escape)
}

@Test func namedKeysAndModifiersAreCaseInsensitive() {
    #expect(p("CMD+Enter=toggle_zoom")?.key == .enter)
    #expect(p("Cmd+T=new_tab")?.key == .char("t"))
}

@Test func parsesPunctuationKeys() {
    #expect(p("cmd+,=open_config")?.key == .char(","))
    #expect(p("cmd+=+=font_bigger") == nil)   // ambiguous, must be rejected rather than guessed
    #expect(p("cmd+minus=font_smaller") == nil)
}

@Test func rejectsMalformedBindings() {
    #expect(p("") == nil)
    #expect(p("cmd+t") == nil)                 // no action
    #expect(p("=new_tab") == nil)              // no key
    #expect(p("cmd+t=not_an_action") == nil)
    #expect(p("bogus+t=new_tab") == nil)       // unknown modifier
    #expect(p("cmd+nosuchkey=new_tab") == nil)
    #expect(p("cmd+f13=new_tab") == nil)
}

@Test func everyActionNameRoundTrips() {
    for action in TerminalAction.allCases {
        #expect(p("cmd+t=\(action.rawValue)")?.action == action)
    }
}

@Test func theDefaultsCoverTheSpecTable() {
    let d = KeyBinding.defaults
    func has(_ mods: KeyModifiers, _ key: Key, _ action: TerminalAction) -> Bool {
        d.contains { $0.modifiers == mods && $0.key == key && $0.action == action }
    }
    #expect(has([.cmd], .char("t"), .newTab))
    #expect(has([.cmd], .char("w"), .closePane))
    #expect(has([.cmd], .char("d"), .splitRight))
    #expect(has([.cmd, .shift], .char("d"), .splitDown))
    #expect(has([.cmd, .alt], .left, .focusLeft))
    #expect(has([.cmd, .ctrl], .right, .growRight))
    #expect(has([.cmd, .shift], .enter, .toggleZoom))
    #expect(has([.cmd], .char("k"), .clearScreen))
    #expect(has([.cmd], .char(","), .openConfig))
    #expect(has([.cmd], .char("1"), .tab1))
    #expect(has([.cmd], .char("9"), .tab9))
}

@Test func noTwoDefaultsShareAChord() {
    var seen = Set<String>()
    for b in KeyBinding.defaults {
        let chord = "\(b.modifiers.rawValue):\(b.key)"
        #expect(!seen.contains(chord), "duplicate default binding for \(chord)")
        seen.insert(chord)
    }
}

@Test func configCollectsKeybinds() {
    let (c, d) = ConfigParser.parse("keybind = cmd+t=new_tab\nkeybind = cmd+w=close_pane")
    #expect(d.isEmpty)
    #expect(c.keybinds.count == 2)
    #expect(c.keybinds[0].action == .newTab)
}

@Test func abadKeybindIsADiagnostic() {
    let (c, d) = ConfigParser.parse("keybind = cmd+t=nonsense")
    #expect(c.keybinds.isEmpty)
    #expect(d.count == 1 && d[0].line == 1)
}

/// The chords every Mac application has. These were left out of the defaults on the grounds that
/// the menu hard-coded them; when the menu was rebuilt from this table it stopped supplying them
/// and ⌘C, ⌘V, ⌘N and the font-size chords silently stopped working. Nothing else would have
/// noticed, because nothing else knows what a user expects to be able to press.
@Test func theChordsEveryMacApplicationHasAreBound() {
    let table = KeyBindingTable(user: [])
    let expected: [(Key, KeyModifiers, TerminalAction)] = [
        (.char("c"), [.cmd], .copy),
        (.char("v"), [.cmd], .paste),
        (.char("n"), [.cmd], .newWindow),
        (.char("t"), [.cmd], .newTab),
        (.char("w"), [.cmd], .closePane),
        (.char("f"), [.cmd], .find),
        (.char("0"), [.cmd], .fontReset),
        (.char("-"), [.cmd], .fontSmaller),
    ]
    for (key, modifiers, action) in expected {
        #expect(table.action(for: key, modifiers: modifiers) == action, "\(action.configName)")
    }
}

/// `⌘+` and `⌘=` are the same physical key; binding one of them makes the shortcut work for half
/// the people who try it.
@Test func bothSpellingsOfTheZoomInChordWork() {
    let table = KeyBindingTable(user: [])
    #expect(table.action(for: .char("+"), modifiers: [.cmd]) == .fontBigger)
    #expect(table.action(for: .char("="), modifiers: [.cmd]) == .fontBigger)
}

/// Every action the menu offers should either carry a chord or be one nobody expects one for.
/// A menu item with no shortcut is fine; an action that *used* to have one and lost it is not.
@Test func everyMenuActionIsEitherBoundOrDeliberatelyNot() {
    let table = KeyBindingTable(user: [])
    let expectedUnbound: Set<TerminalAction> = [
        .selectCommandOutput, .copyCommandOutput, .saveScrollback,
        .foldAllLongOutput,
        .copyBlockMarkdown, .saveCommandOutput, .notifyWhenDone,
        // Reachable from the menu, the palette and a `keybind =` line, but not worth a default
        // chord: they act on a tab's grouping, which is not something anybody does hourly.
        .ungroupTab, .toggleTabGroup,
        // Remote actions ship with no default chord (spec §5.3/§5.4): menu and palette only.
        .remoteSessions, .remotePair, .remoteTakeControl,
    ]
    for action in ActionCatalog.allMenuActions where !expectedUnbound.contains(action) {
        #expect(table.binding(for: action) != nil, "\(action.configName) lost its shortcut")
    }
}

@Test func foldCommandHasADefaultChord() {
    let table = KeyBindingTable(user: [])
    #expect(table.binding(for: .foldCommand) == KeyBinding(key: .up, modifiers: [.cmd, .shift], action: .foldCommand))
}

@Test func theNewBlockActionsParseFromTheConfigSpelling() {
    #expect(p("cmd+shift+m=copy_block_markdown")?.action == .copyBlockMarkdown)
    #expect(p("cmd+shift+s=save_command_output")?.action == .saveCommandOutput)
    #expect(p("cmd+shift+n=notify_when_done")?.action == .notifyWhenDone)
}

/// `remote_sessions`, `remote_pair` and `remote_take_control` are reachable only from the menu and
/// the command palette, never a default chord (spec §5.3/§5.4).
@Test func remoteActionsHaveNoDefaultChord() {
    let table = KeyBindingTable(user: [])
    #expect(table.binding(for: .remoteSessions) == nil)
    #expect(table.binding(for: .remotePair) == nil)
    #expect(table.binding(for: .remoteTakeControl) == nil)
}

@Test func remoteActionNamesRoundTripFromTheConfigSpelling() {
    #expect(p("cmd+shift+m=remote_sessions")?.action == .remoteSessions)
    #expect(p("cmd+shift+m=remote_pair")?.action == .remotePair)
    #expect(p("cmd+shift+m=remote_take_control")?.action == .remoteTakeControl)
}
