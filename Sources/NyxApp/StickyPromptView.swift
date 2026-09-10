import AppKit
import NyxCore

/// The one-row strip pinned to the top of a pane naming the command whose output fills it.
///
/// Drawn *over* the terminal's top row rather than above it: the grid is what the shell resized
/// itself to, and stealing a row from it to draw chrome would mean every pinned strip resized the
/// session. `Pane.render` blanks the row it covers in the frame it hands the renderer, so the band
/// and the output beneath it cannot print on top of each other -- the row is still in the buffer and
/// still selectable, it is only not *drawn* while something is pinned over it.
///
/// Which command to pin, what the strip reads, what it says to VoiceOver and where its text begins
/// are `StickyPrompt` and `StickyPromptLabel` in NyxCore. What is here is a ground, a divider, an
/// arrow, two labels and a click.
final class StickyPromptView: NSView {
    /// The strip was clicked: scroll to the pinned command's prompt.
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    /// The right-aligned "exit 1 · 8.8s" -- the same summary the hover overlay shows for this
    /// command, so scrolling to it after reading the strip finds the header saying the same thing.
    private let note = NSTextField(labelWithString: "")
    /// The opaque ground and the hairline along its bottom edge, drawn together in one view that is
    /// **as tall as the terminal row** rather than as tall as this view's frame.
    ///
    /// The frame is `hitRowHeight`, which at `line-height = 0.8` is 16 pt over a 13 pt row: the band
    /// overhung its own row by 1.5 pt at each end, so the divider -- pinned to the frame's bottom --
    /// was drawn *through* the row below. At 10× the design review watched it cross the top-left of
    /// a `[` and the upper strokes of `日本語`, in the configuration §8.4 was written for (D3/F6).
    /// §2.2 already ruled on exactly this shape for the gutter mark -- **drawn = `cellHeight`, hit =
    /// `hitRowHeight`** -- so the precedent is two sections earlier in the spec and no new decision
    /// is needed: the band still catches a click aimed at its edge, and paints only the row it
    /// covers and blanked.
    private let band = StickyBandView(frame: .zero)
    /// The leading `↑`, drawn as a path. Before it the band had no bezel, no chevron, no pin and no
    /// divider, and was a click target end to end -- a control that said nothing about being one.
    private let arrow = StickyArrowView(frame: .zero)
    /// The command currently pinned, so an unchanged frame does no work at all. The palette and the
    /// two grid numbers are part of the key: a theme reload, a font change and a resize move them
    /// without changing a word, and a guard that ignored them left the old theme's colours and the
    /// old grid's alignment on screen.
    private var shown: (text: String, summary: String, tone: SummaryTone, palette: Palette,
                        inset: CGFloat, kern: CGFloat, font: NSFont, cellHeight: CGFloat)?
    /// The label's leading constraint, moved to whichever column boundary clears the arrow.
    private var labelLeading: NSLayoutConstraint!
    /// What the band *paints*: one terminal row, centred in a frame that is `hitRowHeight` tall.
    private var bandHeight: NSLayoutConstraint!
    /// `NSTextField` insets its string inside its own frame, and the amount is a property of the
    /// cell and the font -- not of the frame, the string or anything that changes per frame. Asked
    /// once per font: this is on the render path.
    private var fieldInset: (font: NSFont, x: CGFloat)?

