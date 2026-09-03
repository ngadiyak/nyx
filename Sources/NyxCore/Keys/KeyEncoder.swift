public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt   = KeyModifiers(rawValue: 2)
    public static let ctrl  = KeyModifiers(rawValue: 4)
    public static let cmd   = KeyModifiers(rawValue: 8)
}

public enum Key: Equatable {
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
    public init(key: Key, modifiers: KeyModifiers, text: String?) {
        self.key = key; self.modifiers = modifiers; self.text = text
    }
}

public struct KeyEncoderOptions: Equatable {
    public var cursorKeysApp: Bool
    public var keypadApp: Bool
    public var optionAsMeta: Bool
    public init(cursorKeysApp: Bool, keypadApp: Bool, optionAsMeta: Bool) {
        self.cursorKeysApp = cursorKeysApp; self.keypadApp = keypadApp; self.optionAsMeta = optionAsMeta
    }
}

/// xterm-compatible key encoding.
public enum KeyEncoder {
    public static func encode(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        let m = e.modifiers
        if m.contains(.cmd) { return nil }
        let param = 1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.ctrl) ? 4 : 0)
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
                let v = s.value
                var byte: UInt8?
                switch v {
                case 0x61...0x7A: byte = UInt8(v - 0x60)          // a-z
                case 0x41...0x5A: byte = UInt8(v - 0x40)          // A-Z
                case 0x40, 0x20: byte = 0x00                      // @ space
                case 0x5B...0x5F: byte = UInt8(v - 0x40)          // [ \ ] ^ _
                case 0x2F: byte = 0x1F                            // /
                case 0x3F: byte = 0x7F                            // ?
                default: byte = nil
                }
                if let b = byte { return withAlt([b]) }
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
