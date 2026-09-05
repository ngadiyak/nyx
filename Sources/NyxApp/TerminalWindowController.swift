import AppKit
import NyxCore

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var tabs: TabController?

    /// This window's remote tabs, stamped with the index the application knows this window by.
    func remoteTabs(inWindow index: Int) -> [RemoteTabs.Open] {
        tabs?.remoteTabs(inWindow: index) ?? []
    }

    /// Selects one of this window's tabs from outside it -- the application raising the window that
    /// already holds a remote session somebody has just chosen again.
    func selectTab(at index: Int) {
        tabs?.selectTab(at: index)
    }
    private var banner: ConfigBanner?
    private var effectView: NSVisualEffectView?
    private var config: Config = .defaults
    private var quickActionFailures: Any?

    deinit {
        if let quickActionFailures { NotificationCenter.default.removeObserver(quickActionFailures) }
    }

    /// A background quick action that fails has no pane to fail in -- nothing was typed anywhere,
    /// and its output goes to /dev/null by design. The banner is where a window says things, so it
    /// says this too, in the window the user is actually looking at: the notification reaches every
    /// open window, and the same sentence appearing in four of them is worse than useful.
    private func observeQuickActionFailures() {
        quickActionFailures = NotificationCenter.default.addObserver(
            forName: QuickActionRunner.failed, object: nil, queue: .main) { [weak self] note in
            guard let self, let message = note.object as? String, self.shouldReport else { return }
            self.banner?.showFailure(message)
        }
    }

    /// Whether this window is the one that should carry a failure message.
    ///
    /// The key window, when there is one. When Nyx is not frontmost there is none -- and a toggle
    /// that dies while you are in another application is exactly when you are least likely to have
    /// noticed the button go out -- so the frontmost Nyx window says it instead, and it is still
    /// there when you come back.
    private var shouldReport: Bool {
        guard let window else { return false }
        if window.isKeyWindow { return true }
        guard NSApp.keyWindow == nil else { return false }
        return NSApp.orderedWindows.first { $0.isVisible && $0.delegate is TerminalWindowController } === window
    }

    /// Builds a window with a live terminal in it, or shows the error and returns nil.
    ///
    /// Failure has to be visible to the caller: the previous version closed the window inside its
    /// initialiser, but `AppDelegate` then called `showWindow(nil)` on the controller it had been
    /// handed, which ordered the empty window straight back to the front. Returning nil means no
    /// window is shown and no controller is retained.
    /// `restoring` is a window a saved session described. Everything about it is best-effort: a
    /// tab whose panes will not start is dropped, a window whose tabs all fail comes back as an
    /// ordinary one-tab window, and a frame that does not describe a usable window is ignored.
    static func make(config: Config, restoring snapshot: WindowSnapshot? = nil) -> TerminalWindowController? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: styleMask(for: config),
                              backing: .buffered, defer: false)
        window.title = "Nyx"
        window.tabbingMode = .disallowed
        let controller = TerminalWindowController(window: window)
        window.delegate = controller

        // A plain container holding, top to bottom in z-order: an NSVisualEffectView (shown only
        // when `background-blur` is on -- it only actually shows through wherever a pane's own
        // Metal layer is drawing at less than full opacity, which `background-opacity < 1` is what
        // makes `Pane.applyBackgroundAppearance` do), the tabs (a tab bar above the selected tab's
        // panes), and the config-error banner pinned above both. Building the hierarchy this way
        // keeps the panes themselves ignorant of the banner and the blur.
        let container = NSView(frame: window.contentView!.bounds)
        let effectView = NSVisualEffectView(frame: container.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.material = .underWindowBackground
        effectView.state = .active
        effectView.isHidden = true
        container.addSubview(effectView)

        let banner = ConfigBanner(frame: .zero)
        banner.onOpenConfig = { NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil) }
        container.addSubview(banner)

        // `TabController` owns every pane in the window, one `PaneTreeView` per tab, and makes them
        // itself; the error from the very first one is kept there so a Mac without Metal still gets
        // the alert it used to.
        let tabs = snapshot.map { TabController(config: config, restoring: $0) }
            ?? TabController(config: config)
        guard let firstPane = tabs.focusedPane else {
            NSAlert(error: tabs.paneCreationFailure ?? NyxError.noMetal).runModal()
            window.delegate = nil
            window.close()
            return nil
        }
        let view = tabs.view
        view.translatesAutoresizingMaskIntoConstraints = false
        tabs.onTitleChange = { [weak window] title in window?.title = title.isEmpty ? "Nyx" : title }
        tabs.onAllTabsClosed = { [weak controller] in controller?.close() }
        container.addSubview(view)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: banner.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.contentResizeIncrements = firstPane.cellSizePoints
        // A floor, in cells rather than points, so it follows the font size. Below roughly this,
        // the tab bar has nothing but its own buttons and the grid stops being a terminal -- and
        // `TabBarGeometry` spends its whole budget on the minimum slot width per tab, which is what
        // makes a very narrow bar drop buttons in the first place. 24×6 is the smallest thing a
        // prompt and its output still read in; below it a person is resizing by accident.
        window.contentMinSize = firstPane.size(forCols: 24, rows: 6)
        window.setContentSize(firstPane.size(forCols: 100, rows: 30))
        window.center()
        window.setFrameAutosaveName("NyxMain")
        // After the autosave name, which restores a frame of its own the moment it is set: the
        // session's own frame is the more specific answer and has to win. `SessionRestore.frame`
        // refuses anything that would come back as a window nobody could use.
        if let rect = SessionRestore.frame(from: snapshot?.frame) {
            window.setFrame(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                            display: false)
        }
        window.makeFirstResponder(firstPane)
        controller.tabs = tabs
        controller.banner = banner
        controller.effectView = effectView
        controller.config = config
        controller.observeQuickActionFailures()
        controller.applyWindowAppearance()
        return controller
    }

    /// `window-decorations` only takes effect at creation (changing it live is noted in the banner
    /// instead, via `ConfigDiff.deferredNotes` -- recreating the window under a running session
    /// would mean rebuilding more than just chrome).
    private static func styleMask(for config: Config) -> NSWindow.StyleMask {
        config.windowDecorations ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless, .resizable]
    }

    private override init(window: NSWindow?) { super.init(window: window) }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called by `AppDelegate` after every `ConfigStore` reload, successful or not. `newConfig` was
    /// parsed with the previous config as its base (`ConfigStore.reload`), so a bad line already
    /// kept that one field's old value -- applying it here is always safe, even when `diagnostics`
    /// is non-empty: every field that parsed cleanly still takes effect, and only the field with the
    /// bad line stays where it was.
    func configChanged(_ newConfig: Config, diagnostics: [ConfigDiagnostic]) {
        let diff = ConfigDiff(from: config, to: newConfig)
        config = newConfig
        tabs?.apply(newConfig)
        applyWindowAppearance()

        if !diagnostics.isEmpty {
            banner?.showProblems(diagnostics)
        } else if let note = diff.deferredNotes.first {
            banner?.showNote(note)
        } else {
            banner?.hide()
        }
    }

    /// `background-opacity`/`background-blur`: the window has to stop being opaque for either the
    /// terminal's own translucency or the blur view behind it to be visible at all.
    private func applyWindowAppearance() {
        guard let window else { return }
        let translucent = config.backgroundOpacity < 1 || config.backgroundBlur > 0
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .black
        effectView?.isHidden = config.backgroundBlur <= 0
    }

    /// This window as a saved session records it, or nil when there is nothing in it worth saving.
    func sessionSnapshot() -> WindowSnapshot? {
        guard let saved = tabs?.sessionSnapshot() else { return nil }
        let frame = window.map { [Double($0.frame.origin.x), Double($0.frame.origin.y),
                                  Double($0.frame.width), Double($0.frame.height)] }
        return WindowSnapshot(tabs: saved.tabs, selectedTab: saved.selected, frame: frame)
    }

    func windowWillClose(_ notification: Notification) {
        tabs?.terminateAll()
        onClose?(self)
    }
}
