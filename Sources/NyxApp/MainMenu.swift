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
        let item = NSMenuItem(title: action.title,
                              action: #selector(TabController.performTerminalAction(_:)),
                              keyEquivalent: "")
        item.representedObject = action.rawValue
        if let binding = bindings.binding(for: action),
           let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
            item.keyEquivalent = key
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
