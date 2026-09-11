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
    private let button = StripButton(title: "Take control", target: nil, action: nil)
    /// The opaque band, **as tall as the terminal row** rather than as tall as this view's frame.
    ///
    /// The frame is `hitRowHeight`, which is 16 pt over a 15.31 pt row at the default font and over
    /// a 12.25 pt one at `line-height = 0.8`. Painted across the frame -- which is what this view
    /// did when its frame grew from one row to the hit floor -- the band covers 0.35 pt of the row
    /// below at the default and 1.9 pt at 0.8, and that row is *not* the one `Pane.render` blanked:
    /// its ascenders are cut off by a sentence. `CommandBlockChrome.stripGroundHeight` exists for
    /// exactly this and `StickyPromptView` obeys it with the same shape -- drawn = `cellHeight`,
    /// hit = `hitRowHeight` (§2.2, applied to this band by D3).
    private let ground = NSView(frame: .zero)
    /// The button's own shape: the fill and the hairline that make it look like something you press.
    ///
    /// Drawn here rather than left to `bezelStyle = .inline`, because the system's fill is a system
    /// colour -- unknowable from the palette, so the hairline that has to clear 3:1 against it
    /// cannot be computed, and measured it left the pill's boundary at 1.09:1 on nyx-light and
    /// 1.20:1 on nyx-dark: "Take control" read as a right-aligned label. It is the only pointer
    /// route to `remote_take_control`, which has no chord, so the shape *is* the cue and the
    /// design's 3:1 floor for a lone cue applies. Same fills and the same hairline rule as the block
    /// strip's unlit pills (`StripPillView`), in the strip's own ground.
    private let pill = StripPillShape(frame: .zero)
    /// What the band *paints*: one terminal row, centred in a frame that is `hitRowHeight` tall.
    private var groundHeight: NSLayoutConstraint!
    /// What is currently shown, so a frame that changes nothing does no layout at all -- this is
    /// updated on every render pass, like the sticky strip. The palette is part of the key: a theme
    /// reload changes no word on the strip, and without it the strip kept the old theme's colours
    /// while everything around it repainted. The cell height is in it because the band's own height
    /// is measured from it: a ⌘+ or a `line-height` reload changes no word and moves the ground.
    private var shown: (text: String, button: String?, palette: Palette, severity: AttachState.Severity,
                        width: CGFloat, font: NSFont, cellHeight: CGFloat)?

    /// The floor the label is held to, and why it is not 4.5.
    ///
    /// The arithmetic runs in sRGB; the layer is painted and captured through a device profile, and
    /// both the band and the text come out lighter than the values set -- the band by more, so the
    /// ratio falls. Aiming at 4.5 measured 4.12:1 in the rendered pixels. This is the floor that
    /// puts the *measured* number above 4.5, which is the only one a person's eyes ever see.
    private static let contrastFloor = 5.4

    /// The pill's height: one point inside `hitRowHeight`'s floor, so the shape never stands outside
    /// the frame that catches its clicks. The system's `.inline` bezel measured 17 pt, which is
    /// taller than the 16 pt frame it sits in at `line-height = 0.8` -- a pill whose top and bottom
    /// point were drawn and not clickable.
    static let buttonHeight: CGFloat = 15

    /// The floor the pill's hairline is *asked* for, and why it is not 3.
    ///
    /// The same gap `contrastFloor` documents: the arithmetic runs in sRGB and the line is painted
    /// and captured through a device profile, so `pillHairline(on: fill, minimum: 3)` put a line in
    /// the pixels that measured **2.50:1** against the fill in both default themes -- a shape at 2.5
    /// where the design asks 3 of a cue that stands alone. 3.6 measured 3.04 on nyx-dark and 2.83 on
    /// nyx-light; this asks for enough that both measure at or above 3 idle (3.23 and 3.03), which
    /// is the only number anybody's eyes see.
    ///
    /// Asking for more would not buy more. `Palette.pillHairline` walks the fill toward `foreground`
    /// in twentieths and stops there, so on the *pressed* fill -- a heavier wash, with less room
    /// left -- the line is already `foreground` itself at this ask and measures 3.03 on nyx-dark and
    /// 2.89 on nyx-light. That is the ceiling of the project's hairline rule rather than a number
    /// this view chose, and it is the state a pointer is holding down.
    static let hairlineFloor = 4.3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        // The label yields; the button never does. A truncating label still defends its intrinsic
        // width at 750, and the strip's own width is only as fixed as its superview's slack allows
        // -- so a sentence too long for a narrow pane was resolved by moving the button *right*,
        // out past the band that is its background: at 300 pt the Close button sat at x=294 in a
        // 300 pt strip. There is nothing to the right of the strip but the terminal grid, and a
        // button with no ground under it is the thing this strip is for.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        ground.wantsLayer = true
        ground.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ground)
        addSubview(pill)
        addSubview(label)

        // No bezel: the fill and the hairline are `pill`'s, in the theme's own colours. `isBordered`
        // rather than a bezel style, because a *bordered* button paints its own rounded fill over
        // anything behind it.
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(buttonPressed)
        // The pill is painted from the button's own pressed state, so the shape and the control
        // cannot disagree about whether a press has landed.
        button.onHighlight = { [weak self] in self?.pill.needsDisplay = true }
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        groundHeight = ground.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            // One point inside the hit frame at every line height, so the shape a person presses is
            // the shape they see. It may stand slightly taller than the row the band paints -- a
            // pill with a hairline is a shape over the grid, not an erasure of it, which is the same
            // licence the block strip's 16 pt pills have over a 13 pt row.
            button.heightAnchor.constraint(equalToConstant: RemoteStripView.buttonHeight),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            ground.centerYAnchor.constraint(equalTo: centerYAnchor),
            groundHeight,
            pill.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            pill.topAnchor.constraint(equalTo: button.topAnchor),
            pill.bottomAnchor.constraint(equalTo: button.bottomAnchor),
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
    /// `cellHeight` is what the band *paints* -- one terminal row -- while its frame stays
    /// `hitRowHeight` tall (§2.2's ruling, applied to this band by D3).
    func update(state: AttachState, palette: Palette, font: NSFont, cellHeight: CGFloat) {
        guard let text = state.stripText else {
            if !isHidden {
                isHidden = true
                shown = nil
                // The sentence goes with the strip. A hidden view is out of the accessibility tree
                // anyway, so this is tidiness rather than a fix -- but the label it kept was the
                // *previous* state's, and a stale sentence on a view is a stale sentence waiting for
                // someone to read it back.
                setAccessibilityLabel(nil)
            }
            return
        }
        // The width and the font are part of the key: which of `stripLabelOptions` fits depends on
        // both, so a window the user has just narrowed and a ⌘+ have to be re-decided even though
        // nothing about the state moved. They are held here rather than read back off the label,
        // which reports a resolved font that need not be the one that was asked for.
        guard shown?.text != text || shown?.button != state.stripButton
                || shown?.palette != palette || shown?.severity != state.severity
                || shown?.width != bounds.width || shown?.font != font
                || shown?.cellHeight != cellHeight else {
            isHidden = false
            return
        }
        shown = (text, state.stripButton, palette, state.severity, bounds.width, font, cellHeight)
        // The same rule the pinned band and the hover strip's ground obey, from the same place: what
        // a one-row band *paints* is one row, whatever its hit frame is.
        groundHeight.constant = max(1, CGFloat(CommandBlockChrome.stripGroundHeight(
            cellHeight: Double(cellHeight))))
        // The pane's theme decides the band, and anything AppKit draws inside it follows the
        // *window's* appearance instead -- so on a light theme under Dark Mode the button's title
        // measured 1.46:1 against its own fill and its bezel disappeared altogether, leaving "Take
        // control" reading as a label. It is the same trap `BlockHeaderView` documents, and the
        // remote strip is the one place it costs a *control*: `remote_take_control` has no chord,
        // so this button is the only pointer route to it.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
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
        // `bandGround`, not `ground`: `ground` is the subview that paints it, and one name for the
        // colour and the view that wears it is how a colour ends up assigned to a frame.
        let bandGround = RGB.blend(band, into: palette.background, amount: 1 - alpha)
        let ink = RGB.readable(warning ? palette.readable(1) : palette.foreground,
                               on: bandGround, towards: palette.foreground,
                               minimum: RemoteStripView.contrastFloor)

        label.textColor = nsColor(ink, alpha: 1)
        // The pill's two fills are §2.3's, in the strip's own ground rather than a block row's:
        // `foreground @ 0.14`, `@ 0.26` pressed, which is the step the unlit strip pills use and the
        // one a press can be seen in. The hairline is what makes the shape a shape, at the design's
        // **3:1** floor for a cue that stands alone rather than the 1.6 an idle strip pill takes --
        // that strip appears under the pointer and this button is the only pointer route to
        // `remote_take_control` there is.
        pill.fill = RGB.blend(bandGround, into: palette.foreground, amount: 0.14)
        pill.pressedFill = RGB.blend(bandGround, into: palette.foreground, amount: 0.26)
        pill.hairline = palette.pillHairline(on: pill.fill,
                                             minimum: RemoteStripView.hairlineFloor)
        pill.pressedHairline = palette.pillHairline(on: pill.pressedFill,
                                                    minimum: RemoteStripView.hairlineFloor)
        pill.isHidden = state.stripButton == nil
        pill.needsDisplay = true
        // `contentTintColor` recolours a symbol image, not a title: a *titled* NSButton paints in
        // the system's `labelColor` unless the title is an attributed string. Eight of the twelve
        // strip states differed between appearances because of those two lines.
        //
        // Resolved against the *pressed* fill, which is the harder of the pill's two grounds in
        // both default themes: the press washes more `foreground` into the ground the title is
        // drawn on, so an ink calibrated for the idle fill measured 3.57:1 on nyx-light the moment
        // the button was held down. One ink for both states, so it is the worse state that sets it.
        //
        // `textOn` rather than `readable(…towards: foreground)`, which is what the label uses: the
        // label's ink starts at `foreground` and is pushed toward `foreground`, so on a light theme
        // -- where `foreground` already clears the floor against the band -- it is never pushed at
        // all, and against the pill's heavier fill it simply measured 3.57:1. `textOn` picks the
        // end it needs and pushes toward black or white, which is the direction that has room.
        let base = palette.textOn(pill.pressedFill)
        let extreme = base.relativeLuminance >= pill.pressedFill.relativeLuminance
            ? RGB(255, 255, 255) : RGB(0, 0, 0)
        let titleInk = RGB.readable(base, on: pill.pressedFill, towards: extreme,
                                    minimum: RemoteStripView.contrastFloor)
        button.attributedTitle = NSAttributedString(
            string: state.stripButton ?? "",
            attributes: [.foregroundColor: nsColor(titleInk, alpha: 1),
                         .font: button.font ?? NSFont.systemFont(ofSize: 10, weight: .medium)])
        // Nothing on the view's own layer: the ground is `ground`'s, one terminal row tall, so a
        // 16 pt frame over a 12.25 pt row cannot paint the rows either side of the one it blanked.
        layer?.backgroundColor = nil
        ground.layer?.backgroundColor = nsColor(bandGround, alpha: 1).cgColor

        // A strip, not a decoration: a screen reader gets the whole sentence including the state
        // the colour is carrying.
        //
        // The group's own label is load-bearing in both shapes: in the three states with no button
        // this view *is* the element and the sentence is only here, and in the eight with one the
        // text field is not vended as a child either, so the words beside the button are only here.
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

    /// Leaf or container, per state -- never both, and never neither.
    ///
    /// It used to answer *both*: an element, role `AXGroup`, vending one child, which is a control a
    /// screen reader can reach twice and describe differently each time. Answering "container,
    /// always" is the other mistake and is worse: three of the eleven strip states have no button
    /// (`attaching`, `reconnecting`, and the live writer carrying only a geometry note), so a view
    /// that is never an element would take "Attaching…", "Reconnecting…" and the geometry note out
    /// of the accessibility tree altogether -- and those are the only three sentences on this strip
    /// that are not also written on a button.
    ///
    /// So: a leaf carrying the whole sentence when there is nothing to press, a container vending
    /// the button when there is. `WorkbenchHintView` is a fair precedent for the
    /// second half only (`WorkbenchHintView.swift:161-165`), because it always has a button.
    override func isAccessibilityElement() -> Bool { !isHidden && button.isHidden }

    override func accessibilityChildren() -> [Any]? {
        isHidden || button.isHidden ? [] : [button]
    }
}

