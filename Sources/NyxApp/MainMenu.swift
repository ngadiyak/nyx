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
        shell.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(item("Shell", shell))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        main.addItem(item("Edit", edit))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(TerminalView.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(TerminalView.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(TerminalView.zoomReset(_:)), keyEquivalent: "0")
        main.addItem(item("View", view))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        main.addItem(item("Window", window))
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        return i
    }
}
