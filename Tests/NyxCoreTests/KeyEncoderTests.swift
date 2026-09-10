import Testing
@testable import NyxCore

private func enc(_ key: Key, _ mods: KeyModifiers = [], text: String? = nil, app: Bool = false, meta: Bool = false) -> String? {
    KeyEncoder.encode(KeyEvent(key: key, modifiers: mods, text: text),
                      options: KeyEncoderOptions(cursorKeysApp: app, optionAsMeta: meta))
        .map { String(decoding: $0, as: UTF8.self) }
}
private let ESC = "\u{1B}"

@Test func plainCharactersUseComposedText() {
    #expect(enc(.char("a"), text: "a") == "a")
    #expect(enc(.char("o"), [.alt], text: "ø") == "ø")
    #expect(enc(.char("я"), text: "я") == "я")
    #expect(enc(.char("a"), [.shift], text: "A") == "A")
}

@Test func optionAsMetaSendsEscapePrefix() {
    #expect(enc(.char("o"), [.alt], text: "ø", meta: true) == ESC + "o")
    #expect(enc(.char("b"), [.alt], text: "∫", meta: true) == ESC + "b")
}

@Test func controlCharacters() {
    #expect(enc(.char("c"), [.ctrl]) == "\u{03}")
    #expect(enc(.char("a"), [.ctrl, .shift]) == "\u{01}")
    #expect(enc(.char(" "), [.ctrl]) == "\u{00}")
    #expect(enc(.char("["), [.ctrl]) == "\u{1B}")
    #expect(enc(.char("\\"), [.ctrl]) == "\u{1C}")
    #expect(enc(.char("]"), [.ctrl]) == "\u{1D}")
    #expect(enc(.char("/"), [.ctrl]) == "\u{1F}")
    #expect(enc(.char("c"), [.ctrl, .alt]) == ESC + "\u{03}")
}

@Test func arrowsNormalAndApplication() {
    #expect(enc(.up) == ESC + "[A")
    #expect(enc(.down, app: true) == ESC + "OB")
    #expect(enc(.right, [.shift]) == ESC + "[1;2C")
    #expect(enc(.left, [.alt, .ctrl], app: true) == ESC + "[1;7D")
    #expect(enc(.home) == ESC + "[H")
    #expect(enc(.end, app: true) == ESC + "OF")
    #expect(enc(.home, [.ctrl]) == ESC + "[1;5H")
}

@Test func editingKeys() {
    #expect(enc(.insert) == ESC + "[2~")
    #expect(enc(.delete) == ESC + "[3~")
    #expect(enc(.pageUp) == ESC + "[5~")
    #expect(enc(.pageDown, [.shift]) == ESC + "[6;2~")
    #expect(enc(.backspace) == "\u{7F}")
    #expect(enc(.backspace, [.ctrl]) == "\u{08}")
    #expect(enc(.backspace, [.alt]) == ESC + "\u{7F}")
    #expect(enc(.tab) == "\t")
    #expect(enc(.tab, [.shift]) == ESC + "[Z")
    #expect(enc(.enter) == "\r")
    #expect(enc(.enter, [.alt]) == ESC + "\r")
    #expect(enc(.escape) == ESC)
    #expect(enc(.escape, [.alt]) == ESC + ESC)
}

@Test func functionKeys() {
    #expect(enc(.f(1)) == ESC + "OP")
    #expect(enc(.f(4)) == ESC + "OS")
    #expect(enc(.f(1), [.shift]) == ESC + "[1;2P")
    #expect(enc(.f(5)) == ESC + "[15~")
    #expect(enc(.f(12)) == ESC + "[24~")
    #expect(enc(.f(12), [.ctrl]) == ESC + "[24;5~")
}

@Test func commandKeysAreNotTerminalInput() {
    #expect(enc(.char("c"), [.cmd], text: "c") == nil)
}

@Test func unknownFunctionKeysAreNil() {
    #expect(enc(.f(13)) == nil)
    #expect(enc(.f(0)) == nil)
    #expect(enc(.tab, [.shift, .alt]) == ESC + "[Z")   // shift+Tab ignores alt
}

// MARK: - Control chords on a non-Latin layout

