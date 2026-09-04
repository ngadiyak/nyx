import AppKit
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private let configStore = ConfigStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        configStore.createIfMissing()
        configStore.onChange = { [weak self] config, diagnostics in
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

    @objc func newWindow(_ sender: Any?) {
        guard let controller = TerminalWindowController.make(config: configStore.config) else { return }
        controller.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    /// `⌘,`: create the config file if this is the first launch, then open it in the user's editor.
    @objc func openConfig(_ sender: Any?) {
        let url = configStore.createIfMissing()
        NSWorkspace.shared.open(url)
    }

    /// `⌘⇧,`: reload now rather than waiting for the debounced file watch.
    @objc func reloadConfig(_ sender: Any?) {
        configStore.reload()
    }
}
