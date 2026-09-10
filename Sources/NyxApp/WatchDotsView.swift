import AppKit
import NyxCore

/// A watch series' runs as a row of coloured circles, oldest first.
///
/// The one piece of chrome in Nyx that says something a sentence cannot: twelve green dots with one
/// red in the middle is "it flapped once, eleven minutes ago", and no line of text reads that fast.
/// The colours are `SummaryTone`'s, so a dot and the status beside it come from one ladder -- there
/// is no second opinion here about whether a run went well.
///
/// A running run is a **filled accent** dot -- the same "this is the live one" colour the rest of
/// the app uses. It was a hollow amber ring, which shares a hue with `redirect` and, at 6 pt,
/// smudged into the filled dots beside it instead of standing apart from them.
final class WatchDotsView: NSView {
    /// 7 pt on a 10 pt pitch (§2.3). The old 6 pt on an 8 pt pitch put the whole timeline in 238 pt
    /// and read as dirt.
    static let diameter: CGFloat = 7
    static let pitch: CGFloat = 10

    /// What `count` dots measure, for `BlockHeaderView.width(of:font:)` -- which is the number the
    /// strip's row is chosen from, and so must be this view's own arithmetic rather than a second
    /// copy of it.
    static func width(ofDots count: Int) -> CGFloat {
        count <= 0 ? 0 : CGFloat(count) * pitch - (pitch - diameter)
    }

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
        NSSize(width: WatchDotsView.width(ofDots: dots.count), height: WatchDotsView.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - WatchDotsView.diameter) / 2
        for (index, dot) in dots.enumerated() {
            let box = NSRect(x: CGFloat(index) * WatchDotsView.pitch, y: y,
                             width: WatchDotsView.diameter, height: WatchDotsView.diameter)
            // The live run is the accent, not a fourth status colour: `running` and `redirect` come
            // down `SummaryTone` as the same amber, so a hollow ring was the only thing telling
            // them apart -- and at this size a ring is a smudge.
            let colour = dot == .running ? palette.accent : dot.tone.color(in: palette)
            nsColor(colour, alpha: 1).setFill()
            NSBezierPath(ovalIn: box).fill()
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Recent runs" }

    /// The dots as words, because VoiceOver cannot read a colour: "3 ok, 1 failed, 1 running".
    /// Counted rather than listed -- a dozen spoken colours is not a summary of anything.
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
