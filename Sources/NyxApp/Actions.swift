import AppKit
import NyxCore

/// One place that turns a `TerminalAction` into an effect. The menu and the key-binding table both
/// go through it, so an action cannot work from one and not the other -- which is what happened
/// before, when the menu owned a selector per action and the config file owned a separate list of
/// names that nothing checked against it.
protocol ActionTarget: AnyObject {
    func perform(_ action: TerminalAction)
    func canPerform(_ action: TerminalAction) -> Bool
}

extension NSResponder {
    /// The nearest `ActionTarget` up the responder chain, then the app delegate. A `Pane` is the
    /// first responder, so this finds the `TabController` behind its window's content view.
    var actionTarget: (any ActionTarget)? {
        var responder: NSResponder? = self
        while let r = responder {
            if let target = r as? any ActionTarget { return target }
            responder = r.nextResponder
        }
        return NSApp.delegate as? any ActionTarget
    }
}

extension StandardEditing {
    /// The AppKit selector for one of the standard editing commands.
    ///
    /// The mapping lives here and not in `NyxCore` because a `Selector` is the one part of this
    /// decision that is AppKit's. `undo:` and `redo:` are strings: they are declared nowhere in
    /// any Swift header -- AppKit's own Edit menu targets First Responder by name and the undo
    /// manager answers -- so `#selector` cannot name them.
    static func selector(for command: StandardEditingCommand) -> Selector {
        switch command {
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSResponder.selectAll(_:))
        }
    }
}

/// Translating a `KeyBinding` into what AppKit needs to show and match it in a menu.
enum MenuShortcut {
    /// The `keyEquivalent` string and modifier mask for a chord, or nil when AppKit cannot express
    /// the key. Shift travels in the mask and the character stays lowercase, which is the
    /// convention the menu already used before it was built from this table.
    static func keyEquivalent(for binding: KeyBinding) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        if binding.modifiers.contains(.cmd) { mask.insert(.command) }
        if binding.modifiers.contains(.ctrl) { mask.insert(.control) }
        if binding.modifiers.contains(.alt) { mask.insert(.option) }
        if binding.modifiers.contains(.shift) { mask.insert(.shift) }

        switch binding.key {
        case .char(let scalar):
            return (String(scalar).lowercased(), mask)
        default:
            guard let scalar = MenuShortcut.functionKeyScalar(binding.key) else { return nil }
            return (String(Character(scalar)), mask)
        }
    }

    /// The `Key` a menu item's `keyEquivalent` came from, or nil when the character names no key
    /// this table knows -- which is every ordinary letter, and is what `.char` answers for.
    ///
    /// The inverse exists because a chord is sometimes *drawn* rather than handed to AppKit:
    /// `MenuSnapshot` reconstructs a real `NSMenu` pixel by pixel, and the character in a key
    /// equivalent for an arrow is one of AppKit's private-use function-key scalars, which the
    /// system font has no glyph for. Going back to a `Key` lets `Key.displayName` -- the one place
    /// that decides how ↑ ⇞ ⌦ ↩ are spelled, and what the command palette's chord column already
    /// uses -- answer there too, instead of a third copy of the same table.
    static func key(forKeyEquivalent keyEquivalent: String) -> Key? {
        let scalars = Array(keyEquivalent.unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        let code = Int(scalar.value)
        if let named = MenuShortcut.functionKeys.first(where: { $0.code == code })?.key { return named }
        if code >= NSF1FunctionKey, code <= NSF35FunctionKey { return .f(code - NSF1FunctionKey + 1) }
        return nil
    }

    private static func functionKeyScalar(_ key: Key) -> Unicode.Scalar? {
        if case .f(let n) = key { return Unicode.Scalar(NSF1FunctionKey + n - 1) }
        guard let code = MenuShortcut.functionKeys.first(where: { $0.key == key })?.code
        else { return nil }
        return Unicode.Scalar(code)
    }

    /// One table, read in both directions, so a key cannot be spelled one character going out and
    /// recognised as another coming back. `.f` is the arithmetic case and stays out of it; `.char`
    /// is not in here at all, because AppKit takes its character as itself.
    private static let functionKeys: [(key: Key, code: Int)] = [
        (.up, NSUpArrowFunctionKey), (.down, NSDownArrowFunctionKey),
        (.left, NSLeftArrowFunctionKey), (.right, NSRightArrowFunctionKey),
        (.home, NSHomeFunctionKey), (.end, NSEndFunctionKey),
        (.pageUp, NSPageUpFunctionKey), (.pageDown, NSPageDownFunctionKey),
        (.delete, NSDeleteFunctionKey), (.insert, NSInsertFunctionKey),
        (.enter, 13), (.tab, 9), (.escape, 27), (.backspace, 8)
    ]
}