    /// The arrow's 8 pt box and the gap after it: the least room the text can begin at, which is
    /// what `StickyPromptLabel.textInset` is asked to clear.
    static let arrowWidth: CGFloat = 8
    static let arrowGap: CGFloat = 6
    static var minimumTextInset: Double { Double(arrowWidth + arrowGap) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        note.lineBreakMode = .byClipping
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        arrow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrow)
        band.translatesAutoresizingMaskIntoConstraints = false
        addSubview(band, positioned: .below, relativeTo: label)

        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                      constant: CGFloat(StickyPromptView.minimumTextInset))
        bandHeight = band.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            labelLeading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: note.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Immediately before the text, whichever column the text landed on: the arrow belongs
            // to the sentence, not to the band's corner.
            arrow.trailingAnchor.constraint(equalTo: label.leadingAnchor,
                                            constant: -StickyPromptView.arrowGap),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: StickyPromptView.arrowWidth),
            arrow.heightAnchor.constraint(equalToConstant: StickyPromptView.arrowWidth),
            band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.centerYAnchor.constraint(equalTo: centerYAnchor),
            bandHeight,
        ])
        // One element, one sentence: the band's two text fields are children, and VoiceOver read
        // the whole sentence and then both fields -- the command line twice and the summary twice.
        setAccessibilityChildren([])
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
    ///
    /// `tone` colours the right-hand note and is not derived from a `failed` flag: a curl that
    /// returned 404 exited 0, so the command did not fail and the response did -- `BlockHeader.tone`
    /// is the one place that distinction is made, and a second flag here would be a second opinion.
    ///
    /// `padding` and `cellWidth` are the pane's own, and only so the text can be put on the column
    /// grid -- `StickyPromptLabel.textInset` for where it starts and `.kern` for every glyph after
    /// that. Nothing else in the band is measured in cells.
    /// `cellHeight` is what the band *paints* -- one terminal row -- while its frame stays
    /// `hitRowHeight` tall (§2.2's ruling, applied to the band by D3).
    func update(text: String?, summary: String, tone: SummaryTone, palette: Palette, font: NSFont,
                padding: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat) {
        guard let text, !text.isEmpty else {
            if !isHidden { isHidden = true; shown = nil }
            return
        }
        // Everything below is inside the unwrap, so `text` is a `String` by the time the label is
        // built and `StickyPromptLabel.accessibilityLabel` never sees an optional. It is already
        // `StickyPromptLabel.text(command:exitStatus:columns:summary:)`'s answer -- the collapsed,
        // cut command line the band draws, with the status in it only when the note is not carrying
        // it -- so the spoken sentence and the drawn one are one string, cut once.
        let inset = textInset(padding: padding, cellWidth: cellWidth, font: font)
        let kern = CGFloat(StickyPromptLabel.kern(cellWidth: Double(cellWidth),
                                                  glyphAdvance: Double(glyphAdvance(of: font))))
        guard shown?.text != text || shown?.summary != summary || shown?.tone != tone
                || shown?.palette != palette || shown?.inset != inset || shown?.kern != kern
                || shown?.font != font || shown?.cellHeight != cellHeight else {
            isHidden = false
            return
        }
        shown = (text, summary, tone, palette, inset, kern, font, cellHeight)
        // The same rule the hover strip's ground obeys, from the same place: what a one-row band
        // *paints* is one row, whatever its hit frame is (§2.2's ruling, D3 for this band).
        bandHeight.constant = max(1, CGFloat(CommandBlockChrome.stripGroundHeight(
            cellHeight: Double(cellHeight))))
        note.stringValue = summary
        note.isHidden = summary.isEmpty
        labelLeading.constant = inset
        // A band that means "this output belongs to that command", and pressing it goes there.
        // "Running command: …" was said of commands that had finished half an hour ago; the whole
        // sentence is decided in Core beside the text the band draws.
        setAccessibilityRole(.button)
        setAccessibilityLabel(StickyPromptLabel.accessibilityLabel(text: text, summary: summary))
        label.font = font
        note.font = font
        // The theme's own colours, never system ones, and the theme's own appearance: this sits on
        // the terminal's background, and a system label colour on a dark theme under Light Mode is
        // the bug the block header already has a comment about.
        //
        // Set through an attributed string rather than `stringValue` + `textColor`, because the
        // kerning has to go on with them: the pane's cell is its font's advance rounded up to whole
        // device pixels, and a plain label drifted that rounding -- half a pixel a character -- out
        // from under the grid.
        label.attributedStringValue = StickyPromptView.attributed(
            text, font: font, colour: nsColor(palette.foreground, alpha: 1), kern: kern)
        // The note follows the block's tone rather than the command line's: `curl` reporting 404
        // exited 0, so the command is not a failure and the response is. It is not kerned: it is a
        // readout at the band's right edge, not a copy of anything in the grid.
        note.textColor = nsColor(tone.color(in: palette), alpha: 1)
        // Opaque, and pinned to the palette's own appearance: `foreground @ 0.10` over live text is
        // why every scrolled composite showed a pinned command and the output beneath it printed on
        // top of each other.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        // Nothing on the view's own layer: the ground is `band`'s, one terminal row tall, so a
        // 16 pt frame over a 13 pt row cannot paint the rows either side of the one it blanked.
        layer?.backgroundColor = nil
        layer?.borderWidth = 0
        band.ground = palette.background
        band.line = palette.foreground
        arrow.colour = palette.foreground
        isHidden = false
    }

    /// Where the text begins, with the field's own inset taken off: `NSTextField` insets its string
    /// inside its frame, so a constraint set to the column's offset put the *field* on the column
    /// and the glyphs two points to the right of it.
    private func textInset(padding: CGFloat, cellWidth: CGFloat, font: NSFont) -> CGFloat {
        let wanted = StickyPromptLabel.textInset(bandLeft: Double(frame.minX), padding: Double(padding),
                                                 cellWidth: Double(cellWidth),
                                                 minimum: StickyPromptView.minimumTextInset)
        return max(CGFloat(StickyPromptView.minimumTextInset), CGFloat(wanted) - fieldInset(for: font))
    }

    /// The field's own text inset, measured once per font on a throwaway cell -- measuring `label`'s
    /// own cell would mean setting its font before the guard above has decided anything.
    private func fieldInset(for font: NSFont) -> CGFloat {
        if let fieldInset, fieldInset.font == font { return fieldInset.x }
        let probe = NSTextField(labelWithString: "M")
        probe.font = font
        let x = probe.cell?.titleRect(forBounds: NSRect(x: 0, y: 0, width: 200, height: 20)).minX ?? 0
        fieldInset = (font, x)
        return x
    }

    /// One glyph's advance in the band's font, measured the way `FontSet` measures the cell's: from
    /// `M`, in points. The difference between the two is what `StickyPromptLabel.kern` closes --
    /// which is only the cell's rounding as long as `font` is the pane's own terminal face, so the
    /// caller passes `Pane.terminalFont` and not the system's mono.
    private func glyphAdvance(of font: NSFont) -> CGFloat {
        ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    private static func attributed(_ text: String, font: NSFont, colour: NSColor,
                                   kern: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // The band is one row and a long command line is longer than it: the tail goes, which is
        // also what `StickyPromptLabel.text`'s own cut assumes has happened to anything past it.
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour,
                                                             .kern: kern,
                                                             .paragraphStyle: paragraph])
    }

    /// Nothing on mouse-down, so the press can be taken back. The band overhangs the rows above and
    /// below it by up to 1.5 pt (`hitRowHeight` over a 13 pt row at `line-height = 0.8`), so a
    /// click aimed at the neighbouring row's edge lands here; dragging off the band before letting
    /// go cancels it, which is what every other button on the platform does.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func isAccessibilityElement() -> Bool { !isHidden }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The band's leading `↑`: an 8 pt path, at `foreground @ 0.55`.
