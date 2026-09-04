import AppKit
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private let configStore = ConfigStore()
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildMenu(for: configStore.config)
        configStore.createIfMissing()
        configStore.onChange = { [weak self] config, diagnostics in
            // The menu carries the key equivalents, so a changed `keybind` line has to rebuild it.
            self?.rebuildMenu(for: config)
            self?.settings?.configChanged(config, diagnostics: diagnostics)
            self?.controllers.forEach { $0.configChanged(config, diagnostics: diagnostics) }
        }
        // Renders the chrome to PNGs and exits. The build machine denies screen recording, so this
        // is the only way to look at the design at all; see `UISnapshot`.
        if let directory = UISnapshot.requestedDirectory {
            UISnapshot.run(into: directory, config: configStore.config)
            NSApp.terminate(nil)
            return
        }
        configStore.startWatching()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        configStore.stopWatching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func rebuildMenu(for config: Config) {
        NSApp.mainMenu = MainMenu.build(bindings: KeyBindingTable(user: config.keybinds))
    }

    @objc func newWindow(_ sender: Any?) {
        guard let controller = TerminalWindowController.make(config: configStore.config) else { return }
        controller.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    /// `⌘,`: the settings window. It edits the config file rather than holding its own copy, so
    /// the "Edit Config File…" button on its Keys tab opens the same file this used to open
    /// directly -- nothing is hidden behind the window.
    @objc func openConfig(_ sender: Any?) {
        if settings == nil {
            let controller = SettingsWindowController(store: configStore)
            settings = controller
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Writes one setting into the config file. The command palette's theme rows use it, and go
    /// through exactly the path the settings window does: the file changes, the watcher notices,
    /// and every window reloads. Nothing sets a theme behind the file's back.
    @discardableResult
    func write(setting key: String, value: String) -> Bool {
        configStore.write([(key: key, value: value)])
    }

    /// `⌘⇧,`: reload now rather than waiting for the debounced file watch.
    @objc func reloadConfig(_ sender: Any?) {
        configStore.reload()
    }
}
