import AppKit
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private let configStore = ConfigStore()
    private var settings: SettingsWindowController?
    /// The session file, beside the config. See `SessionStore`.
    private let sessionStore = SessionStore.standard()
    /// A save is already queued; see `sessionChanged`.
    private var sessionSaveItem: DispatchWorkItem?
    /// Long enough that opening four tabs in a row is one write rather than four, short enough that
    /// a crash a moment later still loses nothing anybody would miss.
    private static let sessionSaveDelay: TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildMenu(for: configStore.config)
        configStore.createIfMissing()
        configStore.onChange = { [weak self] config, diagnostics in
            // The menu carries the key equivalents, so a changed `keybind` line has to rebuild it.
            self?.rebuildMenu(for: config)
            self?.settings?.configChanged(config, diagnostics: diagnostics)
            self?.controllers.forEach { $0.configChanged(config, diagnostics: diagnostics) }
            // Turning the setting off forgets the file there and then, so it cannot come back to
            // life a fortnight later when it is turned on again.
            if !config.restoreSession { self?.sessionStore.clear() }
        }
        // Renders the chrome to PNGs and exits. The build machine denies screen recording, so this
        // is the only way to look at the design at all; see `UISnapshot`.
        if let directory = UISnapshot.requestedDirectory {
            UISnapshot.run(into: directory, config: configStore.config)
            NSApp.terminate(nil)
            return
        }
        configStore.startWatching()
        openInitialWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous on purpose: the process is going away, and a background write would not
        // finish. This is the save that matters -- it is the one the next launch reads.
        if configStore.config.restoreSession {
            let windows = controllers.compactMap { $0.sessionSnapshot() }
            if windows.isEmpty { sessionStore.clear() } else { sessionStore.save(SessionSnapshot(windows: windows)) }
        }
        configStore.stopWatching()
        // Now, not on the debounce: the windows are still standing at this point and their panes
        // still have buffers to read. A queued work item would never run.
        sessionSaveItem?.cancel()
        sessionSaveItem = nil
        saveSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func rebuildMenu(for config: Config) {
        NSApp.mainMenu = MainMenu.build(bindings: KeyBindingTable(user: config.keybinds))
    }

    /// Writes the whole button list back to the config file. The watcher picks the change up and
    /// every window rebuilds its bar, so a button added in one window appears in all of them.
    func setQuickActions(_ actions: [QuickAction]) {
        configStore.writeList("quick", values: actions.map(\.configValue))
    }

    var quickActions: [QuickAction] { configStore.config.quickActions }

    @objc func newWindow(_ sender: Any?) {
        open(restoring: nil)
    }

    /// Opens a window, optionally rebuilding one a saved session described. Returns whether it
    /// actually appeared -- a Mac with no Metal device gets an alert and no window, and the caller
    /// has to know that rather than counting a window that is not there.
    @discardableResult
    private func open(restoring snapshot: WindowSnapshot?) -> Bool {
        guard let controller = TerminalWindowController.make(config: configStore.config,
                                                             restoring: snapshot) else { return false }
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
            self?.sessionChanged()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        sessionChanged()
        return true
    }

    // MARK: - The session
    //
    // What may be restored, and what a snapshot has to look like to be worth restoring, is
    // `SessionRestore`/`SessionSnapshot` in NyxCore. What is here is windows in and windows out --
    // and the promise that every path through it ends with the user looking at a terminal.

    /// Launch. Rebuilds what was open, or opens one window; and if rebuilding produces nothing at
    /// all -- every shell refused to start, the file described windows that cannot be made -- opens
    /// one window anyway rather than leaving the user with a running application and no terminal.
    private func openInitialWindows() {
        switch SessionRestore.plan(snapshot: sessionStore.load(), enabled: configStore.config.restoreSession) {
        case .freshWindow:
            newWindow(nil)
        case .restore(let windows):
            for window in windows { open(restoring: window) }
            if controllers.isEmpty { newWindow(nil) }
        }
    }

    /// Something about the windows, tabs or panes changed. Coalesced, because a tab close is
    /// several of these in a row and each one would otherwise read every pane's scrollback.
    func sessionChanged() {
        guard configStore.config.restoreSession else { return }
        sessionSaveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSaveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.sessionSaveDelay, execute: item)
    }

    /// Writes what is open now. Nothing open means the session is forgotten rather than written
    /// empty: coming back to one fresh window is what closing everything asked for.
    private func saveSession() {
        guard configStore.config.restoreSession else {
            sessionStore.clear()
            return
        }
        let windows = controllers.compactMap { $0.sessionSnapshot() }
        guard !windows.isEmpty else {
            sessionStore.clear()
            return
        }
        // Gathering has to happen here -- it reads views and terminals, which belong to the main
        // thread -- but encoding and writing are just bytes, and a few hundred kilobytes of JSON
        // hitting the disk is not something the interface should wait for.
        let snapshot = SessionSnapshot(windows: windows)
        let store = sessionStore
        DispatchQueue.global(qos: .utility).async { store.save(snapshot) }
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
