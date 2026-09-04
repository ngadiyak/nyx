/// Everything a key or menu item can trigger. The app switches on this in one place.
public enum TerminalAction: String, Equatable, CaseIterable {
    case newWindow = "new_window", newTab = "new_tab", closePane = "close_pane"
    case nextTab = "next_tab", previousTab = "previous_tab"
    case tab1 = "tab_1", tab2 = "tab_2", tab3 = "tab_3", tab4 = "tab_4", tab5 = "tab_5"
    case tab6 = "tab_6", tab7 = "tab_7", tab8 = "tab_8", tab9 = "tab_9"
    case splitRight = "split_right", splitDown = "split_down"
    case focusLeft = "focus_left", focusRight = "focus_right"
    case focusUp = "focus_up", focusDown = "focus_down"
    case growLeft = "grow_left", growRight = "grow_right", growUp = "grow_up", growDown = "grow_down"
    case toggleZoom = "toggle_zoom"
    case copy = "copy", paste = "paste", clearScreen = "clear_screen"
    case fontBigger = "font_bigger", fontSmaller = "font_smaller", fontReset = "font_reset"
    case openConfig = "open_config", reloadConfig = "reload_config"
    case previousPrompt = "previous_prompt", nextPrompt = "next_prompt"
    case selectCommandOutput = "select_command_output", copyCommandOutput = "copy_command_output"
    case find = "find", findNext = "find_next", findPrevious = "find_previous"
    case commandPalette = "command_palette"
    case foldCommand = "fold_command", foldAllLongOutput = "fold_all_long_output"
    case saveScrollback = "save_scrollback"
}

/// A parsed `modifier+modifier+key=action` line from the config's `keybind` setting.
public struct KeyBinding: Equatable {
    public var key: Key
    public var modifiers: KeyModifiers
    public var action: TerminalAction
    public init(key: Key, modifiers: KeyModifiers, action: TerminalAction) {
        self.key = key; self.modifiers = modifiers; self.action = action
    }

    /// Parses one `keybind` value, e.g. "cmd+shift+d=split_down". Returns nil on any error.
    ///
    /// The chord is split on the *last* `=` (so `cmd+,=open_config` works even though `,` is not
    /// the separator), then the chord is split on `+`; the final component is the key and
    /// everything before it is modifiers. A chord whose key part is empty -- as in the ambiguous
    /// `cmd+=+=font_bigger`, where the trailing `+` leaves nothing after it -- is rejected rather
    /// than guessed.
    public static func parse(_ s: String) -> KeyBinding? {
        guard let eq = s.lastIndex(of: "=") else { return nil }
        let chordPart = String(s[s.startIndex..<eq])
        let actionPart = String(s[s.index(after: eq)...])
        guard !chordPart.isEmpty, !actionPart.isEmpty else { return nil }
        guard let action = TerminalAction(rawValue: actionPart) else { return nil }

        let comps = chordPart.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyToken = comps.last, !keyToken.isEmpty else { return nil }
        guard let modifiers = parseModifiers(comps.dropLast()) else { return nil }
        guard let key = parseKeyToken(keyToken) else { return nil }

        return KeyBinding(key: key, modifiers: modifiers, action: action)
    }

