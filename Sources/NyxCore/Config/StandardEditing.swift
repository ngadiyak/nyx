/// One of AppKit's own editing commands -- the ones every Mac application's Edit menu carries and
/// every text field answers.
///
/// They matter to a terminal for a reason that is easy to miss: Nyx's Edit menu was generated
/// entirely from `ActionCatalog`, so its Copy and Paste items were `performTerminalAction:` with a
/// nil target. AppKit resolves a nil target up the *key window's* responder chain, and the search
/// bar's field editor does not answer `performTerminalAction:` -- the chain walked past it to the
/// `TabController`, which pasted into the focused pane. ⌘V with the search field focused typed the
/// clipboard onto the shell command line behind the bar; ⌘A, ⌘C and ⌘Z in any of Nyx's text fields
/// did nothing, because there was no item to match.
///
/// The fix is to let the responder chain do its job: an item whose action is `copy:` reaches the
/// field when the field is focused and the pane when the pane is focused, and `Pane` already
/// implements `copy(_:)`, `paste(_:)` and `selectAll(_:)`. This type is the decision about *which*
/// commands the menu owes a text field and which terminal action each one stands in for, so it can
/// be stated once and tested rather than being an order of items in a view file.
public enum StandardEditingCommand: String, CaseIterable, Equatable {
    case undo, redo, cut, copy, paste, selectAll

    public var title: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        }
    }

    /// The chord AppKit's own item always carries, or nil for a command that stands in for a
    /// `TerminalAction` and therefore takes its chord from the binding table -- where a `keybind`
    /// line can move it.
    public var fixedChord: (key: Unicode.Scalar, modifiers: KeyModifiers)? {
        switch self {
        case .undo: return ("z", [.cmd])
        case .redo: return ("z", [.cmd, .shift])
        case .cut: return ("x", [.cmd])
        case .selectAll: return ("a", [.cmd])
        case .copy, .paste: return nil
        }
    }
}

public enum StandardEditing {
    /// The standard command a terminal action is served by, so the Edit menu shows *one* row for
    /// it rather than a terminal Copy beside an AppKit Copy. The action keeps its
    /// `TerminalAction` -- the palette lists it, `keybind` names it, and `TabController.perform`
    /// still runs it -- only the menu item's selector changes, which is what puts the focused text
    /// field ahead of the pane in the responder chain.
    public static func command(for action: TerminalAction) -> StandardEditingCommand? {
        switch action {
        case .copy: return .copy
        case .paste: return .paste
        // `paste_with_editor` opens Nyx's own editor; AppKit has no command for that, so ⌘⇧V in a
        // text field still reaches the pane. Deliberate: there is nothing better to route it to.
        default: return nil
        }
    }

    /// The commands the Edit menu adds beyond the terminal actions, in the order a Mac user reads
    /// them: Undo and Redo above everything, Cut beside Copy, Select All after the paste items.
    ///
    /// Undo and Redo are here for the sheets and fields -- the Rename Tab field, the search bar,
    /// the request editor -- and are inert over a terminal grid, where nothing implements them; the
    /// item greys out and says so, which is better than a chord that silently does nothing.
    public static let extras: [StandardEditingCommand] = [.undo, .redo, .cut, .selectAll]
}