/// A key press as the AppKit layer hands it over, built the way `Pane.keyEvent(from:)` builds it:
/// the key from `MacKeyCodes.bindingKey`, the composed text from `NSEvent.characters`, and the
/// keycap's own ASCII character from the key code.
///
/// The strings are not invented. They were read off this machine with the RussianWin layout
/// active, by handing a `CGEvent` for the key code to `NSEvent(cgEvent:)` -- so `characters` is
/// macOS's own translation, including the control states that layout happens to define.
private func layoutEnc(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String,
                       _ mods: KeyModifiers, meta: Bool = false,
                       other: ModifyOtherKeys = .off) -> String? {
    guard let key = MacKeyCodes.bindingKey(keyCode: keyCode, characters: characters,
                                           charactersIgnoringModifiers: charactersIgnoringModifiers,
                                           modifiers: mods) else { return nil }
    let e = KeyEvent(key: key, modifiers: mods, text: characters,
                     isKeypad: MacKeyCodes.isKeypad(keyCode),
                     baseLayoutKey: MacKeyCodes.asciiScalar(keyCode))
    return KeyEncoder.encode(e, options: KeyEncoderOptions(cursorKeysApp: false, optionAsMeta: meta,
                                                           keypadApp: false, modifyOtherKeys: other))
        .map { String(decoding: $0, as: UTF8.self) }
}

/// ⌃C must interrupt whatever layout is active. On a Cyrillic layout the C key's character is
/// `с` (U+0441), which has no control byte of its own, so the byte comes from the character the
/// same physical key carries on the ASCII layout -- kitty's "base layout key", Ghostty's
/// "logical key".
@Test func controlChordsFollowTheKeycapOnACyrillicLayout() {
    // keyCode, NSEvent.characters, NSEvent.charactersIgnoringModifiers, expected byte
    let cases: [(UInt16, String, String, String)] = [
        (8,  "\u{03}", "с", "\u{03}"),   // ⌃C -- SIGINT
        (6,  "\u{1A}", "я", "\u{1A}"),   // ⌃Z -- SIGTSTP
        (2,  "\u{04}", "в", "\u{04}"),   // ⌃D -- EOF
        (37, "\u{0C}", "д", "\u{0C}"),   // ⌃L -- clear
        (33, "\u{1B}", "х", "\u{1B}"),   // ⌃[ -- Escape
    ]
    for (code, chars, ignoring, expected) in cases {
        #expect(layoutEnc(keyCode: code, characters: chars,
                          charactersIgnoringModifiers: ignoring, [.ctrl]) == expected)
        // With ⌥ held as well the byte is the same, prefixed with ESC.
        #expect(layoutEnc(keyCode: code, characters: chars,
                          charactersIgnoringModifiers: ignoring, [.ctrl, .alt]) == ESC + expected)
    }
    // The backslash key is ASCII on RussianWin already, and answers as it always did.
    #expect(layoutEnc(keyCode: 42, characters: "\u{1C}", charactersIgnoringModifiers: "\\",
                      [.ctrl]) == "\u{1C}")
}

/// The four control characters that need shift on the ASCII keyboard. On RussianWin the shifted
/// characters are `"`, `:`, `_` and `,` -- three of which name no control byte, and none of which
/// macOS gives a control state to (`NSEvent.characters` is the plain digit or slash). The keycap
/// is what answers: ⇧2 is `@`, ⇧6 is `^`, ⇧- is `_`, ⇧/ is `?`.
@Test func shiftedControlPunctuationFollowsTheKeycapToo() {
    #expect(layoutEnc(keyCode: 19, characters: "2", charactersIgnoringModifiers: "\"",
                      [.ctrl, .shift]) == "\u{00}")           // ⌃@ -- NUL
    #expect(layoutEnc(keyCode: 22, characters: "6", charactersIgnoringModifiers: ":",
                      [.ctrl, .shift]) == "\u{1E}")           // ⌃^ -- RS
    // ⌃_ needs a layout whose ⇧- is not `_` to be the keycap's answer at all: RussianWin's is `_`,
    // so the character itself has the byte. On French AZERTY that key types `)` and `°`, and
    // macOS's own control state for it is ESC -- which is not what we use.
    #expect(layoutEnc(keyCode: 27, characters: "\u{1B}", charactersIgnoringModifiers: "°",
                      [.ctrl, .shift]) == "\u{1F}")           // ⌃_ -- US
    #expect(layoutEnc(keyCode: 44, characters: "/", charactersIgnoringModifiers: ",",
                      [.ctrl, .shift]) == "\u{7F}")           // ⌃? -- DEL
    // And a letter with shift: ⌃⇧C is ctrl+c, as it is on a US keyboard.
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "С",
                      [.ctrl, .shift]) == "\u{03}")
}

