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

    /// `⌘⇧,`: reload now rather than waiting for the debounced file watch.
    @objc func reloadConfig(_ sender: Any?) {
        configStore.reload()
    }
}
