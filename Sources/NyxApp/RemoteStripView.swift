import AppKit
import NyxCore

/// The one-row strip over the top of a remote pane: what the attachment is doing, and the one thing
/// there is to do about it.
///
/// Drawn *over* the terminal's top row rather than above it, exactly like `StickyPromptView` and for
/// the same reason: the grid is the host's, and stealing a row from it here would mean this Mac's
/// window showed one row fewer than the Mac it is mirroring. The row underneath is still in the
/// buffer and still selectable.
///
/// What it says and whether the button is there is `AttachState` in NyxCore -- `stripText` and
/// `stripButton` -- so every state this can be in is decided and tested somewhere a test can reach.
/// What is here is a background, a label, a button and a click.
final class RemoteStripView: NSView {
    /// The "Take control" button was pressed.
    var onTakeControl: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Take control", target: nil, action: nil)
    /// What is currently shown, so a frame that changes nothing does no layout at all -- this is
    /// updated on every render pass, like the sticky strip.
    private var shown: (text: String, button: String?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(takeControlPressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.describeForAccessibility("Take control of this session",
                                        help: "Type into this session; whoever is writing now becomes an observer.")
        addSubview(button)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// While the strip is hidden the pane underneath must get every click, including the one on the
    /// row it would have covered.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// Renders one `AttachState`. A state with no strip text (the live writer -- a tab that is, from
    /// its side, an ordinary terminal) hides the strip entirely.
    func update(state: AttachState, palette: Palette, font: NSFont) {
        guard let text = state.stripText else {
            if !isHidden { isHidden = true; shown = nil }
            return
        }
        guard shown?.text != text || shown?.button != state.stripButton || label.font != font else {
            isHidden = false
            return
        }
        shown = (text, state.stripButton)
        // `stripLabel`, not `stripText`: with the button beside it the whole sentence would say
        // "Take control" twice on one row. The full sentence is what the accessibility label below
        // carries, where there is no button to read.
        label.stringValue = state.stripLabel ?? text
        label.font = font
        button.isHidden = state.stripButton == nil
        if let title = state.stripButton { button.title = title }

        // The theme's own colours, never system ones: this sits on the terminal's background, and a
        // system label colour on a dark theme under Light Mode is the bug the block header already
        // has a comment about.
        label.textColor = nsColor(palette.foreground, alpha: 1)
        button.contentTintColor = nsColor(palette.accentText, alpha: 1)
        layer?.backgroundColor = nsColor(palette.accent, alpha: 0.22).cgColor

        // A strip, not a decoration: a screen reader gets the whole sentence including the state
        // the colour is carrying.
        setAccessibilityRole(.group)
        setAccessibilityLabel("Remote session: \(text)")
        isHidden = false
    }

    @objc private func takeControlPressed() {
        onTakeControl?()
    }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityChildren() -> [Any]? {
        button.isHidden ? [] : [button]
    }
}
