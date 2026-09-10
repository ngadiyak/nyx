public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt   = KeyModifiers(rawValue: 2)
    public static let ctrl  = KeyModifiers(rawValue: 4)
    public static let cmd   = KeyModifiers(rawValue: 8)
}

public enum Key: Hashable {
    case char(Unicode.Scalar)
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, tab, enter, escape
    case f(Int)
}

public struct KeyEvent: Equatable {
    public var key: Key
    public var modifiers: KeyModifiers
    /// The text macOS composed for this key (dead keys, Option-symbols, IME). Used for plain character input.
    public var text: String?
    /// Whether the key was pressed on the numeric keypad rather than on the main block.
    ///
    /// A property of the event, not of the key: `.char("1")` and `.enter` are the same logical keys
    /// wherever they were pressed, and only application-keypad mode (DECKPAM) cares which physical
    /// key it was. Defaulted so every existing construction keeps its meaning.
    public var isKeypad: Bool
    /// The unshifted character the pressed key carries on the ASCII layout -- the letter printed
    /// on the keycap -- when the platform can name it, from `MacKeyCodes.asciiScalar(keyCode)`.
    ///
    /// `key` is the character the *active* layout made, because that is what typing must send. It
    /// is not enough for a control chord: on a Cyrillic layout the C key's character is `с`
    /// (U+0441), which names no control byte, and ⌃C would send two bytes of UTF-8 instead of
    /// 0x03 and interrupt nothing. This is the second answer the encoder needs -- kitty calls it
    /// the *base layout key*, Ghostty the *logical key* -- and it is nil for a key with no ASCII
    /// identity at all (the ISO `§` key, JIS's extra keys), where there is nothing to fall back to.
    public var baseLayoutKey: Unicode.Scalar?
    public init(key: Key, modifiers: KeyModifiers, text: String?, isKeypad: Bool = false,
                baseLayoutKey: Unicode.Scalar? = nil) {
        self.key = key; self.modifiers = modifiers; self.text = text; self.isKeypad = isKeypad
        self.baseLayoutKey = baseLayoutKey
    }
}

/// xterm's `modifyOtherKeys` resource, set by the application with XTMODKEYS `CSI > 4 ; Pv m`.
///
/// The point of the mode is that a terminal's legacy encoding is lossy: ctrl+Tab and Tab both
/// arrive as 0x09, ctrl+Enter and Enter both as 0x0D, ctrl+shift+a and ctrl+a both as 0x01. An
/// application that wants to bind those has no way to tell them apart until it turns this on.
///
/// **Why xterm's protocol and not kitty's.** Both were on the table; kitty's is the more capable
/// one and is on the roadmap (spec §11, stage 3). Two things decided it for now. `TERM` is
/// `xterm-256color` (`TerminalSession`), and applications pick their key protocol from `TERM`:
/// Vim's built-in default is `keyprotocol=xterm:mok2`, so on this `TERM` Vim asks for
/// modifyOtherKeys level 2 and parses what xterm sends back -- it would never send the kitty
/// query. And kitty's protocol is not a mode but a stack of five progressive-enhancement flags
/// with push/pop/query, per screen; supporting only its first flag would answer the query with a
/// half-truth, which is worse than answering the xterm query with the whole one.
public enum ModifyOtherKeys: Int, Equatable {
    /// Legacy encoding for everything. Byte-for-byte what the terminal sent before this mode existed.
    case off = 0
    /// `CSI > 4 ; 1 m`. Conservative: character keys only, and only where the legacy bytes are
    /// already taken by another combination of the same key.
    ///
    /// xterm documents this level as "modify other keys except for those with well-known
    /// behavior" -- Tab, Backspace, Return, Escape and ctrl+space -- and we keep that exemption.
    /// The additional restriction to *ambiguous* combinations is ours, not a claim about xterm:
    /// it is the reading that makes level 1 worth having as something distinct from level 2, and
    /// it errs towards the legacy bytes, which is the safe direction for a level applications
    /// rarely ask for. Everything that actually wants ctrl+Tab and ctrl+Enter asks for level 2,
    /// which is unambiguous and where the conformance that matters was checked.
    case ambiguousOnly = 1
    /// `CSI > 4 ; 2 m`. Rewrite every modified key the protocol covers, including the well-known
    /// ones. This is the level applications actually ask for (Vim's `mok2`), and the level that
    /// makes ctrl+Tab and ctrl+Enter distinguishable.
    ///
    /// It also takes ctrl+c away from the tty line discipline -- the shell would never see 0x03 --
    /// which is why no terminal turns it on by itself and why applications send `CSI > 4 ; 0 m`
    /// when they exit.
    case allOtherKeys = 2
}

