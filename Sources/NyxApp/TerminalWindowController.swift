import AppKit
import NyxCore

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var tabs: TabController?
    private var banner: ConfigBanner?
    private var effectView: NSVisualEffectView?
    private var config: Config = .defaults

    /// Builds a window with a live terminal in it, or shows the error and returns nil.
    ///
    /// Failure has to be visible to the caller: the previous version closed the window inside its
    /// initialiser, but `AppDelegate` then called `showWindow(nil)` on the controller it had been
    /// handed, which ordered the empty window straight back to the front. Returning nil means no
    /// window is shown and no controller is retained.
    static func make(config: Config) -> TerminalWindowController? {
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
        let tabs = TabController(config: config)
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
        window.setContentSize(firstPane.size(forCols: 100, rows: 30))
        window.center()
        window.setFrameAutosaveName("NyxMain")
        window.makeFirstResponder(firstPane)
        controller.tabs = tabs
        controller.banner = banner
        controller.effectView = effectView
        controller.config = config
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
    /// The pane keystrokes would go to. Used by the paste smoke check.
    var focusedPane: Pane? { tabs?.focusedPane }

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

    func windowWillClose(_ notification: Notification) {
        tabs?.terminateAll()
        onClose?(self)
    }
}
