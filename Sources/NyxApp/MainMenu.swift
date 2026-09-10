import AppKit
import NyxCore

/// The menu is generated from `ActionCatalog`, so every action a user can name in their config file
/// is also a menu item, and every menu item shows whatever chord is currently bound to it. Rebinding
/// a key in the config and reloading rebuilds this, which is why `build` takes the table rather than
/// reading a global.
enum MainMenu {
    static func build(bindings: KeyBindingTable) -> NSMenu {
        let main = NSMenu()

        for section in ActionCatalog.sections {
            let menu = NSMenu(title: section.title)
            if section.title == "Nyx" {
                menu.addItem(withTitle: "About Nyx",
                             action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                             keyEquivalent: "")
                menu.addItem(.separator())
            }

            for (index, group) in section.groups.enumerated() {
                if index > 0 { menu.addItem(.separator()) }
                for action in group.actions {
                    menu.addItem(item(for: action, bindings: bindings))
                }
            }

            // AppKit owns these; they are not terminal actions and carry no config binding.
            switch section.title {
            case "Nyx":
                menu.addItem(.separator())
                menu.addItem(withTitle: "Hide Nyx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit Nyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            case "Edit":
                // The items every text field in the app depends on. Nyx's own Copy and Paste are
                // already `copy:`/`paste:` (see `StandardEditing`), so what is missing is the rest
                // of the standard set -- and it is placed by finding the items it belongs beside
                // rather than by counting, so a change to `ActionCatalog.sections` cannot silently
                // move Cut away from Copy.
                if let endOfFirstGroup = menu.items.firstIndex(where: { $0.isSeparatorItem }) {
                    menu.insertItem(standardItem(.selectAll), at: endOfFirstGroup)
                } else {
                    menu.addItem(standardItem(.selectAll))
                }
                if let copy = menu.items.firstIndex(where: { $0.action == StandardEditing.selector(for: .copy) }) {
                    menu.insertItem(standardItem(.cut), at: copy)
                }
                menu.insertItem(.separator(), at: 0)
                menu.insertItem(standardItem(.redo), at: 0)
                menu.insertItem(standardItem(.undo), at: 0)
            case "Window":
                menu.insertItem(.separator(), at: 0)
                menu.insertItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "", at: 0)
                menu.insertItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)),
                                keyEquivalent: "m", at: 0)
                // ⌘⇧W is the window, distinct from ⌘W, which closes a pane.
                menu.addItem(.separator())
                menu.addItem(chord("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
            default:
                break
            }

            main.addItem(container(section.title, menu))
            if section.title == "Window" { NSApp.windowsMenu = menu }
        }
        return main
    }

    /// Every terminal action goes to the same selector; which action it is travels in
    /// `representedObject`, and a nil target sends it up the responder chain to the nearest
    /// `ActionTarget`. Validation goes the same way, so an item greys out when the action
    /// cannot apply right now.
    private static func item(for action: TerminalAction, bindings: KeyBindingTable) -> NSMenuItem {
        // Copy and Paste go on AppKit's own selectors instead. `performTerminalAction:` was
        // resolved up the responder chain past the focused field editor to the `TabController`, so
        // ⌘V in the search bar pasted onto the shell command line behind it; `paste:` stops at the
        // field, and at the pane -- which implements `paste(_:)` -- when the pane is focused. The
        // action, its chord and its palette entry are unchanged.
        let item = NSMenuItem(title: action.title,
                              action: StandardEditing.command(for: action).map(StandardEditing.selector(for:))
                                  ?? #selector(TabController.performTerminalAction(_:)),
                              keyEquivalent: "")
        item.representedObject = action.rawValue
        if let binding = bindings.binding(for: action),
           let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    /// An item for one of AppKit's editing commands: nil target, its own fixed chord, and no
    /// `TerminalAction` behind it.
    private static func standardItem(_ command: StandardEditingCommand) -> NSMenuItem {
        let item = NSMenuItem(title: command.title,
                              action: StandardEditing.selector(for: command), keyEquivalent: "")
        if let chord = command.fixedChord {
            item.keyEquivalent = String(chord.key)
            var mask: NSEvent.ModifierFlags = []
            if chord.modifiers.contains(.cmd) { mask.insert(.command) }
            if chord.modifiers.contains(.ctrl) { mask.insert(.control) }
            if chord.modifiers.contains(.alt) { mask.insert(.option) }
            if chord.modifiers.contains(.shift) { mask.insert(.shift) }
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    private static func chord(_ title: String, _ action: Selector, _ key: String,
                              _ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mask
        return i
    }

    private static func container(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        return i
    }
}
