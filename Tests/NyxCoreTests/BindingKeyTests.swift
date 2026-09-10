import Testing
@testable import NyxCore

/// The chord a key press means, on a layout that is not ASCII.
///
/// Every case here is a real event captured from this machine with the Russian (RussianWin) layout
/// active, built with `CGEvent` so the characters come from the window server's own translation.
/// See `.superpowers/sdd/2026-09-07-ux-round/qa-layout-links.md`.
private func key(_ keyCode: UInt16, _ characters: String, _ ignoring: String,
                 _ modifiers: KeyModifiers) -> Key? {
    MacKeyCodes.bindingKey(keyCode: keyCode, characters: characters,
                           charactersIgnoringModifiers: ignoring, modifiers: modifiers)
}

private let table = KeyBindingTable(user: [])

@Test func aCyrillicCharacterFindsTheChordItsPhysicalKeyIsBoundTo() {
    // ⌘C: `characters` is the ASCII "c", `charactersIgnoringModifiers` the layout's "с" (U+0441).
    #expect(key(8, "c", "\u{0441}", [.cmd]) == .char("c"))
    #expect(table.action(for: key(8, "c", "\u{0441}", [.cmd])!, modifiers: [.cmd]) == .copy)
    // ⌘F -> "а"
    #expect(key(3, "f", "\u{0430}", [.cmd]) == .char("f"))
    #expect(table.action(for: key(3, "f", "\u{0430}", [.cmd])!, modifiers: [.cmd]) == .find)
    // ⌘⇧D -> "В"
    #expect(key(2, "D", "\u{0412}", [.cmd, .shift]) == .char("d"))
    #expect(table.action(for: key(2, "D", "\u{0412}", [.cmd, .shift])!,
                         modifiers: [.cmd, .shift]) == .splitDown)
}

@Test func aShiftedLetterChordMatchesItsLowercaseBinding() {
    // The ASCII control from the report: with the menu bypassed, every shift+letter default was
    // dead because `charactersIgnoringModifiers` applies shift and the bindings are lowercase.
    let cases: [(UInt16, String, TerminalAction)] = [
        (5, "G", .findPrevious),
        (35, "P", .commandPalette),
        (9, "V", .pasteWithEditor),
        (15, "R", .renameTab),
        (2, "D", .splitDown),
    ]
    for (code, chars, action) in cases {
        let k = key(code, chars, chars, [.cmd, .shift])
        #expect(k == .char(Unicode.Scalar(chars.lowercased().unicodeScalars.first!)))
        #expect(table.action(for: k!, modifiers: [.cmd, .shift]) == action)
    }
    // ⌘⇧, -- the shifted form of a punctuation key is the key, not the character it produced.
    #expect(key(43, "<", "<", [.cmd, .shift]) == .char(","))
    #expect(table.action(for: .char(","), modifiers: [.cmd, .shift]) == .reloadConfig)
}

@Test func aControlFoldedCharacterStillNamesItsKey() {
    // ⌘⌃G arrives with `characters` = BEL, because ctrl folds the character to a control code.
    // Neither string in the event is the letter; only the key code is.
    #expect(key(5, "\u{07}", "\u{043F}", [.cmd, .ctrl]) == .char("g"))
    #expect(table.action(for: .char("g"), modifiers: [.cmd, .ctrl]) == .groupTab)
}

@Test func unmodifiedTypingKeepsTheLayoutsOwnCharacter() {
    // Cyrillic must reach the PTY as Cyrillic: this is the path `insertText` and the encoder take.
    #expect(key(35, "\u{043F}", "\u{043F}", []) == .char("\u{043F}"))
    // And its case survives, because `.char("П")` is a different key from `.char("п")` to the
    // encoder's modifyOtherKeys reporting.
    #expect(key(35, "\u{041F}", "\u{041F}", [.shift]) == .char("\u{041F}"))
    #expect(key(2, "D", "D", [.shift]) == .char("D"))
}

@Test func namedKeysComeFromTheKeyCodeAndNotFromCharacters() {
    #expect(key(126, "", "", [.cmd]) == .up)
    #expect(key(36, "\r", "\r", []) == .enter)
    #expect(key(53, "\u{1B}", "\u{1B}", []) == .escape)
    #expect(key(122, "", "", []) == .f(1))
}

@Test func aKeyCodeOffTheAsciiBlockFallsBackToTheEvent() {
    // The ISO section key (10) is not on the ANSI block, so there is nothing to translate it to;
    // the event's own characters are the best answer rather than no answer.
    #expect(key(10, "\u{00A7}", "\u{00A7}", [.cmd]) == .char("\u{00A7}"))
}

@Test func commandPlusIsReachable() {
    // Two faults, both fixed: the event for ⌘+ carries `.shift`, and the physical key is `=`.
    #expect(table.action(for: .char("+"), modifiers: [.cmd, .shift]) == .fontBigger)
    #expect(table.action(for: .char("="), modifiers: [.cmd, .shift]) == .fontBigger)
    #expect(table.action(for: .char("="), modifiers: [.cmd]) == .fontBigger)
    // The real event, ⌘⇧= on the ANSI block: `characters` and `charactersIgnoringModifiers` are
    // both "+", and the key is `=`.
    let k = key(24, "+", "+", [.cmd, .shift])
    #expect(k == .char("="))
    #expect(table.action(for: k!, modifiers: [.cmd, .shift]) == .fontBigger)
    // Zoom in is advertised as ⌘+, which is what every other Mac application shows.
    #expect(table.binding(for: .fontBigger)?.key == .char("+"))
    #expect(table.binding(for: .fontBigger)?.modifiers == [.cmd])
}

@Test func aSecondChordForAnActionDoesNotDisarmTheFirst() {
    // `keybind = cmd+shift+c=copy` moved Copy's menu equivalent off ⌘C. On a Cyrillic layout that
    // silently removed ⌘C, because the pane's own matching read the layout's character.
    let bindings = KeyBindingTable(user: [KeyBinding.parse("cmd+shift+c=copy")!])
    #expect(bindings.binding(for: .copy)?.modifiers == [.cmd, .shift])
    let russian = key(8, "c", "\u{0441}", [.cmd])!
    #expect(bindings.action(for: russian, modifiers: [.cmd]) == .copy)
    #expect(bindings.action(for: .char("c"), modifiers: [.cmd, .shift]) == .copy)
}