public struct KeyEncoderOptions: Equatable {
    public var cursorKeysApp: Bool
    public var optionAsMeta: Bool
    /// DECKPAM/DECKPNM. In vim, `htop` and anything else built on terminfo's `smkx`, the keypad
    /// must send SS3 sequences rather than digits, or the keys are indistinguishable from typing.
    public var keypadApp: Bool
    public var modifyOtherKeys: ModifyOtherKeys
    public init(cursorKeysApp: Bool, optionAsMeta: Bool,
                keypadApp: Bool = false, modifyOtherKeys: ModifyOtherKeys = .off) {
        self.cursorKeysApp = cursorKeysApp
        self.optionAsMeta = optionAsMeta
        self.keypadApp = keypadApp
        self.modifyOtherKeys = modifyOtherKeys
    }
}

/// xterm-compatible key encoding.
public enum KeyEncoder {
    public static func encode(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        if e.modifiers.contains(.cmd) { return nil }
        // Application keypad first: xterm's `modifyKeypadKeys` defaults to leaving keypad keys
        // unmodified, so modifyOtherKeys never sees them however many modifiers are held.
        if let bytes = applicationKeypad(e, options: options) { return bytes }
        if let bytes = modifiedOtherKey(e, options: options) { return bytes }
        return legacy(e, options: options)
    }

    // MARK: - Application keypad (DECKPAM)

    /// The SS3 sequence for a keypad key, or nil when this is not a keypad key in keypad mode.
    ///
    /// Terminfo calls these `ka1`/`kb2`/`kc1`... ; xterm sends `ESC O p` through `ESC O y` for the
    /// digits and `ESC O M` for keypad Enter. vim reads them to tell keypad `1` from the `1` on the
    /// main row -- with `:map <k1>` bound and the keypad sending plain digits, the map can never
    /// fire, which is the bug this closes.
    ///
    /// Modifiers are dropped rather than encoded, which is xterm with its default
    /// `modifyKeypadKeys` (report the value 0 to XTQMODKEYS: keypad keys are not modified). alt
    /// still prefixes ESC, because that is metaSendsEscape and orthogonal to the keypad.
    private static func applicationKeypad(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        guard e.isKeypad, options.keypadApp else { return nil }
        let final: String
        switch e.key {
        case .enter: final = "M"
        case .char(let s):
            switch s {
            case "0": final = "p"
            case "1": final = "q"
            case "2": final = "r"
            case "3": final = "s"
            case "4": final = "t"
            case "5": final = "u"
            case "6": final = "v"
            case "7": final = "w"
            case "8": final = "x"
            case "9": final = "y"
            case ".": final = "n"
            case ",": final = "l"
            case "+": final = "k"
            case "-": final = "m"
            case "*": final = "j"
            case "/": final = "o"
            case "=": final = "X"
            // Keypad Clear and anything else a non-US layout puts here has no SS3 form; falling
            // through sends the character, which is what it did before keypad mode existed.
            default: return nil
            }
        default: return nil
        }
        let ss3 = Array("\u{1B}O\(final)".utf8)
        return e.modifiers.contains(.alt) ? [0x1B] + ss3 : ss3
    }

    // MARK: - modifyOtherKeys

    /// The keys this protocol covers, as the code the sequence reports for them.
    ///
    /// The rule is one line: the code is what the *unmodified* key sends -- its code point for a
    /// character, the control byte for the rest. So an application can map the code back onto the
    /// same key it would have got from legacy input, with no table of its own. Backspace is 127
    /// rather than 8 for exactly that reason: 127 is what we send when nothing is held.
    ///
    /// Cursor, editing and function keys are absent on purpose: they already carry the modifier in
    /// their own parameter (`CSI 1;5D`), so they were never ambiguous, and xterm modifies them
    /// through the separate `modifyCursorKeys` / `modifyFunctionKeys` resources.
    private static func otherKeyCode(_ key: Key) -> UInt32? {
        switch key {
        case .char(let s): return s.value
        case .tab: return 9
        case .enter: return 13
        case .backspace: return 127
        case .escape: return 27
        default: return nil
        }
    }

