import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nyx", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.openConfig(_:)), keyEquivalent: ",")
        let reloadSettings = NSMenuItem(title: "Reload Settings", action: #selector(AppDelegate.reloadConfig(_:)), keyEquivalent: ",")
        reloadSettings.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(reloadSettings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nyx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(item("Nyx", appMenu))

        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        shell.addItem(withTitle: "New Tab", action: #selector(TabController.newTab(_:)), keyEquivalent: "t")
        shell.addItem(.separator())
        shell.addItem(withTitle: "Split Right", action: #selector(PaneTreeView.splitRight(_:)), keyEquivalent: "d")
        shell.addItem(chord("Split Down", #selector(PaneTreeView.splitDown(_:)), "d", [.command, .shift]))
        shell.addItem(.separator())
        // ⌘W closes the focused pane -- and with the pane's last sibling the tab, and with the
        // last tab the window; the whole window at once is ⌘⇧W. `TabController` owns this rather
        // than `PaneTreeView` because only it can ask about a running process first.
        shell.addItem(withTitle: "Close Pane", action: #selector(TabController.closePane(_:)), keyEquivalent: "w")
        shell.addItem(chord("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        main.addItem(item("Shell", shell))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(Pane.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(Pane.paste(_:)), keyEquivalent: "v")
        main.addItem(item("Edit", edit))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(Pane.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(Pane.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(Pane.zoomReset(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(chord("Zoom Pane", #selector(PaneTreeView.togglePaneZoom(_:)), "\r", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(chord("Focus Left", #selector(PaneTreeView.focusLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]))
        view.addItem(chord("Focus Right", #selector(PaneTreeView.focusRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]))
        view.addItem(chord("Focus Up", #selector(PaneTreeView.focusUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        view.addItem(chord("Focus Down", #selector(PaneTreeView.focusDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        view.addItem(.separator())
        view.addItem(chord("Grow Left", #selector(PaneTreeView.growLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .control]))
        view.addItem(chord("Grow Right", #selector(PaneTreeView.growRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .control]))
        view.addItem(chord("Grow Up", #selector(PaneTreeView.growUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .control]))
        view.addItem(chord("Grow Down", #selector(PaneTreeView.growDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .control]))
        main.addItem(item("View", view))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(chord("Show Next Tab", #selector(TabController.selectNextTab(_:)), "]", [.command, .shift]))
        window.addItem(chord("Show Previous Tab", #selector(TabController.selectPreviousTab(_:)), "[", [.command, .shift]))
        window.addItem(.separator())
        // ⌘1...⌘9 have to be menu items to be shortcuts at all. The number travels in the tag;
        // ⌘9 is the *last* tab rather than the ninth, which is why it is titled separately --
        // `TabStrip.index(forCommandNumber:tabCount:)` is where that rule lives, and
        // `TabController.validateMenuItem` greys out the numbers with no tab behind them.
        for number in 1...8 {
            let tab = NSMenuItem(title: "Show Tab \(number)",
                                 action: #selector(TabController.selectTabByNumber(_:)),
                                 keyEquivalent: String(number))
            tab.tag = number
            window.addItem(tab)
        }
        let lastTab = NSMenuItem(title: "Show Last Tab",
                                 action: #selector(TabController.selectTabByNumber(_:)), keyEquivalent: "9")
        lastTab.tag = 9
        window.addItem(lastTab)
        main.addItem(item("Window", window))
        NSApp.windowsMenu = window
        return main
    }

    /// A menu item whose shortcut needs modifiers beyond ⌘. The key equivalent for a chord
    /// including shift is still given in lowercase; AppKit adds the ⇧ from the mask.
    private static func chord(_ title: String, _ action: Selector, _ key: String,
                              _ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mask
        return i
    }

    /// The arrow keys as menu key equivalents: they are function-key code points, not characters.
    private static func arrow(_ code: Int) -> String {
        guard let scalar = UnicodeScalar(code) else { return "" }
        return String(Character(scalar))
    }

    private static func item(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        return i
    }
}