/// The strip's button, with the padding its pill needs and a way to tell the pill about a press.
///
/// `isBordered = false` takes the system's bezel away, and with it the padding a bezel used to put
/// around the title: measured, the title's own bounds. The pill is the button's frame, so the
/// padding has to come from the control itself or the shape is drawn tight against its own letters.
private final class StripButton: NSButton {
    /// Repaint the pill, which draws the pressed fill. `highlight(_:)` does not go through the
    /// `isHighlighted` setter on every path -- the pressed snapshot uses exactly that call -- so both
    /// are overridden and both report.
    var onHighlight: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + StripButton.horizontalPadding, height: base.height)
    }

    /// 7 pt each side of the title, which is what the `.inline` bezel measured out to (71 pt for
    /// "Take control", against 57 pt of glyphs).
    static let horizontalPadding: CGFloat = 14

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { onHighlight?() } }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        onHighlight?()
    }
}

/// One pill: a fill and a hairline, in the palette's own colours.
///
/// A view rather than a layer border, because the fill and the line both have to be resolved against
/// the strip's ground -- `Palette.pillHairline(on:minimum:)` needs the colour it is drawn on, and a
/// system bezel's fill is not a colour this process can name.
private final class StripPillShape: NSView {
    var fill: RGB = RGB(0, 0, 0)
    var pressedFill: RGB = RGB(0, 0, 0)
    var hairline: RGB = RGB(0, 0, 0)
    var pressedHairline: RGB = RGB(0, 0, 0)

    override var isOpaque: Bool { false }
    /// Drawn, not layer-backed: `draw` is where a 1 pt line can be put on the half-pixel so it lands
    /// square on the device grid rather than smeared across three, which is the difference between a
    /// hairline that measures 3:1 and one that measures 2.
    override func draw(_ dirtyRect: NSRect) {
        // The button's own pressed state, read at draw time: one source of truth for which fill this
        // is, whichever route set it.
        let pressed = (superview?.subviews.compactMap { $0 as? NSButton }.first?.isHighlighted) ?? false
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill(
            with: pressed ? pressedFill : fill)
        let line = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius - 0.5, yRadius: radius - 0.5)
        nsColor(pressed ? pressedHairline : hairline, alpha: 1).setStroke()
        line.lineWidth = 1
        line.stroke()
    }
}

private extension NSBezierPath {
    func fill(with colour: RGB) {
        nsColor(colour, alpha: 1).setFill()
        fill()
    }
}