/// With ctrl alone the fallback must not invent a control byte for a key whose own character is
/// plain ASCII: on RussianWin the `/` keycap types `.`, and ⌃. is `.` -- not the 0x1F that the
/// keycap would give. This is kitty's rule (`!is_legacy_ascii_key(ev->key)` guards its own
/// fallback) and Ghostty's. With shift held the keycap does answer for an ASCII character that
/// names no byte -- RussianWin's ⌃⇧, is DEL, the same key's ⌃? on an ASCII keyboard -- which is
/// the deliberate half of the rule and is pinned in `shiftedControlPunctuationFollowsTheKeycapToo`.
@Test func aPlainAsciiCharacterIsNeverTurnedIntoAControlByte() {
    // RussianWin's `/` keycap types `.`, which names no control byte and does not become one.
    #expect(layoutEnc(keyCode: 44, characters: "/", charactersIgnoringModifiers: ".",
                      [.ctrl]) == ".")
    // ⌃, on the key beside it, whose ASCII legend `,` has no byte either way.
    #expect(layoutEnc(keyCode: 43, characters: "б", charactersIgnoringModifiers: "б",
                      [.ctrl]) == "б")
    // The German layout's ⇧- is `?`, so ⌃⇧- is DEL from the *character*; the keycap's `_` would
    // have said 0x1F, and this is the case that proves the order of the two.
    #expect(layoutEnc(keyCode: 27, characters: "?", charactersIgnoringModifiers: "?",
                      [.ctrl, .shift]) == "\u{7F}")
}

/// The measured half of the rule on the Latin layouts that are not US: the pairs come from
/// `UCKeyTranslate` against each layout's own `uchr` data on this machine (`com.apple.keylayout.*`,
/// read, never activated), so they are what AppKit would put in `charactersIgnoringModifiers`.
///
/// Two of these are a **change**: German ⌃⇧2 and ⌃⇧6 used to send `"` and `&`. kitty sends those
/// characters (its fallback stops at `is_legacy_ascii_key(ev->key)`, and `2` is one); Nyx sends the
/// keycap's NUL and RS, which is the same answer it gives a US keyboard. That is the deliberate
/// half of the rule, and this test is where it is visible.
@Test func theLatinLayoutsThatAreNotUS() {
    // German: ⇧2 is `"`, ⇧6 is `&`, ⇧- is `?`, ⇧/ is `_`, and the `[` keycap types `ü`.
    #expect(layoutEnc(keyCode: 19, characters: "\"", charactersIgnoringModifiers: "\"",
                      [.ctrl, .shift]) == "\u{00}")            // ⌃@
    #expect(layoutEnc(keyCode: 22, characters: "&", charactersIgnoringModifiers: "&",
                      [.ctrl, .shift]) == "\u{1E}")            // ⌃^
    #expect(layoutEnc(keyCode: 44, characters: "\u{1F}", charactersIgnoringModifiers: "_",
                      [.ctrl, .shift]) == "\u{1F}")            // ⌃_, from the character
    #expect(layoutEnc(keyCode: 33, characters: "\u{1D}", charactersIgnoringModifiers: "ü",
                      [.ctrl]) == "\u{1B}")                    // ⌃[ -- Escape, like kitty
    // French AZERTY: the digit row is `&é"'(` unshifted, so ⌃1 is the `&` it types and ⌃2 is the
    // `é` -- and NUL comes out of the keycap through the digit aliases, as it does in kitty.
    #expect(layoutEnc(keyCode: 18, characters: "&", charactersIgnoringModifiers: "&",
                      [.ctrl]) == "&")
    #expect(layoutEnc(keyCode: 19, characters: "2", charactersIgnoringModifiers: "é",
                      [.ctrl]) == "\u{00}")
    // Spanish: ⇧6 is `/`, which has a control byte of its own and keeps it.
    #expect(layoutEnc(keyCode: 22, characters: "6", charactersIgnoringModifiers: "/",
                      [.ctrl, .shift]) == "\u{1F}")
    // Dvorak: the C keycap types `j`, and a Latin letter always answers for itself.
    #expect(layoutEnc(keyCode: 8, characters: "\u{0A}", charactersIgnoringModifiers: "j",
                      [.ctrl]) == "\u{0A}")
    // British (Mac) is ASCII-identical to ABC on every key in this rule -- measured, not assumed.
    #expect(layoutEnc(keyCode: 19, characters: "@", charactersIgnoringModifiers: "@",
                      [.ctrl, .shift]) == "\u{00}")
}

/// The digit row's aliases: ⌃2 is ⌃@, ⌃3...⌃7 are ⌃[ to ⌃_, ⌃8 is ⌃?. xterm lists them as X11
/// translations, kitty's `ctrled_key` generates exactly this set, Ghostty repeats it, and iTerm2's
/// switch says "control-number comes from xterm". ⌃1, ⌃9 and ⌃0 have no control character.
@Test func theDigitRowCarriesTheControlAliases() {
    let expected: [(Unicode.Scalar, String)] = [
        ("2", "\u{00}"), ("3", "\u{1B}"), ("4", "\u{1C}"), ("5", "\u{1D}"),
        ("6", "\u{1E}"), ("7", "\u{1F}"), ("8", "\u{7F}"),
        ("1", "1"), ("9", "9"), ("0", "0"),
    ]
    for (digit, bytes) in expected {
        #expect(enc(.char(digit), [.ctrl], text: String(digit)) == bytes)
        #expect(enc(.char(digit), [.ctrl, .alt], text: String(digit)) == ESC + bytes)
    }
}