    private static func parseModifiers<S: Sequence>(_ tokens: S) -> KeyModifiers? where S.Element == String {
        var mods: KeyModifiers = []
        for token in tokens {
            switch token.lowercased() {
            case "cmd": mods.insert(.cmd)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        return mods
    }

    /// A single character keeps its case only insofar as we always normalise it to lowercase --
    /// `shift` must be given explicitly to mean an uppercase-ish chord -- while a multi-character
    /// token is looked up case-insensitively against the named keys.
    private static func parseKeyToken(_ raw: String) -> Key? {
        if raw.count == 1 {
            let normalized = raw.lowercased()
            guard normalized.unicodeScalars.count == 1, let scalar = normalized.unicodeScalars.first else { return nil }
            return .char(scalar)
        }
        return namedKey(raw.lowercased())
    }

    private static func namedKey(_ lower: String) -> Key? {
        switch lower {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "escape", "esc": return .escape
        case "space": return .char(" ")
        case "backspace": return .backspace
        case "delete": return .delete
        case "insert": return .insert
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        default:
            if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...12).contains(n) {
                return .f(n)
            }
            return nil
        }
    }

    /// The default bindings from spec §6.2. `⌘+`/`⌘-`/`⌘0` for font size stay menu-only (they are
    /// `NSMenuItem` key equivalents, and the `+`/`-` chord is exactly the ambiguous case `parse`
    /// rejects), so this list omits `fontBigger`/`fontSmaller`/`fontReset`; the menu supplies them.
    /// The spec table has no entry for a new-window shortcut either, so `newWindow` is likewise
    /// left for the menu (conventionally ⌘N) rather than guessed here.
    public static let defaults: [KeyBinding] = [
        KeyBinding(key: .char("t"), modifiers: [.cmd], action: .newTab),
        KeyBinding(key: .char("w"), modifiers: [.cmd], action: .closePane),
        KeyBinding(key: .char("1"), modifiers: [.cmd], action: .tab1),
        KeyBinding(key: .char("2"), modifiers: [.cmd], action: .tab2),
        KeyBinding(key: .char("3"), modifiers: [.cmd], action: .tab3),
        KeyBinding(key: .char("4"), modifiers: [.cmd], action: .tab4),
        KeyBinding(key: .char("5"), modifiers: [.cmd], action: .tab5),
        KeyBinding(key: .char("6"), modifiers: [.cmd], action: .tab6),
        KeyBinding(key: .char("7"), modifiers: [.cmd], action: .tab7),
        KeyBinding(key: .char("8"), modifiers: [.cmd], action: .tab8),
        KeyBinding(key: .char("9"), modifiers: [.cmd], action: .tab9),
        KeyBinding(key: .char("]"), modifiers: [.cmd, .shift], action: .nextTab),
        KeyBinding(key: .char("["), modifiers: [.cmd, .shift], action: .previousTab),
        KeyBinding(key: .char("d"), modifiers: [.cmd], action: .splitRight),
        KeyBinding(key: .char("d"), modifiers: [.cmd, .shift], action: .splitDown),
        KeyBinding(key: .left, modifiers: [.cmd, .alt], action: .focusLeft),
        KeyBinding(key: .right, modifiers: [.cmd, .alt], action: .focusRight),
        KeyBinding(key: .up, modifiers: [.cmd, .alt], action: .focusUp),
        KeyBinding(key: .down, modifiers: [.cmd, .alt], action: .focusDown),
        KeyBinding(key: .left, modifiers: [.cmd, .ctrl], action: .growLeft),
        KeyBinding(key: .right, modifiers: [.cmd, .ctrl], action: .growRight),
        KeyBinding(key: .up, modifiers: [.cmd, .ctrl], action: .growUp),
        KeyBinding(key: .down, modifiers: [.cmd, .ctrl], action: .growDown),
        KeyBinding(key: .enter, modifiers: [.cmd, .shift], action: .toggleZoom),
        KeyBinding(key: .char("k"), modifiers: [.cmd], action: .clearScreen),
        KeyBinding(key: .char(","), modifiers: [.cmd], action: .openConfig),
        KeyBinding(key: .char(","), modifiers: [.cmd, .shift], action: .reloadConfig),
        KeyBinding(key: .up, modifiers: [.cmd], action: .previousPrompt),
        KeyBinding(key: .down, modifiers: [.cmd], action: .nextPrompt),
        KeyBinding(key: .char("f"), modifiers: [.cmd], action: .find),
        KeyBinding(key: .char("g"), modifiers: [.cmd], action: .findNext),
        KeyBinding(key: .char("g"), modifiers: [.cmd, .shift], action: .findPrevious),
        KeyBinding(key: .char("p"), modifiers: [.cmd, .shift], action: .commandPalette),
    ]
}
