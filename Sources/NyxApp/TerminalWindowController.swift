import AppKit

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var terminalView: TerminalView?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nyx"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self
        do {
            let view = try TerminalView(window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]
            view.onTitleChange = { [weak window] title in window?.title = title.isEmpty ? "Nyx" : title }
            view.onExit = { [weak self] _ in self?.close() }
            window.contentView = view
            window.contentResizeIncrements = view.cellSizePoints
            window.setContentSize(view.size(forCols: 100, rows: 30))
            window.center()
            window.setFrameAutosaveName("NyxMain")
            window.makeFirstResponder(view)
            terminalView = view
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func windowWillClose(_ notification: Notification) {
        terminalView?.terminate()
        onClose?(self)
    }
}
