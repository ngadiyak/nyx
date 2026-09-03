import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        guard let controller = TerminalWindowController.make() else { return }
        controller.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(controller)
        controller.showWindow(nil)
    }
}
