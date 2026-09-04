import AppKit
import NyxCore

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var terminalView: TerminalView?
    private var banner: ConfigBanner?
    private var config: Config = .defaults

    /// Builds a window with a live terminal in it, or shows the error and returns nil.
    ///
    /// Failure has to be visible to the caller: the previous version closed the window inside its
    /// initialiser, but `AppDelegate` then called `showWindow(nil)` on the controller it had been
    /// handed, which ordered the empty window straight back to the front. Returning nil means no
    /// window is shown and no controller is retained.
    static func make(config: Config) -> TerminalWindowController? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nyx"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        let controller = TerminalWindowController(window: window)
        window.delegate = controller

        // A plain container so the config-error banner can sit above the terminal without the
        // terminal itself knowing anything about it: the banner is pinned to the top and the
        // terminal fills whatever room is left below it.
        let container = NSView(frame: window.contentView!.bounds)
        let banner = ConfigBanner(frame: .zero)
        banner.onOpenConfig = { NSApp.sendAction(#selector(AppDelegate.openConfig(_:)), to: nil, from: nil) }
        container.addSubview(banner)

        do {
            let view = try TerminalView(container.bounds)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.onTitleChange = { [weak window] title in window?.title = title.isEmpty ? "Nyx" : title }
            view.onExit = { [weak controller] _ in controller?.close() }
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
            window.contentResizeIncrements = view.cellSizePoints
            window.setContentSize(view.size(forCols: 100, rows: 30))
            window.center()
            window.setFrameAutosaveName("NyxMain")
            window.makeFirstResponder(view)
            controller.terminalView = view
            controller.banner = banner
            controller.config = config
        } catch {
            NSAlert(error: error).runModal()
            window.delegate = nil
            window.close()
            return nil
        }
        return controller
    }

    private override init(window: NSWindow?) { super.init(window: window) }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Called by `AppDelegate` after every `ConfigStore` reload, successful or not. A parse error
    /// leaves `config` (and therefore the running terminal) untouched: only the banner changes.
    func configChanged(_ config: Config, diagnostics: [ConfigDiagnostic]) {
        self.config = config
        if !diagnostics.isEmpty {
            banner?.showProblems(diagnostics)
        } else {
            banner?.hide()
        }
    }

    func windowWillClose(_ notification: Notification) {
        terminalView?.terminate()
        onClose?(self)
    }
}
