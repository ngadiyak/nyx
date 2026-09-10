/// The handful of macOS virtual key codes the encoder has to know about by number.
///
/// Numbers, not AppKit constants: `NyxCore` cannot import AppKit, and these are the same codes
/// `kVK_ANSI_Keypad*` names in Carbon's `Events.h` -- fixed for the life of the platform. The
/// AppKit layer passes `NSEvent.keyCode` straight through.
public enum MacKeyCodes {
    /// The keys on the numeric keypad, as opposed to the ones on the main block that produce the
    /// same characters.
    ///
    /// `NSEvent.modifierFlags.numericPad` cannot answer this: macOS sets that flag for the arrow
    /// keys too, so a terminal that trusted it would send keypad sequences for the cursor keys.
    /// The key codes are unambiguous.
    ///
    /// `kVK_ANSI_KeypadClear` (71) is deliberately absent: the Mac keypad has no NumLock, and Clear
    /// reports itself as `NSClearLineFunctionKey`, which no application-keypad sequence describes.
    public static func isKeypad(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 65,                    // KeypadDecimal
             67,                    // KeypadMultiply
             69,                    // KeypadPlus
             75,                    // KeypadDivide
             76,                    // KeypadEnter
             78,                    // KeypadMinus
             81,                    // KeypadEquals
             82...89,               // Keypad0...Keypad7
             91, 92:                // Keypad8, Keypad9
            return true
        default:
            return false
        }
    }

    /// The named key a key code stands for, or nil for a key that produces a character.
    ///
    /// By code and never by character: an arrow key's `characters` is empty on some layouts and a
    /// private-use function-key scalar on others, and `Home`/`End` share theirs with nothing.
    public static func namedKey(_ keyCode: UInt16) -> Key? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .delete
        case 114: return .insert
        case 51: return .backspace
        case 48: return .tab
        case 36, 76: return .enter
        case 53: return .escape
        case 122: return .f(1)
        case 120: return .f(2)
        case 99: return .f(3)
        case 118: return .f(4)
        case 96: return .f(5)
        case 97: return .f(6)
        case 98: return .f(7)
        case 100: return .f(8)
        case 101: return .f(9)
        case 109: return .f(10)
        case 103: return .f(11)
        case 111: return .f(12)
        default: return nil
        }
    }

    /// The unshifted ASCII character the key at this code carries on the ANSI block -- the letter
    /// printed on the keycap, whatever the active input source translates it to.
    ///
    /// A static table rather than `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` +
    /// `UCKeyTranslate`: those live in Carbon, which `NyxCore` cannot import, and the answer for
    /// every code below is the same on every ASCII-capable layout, because that is what makes a
    /// layout ASCII-capable. It is deliberately only the ANSI block plus the keypad; anything else
    /// (the ISO `§` key, JIS's extra keys) has no ASCII identity and falls back to the event.
    public static func asciiScalar(_ keyCode: UInt16) -> Unicode.Scalar? {
        switch keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "o"
        case 32: return "u"
        case 33: return "["
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 39: return "'"
        case 40: return "k"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "n"
        case 46: return "m"
        case 47: return "."
        case 49: return " "
        case 50: return "`"
        // The keypad. Its characters do not depend on the layout either, and a chord pressed there
        // is the same chord: ⌘ and the keypad `+` is zoom in.
        case 65: return "."
        case 67: return "*"
        case 69: return "+"
        case 75: return "/"
        case 78: return "-"
        case 81: return "="
        case 82: return "0"
        case 83: return "1"
        case 84: return "2"
        case 85: return "3"
        case 86: return "4"
        case 87: return "5"
        case 88: return "6"
        case 89: return "7"
        case 91: return "8"
        case 92: return "9"
        default: return nil
        }
    }

    /// Which `Key` a key press means *as a chord*, as opposed to as text.
    ///
    /// A binding names a physical key. `charactersIgnoringModifiers` is the active layout's
    /// character for it, so on a Cyrillic layout the C key reports U+0441 and no default chord can
    /// ever match: ⌘C, ⌘F, ⌘⇧D and every other binding the pane matches itself is dead, and the
    /// only reason the app is usable is that `NSMenu` matches its key equivalents against the
    /// ASCII-capable layout instead. This is the same translation, so the two agree.
    ///
    /// Only when ⌘ is held, and only then:
    ///
    /// - ⌘ is what makes a key press a chord rather than input. `KeyEncoder` refuses every ⌘ chord
    ///   (`encode` returns nil), so nothing derived here can reach the PTY, and translating cannot
    ///   put a character the user did not type into their shell.
    /// - Without ⌘ the character *is* the answer: typing `п` must send `п`, and `.char("П")` is a
    ///   different key from `.char("п")` to `modifyOtherKeys`, so the case is kept as well.
    /// - ctrl alone is left to the encoder for the same reason -- ctrl+key has a byte to produce
    ///   and its case is part of the report. (ctrl+C on a Cyrillic layout is therefore still the
    ///   encoder's business, not a binding's.)
    ///
    /// The scalar is lowercased, because `charactersIgnoringModifiers` applies shift -- the event
    /// for ⌘⇧D says `D` -- while `keybind` lines and the defaults are stored lowercase with shift
    /// in the modifier set. Punctuation is settled by the same rule from the other end: the key
    /// code says `=`, so ⌘⇧= matches a binding written `cmd+shift+=` rather than one written for
    /// whichever glyph the layout puts on shift.
    public static func bindingKey(keyCode: UInt16, characters: String?,
                                  charactersIgnoringModifiers: String?,
                                  modifiers: KeyModifiers) -> Key? {
        if let named = namedKey(keyCode) { return named }
        guard modifiers.contains(.cmd) else {
            guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
            return .char(scalar)
        }
        if let ascii = asciiScalar(keyCode) { return .char(ascii) }
        // Off the ANSI block: `characters` first, because with ⌘ held macOS puts the ASCII-capable
        // translation there, and the layout's own character only as a last resort.
        let fallback = characters?.unicodeScalars.first ?? charactersIgnoringModifiers?.unicodeScalars.first
        guard let fallback, let lowered = String(fallback).lowercased().unicodeScalars.first else { return nil }
        return .char(lowered)
    }
}
