import AppKit
import NyxCore

/// The pill that appears at the end of a `curl` you have just pasted: `⌘E Workbench`.
///
/// One button and nothing else. It exists because the request workbench is worth nothing if nobody
/// finds it, and the moment somebody would want it -- a wall of quoted `curl` sitting on the
/// command line, about to be edited by counting backslashes -- is the moment to say so. It goes
/// away on its own after `WorkbenchHint.seconds`, on the next key press, or when the line stops
/// being a request; what it says and when it may be shown is `WorkbenchHint` in NyxCore, so the
/// rule is testable and this is layout, colour and a click.
///
/// Drawn over the grid rather than beside it, like `BlockHeaderView` and the sticky strip, for the
/// same reason: the grid is what the shell sized itself to, and a row taken out of it here would
/// resize the session.
final class WorkbenchHintView: NSView {
    /// Pressed. The pane opens the workbench on whatever is on the command line.
    var onPress: (() -> Void)?

    private let button = NSButton(title: "", target: nil, action: nil)
    /// What is currently shown, so a frame that changes nothing does no layout at all -- this is
    /// asked on every render pass. The palette is part of the key for the same reason
    /// `RemoteStripView`'s is: a theme reload changes no word and every colour.
    private var shown: (text: String, palette: Palette)?

    /// The floor the title is held to, and why it is not 4.5: the same measured-versus-computed gap
    /// `RemoteStripView` documents. The arithmetic runs in sRGB and the layer is captured through a
    /// device profile, so aiming at 4.5 lands near 4.1 in the pixels a person actually sees.
    private static let contrastFloor = 5.4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        // The same face as the remote strip's `Take control`: an inline bezel at ten points, which
        // is the size Nyx's floating chrome uses everywhere it sits over a row of the grid.
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = #selector(pressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor,
                                            constant: WorkbenchHintView.horizontalInset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -WorkbenchHintView.horizontalInset),
            // Centred rather than pinned: the pill is exactly one cell row tall, which is shorter
            // than a small button's fitting height, and two required edge constraints on a view
            // shorter than its content break one every frame.
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// While the pill is hidden the pane underneath must get every click, including the one on the
    /// cell it would have covered.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// The pill's width in points for a title, so `CommandBlockChrome.overlayPlacement` can be told
    /// how many columns it is asking for.
    ///
    /// Measured rather than estimated, for the same reason `BlockHeaderView.width` is: the bezel's
    /// own padding is AppKit's, and a guess would be wrong by about the amount that decides whether
    /// the pill covers a character. Cached, because the pane asks on every frame the pill is up and
    /// the answer changes only when the chord or the font does; and it puts the title back, because
    /// `update` skips its work when nothing changed and would otherwise leave the plain measured
    /// string on screen instead of the themed one.
    func width(for text: String) -> CGFloat {
        if let cached = widths[text] { return cached }
        let previous = button.attributedTitle
        button.title = text
        let width = button.intrinsicContentSize.width + WorkbenchHintView.horizontalInset * 2
        button.attributedTitle = previous
        if widths.count >= 8 { widths.removeAll(keepingCapacity: true) }
        widths[text] = width
        return width
    }

    private var widths: [String: CGFloat] = [:]
    private static let horizontalInset: CGFloat = 4

    /// nil hides the pill. Compared before applied: this is called once per frame.
    func update(text: String?, palette: Palette) {
        guard let text, !text.isEmpty else {
            if !isHidden { isHidden = true; shown = nil }
            return
        }
        guard shown?.text != text || shown?.palette != palette else {
            isHidden = false
            return
        }
        shown = (text, palette)
        // The theme's own colours, never the system's: this sits on the terminal's background, and
        // a system label colour on a dark theme under Light Mode is the bug `BlockHeaderView`
        // carries a comment about. Telling the view which appearance it is really in makes the
        // bezel AppKit draws agree with the ground painted behind it.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        // Opaque, and blended here rather than left translucent for the compositor: the title's
        // contrast is computed against this exact colour, and it has to stay readable over a window
        // with `background-opacity` below 1. The accent, because the pill is an offer rather than a
        // warning -- the same colour the remote strip uses when nothing is wrong.
        let ground = RGB.blend(palette.accent, into: palette.background, amount: 0.78)
        let ink = RGB.readable(palette.foreground, on: ground, towards: palette.foreground,
                               minimum: WorkbenchHintView.contrastFloor)
        layer?.backgroundColor = nsColor(ground, alpha: 1).cgColor
        // `contentTintColor` recolours a symbol image, not a title: the title paints in the
        // system's `labelColor` unless it is set as an attributed string.
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: nsColor(ink, alpha: 1),
                         .font: button.font ?? NSFont.systemFont(ofSize: 10, weight: .medium)])
        button.describeForAccessibility("Open this request in the workbench",
                                        help: "Edit the pasted curl as a form: method, parameters, "
                                            + "headers, body.")
        button.toolTip = "Open this request in the workbench"
        isHidden = false
        invalidateIntrinsicContentSize()
    }

    /// Rounded like the pill it is: half of one cell row, which is the height the pane gives it.
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.height, 16) / 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: button.intrinsicContentSize.width + WorkbenchHintView.horizontalInset * 2,
               height: NSView.noIntrinsicMetric)
    }

    @objc private func pressed() { onPress?() }

    /// The button carries the label and the press; a second element for the view around it would
    /// report the same control twice.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? { isHidden ? [] : [button] }
}
