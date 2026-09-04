public enum MouseButton: Int, Equatable {
    case left = 0, middle = 1, right = 2, wheelUp = 64, wheelDown = 65
}

public enum MouseAction: Equatable { case press, release, drag, move }

public struct MouseEvent: Equatable {
    public var button: MouseButton
    public var action: MouseAction
    /// 0-based cell column and viewport-relative row.
    public var col: Int
    public var row: Int
    public var modifiers: KeyModifiers

    public init(button: MouseButton, action: MouseAction, col: Int, row: Int, modifiers: KeyModifiers) {
        self.button = button
        self.action = action
        self.col = col
        self.row = row
        self.modifiers = modifiers
    }
}

/// Encodes mouse events the way xterm does, in either the SGR form (mode 1006) or the original
/// byte-offset form. See xterm's `ctlseqs`, "Mouse Tracking".
public enum MouseEncoder {
    public static func encode(_ e: MouseEvent, mode: MouseMode, sgr: Bool) -> [UInt8]? {
        guard e.col >= 0, e.row >= 0 else { return nil }
        guard wants(e.action, in: mode) else { return nil }

        var code = e.action == .move ? 3 : e.button.rawValue
        if e.action == .drag || e.action == .move { code += 32 }
        // X10 reports the raw button with no modifier bits at all.
        if mode != .x10 {
            if e.modifiers.contains(.shift) { code += 4 }
            if e.modifiers.contains(.alt) { code += 8 }
            if e.modifiers.contains(.ctrl) { code += 16 }
        }

        if sgr {
            let final = e.action == .release ? "m" : "M"
            return Array("\u{1B}[<\(code);\(e.col + 1);\(e.row + 1)\(final)".utf8)
        }

        // The original encoding has one byte per field, biased by 32, so it cannot express a
        // coordinate past 222. Sending a wrong position is worse than sending nothing.
        guard e.col < 223, e.row < 223 else { return nil }
        // It also has no way to say which button was released: 3 means "some button came up".
        let legacyCode = e.action == .release ? (code - e.button.rawValue) + 3 : code
        guard legacyCode >= 0, legacyCode < 223 else { return nil }
        return Array("\u{1B}[M".utf8) + [UInt8(32 + legacyCode), UInt8(32 + e.col + 1), UInt8(32 + e.row + 1)]
    }

    private static func wants(_ action: MouseAction, in mode: MouseMode) -> Bool {
        switch mode {
        case .none: return false
        case .x10: return action == .press
        case .normal: return action == .press || action == .release
        case .button: return action != .move
        case .any: return true
        }
    }
}
