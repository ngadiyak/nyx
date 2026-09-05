import AppKit
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private let configStore = ConfigStore()
    private var settings: SettingsWindowController?
    /// Remote sessions, or nil in a snapshot run. One per application: the socket, the paired list,
    /// the catalogue behind the palette's Remote section and the host that publishes this Mac's
    /// sessions all outlive any one window, and two of any of them would be two answers to the same
    /// question. Windows reach it through `NSApp.delegate`, the way they already reach everything
    /// else that is the application's rather than a window's.
    private(set) var remote: RemoteCoordinator?
    /// The session file, beside the config. See `SessionStore`.
    private let sessionStore = SessionStore.standard()
    /// A save is already queued; see `sessionChanged`.
    private var sessionSaveItem: DispatchWorkItem?
    /// Every write of the session file, in order. Two saves racing would let an older snapshot win.
    private static let sessionQueue = DispatchQueue(label: "nyx.session-write", qos: .utility)
    /// Long enough that opening four tabs in a row is one write rather than four, short enough that
    /// a crash a moment later still loses nothing anybody would miss.
    private static let sessionSaveDelay: TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildMenu(for: configStore.config)
        configStore.createIfMissing()
        Pane.themes = configStore.themes
        configStore.onChange = { [weak self] config, diagnostics in
            // Before the windows: a reload that turns remote sessions off has to stop publishing
            // this Mac's sessions before anything else redraws from the new configuration.
            self?.remote?.apply(config)
            // Before the windows are told: they will resolve palettes as they apply the config, and
            // a `theme =` line and the file it names arrive in the same reload.
            Pane.themes = self?.configStore.themes ?? .builtinOnly
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
        // After the snapshot check above: a snapshot run must not open a socket, publish this Mac's
        // sessions or write an audit line -- it renders chrome to PNGs and exits.
        let coordinator = RemoteCoordinator(config: configStore.config)
        coordinator.onChange = { [weak self] in self?.remoteChanged() }
        remote = coordinator
        configStore.startWatching()
        openInitialWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        configStore.stopWatching()
        // Cancelling the debounce only stops a save that has not been handed over yet; one already
        // on the queue would land *after* this one and restore the pre-quit state. Everything goes
        // through one serial queue, and this waits for it, so the last write is the last state.
        sessionSaveItem?.cancel()
        sessionSaveItem = nil
        saveSession(waitForWrite: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Every remote tab in every window of this application, numbered by window.
    ///
    /// One attachment has one owner, so "is this session already open?" is a question about the
    /// whole application and not about the window doing the asking. Asking only the current window
    /// is what let a second window wire itself into a live attachment and freeze the first one's
    /// tab -- drawn, taking keystrokes, and never showing another byte again.
    var openRemoteTabs: [RemoteTabs.Open] {
        controllers.enumerated().flatMap { index, controller in
            controller.remoteTabs(inWindow: index)
        }
    }

    /// Brings the window holding an already-open remote session forward, on the tab it is in.
    /// `window` is an index into the same list `openRemoteTabs` numbered.
    func revealRemoteTab(_ match: RemoteTabs.Match) {
        guard controllers.indices.contains(match.window) else { return }
        let controller = controllers[match.window]
        controller.selectTab(at: match.tab)
        // `makeKeyAndOrderFront` on a minimised window puts it in front of the other windows in the
        // Dock's sense and leaves it in the Dock: the palette row would answer by doing nothing
        // visible at all, which is the same symptom as the row being broken.
        if let window = controller.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

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
    private func saveSession(waitForWrite: Bool = false) {
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
        // Gathering reads views and terminals, so it happens here on the main thread; encoding and
        // writing are just bytes and go to one serial queue, which is what keeps two saves from
        // landing out of order.
        let snapshot = SessionSnapshot(windows: windows)
        let store = sessionStore
        let write: () -> Void = { _ = store.save(snapshot) }
        if waitForWrite { AppDelegate.sessionQueue.sync(execute: write) }
        else { AppDelegate.sessionQueue.async(execute: write) }
    }

    /// The catalogue, the connection status or the paired list moved. Only the settings window
    /// draws any of them continuously; an open command palette is a snapshot of the list at the
    /// moment it opened, and re-ranking it under the user's cursor would move the row they are
    /// about to press.
    private func remoteChanged() {
        settings?.remoteChanged()
    }

    /// Opens Settings → Remote and starts a pairing there, which is the `remote_pair` action and
    /// the one place a pairing has ever been shown. Reached from the menu, the palette and a
    /// `keybind` line, so that a user who has never opened the settings window can still pair.
    @objc func pairRemoteDevice(_ sender: Any?) {
        openConfig(nil)
        settings?.beginHostPairing()
    }

    /// Settings → Remote, with nothing started on it. Where `remote_sessions` and `remote_pair` go
    /// when remote sessions are on but no relay token has been pasted in: the one field standing
    /// between the user and both of those actions is on this page.
    @objc func openRemoteSettings(_ sender: Any?) {
        openConfig(nil)
        settings?.showRemotePage()
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
