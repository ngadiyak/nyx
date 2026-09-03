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
