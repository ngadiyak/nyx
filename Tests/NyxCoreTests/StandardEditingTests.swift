import Testing
@testable import NyxCore

/// The Edit menu had no `copy:`/`paste:`/`selectAll:`/`undo:` items at all -- the terminal's own
/// actions had taken their chords -- so ⌘V with the search field focused pasted the clipboard onto
/// the shell command line behind the bar, and ⌘A, ⌘C and ⌘Z did nothing in any of Nyx's text
/// fields. See `.superpowers/sdd/2026-09-07-ux-round/qa-layout-links.md`.
@Test func copyAndPasteAreServedByTheStandardSelector() {
    #expect(StandardEditing.command(for: .copy) == .copy)
    #expect(StandardEditing.command(for: .paste) == .paste)
}

@Test func onlyCopyAndPasteHaveAStandardEquivalent() {
    // `paste_with_editor` opens Nyx's own editor; nothing in AppKit does that, so it keeps
    // `performTerminalAction:` and a text field does not get ⌘⇧V.
    #expect(StandardEditing.command(for: .pasteWithEditor) == nil)
    #expect(StandardEditing.command(for: .clearScreen) == nil)
    #expect(StandardEditing.command(for: .find) == nil)
    #expect(StandardEditing.command(for: .selectCommandOutput) == nil)
    for action in ActionCatalog.allMenuActions where action != .copy && action != .paste {
        #expect(StandardEditing.command(for: action) == nil)
    }
}

@Test func theEditMenuCarriesTheCommandsNoTerminalActionStandsFor() {
    #expect(StandardEditing.extras == [.undo, .redo, .cut, .selectAll])
    #expect(StandardEditingCommand.undo.title == "Undo")
    #expect(StandardEditingCommand.redo.title == "Redo")
    #expect(StandardEditingCommand.cut.title == "Cut")
    #expect(StandardEditingCommand.selectAll.title == "Select All")
}

@Test func copyAndPasteTakeTheirChordFromTheBindingTable() {
    // Their chord is `keybind`-able, so it cannot be frozen here; the extras' chords are AppKit's
    // and are.
    #expect(StandardEditingCommand.copy.fixedChord == nil)
    #expect(StandardEditingCommand.paste.fixedChord == nil)
    #expect(StandardEditingCommand.undo.fixedChord?.key == "z")
    #expect(StandardEditingCommand.undo.fixedChord?.modifiers == [.cmd])
    #expect(StandardEditingCommand.redo.fixedChord?.modifiers == [.cmd, .shift])
    #expect(StandardEditingCommand.cut.fixedChord?.key == "x")
    #expect(StandardEditingCommand.selectAll.fixedChord?.key == "a")
}

/// ⌘A, ⌘Z, ⌘⇧Z and ⌘X are now menu key equivalents, which AppKit matches before `Pane.keyDown` is
/// called. A default binding on any of them would be shadowed by an item the config cannot name.
@Test func noStandardChordShadowsADefaultBinding() {
    let table = KeyBindingTable(user: [])
    for command in StandardEditing.extras {
        let chord = command.fixedChord
        let found = chord.flatMap { table.action(for: .char($0.key), modifiers: $0.modifiers) }
        #expect(found == nil, "\(command.rawValue) collides with \(String(describing: found))")
    }
}