    /// `CSI 27 ; modifier ; code ~`, or nil when this combination stays on the legacy encoding.
    ///
    /// The wire format is xterm's default (`formatOtherKeys` 0), not the `CSI code ; modifier u`
    /// spelling the protocol is colloquially named after. An application that asked for
    /// modifyOtherKeys asked xterm's question and must get xterm's answer: on `TERM=xterm-256color`
    /// Vim's `mok2` parser expects exactly this shape. (Vim happens to accept both forms; a
    /// hand-rolled parser that reads `27;mod;code~` because that is what xterm sends does not.)
    private static func modifiedOtherKey(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        let level = options.modifyOtherKeys
        guard level != .off else { return nil }
        guard let code = otherKeyCode(e.key) else { return nil }
        let m = e.modifiers
        var isChar = false
        if case .char = e.key { isChar = true }

        // Option is only a modifier when the user asked for it to be Meta; otherwise it composes
        // characters (alt+o is "ø"), and reporting it would turn every composed character into an
        // escape sequence. Tab, Enter, Backspace and Escape compose nothing, so option always
        // modifies them -- which is also what the legacy encoding here already assumes.
        let altModifies = m.contains(.alt) && (isChar ? options.optionAsMeta : true)
        // Shift is not a modifier of a character key: it is already inside the character, and
        // `.char("A")` is a different key from `.char("a")`.
        let shiftModifies = m.contains(.shift) && !isChar

        guard m.contains(.ctrl) || altModifies || shiftModifies else { return nil }

        // shift+Tab keeps CSI Z at every level. On X11 that combination is its own keysym
        // (ISO_Left_Tab), so it never reaches xterm's other-keys path, and every application that
        // reads back-tab reads CSI Z.
        if case .tab = e.key, m.contains(.shift), !m.contains(.ctrl), !m.contains(.alt) { return nil }

        if level == .ambiguousOnly {
            // Level 1 keeps xterm's exemption for keys with well-known behaviour -- Tab, Backspace,
            // Return, Escape and ctrl+space stay legacy however ambiguous they are, which is why
            // applications that want ctrl+Tab ask for level 2 -- and adds a restriction of our own
            // to combinations whose legacy bytes are genuinely ambiguous. See `ambiguousOnly`.
            guard isChar else { return nil }
            guard !(m.contains(.ctrl) && code == 0x20) else { return nil }
            guard isAmbiguous(e) else { return nil }
        }

        let param = modifierParameter(m)
        return Array("\u{1B}[27;\(param);\(code)~".utf8)
    }

    /// Whether the legacy bytes for this character key are already spoken for by another
    /// combination the user can type, so an application receiving them cannot tell which was meant.
    ///
    /// Only two cases produce a collision, and both come straight out of `legacy` below:
    /// ctrl on a key with no control-character mapping falls through to the bare character
    /// (ctrl+1 arrives as "1"), and shift is dropped on a key that does have one (ctrl+shift+a and
    /// ctrl+a both arrive as 0x01).
    private static func isAmbiguous(_ e: KeyEvent) -> Bool {
        guard e.modifiers.contains(.ctrl) else { return false }
        if controlByte(for: e) == nil { return true }
        return e.modifiers.contains(.shift)
    }

