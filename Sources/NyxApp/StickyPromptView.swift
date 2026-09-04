import AppKit
import NyxCore

/// The one-row strip pinned to the top of a pane naming the command whose output fills it.
///
/// Drawn *over* the terminal's top row rather than above it: the grid is what the shell resized
/// itself to, and stealing a row from it to draw chrome would mean every pinned strip resized the
/// session. The row underneath is still there, still in the buffer and still selectable -- it is
/// covered while there is something worth pinning and uncovered the instant there is not, which is
/// the whole reason `Terminal.stickyPrompt` returns nil while the prompt is on screen.
///
/// Which command to pin, and what the strip reads, are `StickyPrompt` and `StickyPromptLabel` in
/// NyxCore. What is here is a background, a label and a click.
final class StickyPromptView: NSView {
    /// The strip was clicked: scroll to the pinned command's prompt.
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    /// The command currently pinned, so an unchanged frame does no work at all.
    private var shown: (text: String, failed: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The strip is chrome over the terminal; while it is hidden the pane underneath must get every
    /// click, including the one on the row it would have covered.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// nil hides the strip. Everything is compared before it is applied: this is called once per
    /// frame, and an unchanged strip must not relayout a text field sixty times a second.
    func update(text: String?, failed: Bool, palette: Palette, font: NSFont) {
        guard let text, !text.isEmpty else {
            if !isHidden { isHidden = true; shown = nil }
            return
        }
        guard shown?.text != text || shown?.failed != failed || label.font != font else {
            isHidden = false
            return
        }
        shown = (text, failed)
        label.stringValue = text
        label.font = font
        // The theme's own red for a failure, its foreground otherwise, over a background lifted
        // just far enough off the terminal's to read as a different surface rather than as text.
        label.textColor = nsColor(failed ? palette.colors[1] : palette.foreground, alpha: 1)
        layer?.backgroundColor = nsColor(palette.foreground, alpha: 0.10).cgColor
        layer?.borderWidth = 0
        isHidden = false
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