/// The keypad is not the number row. xterm reports `modifyKeypadKeys` as 0 -- keypad keys are not
/// modified however many modifiers are held -- and a keypad key has no second legend, so it gets
/// neither the digit aliases nor the keycap: ⌃keypad-2 is "2", not NUL.
@Test func theKeypadGetsNeitherTheAliasesNorTheKeycap() {
    #expect(layoutEnc(keyCode: 84, characters: "2", charactersIgnoringModifiers: "2",
                      [.ctrl]) == "2")
    #expect(layoutEnc(keyCode: 84, characters: "2", charactersIgnoringModifiers: "2",
                      [.ctrl, .shift]) == "2")
    #expect(layoutEnc(keyCode: 88, characters: "6", charactersIgnoringModifiers: "6",
                      [.ctrl]) == "6")
    // What the keypad keeps is the character's own byte, which is what it always sent.
    #expect(layoutEnc(keyCode: 75, characters: "/", charactersIgnoringModifiers: "/",
                      [.ctrl]) == "\u{1F}")
}

/// Typing is untouched: without ctrl the character the layout made is what reaches the shell,
/// and ⌥ still sends the layout's own character after the ESC rather than the keycap's.
@Test func plainTypingAndOptionAreUnchangedOnACyrillicLayout() {
    #expect(layoutEnc(keyCode: 8, characters: "с", charactersIgnoringModifiers: "с", []) == "с")
    #expect(layoutEnc(keyCode: 8, characters: "С", charactersIgnoringModifiers: "С",
                      [.shift]) == "С")
    #expect(layoutEnc(keyCode: 8, characters: "с", charactersIgnoringModifiers: "с",
                      [.alt]) == "с")
    #expect(layoutEnc(keyCode: 8, characters: "с", charactersIgnoringModifiers: "с",
                      [.alt], meta: true) == ESC + "с")
    #expect(layoutEnc(keyCode: 8, characters: "с", charactersIgnoringModifiers: "с",
                      [.cmd]) == nil)
}

/// modifyOtherKeys reports the *layout's* code point, not the keycap's: xterm derives the code
/// from the keysym (`keysym2ucs` for anything outside Latin-1), and Ghostty and iTerm2 both read
/// it off the character. So ⌃C on a Cyrillic layout is `CSI 27;5;1089~` -- U+0441 -- while the
/// legacy byte for the same press is 0x03.
@Test func modifyOtherKeysReportsTheLayoutsCodePoint() {
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "с",
                      [.ctrl], other: .allOtherKeys) == ESC + "[27;5;1089~")
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "С",
                      [.ctrl, .shift], other: .allOtherKeys) == ESC + "[27;6;1057~")
    // Level 1 rewrites only what the legacy encoding loses. ⌃C on a Cyrillic layout now *has* a
    // legacy byte, so it keeps it -- exactly as ⌃C does on a US layout.
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "с",
                      [.ctrl], other: .ambiguousOnly) == "\u{03}")
    // ⌃⇧C loses the shift in the legacy byte, so level 1 does report it.
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "С",
                      [.ctrl, .shift], other: .ambiguousOnly) == ESC + "[27;6;1057~")
}

/// The ASCII layout cannot change: for every key on it the layout's character *is* the keycap's,
/// so the fallback can only ever agree with what the encoder already did.
@Test func theAsciiLayoutIsUnaffectedByTheFallback() {
    #expect(layoutEnc(keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "c",
                      [.ctrl]) == "\u{03}")
    #expect(layoutEnc(keyCode: 33, characters: "\u{1B}", charactersIgnoringModifiers: "[",
                      [.ctrl]) == "\u{1B}")
    #expect(layoutEnc(keyCode: 19, characters: "@", charactersIgnoringModifiers: "@",
                      [.ctrl, .shift]) == "\u{00}")
    #expect(layoutEnc(keyCode: 22, characters: "^", charactersIgnoringModifiers: "^",
                      [.ctrl, .shift]) == "\u{1E}")
    #expect(layoutEnc(keyCode: 44, characters: "?", charactersIgnoringModifiers: "?",
                      [.ctrl, .shift]) == "\u{7F}")
    // A key off the ANSI block has no keycap character, and nothing to fall back to.
    #expect(layoutEnc(keyCode: 10, characters: "§", charactersIgnoringModifiers: "§",
                      [.ctrl]) == "§")
}
