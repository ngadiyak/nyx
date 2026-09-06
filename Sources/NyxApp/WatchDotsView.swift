import AppKit
import NyxCore

/// A watch series' runs as a row of coloured circles, oldest first.
///
/// The one piece of chrome in Nyx that says something a sentence cannot: twelve green dots with one
/// red in the middle is "it flapped once, eleven minutes ago", and no line of text reads that fast.
/// The colours are `SummaryTone`'s, so a dot and the status beside it come from one ladder -- there
/// is no second opinion here about whether a run went well.
///
/// A running run is drawn hollow rather than in a fourth colour, the same shape the gutter's
/// running mark uses: "in progress" survives being looked at in greyscale, and a colour-blind
/// reader can still tell the run that has not answered yet from the ones that have.
final class WatchDotsView: NSView {
    /// The circle's diameter, in points. The spec's number, and about the height of a lower-case
    /// letter beside it -- larger reads as a bullet list, smaller as dirt on the screen.
    static let diameter: CGFloat = 6
    static let gap: CGFloat = 2

    private var dots: [WatchSeries.Dot] = []
    private var palette = Palette.xtermDefault()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Compared before applied: the strip calls this on every frame it is up.
    func update(dots newDots: [WatchSeries.Dot], palette newPalette: Palette) {
        guard dots != newDots || palette != newPalette else { return }
        dots = newDots
        palette = newPalette
        invalidateIntrinsicContentSize()
        needsDisplay = true
        setAccessibilityValue(WatchDotsView.spoken(dots))
    }

    override var intrinsicContentSize: NSSize {
        guard !dots.isEmpty else { return NSSize(width: 0, height: WatchDotsView.diameter) }
        let pitch = WatchDotsView.diameter + WatchDotsView.gap
        return NSSize(width: CGFloat(dots.count) * pitch - WatchDotsView.gap,
                      height: WatchDotsView.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pitch = WatchDotsView.diameter + WatchDotsView.gap
        let y = (bounds.height - WatchDotsView.diameter) / 2
        for (index, dot) in dots.enumerated() {
            let box = NSRect(x: CGFloat(index) * pitch, y: y,
                             width: WatchDotsView.diameter, height: WatchDotsView.diameter)
            let color = nsColor(dot.tone.color(in: palette), alpha: 1)
            if dot == .running {
                // Inset by half the line width, or the stroke straddles the edge and the ring
                // comes out a pixel wider than every filled dot beside it.
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                color.setStroke()
                ring.stroke()
            } else {
                color.setFill()
                NSBezierPath(ovalIn: box).fill()
            }
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Recent runs" }

    /// The dots as words, because VoiceOver cannot read a colour: "3 ok, 1 failed, 1 running".
    /// Counted rather than listed -- thirty spoken colours is not a summary of anything.
    static func spoken(_ dots: [WatchSeries.Dot]) -> String {
        guard !dots.isEmpty else { return "no runs yet" }
        var parts: [String] = []
        for (count, word) in [(dots.filter { $0 == .success }.count, "ok"),
                              (dots.filter { $0 == .redirect }.count, "redirected"),
                              (dots.filter { $0 == .failure }.count, "failed"),
                              (dots.filter { $0 == .running }.count, "running")]
        where count > 0 {
            parts.append("\(count) \(word)")
        }
        return parts.joined(separator: ", ")
    }
}
