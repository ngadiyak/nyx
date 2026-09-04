import AppKit
import NyxCore

/// The `⌘F` bar: a field, a "3 of 47" readout, previous/next and a close button.
///
/// It owns no search state at all. Every keystroke and click is reported to the `Pane` that put it
/// on screen, which drives the `SearchSession` in `NyxCore` and hands back the readout to display.
/// That split is what keeps the searching itself testable while this file stays event conversion
/// and layout, which the environment cannot exercise.
final class SearchBarView: NSView, NSTextFieldDelegate {
    /// Typed text, on every keystroke -- the search is incremental.
    var onQueryChange: ((String) -> Void)?
    /// `⏎`/`⇧⏎` and the two buttons, `true` for forwards.
    var onStep: ((Bool) -> Void)?
    /// `⎋` or the close button.
    var onClose: (() -> Void)?
    /// The scope toggle: `true` once the search covers every tab rather than this pane.
    var onScopeChange: ((Bool) -> Void)?

    static let height: CGFloat = 36
    static let preferredWidth: CGFloat = 400

    private let field = NSTextField(frame: .zero)
    /// The field's own rounded well, drawn by us rather than by AppKit's bezel.
    private let fieldBackground = NSView(frame: .zero)
    private let readout = NSTextField(labelWithString: "")
    private let previous = NSButton(frame: .zero)
    private let next = NSButton(frame: .zero)
    private let close = NSButton(frame: .zero)
    /// "This pane" or "All tabs". A per-pane search cannot answer "which of my tabs had that
    /// error in it", which is the question people actually have once more than one tab is open.
    private let scope = NSButton(frame: .zero)

    init(palette: Palette) {
        super.init(frame: NSRect(x: 0, y: 0, width: SearchBarView.preferredWidth, height: SearchBarView.height))
        wantsLayer = true
        field.delegate = self
        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 13)
        // AppKit's own bezel is a light rounded rectangle drawn for a light window; over the
        // terminal's background it reads as a bright box cut into the bar, and it crops a 13pt
        // line's descenders. The field is drawn in the pane's own colours instead.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        // The field must not fire on every keystroke through the target/action path as well as
        // `controlTextDidChange`; ⏎ is handled in `doCommandBy` instead.
        field.isContinuous = false
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.alignment = .right
        configure(scope, symbol: "square.on.square", fallback: "All", action: #selector(toggleScope))
        scope.setButtonType(.pushOnPushOff)
        scope.toolTip = "Search every tab"
        configure(previous, symbol: "chevron.left", fallback: "<", action: #selector(stepBackward))
        configure(next, symbol: "chevron.right", fallback: ">", action: #selector(stepForward))
        configure(close, symbol: "xmark", fallback: "x", action: #selector(dismiss))
        fieldBackground.wantsLayer = true
        addSubview(fieldBackground)
        for view in [field, readout, scope, previous, next, close] { addSubview(view) }
        apply(palette: palette)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure(_ button: NSButton, symbol: String, fallback: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .roundRect
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
        }
    }

    /// The bar is drawn in the terminal's own colours so it reads as part of the pane rather than a
    /// piece of another application floating over it.
    func apply(palette: Palette) {
        layer?.backgroundColor = nsColor(palette.background, alpha: 0.96).cgColor
        layer?.borderColor = nsColor(palette.foreground, alpha: 0.25).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        fieldBackground.layer?.backgroundColor = nsColor(palette.foreground, alpha: 0.08).cgColor
        fieldBackground.layer?.cornerRadius = 6
        field.textColor = nsColor(palette.foreground, alpha: 1)
        readout.textColor = nsColor(palette.foreground, alpha: 0.7)
        for button in [previous, next, close] { button.contentTintColor = nsColor(palette.foreground, alpha: 0.8) }
        updateScopeTint(palette: palette)
    }

    /// The "3 of 47" text, or an empty string before anything has been typed.
    func setReadout(_ text: String) {
        readout.stringValue = text
    }

    var query: String { field.stringValue }

    /// Puts the caret in the field. Called after the bar is added to a pane, and again when `⌘F` is
    /// pressed while it is already open -- which is how every editor re-focuses a search bar.
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8, gap: CGFloat = 6, button: CGFloat = 24
        let wellHeight: CGFloat = 24
        let buttonsWidth = button * 4 + gap * 3
        let readoutWidth: CGFloat = 66
        let wellWidth = max(80, bounds.width - inset * 2 - buttonsWidth - readoutWidth - gap * 3)

        var x = inset
        fieldBackground.frame = NSRect(x: x, y: (bounds.height - wellHeight) / 2,
                                       width: wellWidth, height: wellHeight)
        // Inset inside the well so the text is not flush against its edge, and tall enough that a
        // 13pt line keeps its descenders.
        field.frame = fieldBackground.frame.insetBy(dx: 8, dy: 3)
        x += wellWidth + gap
        readout.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: readoutWidth, height: 14)
        x += readoutWidth + gap
        for control in [scope, previous, next, close] {
            control.frame = NSRect(x: x, y: (bounds.height - button) / 2, width: button, height: button)
            x += button + gap
        }
    }

    // MARK: - Events

    /// Whether the search covers every tab.
    private(set) var searchesAllTabs = false
    private var lastPalette: Palette?

    @objc private func toggleScope() {
        searchesAllTabs.toggle()
        scope.state = searchesAllTabs ? .on : .off
        if let lastPalette { updateScopeTint(palette: lastPalette) }
        onScopeChange?(searchesAllTabs)
    }

    /// The toggle is the one control here with a state, so it says so in colour rather than only in
    /// the pressed look, which is nearly invisible on a borderless button.
    private func updateScopeTint(palette: Palette) {
        lastPalette = palette
        scope.contentTintColor = searchesAllTabs
            ? nsColor(palette.cursor, alpha: 1)
            : nsColor(palette.foreground, alpha: 0.8)
        scope.toolTip = searchesAllTabs ? "Searching every tab" : "Search every tab"
    }

    @objc private func stepForward() { onStep?(true) }
    @objc private func stepBackward() { onStep?(false) }
    @objc private func dismiss() { onClose?() }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    /// The field editor turns keys into these selectors: `⏎` steps forwards, `⇧⏎` backwards (the
    /// standard binding for it is `insertNewlineIgnoringFieldEditor:`), `⎋` closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(true)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertBacktab(_:)):
            onStep?(false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
