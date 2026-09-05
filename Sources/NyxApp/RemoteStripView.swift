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
    /// The strip's one button was pressed. Which button it was is `AttachState.stripAction`, which
    /// the owner reads: this view draws a title and reports a click.
    var onButton: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Take control", target: nil, action: nil)
    /// What is currently shown, so a frame that changes nothing does no layout at all -- this is
    /// updated on every render pass, like the sticky strip. The palette is part of the key: a theme
    /// reload changes no word on the strip, and without it the strip kept the old theme's colours
    /// while everything around it repainted.
    private var shown: (text: String, button: String?, palette: Palette, severity: AttachState.Severity,
                        width: CGFloat, font: NSFont)?

    /// The floor the label is held to, and why it is not 4.5.
    ///
    /// The arithmetic runs in sRGB; the layer is painted and captured through a device profile, and
    /// both the band and the text come out lighter than the values set -- the band by more, so the
    /// ratio falls. Aiming at 4.5 measured 4.12:1 in the rendered pixels. This is the floor that
    /// puts the *measured* number above 4.5, which is the only one a person's eyes ever see.
    private static let contrastFloor = 5.4

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
        button.action = #selector(buttonPressed)
        button.translatesAutoresizingMaskIntoConstraints = false
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
        // The width and the font are part of the key: which of `stripLabelOptions` fits depends on
        // both, so a window the user has just narrowed and a ⌘+ have to be re-decided even though
        // nothing about the state moved. They are held here rather than read back off the label,
        // which reports a resolved font that need not be the one that was asked for.
        guard shown?.text != text || shown?.button != state.stripButton
                || shown?.palette != palette || shown?.severity != state.severity
                || shown?.width != bounds.width || shown?.font != font else {
            isHidden = false
            return
        }
        shown = (text, state.stripButton, palette, state.severity, bounds.width, font)
        // `stripLabelOptions`, not `stripText`: with the button beside it the whole sentence would
        // say "Take control" twice on one row, and on a narrow window the geometry clause goes
        // rather than the sentence in front of it being cut off mid-word. The full sentence is what
        // the accessibility label below carries, where there is neither a button nor a width.
        label.font = font
        label.stringValue = RemoteStripView.fitting(state.stripLabelOptions,
                                                    width: labelWidth(button: state.stripButton),
                                                    font: font) ?? text
        button.isHidden = state.stripButton == nil
        if let title = state.stripButton { button.title = title }
        // Re-described on every change: the two buttons are two different acts, and a screen reader
        // reading "Take control of this session" over a Close button would be worse than silence.
        switch state.stripAction {
        case .takeControl:
            button.describeForAccessibility("Take control of this session",
                                            help: "Type into this session; whoever is writing now becomes an observer.")
        case .close:
            button.describeForAccessibility("Close this tab",
                                            help: "Nothing more will arrive here. The host's session is not affected.")
        case nil:
            break
        }

        // The theme's own colours, never system ones: this sits on the terminal's background, and a
        // system label colour on a dark theme under Light Mode is the bug the block header already
        // has a comment about.
        //
        // The band's colour carries the severity, the way a block header colours a failed exit
        // status: a session that ended and one that is attaching were otherwise the same picture
        // with different words in it, and the words are the part a person reads last.
        // `readable(1)` rather than `colors[1]` for the same reason `StickyPromptView` uses it --
        // gruvbox's red is 2.7:1 against its own background and unreadable as a line of text.
        let warning = state.severity == .warning
        let band = warning ? palette.readable(1) : palette.accent
        let alpha = warning ? 0.28 : 0.22

        // The band is blended here and painted opaque, rather than painted translucent and left to
        // the compositor. Two reasons, and the second is the one that matters: the label's contrast
        // is computed against this colour, and a band composited by CoreAnimation in its own colour
        // space is a *different* colour from the one the arithmetic saw -- rendering it translucent
        // measured 4.11:1 for a floor of 4.5. It also stops the strip going double-translucent over
        // a window with `background-opacity` below 1, where chrome that says "session ended" should
        // be readable whatever the terminal behind it is doing.
        let ground = RGB.blend(band, into: palette.background, amount: 1 - alpha)
        let ink = RGB.readable(warning ? palette.readable(1) : palette.foreground,
                               on: ground, towards: palette.foreground,
                               minimum: RemoteStripView.contrastFloor)

        label.textColor = nsColor(ink, alpha: 1)
        button.contentTintColor = nsColor(palette.accentText, alpha: 1)
        layer?.backgroundColor = nsColor(ground, alpha: 1).cgColor

        // A strip, not a decoration: a screen reader gets the whole sentence including the state
        // the colour is carrying.
        setAccessibilityRole(.group)
        setAccessibilityLabel("Remote session: \(text)")
        isHidden = false
    }

    /// How much room the label has: the strip minus its margins, minus the button when there is one.
    private func labelWidth(button title: String?) -> CGFloat {
        var available = bounds.width - 12
        if let title, !title.isEmpty {
            button.title = title
            available -= button.intrinsicContentSize.width + 8
        }
        return max(0, available)
    }

    /// The first option that fits, or the last one when none does -- which the label then truncates,
    /// because a strip has to say *something*.
    static func fitting(_ options: [String], width: CGFloat, font: NSFont) -> String? {
        guard let last = options.last else { return nil }
        for option in options {
            let size = (option as NSString).size(withAttributes: [.font: font])
            if size.width <= width { return option }
        }
        return last
    }

    @objc private func buttonPressed() {
        onButton?()
    }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityChildren() -> [Any]? {
        button.isHidden ? [] : [button]
    }
}
