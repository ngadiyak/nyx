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

    private static func functionKeyScalar(_ key: Key) -> Unicode.Scalar? {
        let code: Int
        switch key {
        case .up: code = NSUpArrowFunctionKey
        case .down: code = NSDownArrowFunctionKey
        case .left: code = NSLeftArrowFunctionKey
        case .right: code = NSRightArrowFunctionKey
        case .home: code = NSHomeFunctionKey
        case .end: code = NSEndFunctionKey
        case .pageUp: code = NSPageUpFunctionKey
        case .pageDown: code = NSPageDownFunctionKey
        case .delete: code = NSDeleteFunctionKey
        case .insert: code = NSInsertFunctionKey
        case .enter: return Unicode.Scalar(13)
        case .tab: return Unicode.Scalar(9)
        case .escape: return Unicode.Scalar(27)
        case .backspace: return Unicode.Scalar(8)
        case .f(let n): code = NSF1FunctionKey + n - 1
        case .char: return nil
        }
        return Unicode.Scalar(code)
    }
}
