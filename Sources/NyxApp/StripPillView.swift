import AppKit
import NyxCore

/// One control on the hover strip: a 20 pt pill with a 6 pt radius, a label or an 8 pt path glyph,
/// and its own hover, pressed and on art.
///
/// Not an `NSButton`. An `.inline` bezel's hovered art is AppKit's own tracking and is unreachable
/// without a window -- which is why the round had no hovered strip picture at all -- and its
/// pressed art moves 11/255 on a dark theme, which is not a press anybody sees. Drawing the pill
/// here makes every state a value this view holds, so `StateSnapshot` can render it and a person
/// can see it.
final class StripPillView: NSView {
    static let height: CGFloat = 20
    static let radius: CGFloat = 6
    static let glyphPillWidth: CGFloat = 24
    static let glyphWidth: CGFloat = 8
    static let labelPadding: CGFloat = 16
    static let chevronGap: CGFloat = 4
    static let gap: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// The two shapes a pill draws as a path. `CommandBlockChrome.Pill.Glyph` names only the one
    /// Core has an opinion about (`⋯`, which *replaces* a label); the `▾` is a decoration this view
    /// adds after a title, and giving Core a case nothing ever returns would be a public enum
    /// member with no rule behind it.
    private enum Shape { case ellipsis, chevronDown }

    var onPress: (() -> Void)?
    private(set) var pill: CommandBlockChrome.Pill?
    private var palette = Palette.xtermDefault()
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    /// Back to rest -- `resetInteraction` rather than `prepareForReuse`, which `NSView` already has
    /// from `NSCollectionViewElement`. The views are pooled, so a pill that was hovered or held down as `Copy` must
    /// not come back lit on the next block the pointer lands on -- and the pointer is *not* over a
    /// view that was hidden while it moved, whatever the last `mouseEntered` said. Called by
    /// `BlockHeaderView` whenever a view is hidden, shown again, or moved to another block; doing
    /// it from `configure` alone missed the case that matters, the same pill on a different block.
    func resetInteraction() {
        guard hovered || pressed else { return }
        hovered = false
        pressed = false
        needsDisplay = true
    }

