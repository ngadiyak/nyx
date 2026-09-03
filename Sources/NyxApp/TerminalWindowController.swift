import AppKit

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var terminalView: TerminalView?

    /// Builds a window with a live terminal in it, or shows the error and returns nil.
    ///
    /// Failure has to be visible to the caller: the previous version closed the window inside its
    /// initialiser, but `AppDelegate` then called `showWindow(nil)` on the controller it had been
    /// handed, which ordered the empty window straight back to the front. Returning nil means no
    /// window is shown and no controller is retained.
    static func make() -> TerminalWindowController? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nyx"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        let controller = TerminalWindowController(window: window)
        window.delegate = controller
        do {
            let view = try TerminalView(window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]
            view.onTitleChange = { [weak window] title in window?.title = title.isEmpty ? "Nyx" : title }
            view.onExit = { [weak controller] _ in controller?.close() }
            window.contentView = view
            window.contentResizeIncrements = view.cellSizePoints
            window.setContentSize(view.size(forCols: 100, rows: 30))
            window.center()
            window.setFrameAutosaveName("NyxMain")
            window.makeFirstResponder(view)
            controller.terminalView = view
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

    func windowWillClose(_ notification: Notification) {
        terminalView?.terminate()
        onClose?(self)
    }
}