    private static func modifierParameter(_ m: KeyModifiers) -> Int {
        1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.ctrl) ? 4 : 0)
    }

    /// The control character this key press produces with ctrl held, or nil when it produces none.
    ///
    /// The layout's own character answers first, so a chord the user can see on their keyboard is
    /// never re-interpreted: ⌃/ is 0x1F on a US layout and, on RussianWin, where that keycap types
    /// `.`, ⌃. is still `.`. Only when the layout's character cannot name a control byte does the
    /// keycap answer, and then only in the two cases where the character is not a chord the user
    /// could have meant:
    ///
    /// - the character is not ASCII (⌃с, ⌃х), which is kitty's rule verbatim -- its fallback to
    ///   `ev->alternate_key` is guarded by `!is_legacy_ascii_key(ev->key)` -- and Ghostty's, whose
    ///   `ctrlSeq` reaches for the logical key with the comment "this was added to support cyrillic
    ///   keyboard layouts such as Russian and Mongolian ... but every terminal I've tested encodes
    ///   this as ctrl+c";
    /// - shift is held, where the character is whatever glyph *that* layout puts on shift and the
    ///   four control characters that need shift on a PC keyboard (⌃@, ⌃^, ⌃_, ⌃?) would otherwise
    ///   be unreachable. kitty and Ghostty both refuse the fallback here and send `CSI code;mod u`
    ///   instead, which is the kitty protocol -- a protocol Nyx does not implement (see
    ///   `ModifyOtherKeys`), so the choice is the keycap's byte or nothing. The invariant kept
    ///   here is that the same physical chord types the same byte on every layout.
    ///
    /// The keycap is `baseLayoutKey`, shifted through `MacKeyCodes.shiftedAscii` when shift is
    /// held, because `⇧2` is `@` on the keyboard whatever the layout makes of it.
    private static func controlByte(for e: KeyEvent) -> UInt8? {
        guard case .char(let s) = e.key else { return nil }
        if let b = controlByte(for: s) { return b }
        let shift = e.modifiers.contains(.shift)
        guard !s.isASCII || shift, let cap = e.baseLayoutKey else { return nil }
        return controlByte(for: shift ? MacKeyCodes.shiftedAscii(cap) : cap)
    }

    /// The control character a character key produces when ctrl is held, or nil when it produces
    /// none.
    private static func controlByte(for s: Unicode.Scalar) -> UInt8? {
        switch s.value {
        case 0x61...0x7A: return UInt8(s.value - 0x60)          // a-z
        case 0x41...0x5A: return UInt8(s.value - 0x40)          // A-Z
        case 0x40, 0x20: return 0x00                            // @ space
        case 0x5B...0x5F: return UInt8(s.value - 0x40)          // [ \ ] ^ _
        case 0x2F: return 0x1F                                  // /
        case 0x3F: return 0x7F                                  // ?
        default: return nil
        }
    }

    // MARK: - Legacy encoding

    private static func legacy(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        let m = e.modifiers
        let param = modifierParameter(m)
        let esc: UInt8 = 0x1B

        func cursor(_ final: String) -> [UInt8] {
            if param == 1 { return Array((options.cursorKeysApp ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8) }
            return Array("\u{1B}[1;\(param)".utf8) + Array(final.utf8)
        }
        func tilde(_ code: Int) -> [UInt8] {
            param == 1 ? Array("\u{1B}[\(code)~".utf8) : Array("\u{1B}[\(code);\(param)~".utf8)
        }
        func withAlt(_ bytes: [UInt8]) -> [UInt8] { m.contains(.alt) ? [esc] + bytes : bytes }

        switch e.key {
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .backspace: return withAlt([m.contains(.ctrl) ? 0x08 : 0x7F])
        case .tab: return m.contains(.shift) ? Array("\u{1B}[Z".utf8) : withAlt([0x09])
        case .enter: return withAlt([0x0D])
        case .escape: return withAlt([esc])
        case .f(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                return param == 1 ? Array("\u{1B}O\(final)".utf8) : Array("\u{1B}[1;\(param)\(final)".utf8)
            case 5: return tilde(15)
            case 6: return tilde(17)
            case 7: return tilde(18)
            case 8: return tilde(19)
            case 9: return tilde(20)
            case 10: return tilde(21)
            case 11: return tilde(23)
            case 12: return tilde(24)
            default: return nil
            }
        case .char(let s):
            if m.contains(.ctrl) {
                if let b = controlByte(for: e) { return withAlt([b]) }
                return withAlt(Array(String(s).utf8))
            }
            if m.contains(.alt) && options.optionAsMeta {
                return [esc] + Array(String(s).utf8)
            }
            if let t = e.text, !t.isEmpty { return Array(t.utf8) }
            return Array(String(s).utf8)
        }
    }
}
