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
