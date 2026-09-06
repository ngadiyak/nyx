import AppKit
import NyxCore

/// The one-line field a `Filter…` or `Find in Body…` lens is typed into, drawn over the block's own
/// command row.
///
/// Not a sheet and not a popover: what is being filtered is the response *underneath*, and a modal
/// that covers it would make the reader type blind. It evaluates on every keystroke -- the lens is
/// a pure function of the exchange and the text, so there is nothing to submit -- and says when the
/// expression is outside the subset, with the way out beside it.
final class LensFieldView: NSView, NSTextFieldDelegate {
    /// Called on every keystroke with the current text.
    var onChange: ((String) -> Void)?
    /// The `Run with jq` button: the expression as typed, for the shell.
    var onRunWithJq: ((String) -> Void)?
    /// `⎋` and the close button. The pane takes the field down for the other reasons a one-line
    /// popover has to go: a click anywhere in the grid, a `clear`, and the block being evicted from
    /// the scrollback. Scrolling does not close it -- it follows the command row it belongs to; see
    /// `Pane.repositionLensField`.
    var onClose: (() -> Void)?

    private let caption = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private let jq = NSButton(title: "Run with jq", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        caption.setAccessibilityElement(false)
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = self
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        jq.bezelStyle = .rounded
        jq.controlSize = .small
        jq.target = self
        jq.action = #selector(runWithJq)
        jq.isHidden = true
        for view in [caption, field, message, jq] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            caption.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            message.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            jq.leadingAnchor.constraint(equalTo: message.trailingAnchor, constant: 8),
            jq.centerYAnchor.constraint(equalTo: message.centerYAnchor),
            jq.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }

    /// `Filter` or `Find`, with whatever was already typed, and the colours of the pane it sits on.
    func show(caption text: String, text existing: String, palette: Palette) {
        // The field's bezel, the `Run with jq` button and `secondaryLabelColor` are drawn by
        // AppKit in the *window's* appearance, while everything else here is painted from the
        // pane's theme. A dark theme under Light Mode therefore gave a white bezel and near-black
        // secondary text on a near-black pane. Telling the view which appearance it is really
        // sitting in makes all of them agree with the theme -- the same line
        // `BlockHeaderView.update` carries, for the same reason.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        caption.stringValue = text
        field.stringValue = existing
        field.placeholderString = text == "Filter" ? ".users[0].name" : "a word in the body"
        layer?.backgroundColor = NSColor(srgbRed: CGFloat(palette.background.r) / 255,
                                         green: CGFloat(palette.background.g) / 255,
                                         blue: CGFloat(palette.background.b) / 255,
                                         alpha: 0.97).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        caption.textColor = NSColor(srgbRed: CGFloat(palette.foreground.r) / 255,
                                    green: CGFloat(palette.foreground.g) / 255,
                                    blue: CGFloat(palette.foreground.b) / 255, alpha: 1)
        setAccessibilityLabel("\(text) the response")
        window?.makeFirstResponder(field)
    }

    /// The sentence under the field when the expression is outside the subset, with the button that
    /// hands the whole thing to a real jq. nil takes both away.
    func setMessage(_ text: String?, offersJq: Bool) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        jq.isHidden = text == nil || !offersJq
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: message.isHidden ? 34 : 58)
    }

    var text: String { field.stringValue }

    func focus() { window?.makeFirstResponder(field) }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    /// `⎋` closes, and `⏎` closes too: there is nothing to submit -- every keystroke has already
    /// been applied -- so the return key means "I am done typing", not "now do it".
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertNewline(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func runWithJq() {
        onRunWithJq?(field.stringValue)
    }
}