///
/// A path rather than a glyph set in the band's font, for the same reason the strip's `⋯` and `▾`
/// are paths: an arrow set at the terminal's font size inside a 20 pt band measures as "weak
/// because of size" (design §2.7), and this one has to carry the band's only claim to being a
/// control.
private final class StickyArrowView: NSView {
    var colour: RGB = RGB(255, 255, 255) {
        didSet { if colour != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        nsColor(colour, alpha: 0.55).setFill()
        // Unflipped, so "up" is `+y`: a head across the top third and a shaft down the middle.
        let head = NSBezierPath()
        head.move(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        head.line(to: NSPoint(x: bounds.minX, y: bounds.maxY - 4))
        head.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 4))
        head.close()
        head.fill()
        NSBezierPath(rect: NSRect(x: bounds.midX - 0.75, y: bounds.minY,
                                  width: 1.5, height: bounds.height - 4)).fill()
    }
}

/// The band's opaque ground and the hairline along its bottom edge.
///
/// Both drawn rather than constrained, for one reason: the hairline has to be **one device pixel**,
/// snapped to the device pixel grid. A 1 pt-high subview at a fractional y -- and its y *is*
/// fractional, `(hitRowHeight - cellHeight) / 2` is 1.5 pt at `line-height = 0.8` -- rendered as a
/// 3-device-pixel smear whose peak measured 1.86:1 against the background, which is a fuzzy grey
/// band where §2.7 asked for a rule (D3). `backingAlignedRect` puts it on whole pixels, and
/// `convertFromBacking` makes it exactly one of them: 0.5 pt on a Retina display, 1 pt on a 1×
/// one, which is what "1 px" in §2.7 means.
private final class StickyBandView: NSView {
    var ground: RGB = RGB(0, 0, 0) { didSet { if ground != oldValue { needsDisplay = true } } }
    var line: RGB = RGB(255, 255, 255) { didSet { if line != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    /// The band is chrome over the terminal and the *whole* of `StickyPromptView` is the click
    /// target, including the 1.5 pt it overhangs its row by; this subview must not take the point
    /// off its own parent.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        nsColor(ground, alpha: 1).setFill()
        bounds.fill()
        nsColor(line, alpha: 0.20).setFill()
        hairlineAtBottom().fill()
    }

    /// One device pixel along the bottom edge, on the device pixel grid.
    ///
    /// Snapped through the *context's* own transform rather than through
    /// `NSView.backingAlignedRect`: that one asks the view's window for the scale, and the offscreen
    /// snapshot path has no window -- it rounded a half-point rule to nothing and the divider
    /// disappeared from the picture altogether. The graphics context always carries the scale it is
    /// drawing at, so this is right in a window, in a bitmap, and at 1× where one pixel is a whole
    /// point.
    private func hairlineAtBottom() -> NSBezierPath {
        let fallback = NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            return NSBezierPath(rect: fallback)
        }
        // `abs`: this view is flipped, so the context's y scale is negative.
        let onePixel = abs(ctx.convertToUserSpace(CGSize(width: 0, height: 1)).height)
        guard onePixel > 0 else { return NSBezierPath(rect: fallback) }
        let edge = ctx.convertToDeviceSpace(CGPoint(x: bounds.minX, y: bounds.maxY))
        let snapped = ctx.convertToUserSpace(CGPoint(x: edge.x, y: edge.y.rounded())).y
        return NSBezierPath(rect: NSRect(x: bounds.minX, y: snapped - onePixel,
                                         width: bounds.width, height: onePixel))
    }
}