    func configure(_ pill: CommandBlockChrome.Pill, palette: Palette) {
        if pill != self.pill { resetInteraction() }
        guard pill != self.pill || palette != self.palette else { return }
        self.pill = pill
        self.palette = palette
        toolTip = pill.help
        setAccessibilityLabel(pill.accessibilityLabel)
        setAccessibilityHelp(pill.help)
        // A disabled pill reports as disabled rather than as a button that beeps -- the gutter's
        // no-output mark already answers this way, through `press: nil`.
        setAccessibilityEnabled(isEnabled)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// `.copy(enabled: false)` is the one pill that can arrive inert: it draws dimmed, does not
    /// press, and offers no pointing hand.
    private var isEnabled: Bool {
        if case .copy(let enabled) = pill { return enabled }
        return true
    }

    /// `StateSnapshot` presses a pill by name; `NSButton.highlight(true)` has no equivalent here.
    func setPressedForSnapshot(_ pressed: Bool) { self.pressed = pressed; needsDisplay = true }

    /// What one pill measures, without a view to put it in.
    ///
    /// `BlockHeaderView.width(of:font:)` is what `CommandBlockChrome.stripPlacement` chooses a row
    /// from, and it must be the same arithmetic that lays the pill out a frame later -- a strip
    /// measured narrower than it draws begins inside the command's last word.
    static func width(of pill: CommandBlockChrome.Pill) -> CGFloat {
        guard pill.glyph == nil else { return glyphPillWidth }
        var width = ceil((pill.title as NSString).size(withAttributes: [.font: font]).width)
            + labelPadding
        if pill.trailingChevron { width += chevronGap + glyphWidth }
        return width
    }

    override var intrinsicContentSize: NSSize {
        guard let pill else { return NSSize(width: 0, height: StripPillView.height) }
        return NSSize(width: StripPillView.width(of: pill), height: StripPillView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pill else { return }
        var on = false
        if case .lens(_, let lit) = pill { on = lit }
        let enabled = isEnabled
        let box = NSRect(x: 0, y: (bounds.height - StripPillView.height) / 2,
                         width: bounds.width, height: StripPillView.height)
        let path = NSBezierPath(roundedRect: box, xRadius: StripPillView.radius,
                                yRadius: StripPillView.radius)
        // An "on" chip is the accent fill everything else in Nyx uses for "on" (the search bar's
        // scope toggle, a running quick action); the rest are a wash of the theme's own foreground,
        // which reads on every palette because it *is* the palette.
        let ink: RGB
        if on {
            nsColor(palette.accent, alpha: 1).setFill(); path.fill()
            ink = palette.textOn(palette.accent)
        } else {
            // Opaque `background` always -- including where the pill sits over the command's own
            // text, which used to be the one case that got a solid fill. `Stop`'s colour is
            // calibrated to clear 4.5:1 on `background` with no headroom to spare (one-dark:
            // 4.503:1), and a translucent wash of the row's hover-tinted band underneath it spent
            // that headroom: gruvbox-dark's `Stop` read at 2.82:1 hovered
            // (`ReadableColourTests.theStripsUnlitPillsAreReadableInEveryTheme`). The wash is now
            // purely the hover/press cue on top of that solid ground; idle draws none.
            nsColor(palette.background, alpha: 1).setFill(); path.fill()
            let alpha: CGFloat = pressed ? 0.26 : (hovered ? 0.20 : 0)
            if alpha > 0 { nsColor(palette.foreground, alpha: alpha).setFill(); path.fill() }
            // 0.30, not the old 0.22: against an opaque `background` ground, 0.22 tops out at
            // 1.29:1 in every theme -- a straight `RGB.blend` line from any ground to `foreground`
            // cannot clear 1.6 at a 0.08 step, so this was never a tuning problem. 0.30 is the
            // smallest alpha that clears 1.6:1 everywhere.
            nsColor(palette.foreground, alpha: 0.30).setStroke()
            path.lineWidth = 1
            path.stroke()
            ink = enabled ? tint(of: pill) : palette.noteForeground
        }
        if pill.glyph != nil {
            draw(.ellipsis, in: NSRect(x: box.midX - StripPillView.glyphWidth / 2,
                                       y: box.midY - StripPillView.glyphWidth / 2,
                                       width: StripPillView.glyphWidth,
                                       height: StripPillView.glyphWidth), colour: ink)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: StripPillView.font,
                                                         .foregroundColor: nsColor(ink, alpha: 1)]
        let size = (pill.title as NSString).size(withAttributes: attributes)
        var x = box.minX + StripPillView.labelPadding / 2
        (pill.title as NSString).draw(at: NSPoint(x: x, y: box.midY - size.height / 2),
                                      withAttributes: attributes)
        x += ceil(size.width)
        if pill.trailingChevron {
            draw(.chevronDown,
                 in: NSRect(x: x + StripPillView.chevronGap,
                            y: box.midY - StripPillView.glyphWidth / 2,
                            width: StripPillView.glyphWidth, height: StripPillView.glyphWidth),
                 colour: ink)
        }
    }

    /// `Stop` is the one pill with a running side effect and keeps the theme's own red; everything
    /// else is the foreground. Through `SummaryTone`, so gruvbox-dark's 2.82:1 cannot recur.
    private func tint(of pill: CommandBlockChrome.Pill) -> RGB {
        if case .stop = pill { return SummaryTone.failure.color(in: palette) }
        return palette.foreground
    }

    private func draw(_ shape: Shape, in box: NSRect, colour: RGB) {
        nsColor(colour, alpha: 1).setFill()
        switch shape {
        case .chevronDown:
            // The view is flipped, so "down" is `+y`.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: box.minX, y: box.midY - 2))
            path.line(to: NSPoint(x: box.maxX, y: box.midY - 2))
            path.line(to: NSPoint(x: box.midX, y: box.midY + 3))
            path.close()
            path.fill()
        case .ellipsis:
            // Three 2 pt dots across the 8 pt box: a path, not a `⋯` set at 5 pt in a 20 pt pill.
            for offset in [CGFloat(0), 3, 6] {
                NSBezierPath(ovalIn: NSRect(x: box.minX + offset, y: box.midY - 1,
                                            width: 2, height: 2)).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard !isHidden, isEnabled,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    /// A pooled view waiting off the end of the plan is not a control. It keeps its last pill so
    /// the pool can recognise it, so "is there a pill" is not the question -- "is it on the strip"
    /// is.
    override func isAccessibilityElement() -> Bool { !isHidden && pill != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard !isHidden, isEnabled, let onPress else { return false }
        onPress()
        return true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        // No hand over a pill that cannot be pressed: the pointing hand is a promise, and this
        // round exists to make it a true one everywhere.
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
