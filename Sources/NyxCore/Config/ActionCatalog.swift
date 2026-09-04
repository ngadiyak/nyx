/// Everything about a `TerminalAction` that is not AppKit: what it is called, where it sits in the
/// menu, and which chord currently invokes it. Keeping this here rather than in the menu builder is
/// what lets a test assert that every action a user can name in their config is also discoverable
/// in the menu -- the two lists cannot drift apart if there is only one list.

public extension TerminalAction {
    /// The menu title. Also the name to show a user when talking about the action.
    var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .closePane: return "Close Pane"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .tab1: return "Tab 1"
        case .tab2: return "Tab 2"
        case .tab3: return "Tab 3"
        case .tab4: return "Tab 4"
        case .tab5: return "Tab 5"
        case .tab6: return "Tab 6"
        case .tab7: return "Tab 7"
        case .tab8: return "Tab 8"
        case .tab9: return "Last Tab"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .focusLeft: return "Focus Left"
        case .focusRight: return "Focus Right"
        case .focusUp: return "Focus Up"
        case .focusDown: return "Focus Down"
        case .growLeft: return "Grow Left"
        case .growRight: return "Grow Right"
        case .growUp: return "Grow Up"
        case .growDown: return "Grow Down"
        case .toggleZoom: return "Zoom Pane"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .clearScreen: return "Clear Screen"
        case .fontBigger: return "Bigger"
        case .fontSmaller: return "Smaller"
        case .fontReset: return "Actual Size"
        case .openConfig: return "Settings..."
        case .reloadConfig: return "Reload Settings"
        case .previousPrompt: return "Previous Prompt"
        case .nextPrompt: return "Next Prompt"
        case .selectCommandOutput: return "Select Command Output"
        case .copyCommandOutput: return "Copy Last Command Output"
        case .find: return "Find..."
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .commandPalette: return "Command Palette"
        case .foldCommand: return "Fold Command Output"
        case .foldAllLongOutput: return "Fold All Long Output"
        case .saveScrollback: return "Save Scrollback\u{2026}"
        }
    }

    /// The config-file spelling, which is what a diagnostic should name.
    var configName: String { rawValue }
}

/// The menu's structure, as data. The app turns this into `NSMenu`s; nothing here knows that.
public enum ActionCatalog {
    public struct Group: Equatable {
        /// A separator goes before every group after the first within a section.
        public let actions: [TerminalAction]
        public init(_ actions: [TerminalAction]) { self.actions = actions }
    }

    public struct Section: Equatable {
        public let title: String
        public let groups: [Group]
        public init(title: String, groups: [Group]) {
            self.title = title
            self.groups = groups
        }
        public var actions: [TerminalAction] { groups.flatMap(\.actions) }
    }

    /// `nyxSection` is the application menu, which AppKit also fills with About/Hide/Quit.
    public static let sections: [Section] = [
        Section(title: "Nyx", groups: [
            Group([.openConfig, .reloadConfig]),
        ]),
        Section(title: "Shell", groups: [
            Group([.newWindow, .newTab]),
            Group([.splitRight, .splitDown]),
            Group([.saveScrollback]),
            Group([.closePane]),
        ]),
        Section(title: "Edit", groups: [
            Group([.copy, .paste]),
            Group([.find, .findNext, .findPrevious]),
            Group([.clearScreen]),
        ]),
        Section(title: "Go", groups: [
            Group([.commandPalette]),
            Group([.previousPrompt, .nextPrompt]),
            Group([.selectCommandOutput, .copyCommandOutput]),
            Group([.foldCommand, .foldAllLongOutput]),
        ]),
        Section(title: "View", groups: [
            Group([.fontBigger, .fontSmaller, .fontReset]),
            Group([.toggleZoom]),
            Group([.focusLeft, .focusRight, .focusUp, .focusDown]),
            Group([.growLeft, .growRight, .growUp, .growDown]),
        ]),
        Section(title: "Window", groups: [
            Group([.nextTab, .previousTab]),
            Group([.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9]),
        ]),
    ]

    /// Every action the menu offers, in menu order.
    public static var allMenuActions: [TerminalAction] { sections.flatMap(\.actions) }
}

/// The bindings in force: the built-in defaults with the user's config bindings layered on top.
///
/// Both lookups search from the end, so a user binding beats a default, and the *last* line in the
/// config file wins over an earlier one for the same chord. That is the rule a user can predict
/// from reading their file top to bottom.
public struct KeyBindingTable {
    private let bindings: [KeyBinding]

    public init(user: [KeyBinding], defaults: [KeyBinding] = KeyBinding.defaults) {
        bindings = defaults + user
    }

    /// The action a chord invokes, or nil when the chord is not bound and belongs to the shell.
    /// Modifiers must match exactly: `⌘K` is bound, so plain `k` must not find it.
    public func action(for key: Key, modifiers: KeyModifiers) -> TerminalAction? {
        for binding in bindings.reversed() where binding.key == key && binding.modifiers == modifiers {
            return binding.action
        }
        return nil
    }

    /// The chord to advertise for an action, for the menu's key equivalent. An action with no
    /// binding returns nil and still belongs in the menu, just without a shortcut.
    ///
    /// A user who rebinds a chord to a different action leaves the old action unbound, and this
    /// reports that honestly rather than showing a shortcut that now does something else.
    public func binding(for action: TerminalAction) -> KeyBinding? {
        var candidate: KeyBinding?
        for binding in bindings.reversed() where binding.action == action {
            candidate = binding
            break
        }
        guard let candidate else { return nil }
        // The chord may since have been rebound to something else further down the list.
        guard self.action(for: candidate.key, modifiers: candidate.modifiers) == action else { return nil }
        return candidate
    }
}
